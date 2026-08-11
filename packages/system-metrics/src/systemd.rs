//! Parsers for what `systemctl` and `journalctl` print.
//!
//! The producer shells out rather than speaking D-Bus directly: the properties it needs are a
//! dozen scalars, `systemctl show` renders them as `Key=value` lines, and the alternative is a
//! D-Bus client crate whose closure would dwarf this binary. Unprivileged reads of unit
//! properties are allowed, so the sandbox needs nothing beyond the system bus socket.
//!
//! As everywhere else in this crate, the parsing is pure and the process spawning lives in
//! `main.rs`.

use std::collections::BTreeMap;

/// `systemctl show` output: one `Key=value` per line, values may be empty or contain `=`.
///
/// A `BTreeMap` rather than a `HashMap` only so that a failing test prints its keys in a stable
/// order.
pub fn parse_show_properties(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.to_owned(), value.to_owned()))
        })
        .collect()
}

/// systemd renders "no such timestamp" as `0` and "never going to happen" as `infinity`. Both
/// mean the value is unknown rather than zero seconds ago, which is why this is an `Option`.
///
/// Monotonic properties (`*TimestampMonotonic`, `NextElapseUSecMonotonic`) are plain integers.
pub fn parse_timestamp_micros(raw: &str) -> Option<u64> {
    let raw = raw.trim();
    if raw.is_empty() || raw == "infinity" {
        return None;
    }
    match raw.parse::<u64>().ok()? {
        0 => None,
        micros => Some(micros),
    }
}

/// A *realtime* timestamp property, in seconds since the epoch.
///
/// These do not come back as integers. Despite the `USec` in their names, `systemctl show`
/// formats realtime timestamps for humans -- `LastTriggerUSec=Mon 2026-08-10 11:29:36 UTC` --
/// so the caller asks for `--timestamp=unix`, which renders them as `@1786528827`. Parsing the
/// human form instead would mean carrying a date parser and a timezone assumption.
pub fn parse_unix_timestamp_seconds(raw: &str) -> Option<u64> {
    let raw = raw.trim();
    if raw.is_empty() || raw == "infinity" || raw == "n/a" {
        return None;
    }
    // The `@` prefix is what `--timestamp=unix` produces; accepting a bare integer too costs
    // nothing and keeps this working if a systemd version ever drops the sigil.
    match raw.strip_prefix('@').unwrap_or(raw).parse::<u64>().ok()? {
        0 => None,
        seconds => Some(seconds),
    }
}

/// Seconds between an earlier monotonic timestamp and now, both in microseconds.
///
/// Monotonic rather than wall-clock on purpose: this producer runs on a host whose clock can step
/// by hours once NTP arrives, and a step must not turn "started 5 minutes ago" into a negative
/// number or a decade.
pub fn seconds_since(now_micros: u64, then_micros: u64) -> Option<f64> {
    Some(now_micros.checked_sub(then_micros)? as f64 / 1_000_000.0)
}

/// Seconds from now until a future timestamp; `None` once it is in the past, which is what an
/// already-elapsed timer reports in the window before systemd rearms it.
pub fn seconds_until(now_micros: u64, then_micros: u64) -> Option<f64> {
    Some(then_micros.checked_sub(now_micros)? as f64 / 1_000_000.0)
}

/// Unit names from `systemctl list-units --plain --no-legend`. The first whitespace-separated
/// field is the unit; the rest is LOAD/ACTIVE/SUB/DESCRIPTION and varies by locale.
pub fn parse_unit_names(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|line| line.split_whitespace().next())
        .filter(|name| name.contains('.'))
        .map(str::to_owned)
        .collect()
}

/// Per-unit message counts by severity, for one collection window.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct JournalCounts {
    /// Priority 4.
    pub warning: u64,
    /// Priority 3.
    pub err: u64,
    /// Priority 2 and below -- crit, alert and emerg, which would otherwise fall through
    /// unreported because nothing else counts them.
    pub crit: u64,
}

/// The name a message is attributed to. Kernel messages carry no `_SYSTEMD_UNIT`, and dropping
/// them would hide the single loudest source on the Pi: a flapping USB device once produced
/// ~20k kernel lines in an afternoon while every systemd unit stayed quiet.
const KERNEL_UNIT: &str = "kernel";

