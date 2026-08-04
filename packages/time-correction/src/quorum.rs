//! Which providers to ask, and whether their answers may be believed.
//!
//! Pure: the whole decision is a function of the sampled provider names, the answers that came
//! back, and the two thresholds. Every rare case this program exists to survive -- one
//! provider silent, one lying, one answering twice from two addresses -- is a table entry in
//! the tests below rather than a VM boot.

/// One successful reading.
///
/// `operator` is the voting identity: the organisation running the NTS server, not the server
/// itself. lib/nts-servers.nix carries it explicitly because nothing in a hostname says that
/// ptbtime1 and ptbtime2 are one organisation, one failure and one opinion. `endpoint`
/// describes which server and which resolver produced this, for diagnostics only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub operator: String,
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

/// The middle of a set of readings that already agree.
///
/// Deliberately not an extreme. An NTP transmit timestamp has no staleness bias to correct for --
/// it is the server's own send time, early or late only by network delay, in either direction --
/// so there is no reason to prefer the newest or the oldest. The middle is the reading least
/// sensitive to one outlier, and since everything here has already passed the tolerance check,
/// any choice is within tolerance of the truth anyway.
fn middle(mut values: Vec<i64>) -> i64 {
    values.sort_unstable();
    values[values.len() / 2]
}

