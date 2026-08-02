//! Which providers to ask, and whether their answers may be believed.
//!
//! Pure: the whole decision is a function of the sampled provider names, the answers that came
//! back, and the two thresholds. Every rare case this program exists to survive -- one
//! provider silent, one lying, one answering twice from two addresses -- is a table entry in
//! the tests below rather than a VM boot.

/// One successful reading. `provider` is the operator key, `endpoint` the address it came
/// from, so a provider reachable over both IPv4 and IPv6 yields two answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub provider: String,
    pub endpoint: String,
    pub seconds: i64,
}

/// Deterministically pick `count` providers from `names` using `seed`.
///
/// Partial Fisher-Yates over a copy, so the result is a set of *distinct* providers -- drawing
/// with replacement could pick the same operator twice and satisfy "two providers agreed" with
/// one source. Split out from the randomness so the shuffle itself is testable; `main` supplies
/// the seed from /dev/urandom.
pub fn sample(names: &[String], count: usize, seed: u64) -> Vec<String> {
    let mut pool: Vec<String> = names.to_vec();
    let mut state = seed;
    let mut picked = Vec::new();

    while picked.len() < count && !pool.is_empty() {
        // SplitMix64: a few lines, no dependency, and good enough to spread a draw across a
        // four-element pool. Nothing here is security-relevant -- an attacker who can predict
        // the draw still has to compromise both providers it lands on.
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;

        picked.push(pool.remove((z % pool.len() as u64) as usize));
    }

    picked
}

/// Collapse one provider's answers into a single vote.
///
/// A provider reachable on both families answers twice, and those two readings are one
/// source's opinion -- counting them separately would let a single operator satisfy a quorum
/// of two. They must also agree with each other: a provider whose own addresses disagree is
/// either misconfigured or partially impersonated, and neither is something to average over.
///
/// The vote is the latest reading. `Date` is stamped when the response is generated and read
/// some milliseconds later, so the true time is at or after it; the newest reading is the
/// least stale.
fn vote(answers: &[&Answer], tolerance: i64) -> Result<i64, String> {
    let newest = answers.iter().map(|a| a.seconds).max().expect("non-empty");
    let oldest = answers.iter().map(|a| a.seconds).min().expect("non-empty");

    if newest - oldest > tolerance {
        let provider = &answers[0].provider;
        let spread: Vec<String> = answers
            .iter()
            .map(|a| format!("{}={}", a.endpoint, a.seconds))
            .collect();
        return Err(format!(
            "{provider} disagrees with itself across its own addresses by {}s (>{tolerance}s): {}",
            newest - oldest,
            spread.join(" ")
        ));
    }

    Ok(newest)
}

