//! Reads per-provider DoH health out of dnscrypt-proxy's journal.
//!
//! dnscrypt-proxy has no query interface for this. What it does have is a refresh pass, every
//! `cert_refresh_delay`, that probes EVERY registered server concurrently with a real DoH query
//! and logs one line per success:
//!
//!     [2026-09-17 12:34:56] [INFO] [cloudflare-ipv4] OK (DoH) - rtt: 23ms
//!
//! Failure is the hard half, and the reason this module is shaped the way it is: most failure
//! paths log nothing that names the server. `TLS handshake failed` and the response validation
//! return with no log line at all, "Webserver returned an unexpected response" is logged without
//! the name, and the refresh loop discards the error it was handed. So `ok: false` is never read
//! -- it is DERIVED, from the absence of an OK line for a configured provider in a pass that other
//! providers were observed in.
//!
//! That derivation needs the configured set, which comes from lib/doh-stamps.nix rather than from
//! the log, and it needs a witness that a pass happened at all. A pass is witnessed by at least
//! one success: with no OK lines anywhere in the window there is nothing to distinguish "every
//! provider is down" from "no refresh was due", so every provider reports absent rather than
//! false. That gap is deliberate and is covered elsewhere -- a pool with no live server answers
//! nothing, which connectivity-watchdog sees directly and reboots on.
//!
//! As everywhere else in this crate the parsing is pure and the process spawning lives in
//! `main.rs`.

use std::collections::BTreeMap;

/// How far apart two successes may be and still belong to the same refresh pass.
///
/// A pass is concurrent across all servers (`cert_refresh_concurrency` defaults to 10) and bounded
/// by a couple of multiples of the per-server timeout, so it spans seconds; passes themselves are
/// `cert_refresh_delay` apart, which is hours. Anything between those two scales separates them,
/// and five minutes sits comfortably in the middle of a range that spans three orders of
/// magnitude.
///
/// The ten-second retry dnscrypt-proxy falls back to when the pool is empty cannot collapse two
/// passes into one here, because that state produces no successes at all and passes are built from
/// successes only.
const PASS_GAP_MICROS: u64 = 300 * 1_000_000;

/// dlog writes to stderr with no syslog level prefix, and the unit does not pass `-syslog`, so
/// systemd stamps every line with `SyslogLevel=` -- which defaults to info. NOTICE, INFO and
/// WARNING therefore all arrive at the same journal priority and the severity survives only as
/// this text marker.
const SEVERITIES: [&str; 7] =
    ["DEBUG", "INFO", "NOTICE", "WARNING", "ERROR", "CRITICAL", "FATAL"];

/// One journal entry, reduced to what this module reads.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub at_micros: u64,
    pub message: String,
}

/// `journalctl -o json` output, one JSON object per line.
///
/// The timestamp is journald's `__REALTIME_TIMESTAMP` and NOT the one dlog puts inside the
/// message: that one is local time with no offset and one-second resolution, so it cannot be
/// compared against anything without knowing the host's timezone at the moment it was written.
///
/// Unparseable lines are skipped rather than failing the batch, for the same reason
/// `parse_journal_counts` does it: journald can emit records with binary fields, and one
/// unreadable line is not a reason to lose every other.
pub fn parse_entries(text: &str) -> Vec<Entry> {
    text.lines()
        .filter_map(|line| {
            let entry = serde_json::from_str::<serde_json::Value>(line).ok()?;
            let at_micros = match entry.get("__REALTIME_TIMESTAMP")? {
                serde_json::Value::String(s) => s.parse().ok()?,
                serde_json::Value::Number(n) => n.as_u64()?,
                _ => return None,
            };
            // A MESSAGE can arrive as an array of bytes when it is not valid UTF-8. Nothing this
            // module matches on could be in such a line.
            let message = entry.get("MESSAGE")?.as_str()?.to_owned();
            Some(Entry { at_micros, message })
        })
        .collect()
}

/// Strips dlog's `[<timestamp>] [<SEVERITY>] ` prefix, leaving the message dnscrypt-proxy wrote.
///
/// Both prefixes are optional: dlog omits them entirely when writing to syslog, and matching on
/// their presence would make the parser depend on how the unit happens to be wired. Stops at the
/// provider's own bracket, which is neither a timestamp nor a severity name.
fn strip_dlog_prefix(message: &str) -> &str {
    let mut rest = message.trim_start();
    for _ in 0..2 {
        let Some((inner, tail)) = bracketed(rest) else {
            break;
        };
        let is_severity = SEVERITIES.contains(&inner);
        let is_timestamp =
            inner.starts_with(|c: char| c.is_ascii_digit()) && inner.contains(':');
        if !(is_severity || is_timestamp) {
            break;
        }
        rest = tail.trim_start();
    }
    rest
}