/// Counts `journalctl -o json` output, one JSON object per line.
///
/// Lines that do not parse are skipped rather than failing the batch: journald can emit records
/// with binary fields, and one unreadable line is not a reason to lose the counts of every other.
pub fn parse_journal_counts(text: &str) -> BTreeMap<String, JournalCounts> {
    let mut counts: BTreeMap<String, JournalCounts> = BTreeMap::new();

    for line in text.lines() {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        // journald renders PRIORITY as a string, but a caller comparing against a number should
        // not silently get zero matches, so both spellings are accepted.
        let Some(priority) = entry.get("PRIORITY").and_then(|p| match p {
            serde_json::Value::String(s) => s.parse::<u8>().ok(),
            serde_json::Value::Number(n) => n.as_u64().map(|n| n as u8),
            _ => None,
        }) else {
            continue;
        };

        let unit = entry
            .get("_SYSTEMD_UNIT")
            .and_then(|u| u.as_str())
            .map(str::to_owned)
            .unwrap_or_else(|| KERNEL_UNIT.to_owned());

        let entry = counts.entry(unit).or_default();
        match priority {
            0..=2 => entry.crit += 1,
            3 => entry.err += 1,
            4 => entry.warning += 1,
            // journalctl is asked for `-p warning`, which already excludes anything quieter;
            // a notice arriving here would be a caller bug, and counting it as a warning would
            // hide that.
            _ => {}
        }
    }

    counts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn show_output_splits_on_the_first_equals_only() {
        let properties = parse_show_properties(
            "ActiveState=active\nSubState=running\nResult=success\nEnvironment=A=b\nEmpty=\n",
        );
        assert_eq!(properties["ActiveState"], "active");
        assert_eq!(properties["Environment"], "A=b");
        assert_eq!(properties["Empty"], "");
    }

    /// The three spellings of "there is no such timestamp" that were observed on the Pi: an
    /// already-elapsed `OnBootSec` timer reports an empty realtime and a monotonic of `infinity`.
    #[test]
    fn absent_timestamps_are_unknown_rather_than_zero() {
        assert_eq!(parse_timestamp_micros(""), None);
        assert_eq!(parse_timestamp_micros("infinity"), None);
        assert_eq!(parse_timestamp_micros("0"), None);
        assert_eq!(parse_timestamp_micros("1786397627467839"), Some(1786397627467839));
    }

    /// `--timestamp=unix` renders a realtime timestamp as `@<seconds>`; without it the same
    /// property comes back as `Mon 2026-08-10 11:29:36 UTC`, which is not a number and must not
    /// be mistaken for one.
    #[test]
    fn realtime_timestamps_are_read_from_their_unix_rendering() {
        assert_eq!(parse_unix_timestamp_seconds("@1786528827"), Some(1786528827));
        assert_eq!(parse_unix_timestamp_seconds("1786528827"), Some(1786528827));
        assert_eq!(parse_unix_timestamp_seconds(""), None);
        assert_eq!(parse_unix_timestamp_seconds("infinity"), None);
        assert_eq!(parse_unix_timestamp_seconds("n/a"), None);
        assert_eq!(parse_unix_timestamp_seconds("@0"), None);
        assert_eq!(parse_unix_timestamp_seconds("Mon 2026-08-10 11:29:36 UTC"), None);
    }

    #[test]
    fn elapsed_and_remaining_are_none_when_the_sign_would_flip() {
        assert_eq!(seconds_since(5_000_000, 2_000_000), Some(3.0));
        assert_eq!(seconds_since(2_000_000, 5_000_000), None);
        assert_eq!(seconds_until(2_000_000, 5_000_000), Some(3.0));
        assert_eq!(seconds_until(5_000_000, 2_000_000), None);
    }

    #[test]
    fn list_units_takes_the_first_column() {
        let names = parse_unit_names(
            "\
nix-gc.service            loaded active   exited  Nix garbage collector
broken.service            loaded failed   failed  A broken unit
",
        );
        assert_eq!(names, vec!["nix-gc.service", "broken.service"]);
    }

    /// `--no-legend` still prints a trailing blank line and, without `--plain`, a bullet column.
    #[test]
    fn list_units_ignores_lines_that_are_not_unit_rows() {
        assert_eq!(parse_unit_names("\n\n  \n"), Vec::<String>::new());
    }

    #[test]
    fn journal_counts_bucket_by_priority_and_unit() {
        let text = "\
{\"PRIORITY\":\"3\",\"_SYSTEMD_UNIT\":\"a.service\",\"MESSAGE\":\"boom\"}
{\"PRIORITY\":\"3\",\"_SYSTEMD_UNIT\":\"a.service\",\"MESSAGE\":\"boom again\"}
{\"PRIORITY\":\"4\",\"_SYSTEMD_UNIT\":\"a.service\",\"MESSAGE\":\"careful\"}
{\"PRIORITY\":\"2\",\"_SYSTEMD_UNIT\":\"b.service\",\"MESSAGE\":\"critical\"}
{\"PRIORITY\":\"0\",\"_SYSTEMD_UNIT\":\"b.service\",\"MESSAGE\":\"emergency\"}
";
        let counts = parse_journal_counts(text);
        assert_eq!(counts["a.service"], JournalCounts { warning: 1, err: 2, crit: 0 });
        // crit is "priority <= 2", so emerg and alert land here rather than nowhere.
        assert_eq!(counts["b.service"], JournalCounts { warning: 0, err: 0, crit: 2 });
        assert_eq!(counts.len(), 2);
    }

    /// Kernel messages have no `_SYSTEMD_UNIT`, and on the Pi they are the loudest source there
    /// is -- a USB device failing to enumerate produced thousands of them in an hour.
    #[test]
    fn kernel_messages_are_attributed_rather_than_dropped() {
        let counts = parse_journal_counts(
            "{\"PRIORITY\":\"3\",\"_TRANSPORT\":\"kernel\",\"MESSAGE\":\"unable to enumerate\"}\n",
        );
        assert_eq!(counts["kernel"], JournalCounts { warning: 0, err: 1, crit: 0 });
    }

    #[test]
    fn an_unparsable_line_does_not_lose_the_rest_of_the_window() {
        let counts = parse_journal_counts(
            "not json\n{\"PRIORITY\":3,\"_SYSTEMD_UNIT\":\"a.service\"}\n{\"no\":\"priority\"}\n",
        );
        assert_eq!(counts["a.service"], JournalCounts { warning: 0, err: 1, crit: 0 });
        assert_eq!(counts.len(), 1);
    }
}