/// Decide what time to believe, or why no time may be believed.
///
/// Every sampled provider must have answered. A missing provider is not outvoted by the ones
/// that did answer: with a sample of two there is nothing left to cross-check against, and a
/// single unchallenged source is exactly what the sampling exists to avoid.
pub fn decide(
    sampled: &[String],
    answers: &[Answer],
    tolerance: i64,
    floor: i64,
) -> Result<i64, String> {
    if sampled.is_empty() {
        return Err("no providers were sampled".to_string());
    }

    let silent: Vec<&str> = sampled
        .iter()
        .filter(|p| !answers.iter().any(|a| &a.provider == *p))
        .map(String::as_str)
        .collect();
    if !silent.is_empty() {
        // Counted from the answers rather than assumed to be one: several providers can fail
        // in the same round, and a message that says "1 of 2" when 2 of 4 failed sends whoever
        // reads it looking for the wrong problem.
        return Err(format!(
            "{} of {} providers gave no usable answer ({}), and the rest are unchallenged, which is not enough to set a clock",
            silent.len(),
            sampled.len(),
            silent.join(", ")
        ));
    }

    let mut votes: Vec<(String, i64)> = Vec::new();
    for provider in sampled {
        let own: Vec<&Answer> = answers.iter().filter(|a| &a.provider == provider).collect();
        votes.push((provider.clone(), vote(&own, tolerance)?));
    }

    let newest = votes.iter().map(|(_, s)| *s).max().expect("non-empty");
    let oldest = votes.iter().map(|(_, s)| *s).min().expect("non-empty");
    if newest - oldest > tolerance {
        let spread: Vec<String> = votes.iter().map(|(p, s)| format!("{p}={s}")).collect();
        return Err(format!(
            "providers disagree by {}s (>{tolerance}s): {}",
            newest - oldest,
            spread.join(" ")
        ));
    }

    if newest < floor {
        return Err(format!(
            "refusing {newest}: earlier than the build-time floor {floor}. Retroactive certificate validation proves a chain was valid at the claimed time, not that the claimed time is now, so a once-valid certificate could otherwise roll this clock backwards"
        ));
    }

    Ok(newest)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FLOOR: i64 = 1_700_000_000;
    const NOW: i64 = 1_800_000_000;

    fn answer(provider: &str, endpoint: &str, seconds: i64) -> Answer {
        Answer {
            provider: provider.to_string(),
            endpoint: endpoint.to_string(),
            seconds,
        }
    }

    fn names(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn two_providers_agreeing_are_accepted() {
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "1.1.1.1", NOW), answer("b", "9.9.9.10", NOW + 3)],
            60,
            FLOOR,
        );
        assert_eq!(got, Ok(NOW + 3), "the newest reading is the least stale");
    }

    #[test]
    fn two_providers_disagreeing_are_rejected() {
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "1.1.1.1", NOW), answer("b", "9.9.9.10", NOW + 3_600)],
            60,
            FLOOR,
        );
        assert!(got.unwrap_err().contains("providers disagree"));
    }

    #[test]
    fn a_silent_provider_blocks_the_decision() {
        let got = decide(&names(&["a", "b"]), &[answer("a", "1.1.1.1", NOW)], 60, FLOOR);
        let message = got.unwrap_err();
        assert!(message.contains("1 of 2 providers"), "{message}");
        assert!(message.contains("(b)"), "{message}");
    }

    #[test]
    fn one_provider_on_two_families_is_one_vote() {
        // The case the spec calls out: cloudflare-ipv4 and cloudflare-ipv6 are one operator,
        // so two answers from them must not satisfy a quorum of two.
        let got = decide(
            &names(&["a", "b"]),
            &[
                answer("a", "1.1.1.1", NOW),
                answer("a", "2606:4700:4700::1111", NOW + 1),
            ],
            60,
            FLOOR,
        );
        assert!(got.unwrap_err().contains("(b)"));
    }

    #[test]
    fn several_silent_providers_are_all_named() {
        // The real failure mode: two of the four configured providers send no Date at all, and
        // a message naming only one of them points at the wrong operator.
        let got = decide(
            &names(&["a", "b", "c", "d"]),
            &[answer("a", "x", NOW), answer("c", "y", NOW)],
            60,
            FLOOR,
        );
        let message = got.unwrap_err();
        assert!(message.contains("2 of 4 providers"), "{message}");
        assert!(message.contains('b') && message.contains('d'), "{message}");
    }

    #[test]
    fn a_provider_contradicting_itself_is_rejected() {
        let got = decide(
            &names(&["a", "b"]),
            &[
                answer("a", "1.1.1.1", NOW),
                answer("a", "2606:4700:4700::1111", NOW + 3_600),
                answer("b", "9.9.9.10", NOW),
            ],
            60,
            FLOOR,
        );
        assert!(got.unwrap_err().contains("a disagrees with itself"));
    }

    #[test]
    fn three_answers_spanning_two_providers_are_accepted() {
        let got = decide(
            &names(&["a", "b"]),
            &[
                answer("a", "1.1.1.1", NOW),
                answer("a", "2606:4700:4700::1111", NOW + 2),
                answer("b", "9.9.9.10", NOW + 1),
            ],
            60,
            FLOOR,
        );
        assert_eq!(got, Ok(NOW + 2));
    }

    #[test]
    fn tolerance_is_inclusive_at_the_boundary() {
        let at = decide(
            &names(&["a", "b"]),
            &[answer("a", "x", NOW), answer("b", "y", NOW + 60)],
            60,
            FLOOR,
        );
        assert_eq!(at, Ok(NOW + 60), "exactly the tolerance still agrees");

        let over = decide(
            &names(&["a", "b"]),
            &[answer("a", "x", NOW), answer("b", "y", NOW + 61)],
            60,
            FLOOR,
        );
        assert!(over.is_err(), "one second past the tolerance does not");
    }

    #[test]
    fn a_time_below_the_floor_is_rejected() {
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "x", FLOOR - 1), answer("b", "y", FLOOR - 1)],
            60,
            FLOOR,
        );
        assert!(got.unwrap_err().contains("floor"));
    }

    #[test]
    fn a_time_exactly_at_the_floor_is_accepted() {
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "x", FLOOR), answer("b", "y", FLOOR)],
            60,
            FLOOR,
        );
        assert_eq!(got, Ok(FLOOR));
    }

    #[test]
    fn unreachable_endpoints_contribute_nothing_rather_than_disagreeing() {
        // An address that never answered produces no Answer at all. As long as the provider
        // was reachable on some other address, the decision stands -- this is what keeps a
        // v4-only host from being blocked by its unreachable IPv6 endpoints.
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "1.1.1.1", NOW), answer("b", "9.9.9.10", NOW)],
            60,
            FLOOR,
        );
        assert_eq!(got, Ok(NOW));
    }

    #[test]
    fn no_answers_at_all_is_rejected() {
        let got = decide(&names(&["a", "b"]), &[], 60, FLOOR);
        assert!(got.is_err());
    }

    #[test]
    fn an_empty_sample_is_rejected() {
        assert!(decide(&[], &[answer("a", "x", NOW)], 60, FLOOR).is_err());
    }

    #[test]
    fn sample_draws_distinct_providers() {
        let pool = names(&["a", "b", "c", "d"]);
        for seed in 0..500u64 {
            let picked = sample(&pool, 2, seed);
            assert_eq!(picked.len(), 2);
            assert_ne!(picked[0], picked[1], "seed {seed} drew one provider twice");
        }
    }

    #[test]
    fn sample_is_deterministic_for_a_seed() {
        let pool = names(&["a", "b", "c", "d"]);
        assert_eq!(sample(&pool, 2, 42), sample(&pool, 2, 42));
    }

    #[test]
    fn sample_reaches_every_provider() {
        // A shuffle that could never draw a given provider would quietly reduce the pool.
        let pool = names(&["a", "b", "c", "d"]);
        let mut seen: Vec<String> = Vec::new();
        for seed in 0..500u64 {
            for name in sample(&pool, 2, seed) {
                if !seen.contains(&name) {
                    seen.push(name);
                }
            }
        }
        assert_eq!(seen.len(), 4, "only reached {seen:?}");
    }

    #[test]
    fn sample_cannot_exceed_the_pool() {
        let pool = names(&["a", "b"]);
        assert_eq!(sample(&pool, 5, 7).len(), 2);
        assert!(sample(&[], 2, 7).is_empty());
    }
}