/// Collapse one operator's answers into a single vote.
///
/// An operator reachable more than one way answers more than once, and those readings are one
/// source's opinion -- counting them separately would let a single operator satisfy a quorum of
/// two. They must also agree with each other: an operator whose own endpoints disagree is
/// either misconfigured or partially impersonated, and neither is something to average over.
fn vote(answers: &[&Answer], tolerance: i64) -> Result<i64, String> {
    let newest = answers.iter().map(|a| a.seconds).max().expect("non-empty");
    let oldest = answers.iter().map(|a| a.seconds).min().expect("non-empty");

    if newest - oldest > tolerance {
        let provider = &answers[0].operator;
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

    Ok(middle(answers.iter().map(|a| a.seconds).collect()))
}

/// Decide what time to believe, or why no time may be believed.
///
/// Every sampled operator must have answered. A missing one is not outvoted by the ones that
/// did: with a sample of two there is nothing left to cross-check against, and a single
/// unchallenged source is exactly what the sampling exists to avoid.
///
/// Why an operator can be missing is deliberately not summarised here. Resolution failing, key
/// establishment being refused and an NTP packet failing authentication are three different
/// operational faults, and each is reported by the caller at the point it happened; folding
/// them into one sentence would lose the only part worth acting on.
///
/// The caller refuses the run outright when any pair failed, so the silent-operator branch below
/// is unreachable from `main::run`. It stays because this function's contract is "every sampled
/// operator must have answered", and a function that quietly returned a time from half a sample
/// would be the wrong thing for any future caller to be handed.
///
/// The build-time floor is NOT checked here. It applies to each set's own reported timestamp,
/// before that timestamp is used to re-verify any certificate chain, so it lives in
/// `main::ask_pair`; applying it to the agreed time as well would only re-check a bound already
/// enforced on every input to the agreement.
pub fn decide(sampled: &[String], answers: &[Answer], tolerance: i64) -> Result<i64, String> {
    if sampled.is_empty() {
        return Err("no providers were sampled".to_string());
    }

    let silent: Vec<&str> = sampled
        .iter()
        .filter(|p| !answers.iter().any(|a| &a.operator == *p))
        .map(String::as_str)
        .collect();
    if !silent.is_empty() {
        // Counted from the answers rather than assumed to be one: several providers can fail
        // in the same round, and a message that says "1 of 2" when 2 of 4 failed sends whoever
        // reads it looking for the wrong problem.
        return Err(format!(
            "{} of {} operators gave no usable answer ({}), and the rest are unchallenged, which is not enough to set a clock",
            silent.len(),
            sampled.len(),
            silent.join(", ")
        ));
    }

    let mut votes: Vec<(String, i64)> = Vec::new();
    for provider in sampled {
        let own: Vec<&Answer> = answers.iter().filter(|a| &a.operator == provider).collect();
        votes.push((provider.clone(), vote(&own, tolerance)?));
    }

    let newest = votes.iter().map(|(_, s)| *s).max().expect("non-empty");
    let oldest = votes.iter().map(|(_, s)| *s).min().expect("non-empty");
    if newest - oldest > tolerance {
        let spread: Vec<String> = votes.iter().map(|(p, s)| format!("{p}={s}")).collect();
        return Err(format!(
            "operators disagree by {}s (>{tolerance}s): {}",
            newest - oldest,
            spread.join(" ")
        ));
    }

    Ok(middle(votes.iter().map(|(_, s)| *s).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn answer(operator: &str, endpoint: &str, seconds: i64) -> Answer {
        Answer {
            operator: operator.to_string(),
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
        );
        // The middle of two is the upper of the pair after sorting; what matters is that it is
        // one of the readings and inside the tolerance, not which extreme it is.
        assert_eq!(got, Ok(NOW + 3));
    }

    #[test]
    fn two_providers_disagreeing_are_rejected() {
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "1.1.1.1", NOW), answer("b", "9.9.9.10", NOW + 3_600)],
            60,
        );
        assert!(got.unwrap_err().contains("operators disagree"));
    }

    #[test]
    fn a_silent_provider_blocks_the_decision() {
        let got = decide(&names(&["a", "b"]), &[answer("a", "1.1.1.1", NOW)], 60);
        let message = got.unwrap_err();
        assert!(message.contains("1 of 2 operators"), "{message}");
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
        );
        assert!(got.unwrap_err().contains("(b)"));
    }

    #[test]
    fn several_silent_providers_are_all_named() {
        // Two of the four sampled operators never answered, and a message naming only one of
        // them points at the wrong operator.
        let got = decide(
            &names(&["a", "b", "c", "d"]),
            &[answer("a", "x", NOW), answer("c", "y", NOW)],
            60,
        );
        let message = got.unwrap_err();
        assert!(message.contains("2 of 4 operators"), "{message}");
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
        );
        assert_eq!(got, Ok(NOW + 2));
    }

    #[test]
    fn tolerance_is_inclusive_at_the_boundary() {
        let at = decide(
            &names(&["a", "b"]),
            &[answer("a", "x", NOW), answer("b", "y", NOW + 60)],
            60,
        );
        assert_eq!(at, Ok(NOW + 60), "exactly the tolerance still agrees");

        let over = decide(
            &names(&["a", "b"]),
            &[answer("a", "x", NOW), answer("b", "y", NOW + 61)],
            60,
        );
        assert!(over.is_err(), "one second past the tolerance does not");
    }

    // The floor's own fixtures are not here any more: it is applied per set in
    // `main::ask_pair`, against each provider's own reported timestamp, so `decide` never sees
    // a time the floor would refuse. `main::floor_rejects_a_time_before_it` covers the rule and
    // tests/time-correction.nix covers the message a real provider produces.

    #[test]
    fn unreachable_endpoints_contribute_nothing_rather_than_disagreeing() {
        // An address that never answered produces no Answer at all. As long as the provider
        // was reachable on some other address, the decision stands -- this is what keeps a
        // v4-only host from being blocked by its unreachable IPv6 endpoints.
        let got = decide(
            &names(&["a", "b"]),
            &[answer("a", "1.1.1.1", NOW), answer("b", "9.9.9.10", NOW)],
            60,
        );
        assert_eq!(got, Ok(NOW));
    }

    #[test]
    fn the_middle_is_used_rather_than_an_extreme() {
        // Three operators spread across the tolerance: the answer must be the middle reading,
        // so one operator drifting toward the edge cannot drag the result with it.
        let got = decide(
            &names(&["a", "b", "c"]),
            &[
                answer("a", "x", NOW - 20),
                answer("b", "y", NOW),
                answer("c", "z", NOW + 20),
            ],
            60,
        );
        assert_eq!(got, Ok(NOW));
    }

    #[test]
    fn no_answers_at_all_is_rejected() {
        let got = decide(&names(&["a", "b"]), &[], 60);
        assert!(got.is_err());
    }

    #[test]
    fn an_empty_sample_is_rejected() {
        assert!(decide(&[], &[answer("a", "x", NOW)], 60).is_err());
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
