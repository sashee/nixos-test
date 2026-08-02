//! Parsing of the HTTP `Date` header into a Unix timestamp.
//!
//! RFC 9110 requires a recipient to accept all three historical formats, so all three are
//! here even though every server in the configured list emits IMF-fixdate. The obsolete forms
//! cost a few lines and are the difference between "the clock could not be established" and a
//! working boot if some middlebox ever rewrites the header.
//!
//! Pure `&str -> i64`, so the awkward cases (two-digit years, out-of-range fields, non-GMT
//! zones) are covered by unit tests rather than by booting a VM.

/// Days from 1970-01-01 to the given civil date, for a proleptic Gregorian calendar.
///
/// Howard Hinnant's `days_from_civil`. Integer-only, valid for any year the header can hold,
/// and notably correct for the 1900/2000 century rule that a naive leap-year test gets wrong.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_adjusted = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_adjusted + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn month_from_name(name: &str) -> Option<i64> {
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    MONTHS.iter().position(|m| *m == name).map(|i| i as i64 + 1)
}

fn number(text: &str) -> Option<i64> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// Days in `month` of `year`, so 31 April and 29 February in a common year are rejected
/// rather than silently rolling over into the next month.
fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        _ => 0,
    }
}

fn assemble(year: i64, month: i64, day: i64, time: &str) -> Option<i64> {
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }

    let mut parts = time.split(':');
    let hour = number(parts.next()?)?;
    let minute = number(parts.next()?)?;
    let second = number(parts.next()?)?;
    if parts.next().is_some() {
        return None;
    }
    // 60 is allowed: RFC 9110 permits a leap second in the header, and rejecting it would
    // turn one second a year into a boot with no clock.
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    Some(days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`.
fn parse_imf(value: &str) -> Option<i64> {
    let (_weekday, rest) = value.split_once(", ")?;
    let fields: Vec<&str> = rest.split(' ').collect();
    if fields.len() != 5 || fields[4] != "GMT" {
        return None;
    }
    if fields[0].len() != 2 {
        return None;
    }
    assemble(
        number(fields[2])?,
        month_from_name(fields[1])?,
        number(fields[0])?,
        fields[3],
    )
}

/// RFC 850: `Sunday, 06-Nov-94 08:49:37 GMT`. The two-digit year is interpreted per RFC 9110:
/// a year that would put the timestamp more than 50 years in the future belongs to the
/// previous century. Applied against a fixed pivot rather than the system clock, because the
/// system clock is precisely what this program does not yet know.
fn parse_rfc850(value: &str) -> Option<i64> {
    let (_weekday, rest) = value.split_once(", ")?;
    let fields: Vec<&str> = rest.split(' ').collect();
    if fields.len() != 3 || fields[2] != "GMT" {
        return None;
    }
    let date: Vec<&str> = fields[0].split('-').collect();
    if date.len() != 3 || date[2].len() != 2 {
        return None;
    }
    let two_digit = number(date[2])?;
    let year = if two_digit >= 70 {
        1900 + two_digit
    } else {
        2000 + two_digit
    };
    assemble(year, month_from_name(date[1])?, number(date[0])?, fields[1])
}

/// asctime: `Sun Nov  6 08:49:37 1994`. The day is space-padded, so consecutive spaces are
/// collapsed before splitting.
fn parse_asctime(value: &str) -> Option<i64> {
    let fields: Vec<&str> = value.split_whitespace().collect();
    if fields.len() != 5 {
        return None;
    }
    assemble(
        number(fields[4])?,
        month_from_name(fields[1])?,
        number(fields[2])?,
        fields[3],
    )
}

/// Parse a `Date` header value into seconds since the Unix epoch.
///
/// No range policy is applied here: a timestamp in 1980 or 2200 parses cleanly. Whether it is
/// acceptable is a decision for the floor check and the quorum, which have the context to
/// explain a rejection.
pub fn parse(value: &str) -> Result<i64, String> {
    let value = value.trim();
    parse_imf(value)
        .or_else(|| parse_rfc850(value))
        .or_else(|| parse_asctime(value))
        .ok_or_else(|| format!("unparseable Date header {value:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The three spellings of the same instant, from RFC 9110 section 5.6.7.
    const EXPECTED: i64 = 784_111_777;

    #[test]
    fn parses_imf_fixdate() {
        assert_eq!(parse("Sun, 06 Nov 1994 08:49:37 GMT"), Ok(EXPECTED));
    }

    #[test]
    fn parses_rfc850() {
        assert_eq!(parse("Sunday, 06-Nov-94 08:49:37 GMT"), Ok(EXPECTED));
    }

    #[test]
    fn parses_asctime() {
        assert_eq!(parse("Sun Nov  6 08:49:37 1994"), Ok(EXPECTED));
    }

    #[test]
    fn tolerates_surrounding_whitespace() {
        assert_eq!(parse("  Sun, 06 Nov 1994 08:49:37 GMT  "), Ok(EXPECTED));
    }

    #[test]
    fn epoch_itself_round_trips() {
        assert_eq!(parse("Thu, 01 Jan 1970 00:00:00 GMT"), Ok(0));
    }

    #[test]
    fn rejects_non_gmt_zone() {
        // A zone this parser silently treated as GMT would shift the clock by hours while
        // looking entirely well-formed.
        assert!(parse("Sun, 06 Nov 1994 08:49:37 CET").is_err());
        assert!(parse("Sun, 06 Nov 1994 08:49:37 +0100").is_err());
    }

    #[test]
    fn rejects_missing_and_empty() {
        assert!(parse("").is_err());
        assert!(parse("   ").is_err());
    }

    #[test]
    fn rejects_bad_month_and_weekday_shape() {
        assert!(parse("Sun, 06 Nov 1994 08:49:37").is_err());
        assert!(parse("Sun, 06 Foo 1994 08:49:37 GMT").is_err());
        assert!(parse("Sun 06 Nov 1994 08:49:37 GMT").is_err());
    }

    #[test]
    fn rejects_out_of_range_fields() {
        assert!(parse("Sun, 06 Nov 1994 24:49:37 GMT").is_err());
        assert!(parse("Sun, 06 Nov 1994 08:60:37 GMT").is_err());
        assert!(parse("Sun, 32 Nov 1994 08:49:37 GMT").is_err());
        assert!(parse("Sun, 00 Nov 1994 08:49:37 GMT").is_err());
        assert!(parse("Sun, 31 Apr 1994 08:49:37 GMT").is_err());
    }

    #[test]
    fn rejects_non_numeric_fields() {
        assert!(parse("Sun, 0x Nov 1994 08:49:37 GMT").is_err());
        assert!(parse("Sun, 06 Nov 199x 08:49:37 GMT").is_err());
        assert!(parse("Sun, 06 Nov 1994 08:49:3x GMT").is_err());
    }

    #[test]
    fn accepts_leap_second() {
        // A rejected leap second would mean one second a year with no usable clock.
        assert!(parse("Sat, 31 Dec 2016 23:59:60 GMT").is_ok());
    }

    #[test]
    fn handles_century_leap_rule() {
        // 2000 is a leap year, 1900 is not -- the case a `year % 4` test gets wrong.
        assert!(parse("Tue, 29 Feb 2000 00:00:00 GMT").is_ok());
        assert!(parse("Thu, 29 Feb 1900 00:00:00 GMT").is_err());
        assert!(parse("Mon, 29 Feb 2100 00:00:00 GMT").is_err());
    }

    #[test]
    fn rfc850_pivots_two_digit_years() {
        // >= 70 is last century, < 70 is this one; both must land on the right side of 2000.
        let seventies = parse("Sunday, 06-Nov-94 08:49:37 GMT").unwrap();
        let twenties = parse("Sunday, 06-Nov-24 08:49:37 GMT").unwrap();
        assert_eq!(seventies, EXPECTED);
        assert!(twenties > 1_700_000_000, "{twenties} should be in the 2020s");
    }

    #[test]
    fn parses_dates_far_from_now() {
        // Parsing is not policy: the floor check rejects these, with a message that explains
        // why. A parse failure here would report the wrong cause.
        assert!(parse("Tue, 01 Jan 1980 00:00:00 GMT").is_ok());
        assert!(parse("Fri, 01 Jan 2200 00:00:00 GMT").is_ok());
    }

    #[test]
    fn known_timestamps_round_trip() {
        // Cross-checked against `date -u -d @<n>`; these are the fixed points that would
        // catch an off-by-one-day error in days_from_civil, which every other test here
        // would happily agree with because they all go through the same function.
        assert_eq!(parse("Fri, 13 Feb 2009 23:31:30 GMT"), Ok(1_234_567_890));
        assert_eq!(parse("Wed, 14 Jul 2038 02:40:00 GMT"), Ok(2_162_688_000));
        assert_eq!(parse("Tue, 19 Jan 2038 03:14:07 GMT"), Ok(2_147_483_647));
    }
}
