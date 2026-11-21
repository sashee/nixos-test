//! Calendar arithmetic for the timestamps the report prints: GitHub's and crates.io's RFC 3339
//! strings, flake.lock's Unix seconds, and the run's own clock.
//!
//! Hand-rolled (Howard Hinnant's days-from-civil) instead of a date crate: every input is UTC or
//! carries an explicit offset, nothing needs time zones, and every dependency is code that runs
//! with the whole first sandbox stage's access (see sandbox.rs).

pub const DAY: i64 = 86_400;

/// Days since 1970-01-01 for a proleptic Gregorian date.
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Inverse of `days_from_civil`.
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

fn digits(s: &str, range: std::ops::Range<usize>) -> Option<i64> {
    let part = s.get(range)?;
    if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    part.parse().ok()
}

/// Unix seconds for an RFC 3339 timestamp such as `2026-11-21T15:41:47Z` or
/// `2026-10-21T21:05:43.950213+00:00`. Fractional seconds are dropped.
pub fn parse_rfc3339(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    if !matches!(b[10], b'T' | b't' | b' ') {
        return None;
    }
    let (year, month, day) = (digits(s, 0..4)?, digits(s, 5..7)?, digits(s, 8..10)?);
    let (hour, minute, second) = (digits(s, 11..13)?, digits(s, 14..16)?, digits(s, 17..19)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let mut i = 19;
    if b[i] == b'.' {
        i += 1;
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return None;
        }
    }
    let offset = match b.get(i)? {
        b'Z' | b'z' if i + 1 == b.len() => 0,
        sign @ (b'+' | b'-') if i + 6 == b.len() && b[i + 3] == b':' => {
            let magnitude = digits(s, i + 1..i + 3)? * 3600 + digits(s, i + 4..i + 6)? * 60;
            if *sign == b'+' { magnitude } else { -magnitude }
        }
        _ => return None,
    };
    let days = days_from_civil(year, month as u32, day as u32);
    Some(days * DAY + hour * 3600 + minute * 60 + second - offset)
}

/// `YYYY-MM-DD` (UTC).
pub fn format_date(ts: i64) -> String {
    let (y, m, d) = civil_from_days(ts.div_euclid(DAY));
    format!("{y:04}-{m:02}-{d:02}")
}

/// `HH:MM UTC`.
pub fn format_time(ts: i64) -> String {
    let secs = ts.rem_euclid(DAY);
    format!("{:02}:{:02} UTC", secs / 3600, secs % 3600 / 60)
}

/// `YYYY-MM-DD HH:MM UTC`.
pub fn format_datetime(ts: i64) -> String {
    let secs = ts.rem_euclid(DAY);
    format!("{} {:02}:{:02} UTC", format_date(ts), secs / 3600, secs % 3600 / 60)
}

/// Whole days from `from` to `to`, rounded down; negative when `to` is earlier.
pub fn gap_days(from: i64, to: i64) -> i64 {
    (to - from).div_euclid(DAY)
}

/// "today", "1 day ago", "12 days ago". A timestamp in the future (clock skew) reads as today.
pub fn ago(now: i64, ts: i64) -> String {
    match gap_days(ts, now) {
        ..=0 => "today".to_string(),
        1 => "1 day ago".to_string(),
        n => format!("{n} days ago"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_round_trips() {
        for days in [-800_000, -1, 0, 1, 11_016, 20_413, 2_000_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(days_from_civil(2000, 3, 1), 11_017);
    }

    #[test]
    fn parses_github_and_crates_io_timestamps() {
        // flake.lock's lastModified for nixpkgs_2 (f684076) is 1794872590.
        assert_eq!(parse_rfc3339("2026-11-16T23:43:10Z"), Some(1_794_872_590));
        assert_eq!(parse_rfc3339("2026-11-16T23:43:10.950213Z"), Some(1_794_872_590));
        assert_eq!(parse_rfc3339("2026-11-17T00:43:10+01:00"), Some(1_794_872_590));
        assert_eq!(parse_rfc3339("2026-11-16T22:43:10-01:00"), Some(1_794_872_590));
    }

    #[test]
    fn rejects_malformed_timestamps() {
        for bad in ["", "2026-11-16", "2026-11-16T23:43:10", "2026-13-16T23:43:10Z", "2026-11-16T23:43:10Zx",
            "2026-11-16T23:43:10.Z", "+026-11-16T23:43:10Z", "2026-11-16T23:43:10+0100"]
        {
            assert_eq!(parse_rfc3339(bad), None, "{bad}");
        }
    }

    #[test]
    fn formats() {
        assert_eq!(format_date(1_794_872_590), "2026-11-16");
        assert_eq!(format_time(1_794_872_590), "23:43 UTC");
        assert_eq!(format_datetime(1_794_872_590), "2026-11-16 23:43 UTC");
    }

    #[test]
    fn relative_ages() {
        let now = 1_794_872_590;
        assert_eq!(ago(now, now + 10), "today");
        assert_eq!(ago(now, now - DAY + 1), "today");
        assert_eq!(ago(now, now - DAY), "1 day ago");
        assert_eq!(ago(now, now - 12 * DAY - 5), "12 days ago");
        assert_eq!(gap_days(now, now - 1), -1);
    }
}