/// Splits a leading `[contents]` off a string, returning the contents and what follows it.
fn bracketed(text: &str) -> Option<(&str, &str)> {
    let end = text.strip_prefix('[')?.find(']')?;
    Some((&text[1..1 + end], &text[end + 2..]))
}

/// `[NAME] OK (DoH) - rtt: NNNms` -> the provider and its round-trip time.
///
/// Anchored on the whole `OK (DoH)` phrase rather than on `OK`, because `OK (ODoH)` is a different
/// protocol and `[NAME] TLS version: ...` fires for the same provider in the same pass.
///
/// Matching must not depend on the severity: the line is logged at NOTICE only on a server's FIRST
/// successful refresh and at INFO every time after. A parser anchored on `[NOTICE]` works
/// perfectly at boot and reports the entire pool dead one refresh interval later.
pub fn parse_ok(message: &str) -> Option<(&str, i64)> {
    let (name, tail) = bracketed(strip_dlog_prefix(message))?;
    let rtt = tail
        .trim_start()
        .strip_prefix("OK (DoH) - rtt:")?
        .trim()
        .strip_suffix("ms")?
        .trim()
        .parse()
        .ok()?;
    Some((name, rtt))
}

/// The two failure shapes that name their server: `[NAME] [URL]: error` from the DoH query itself,
/// and `[NAME]: error` from response unpacking.
///
/// The colon is what separates these from the per-provider lines that are NOT failures --
/// `[NAME] does not support HTTP/2 nor HTTP/3` and `[NAME] TLS version: ...` both continue with a
/// space, and both are logged for servers that go on to work fine.
pub fn parse_failure(message: &str) -> Option<(&str, &str)> {
    let (name, tail) = bracketed(strip_dlog_prefix(message))?;
    if let Some(error) = tail.strip_prefix(':') {
        return Some((name, error.trim()));
    }
    // The URL is deliberately NOT read as a bracket group: a DoH endpoint pinned to an IPv6
    // literal carries its own brackets -- `https://[2001:4860:4860::8888]/dns-query` -- so the
    // first `]` closes the address, not the URL, and half the providers in lib/doh-stamps.nix are
    // stamped v6-only. `]: ` cannot occur inside a URL, which has no spaces in it, so that is the
    // separator and its first occurrence is the right one.
    let rest = tail.trim_start().strip_prefix('[')?;
    let (_url, error) = rest.split_once("]: ")?;
    Some((name, error.trim()))
}

/// Everything reported about one provider for one collection window.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Status {
    pub ok: Option<bool>,
    pub rtt_ms: Option<i64>,
    pub error: Option<String>,
    pub probe_age_seconds: Option<f64>,
    pub last_ok_seconds: Option<f64>,
    pub last_fail_seconds: Option<f64>,
}

/// One refresh pass: the successes observed in it, and the span they covered.
struct Pass {
    start: u64,
    end: u64,
    successes: BTreeMap<String, i64>,
}

/// Groups successes into passes by their spacing in time.
fn passes(observations: &[(u64, String, i64)]) -> Vec<Pass> {
    let mut sorted: Vec<&(u64, String, i64)> = observations.iter().collect();
    sorted.sort_by_key(|(at, _, _)| *at);

    let mut passes: Vec<Pass> = Vec::new();
    for (at, provider, rtt) in sorted {
        match passes.last_mut() {
            Some(pass) if at.saturating_sub(pass.end) <= PASS_GAP_MICROS => {
                pass.end = *at;
                pass.successes.insert(provider.clone(), *rtt);
            }
            _ => passes.push(Pass {
                start: *at,
                end: *at,
                successes: BTreeMap::from([(provider.clone(), *rtt)]),
            }),
        }
    }
    passes
}

/// One status per CONFIGURED provider, in configuration order.
///
/// `ok` is the absence rule: true when the provider succeeded in the most recent pass, false when
/// that pass happened without it, and absent when no pass was observed in the window at all.
///
/// The three time fields describe at most two events, because a pass observes every provider at
/// once: `probe_age_seconds` is the age of the verdict (the last pass), while `last_ok_seconds`
/// and `last_fail_seconds` are the ages of the most recent pass this provider did and did not
/// appear in. They are emitted anyway rather than left to the consumer, because deriving the first
/// from the other two means re-implementing the absence rule in every query.
pub fn statuses(providers: &[String], entries: &[Entry], now_micros: Option<u64>) -> Vec<Status> {
    let configured: Vec<&str> = providers.iter().map(String::as_str).collect();

    let observations: Vec<(u64, String, i64)> = entries
        .iter()
        .filter_map(|entry| {
            let (name, rtt) = parse_ok(&entry.message)?;
            configured.contains(&name).then(|| (entry.at_micros, name.to_owned(), rtt))
        })
        .collect();

    let passes = passes(&observations);
    // A host that cannot read its own clock still knows which providers answered; only the ages
    // become unreportable.
    let age = |then: u64| -> Option<f64> {
        Some(now_micros?.checked_sub(then)? as f64 / 1_000_000.0)
    };

    let Some(last) = passes.last() else {
        // No success anywhere in the window, so nothing witnesses a refresh having run. Reporting
        // every provider as failed here would turn a quiet window into a fleet-wide outage.
        return providers.iter().map(|_| Status::default()).collect();
    };

    providers
        .iter()
        .map(|provider| {
            let ok = last.successes.contains_key(provider);

            let last_ok = passes
                .iter()
                .rev()
                .find(|pass| pass.successes.contains_key(provider))
                .map(|pass| pass.end);
            let last_fail = passes
                .iter()
                .rev()
                .find(|pass| !pass.successes.contains_key(provider))
                .map(|pass| pass.end);

            // Bounded to the last pass, so the reason describes the verdict rather than some
            // earlier one. Widened by the pass gap because a failure can be logged before the
            // first success of its own pass, which is what defines the pass's start.
            let error = entries
                .iter()
                .filter(|entry| {
                    entry.at_micros + PASS_GAP_MICROS >= last.start
                        && entry.at_micros <= last.end + PASS_GAP_MICROS
                })
                .filter_map(|entry| {
                    let (name, error) = parse_failure(&entry.message)?;
                    (name == provider).then(|| (entry.at_micros, error.to_owned()))
                })
                .max_by_key(|(at, _)| *at)
                .map(|(_, error)| error);

            Status {
                ok: Some(ok),
                rtt_ms: last.successes.get(provider).copied(),
                error,
                probe_age_seconds: age(last.end),
                last_ok_seconds: last_ok.and_then(age),
                last_fail_seconds: last_fail.and_then(age),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECOND: u64 = 1_000_000;
    const NOW: u64 = 1_800_000_000 * SECOND;

    fn entry(seconds_ago: u64, message: &str) -> Entry {
        Entry { at_micros: NOW - seconds_ago * SECOND, message: message.to_owned() }
    }

    fn providers() -> Vec<String> {
        ["cloudflare-ipv4", "quad9-ipv4", "google-ipv6"].iter().map(|s| s.to_string()).collect()
    }

    /// A pass in which one provider failed silently: two OK lines, no failure line naming the
    /// third, which is the normal case rather than the exceptional one.
    fn one_pass() -> Vec<Entry> {
        vec![
            entry(3601, "[2026-09-17 11:00:01] [INFO] [cloudflare-ipv4] OK (DoH) - rtt: 23ms"),
            entry(3600, "[2026-09-17 11:00:02] [INFO] [quad9-ipv4] OK (DoH) - rtt: 31ms"),
        ]
    }

    /// The line is NOTICE only on a server's first successful refresh and INFO ever after, so a
    /// parser anchored on either severity works at boot and then silently stops.
    #[test]
    fn both_severities_of_the_success_line_match() {
        assert_eq!(
            parse_ok("[2026-09-17 11:00:01] [NOTICE] [cloudflare-ipv4] OK (DoH) - rtt: 23ms"),
            Some(("cloudflare-ipv4", 23))
        );
        assert_eq!(
            parse_ok("[2026-09-17 15:00:01] [INFO] [cloudflare-ipv4] OK (DoH) - rtt: 105ms"),
            Some(("cloudflare-ipv4", 105))
        );
        // dlog omits both prefixes when it writes to syslog instead of stderr.
        assert_eq!(parse_ok("[quad9-ipv4] OK (DoH) - rtt: 7ms"), Some(("quad9-ipv4", 7)));
    }

    /// Lines that are per-provider, in the same pass, and not successes. `TLS version` in
    /// particular is logged at INFO for every server on every refresh.
    #[test]
    fn near_miss_lines_are_not_successes() {
        assert_eq!(
            parse_ok("[2026-09-17 11:00:01] [INFO] [odoh-target] OK (ODoH) - rtt: 23ms"),
            None
        );
        assert_eq!(
            parse_ok("[2026-09-17 11:00:01] [INFO] [quad9-ipv4] TLS version: 304 - Protocol: h2"),
            None
        );
        assert_eq!(
            parse_ok("[2026-09-17 11:00:01] [WARNING] [quad9-ipv4] does not support HTTP/2 nor HTTP/3"),
            None
        );
        assert_eq!(parse_ok("[2026-09-17 11:00:01] [NOTICE] Sorted latencies:"), None);
    }

    #[test]
    fn the_two_named_failure_shapes_parse_and_the_others_do_not() {
        assert_eq!(
            parse_failure(
                "[2026-09-17 11:00:01] [INFO] [quad9-ipv4] [https://9.9.9.9/dns-query]: dial tcp 9.9.9.9:443: connect: no route to host"
            ),
            Some(("quad9-ipv4", "dial tcp 9.9.9.9:443: connect: no route to host"))
        );
        assert_eq!(
            parse_failure("[2026-09-17 11:00:01] [WARNING] [quad9-ipv4]: dns: overflow unpacking uint16"),
            Some(("quad9-ipv4", "dns: overflow unpacking uint16"))
        );
        // Six of the twelve stamps in lib/doh-stamps.nix are pinned to an IPv6 literal, whose URL
        // carries brackets of its own -- so the first `]` in the line closes the address rather
        // than the URL.
        assert_eq!(
            parse_failure(
                "[2026-09-17 11:00:01] [INFO] [google-ipv6] [https://[2001:4860:4860::8888]/dns-query]: connect: network is unreachable"
            ),
            Some(("google-ipv6", "connect: network is unreachable"))
        );
        // Not failures: both are logged for servers that go on to work.
        assert_eq!(
            parse_failure("[2026-09-17 11:00:01] [WARNING] [quad9-ipv4] does not support HTTP/2 nor HTTP/3"),
            None
        );
        assert_eq!(
            parse_failure("[2026-09-17 11:00:01] [INFO] [quad9-ipv4] TLS version: 304 - Protocol: h2"),
            None
        );
    }

    /// The core derivation: a provider that logged nothing in a pass other providers were seen in
    /// has failed, even though no line anywhere says so.
    #[test]
    fn a_provider_absent_from_an_observed_pass_has_failed() {
        let statuses = statuses(&providers(), &one_pass(), Some(NOW));

        assert_eq!(statuses[0].ok, Some(true));
        assert_eq!(statuses[0].rtt_ms, Some(23));
        assert_eq!(statuses[1].ok, Some(true));
        assert_eq!(statuses[2].ok, Some(false), "google-ipv6 missed a pass the others were in");
        assert_eq!(statuses[2].rtt_ms, None);
        assert_eq!(statuses[2].error, None, "its failure path logged nothing that names it");
    }

    /// With no success anywhere there is nothing to say a refresh even ran, so the whole pool is
    /// unknown rather than failed. A pool that really is empty answers nothing at all, which
    /// connectivity-watchdog sees directly.
    #[test]
    fn a_window_with_no_success_is_unknown_rather_than_a_fleet_wide_failure() {
        let entries = vec![entry(
            60,
            "[2026-09-17 11:59:00] [INFO] [quad9-ipv4] [https://9.9.9.9/dns-query]: context deadline exceeded",
        )];
        let statuses = statuses(&providers(), &entries, Some(NOW));

        assert_eq!(statuses.len(), 3);
        for status in &statuses {
            assert_eq!(status.ok, None);
            assert_eq!(status, &Status::default());
        }
    }

    #[test]
    fn an_empty_window_is_unknown() {
        let statuses = statuses(&providers(), &[], Some(NOW));
        assert_eq!(statuses, vec![Status::default(), Status::default(), Status::default()]);
    }

    /// Two passes four hours apart, with a provider that worked in the first and not the second.
    /// This pins the three time fields against each other: the verdict is as of the second pass,
    /// the last success is the first pass, and the failure is the second.
    #[test]
    fn the_time_fields_separate_the_verdict_from_the_last_success() {
        let mut entries = vec![
            entry(14401, "[INFO] [cloudflare-ipv4] OK (DoH) - rtt: 20ms"),
            entry(14400, "[INFO] [quad9-ipv4] OK (DoH) - rtt: 30ms"),
            entry(14399, "[INFO] [google-ipv6] OK (DoH) - rtt: 40ms"),
        ];
        entries.extend(one_pass());

        let statuses = statuses(&providers(), &entries, Some(NOW));

        assert_eq!(statuses[2].ok, Some(false));
        assert_eq!(statuses[2].probe_age_seconds, Some(3600.0), "the verdict is the later pass");
        assert_eq!(statuses[2].last_ok_seconds, Some(14399.0), "it did work four hours ago");
        assert_eq!(statuses[2].last_fail_seconds, Some(3600.0));

        assert_eq!(statuses[0].ok, Some(true));
        assert_eq!(statuses[0].probe_age_seconds, Some(3600.0));
        assert_eq!(statuses[0].last_ok_seconds, Some(3600.0));
        assert_eq!(statuses[0].last_fail_seconds, None, "it has not missed a pass");
    }

    /// A pass is concurrent, so its lines are seconds apart and must not be split into one pass
    /// per provider -- which would make every provider "the only one in its own pass" and so
    /// never absent from one.
    #[test]
    fn successes_seconds_apart_are_one_pass() {
        let entries = vec![
            entry(3630, "[INFO] [cloudflare-ipv4] OK (DoH) - rtt: 23ms"),
            entry(3600, "[INFO] [quad9-ipv4] OK (DoH) - rtt: 31ms"),
        ];
        let statuses = statuses(&providers(), &entries, Some(NOW));
        assert_eq!(statuses[2].ok, Some(false), "both successes belong to the same pass");
        assert_eq!(statuses[0].last_fail_seconds, None);
    }

    /// When a failure line does name the provider it is reported, bounded to the pass that
    /// produced the current verdict.
    #[test]
    fn a_named_failure_supplies_the_reason_for_the_current_verdict() {
        let mut entries = one_pass();
        entries.push(entry(
            3602,
            "[2026-09-17 11:00:00] [INFO] [google-ipv6] [https://[2001:4860:4860::8888]/dns-query]: connect: network is unreachable",
        ));

        let statuses = statuses(&providers(), &entries, Some(NOW));
        assert_eq!(statuses[2].ok, Some(false));
        assert_eq!(statuses[2].error.as_deref(), Some("connect: network is unreachable"));
        assert_eq!(statuses[0].error, None);
    }

    /// A provider that is no longer configured must not create a record, and its log lines must
    /// not witness a pass on their own.
    #[test]
    fn lines_for_unconfigured_providers_are_ignored() {
        let entries = vec![entry(60, "[INFO] [retired-provider] OK (DoH) - rtt: 12ms")];
        let statuses = statuses(&providers(), &entries, Some(NOW));
        assert_eq!(statuses.len(), 3);
        assert!(statuses.iter().all(|s| s.ok.is_none()));
    }

    /// journald's own timestamp, not the one dlog wrote into the message: that one is local time
    /// with no offset, so a host outside UTC would report ages off by its whole timezone.
    #[test]
    fn entries_take_the_journal_timestamp_not_the_message_one() {
        let parsed = parse_entries(
            r#"{"__REALTIME_TIMESTAMP":"1800000000000000","MESSAGE":"[2026-09-17 13:00:00] [INFO] [quad9-ipv4] OK (DoH) - rtt: 31ms"}
{"__REALTIME_TIMESTAMP":"1800000001000000","MESSAGE":"[2026-09-17 13:00:01] [NOTICE] Sorted latencies:"}
not json
{"MESSAGE":"no timestamp"}
{"__REALTIME_TIMESTAMP":"1800000002000000","MESSAGE":[104,105]}
"#,
        );

        assert_eq!(parsed.len(), 2, "unparseable and incomplete lines are skipped");
        assert_eq!(parsed[0].at_micros, 1_800_000_000 * SECOND);
        assert_eq!(parse_ok(&parsed[0].message), Some(("quad9-ipv4", 31)));
    }
}
