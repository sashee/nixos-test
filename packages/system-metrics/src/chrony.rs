//! Parsers for `chronyc -c` output -- the CSV rendering of `sources` and `authdata`.
//!
//! chronyd already polls every configured source every 64-1024 seconds and keeps the result, so
//! reading this costs one unix-socket round trip and no network traffic at all. That is the whole
//! reason the time half of this feature is cheap: nothing here probes anything, it reads an
//! opinion chrony has already formed.
//!
//! Three properties of `-c` decide the shape of everything below, and each of them is silent when
//! got wrong:
//!
//!   * `-N` is required, or the name column is the *resolved address*. `time.cloudflare.com` is
//!     anycast and `nts.netnod.se` a ten-way round-robin (see lib/nts-servers.nix), so without it
//!     the series key churns on every roam and a provider's history is scattered across addresses.
//!   * `-a` is required, or a source whose hostname does not resolve is absent from the output
//!     entirely -- so the record vanishes exactly when the provider is most broken, which reads
//!     as a configuration change rather than an outage.
//!   * "never" is `(uint32_t)-1`, printed verbatim in CSV mode. See `interval_seconds`.
//!
//! As everywhere else in this crate the parsing is pure and the process spawning lives in
//! `main.rs`.

/// chrony's "there is no such moment", for the interval-valued columns.
///
/// Human-readable mode renders this as `-` (`print_seconds` in chrony's client.c); CSV mode does
/// not, because `-c` remaps the interval conversion to a plain unsigned decimal. Read as a number
/// it is 4294967295 seconds, i.e. 136 years -- which is how "this server has never completed
/// NTS-KE" would otherwise land in a store that has no retention.
const NEVER_SECONDS: u64 = u32::MAX as u64;

/// An interval column: seconds, or `None` for chrony's never-sentinel.
pub fn interval_seconds(raw: &str) -> Option<u64> {
    match raw.trim().parse::<u64>().ok()? {
        NEVER_SECONDS => None,
        seconds => Some(seconds),
    }
}

/// The reachability register, printed as an OCTAL number.
///
/// `sources` formats it with `%3o` and the CSV mode does not remap `o`, so `377` on the wire is
/// 255 in the store. A decimal parse is correct for `0` and `1` and wrong for everything between,
/// which means the bug only appears once a provider is *partially* reachable -- the one state
/// this record exists to see.
pub fn parse_reach(raw: &str) -> Option<u8> {
    u8::from_str_radix(raw.trim(), 8).ok()
}

/// chrony's single-character selection state, spelled out.
///
/// Translated rather than passed through because `*` and `?` are one keystroke apart and carry the
/// most important distinction on the host; a punctuation character is not something to read off a
/// dashboard at a glance.
pub fn state_name(raw: &str) -> Option<&'static str> {
    Some(match raw.trim() {
        "*" => "selected",
        "+" => "combined",
        "-" => "selectable",
        "x" => "falseticker",
        "~" => "jittery",
        "?" => "unselectable",
        _ => return None,
    })
}

/// The authentication mechanism column, spelled out for the same reason as `state_name` -- chrony
/// writes "authentication is disabled" as `-`, which is indistinguishable from a missing field.
pub fn auth_mode_name(raw: &str) -> Option<&'static str> {
    Some(match raw.trim() {
        "NTS" => "nts",
        "SK" => "symmetric",
        "-" => "none",
        _ => return None,
    })
}

/// chrony reports the poll interval as a base-2 logarithm, and it can be negative: converting here
/// means no consumer has to know that, and `f64` rather than an integer because `minpoll -6` is a
/// perfectly legal 15.6ms.
pub fn poll_seconds(raw: &str) -> Option<f64> {
    raw.trim().parse::<i32>().ok().map(|log2| 2f64.powi(log2))
}

fn fields(line: &str) -> Vec<&str> {
    line.split(',').collect()
}

/// One row of `chronyc -c -N sources -a`.
///
/// Fields, in the order chrony's format string emits them (`%c%c %*s %2d %2d %3o %I %+S[%+S] +/- %S`):
/// mode, state, name, stratum, poll, reach, last-rx, offset adjusted, offset measured, root
/// distance. Only what this producer reports is kept.
#[derive(Debug, Clone, PartialEq)]
pub struct Source {
    pub name: String,
    pub state: Option<&'static str>,
    pub stratum: Option<i64>,
    pub poll_seconds: Option<f64>,
    pub reach: Option<u8>,
    pub last_rx_seconds: Option<u64>,
    pub offset_seconds: Option<f64>,
}

pub fn parse_sources(text: &str) -> Vec<Source> {
    text.lines()
        .filter_map(|line| {
            let f = fields(line);
            // Through the adjusted offset. A row shorter than that is not a source row -- chronyc
            // prints nothing else on stdout, but a truncated read should drop the line rather
            // than index past the end of it.
            if f.len() < 8 {
                return None;
            }
            Some(Source {
                name: f[2].trim().to_owned(),
                state: state_name(f[1]),
                stratum: f[3].trim().parse().ok(),
                poll_seconds: poll_seconds(f[4]),
                reach: parse_reach(f[5]),
                last_rx_seconds: interval_seconds(f[6]),
                // Index 7 is the offset adjusted for slews applied since the measurement, which is
                // the number chrony itself prints to the left of the brackets; index 8 is the raw
                // measurement.
                offset_seconds: f[7].trim().parse().ok(),
            })
        })
        .collect()
}

/// One row of `chronyc -c -N authdata -a`.
///
/// `key_id` is not an identifier despite the name: with NTS it starts at zero and increments on
/// every successful key establishment, so it counts them.
#[derive(Debug, Clone, PartialEq)]
pub struct AuthData {
    pub name: String,
    pub mode: Option<&'static str>,
    pub key_id: Option<i64>,
    pub last_ke_seconds: Option<u64>,
    pub ke_attempts: Option<i64>,
    pub naks: Option<i64>,
    pub cookies: Option<i64>,
}

pub fn parse_authdata(text: &str) -> Vec<AuthData> {
    text.lines()
        .filter_map(|line| {
            let f = fields(line);
            // Through the cookie count at index 8; the cookie length after it is not reported.
            if f.len() < 9 {
                return None;
            }
            Some(AuthData {
                name: f[0].trim().to_owned(),
                mode: auth_mode_name(f[1]),
                key_id: f[2].trim().parse().ok(),
                last_ke_seconds: interval_seconds(f[5]),
                ke_attempts: f[6].trim().parse().ok(),
                naks: f[7].trim().parse().ok(),
                cookies: f[8].trim().parse().ok(),
            })
        })
        .collect()
}

/// A configured NTS provider: the key this fleet knows it by, the hostname chrony knows it by, and
/// the organisation that runs it.
///
/// None of the three comes out of chrony. `-N` yields the hostname from chrony's own configuration
/// (`ptbtime1.ptb.de`), never the key (`ptb1`), and `operator` is not a chrony concept at any
/// level -- it exists because the quorum rule counts organisations rather than hostnames, and two
/// PTB machines are one failure. All of it lives in lib/nts-servers.nix and arrives here as
/// `--nts-provider`, the same `NAME=HOSTNAME@OPERATOR` spelling packages/time-correction takes.
#[derive(Debug, Clone, PartialEq)]
pub struct Provider {
    pub name: String,
    pub hostname: String,
    pub operator: String,
}

pub fn parse_provider(spec: &str) -> Result<Provider, String> {
    let (name, rest) = spec
        .split_once('=')
        .ok_or_else(|| format!("nts provider {spec:?} is not NAME=HOSTNAME@OPERATOR"))?;
    let (hostname, operator) = rest
        .split_once('@')
        .ok_or_else(|| format!("nts provider {spec:?} has nothing after @"))?;
    if name.is_empty() || hostname.is_empty() || operator.is_empty() {
        return Err(format!("nts provider {spec:?} has an empty component"));
    }
    Ok(Provider {
        name: name.to_owned(),
        hostname: hostname.to_owned(),
        operator: operator.to_owned(),
    })
}

/// Everything reported about one provider.
///
/// Every field is optional and defaults to absent, so a provider chrony said nothing about still
/// produces a record with a stable key set rather than disappearing from the batch.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Status {
    pub reachable: Option<bool>,
    pub reach: Option<u8>,
    pub state: Option<&'static str>,
    pub stratum: Option<i64>,
    pub poll_seconds: Option<f64>,
    pub last_rx_seconds: Option<u64>,
    pub offset_seconds: Option<f64>,
    pub auth_mode: Option<&'static str>,
    pub nts_ke_count: Option<i64>,
    pub nts_ke_attempts: Option<i64>,
    pub nts_last_ke_seconds: Option<u64>,
    pub nts_cookies: Option<i64>,
    pub nts_naks: Option<i64>,
}

/// One status per CONFIGURED provider, in configuration order, joined to chrony's two reports by
/// hostname.
///
/// Driven by the configured list rather than by chrony's output, so the set of records this
/// produces is a property of the fleet's configuration and not of what chronyd felt like
/// reporting. A provider chrony has no row for comes back all-null, which is distinguishable from
/// `reachable: false` and from the record being absent.
///
/// The join is BY NAME and not by row position. `authdata` skips sources that are neither client
/// nor peer (chrony's client.c filters on the source mode), so a single reference clock in
/// `sources` shifts every subsequent row -- and a positional join would then attribute one
/// provider's cookies to the next one along, silently and plausibly.
pub fn statuses(providers: &[Provider], sources: &str, authdata: &str) -> Vec<Status> {
    let sources = parse_sources(sources);
    let authdata = parse_authdata(authdata);

    providers
        .iter()
        .map(|provider| {
            let source = sources.iter().find(|s| s.name == provider.hostname);
            let auth = authdata.iter().find(|a| a.name == provider.hostname);

            Status {
                // Derived here rather than left to the consumer: the raw register is octal and
                // eight bits wide, and "is this server answering at all" should not require
                // anyone to know that.
                reachable: source.and_then(|s| s.reach).map(|reach| reach != 0),
                reach: source.and_then(|s| s.reach),
                state: source.and_then(|s| s.state),
                stratum: source.and_then(|s| s.stratum),
                poll_seconds: source.and_then(|s| s.poll_seconds),
                last_rx_seconds: source.and_then(|s| s.last_rx_seconds),
                offset_seconds: source.and_then(|s| s.offset_seconds),
                auth_mode: auth.and_then(|a| a.mode),
                nts_ke_count: auth.and_then(|a| a.key_id),
                nts_ke_attempts: auth.and_then(|a| a.ke_attempts),
                nts_last_ke_seconds: auth.and_then(|a| a.last_ke_seconds),
                nts_cookies: auth.and_then(|a| a.cookies),
                nts_naks: auth.and_then(|a| a.naks),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim shape of `chronyc -c -N sources -a`: four NTS servers, one of them unreachable and
    /// one never heard from at all. The last row is what `-a` exists for -- a source whose hostname
    /// has not resolved, which chrony reports with an `ID#` identifier when the name lookup has not
    /// succeeded and which is absent entirely without `-a`.
    const SOURCES: &str = "\
^,*,time.cloudflare.com,3,6,377,23,-0.000048829,-0.000049012,0.000431201
^,+,nts.netnod.se,1,6,377,41,0.000102334,0.000101998,0.000622110
^,?,ptbtime1.ptb.de,1,6,0,4294967295,0.000000000,0.000000000,1.000000000
^,?,ptbtime2.ptb.de,0,6,0,4294967295,0.000000000,0.000000000,1.000000000
";

    const AUTHDATA: &str = "\
time.cloudflare.com,NTS,4,15,256,8102,0,0,8,100
nts.netnod.se,NTS,1,15,256,3391,0,0,8,100
ptbtime1.ptb.de,NTS,0,0,0,4294967295,7,0,0,0
ptbtime2.ptb.de,-,0,0,0,4294967295,0,0,0,0
";

    fn providers() -> Vec<Provider> {
        vec![
            parse_provider("cloudflare=time.cloudflare.com@cloudflare").unwrap(),
            parse_provider("netnod=nts.netnod.se@netnod").unwrap(),
            parse_provider("ptb1=ptbtime1.ptb.de@ptb").unwrap(),
            parse_provider("ptb2=ptbtime2.ptb.de@ptb").unwrap(),
        ]
    }

    /// The trap this whole module is shaped around: in CSV mode chrony prints its never-sentinel
    /// as the raw `(uint32_t)-1` instead of the `-` the human-readable output uses. Unmapped, a
    /// server that has never completed NTS-KE reports its last handshake as 136 years ago.
    #[test]
    fn the_never_sentinel_is_absent_rather_than_136_years() {
        assert_eq!(interval_seconds("4294967295"), None);
        assert_eq!(interval_seconds("0"), Some(0));
        assert_eq!(interval_seconds("8102"), Some(8102));
        assert_eq!(interval_seconds(""), None);

        let statuses = statuses(&providers(), SOURCES, AUTHDATA);
        assert_eq!(statuses[2].nts_last_ke_seconds, None, "ptb1 has never established keys");
        assert_eq!(statuses[2].last_rx_seconds, None, "ptb1 has never been heard from");
        assert_eq!(statuses[0].nts_last_ke_seconds, Some(8102));
    }

    /// `%3o`, and CSV mode does not remap `o`. A decimal parse agrees for 0 and 1 and disagrees
    /// for every partially-reachable value, so this only breaks once a provider starts losing
    /// polls -- exactly the state worth seeing.
    #[test]
    fn reach_is_octal() {
        assert_eq!(parse_reach("377"), Some(255));
        assert_eq!(parse_reach("0"), Some(0));
        assert_eq!(parse_reach("1"), Some(1));
        assert_eq!(parse_reach("17"), Some(15));
        // Not an octal number at all: chrony cannot emit this, and guessing would be worse than
        // reporting that the column could not be read.
        assert_eq!(parse_reach("8"), None);
    }

    #[test]
    fn reachable_is_derived_from_the_whole_register() {
        let statuses = statuses(&providers(), SOURCES, AUTHDATA);
        assert_eq!(statuses[0].reachable, Some(true));
        assert_eq!(statuses[0].reach, Some(255));
        assert_eq!(statuses[2].reachable, Some(false), "ptb1 answered none of the last 8 polls");
        assert_eq!(statuses[2].reach, Some(0));
    }

    /// The exponent is signed, and a `minpoll -6` source really does poll faster than once a
    /// second. An integer field would silently floor that to zero.
    #[test]
    fn poll_is_two_to_the_signed_exponent() {
        assert_eq!(poll_seconds("6"), Some(64.0));
        assert_eq!(poll_seconds("10"), Some(1024.0));
        assert_eq!(poll_seconds("-6"), Some(0.015625));
    }

    #[test]
    fn states_and_auth_modes_are_spelled_out() {
        assert_eq!(state_name("*"), Some("selected"));
        assert_eq!(state_name("?"), Some("unselectable"));
        assert_eq!(state_name("x"), Some("falseticker"));
        assert_eq!(auth_mode_name("NTS"), Some("nts"));
        assert_eq!(auth_mode_name("-"), Some("none"));
        assert_eq!(auth_mode_name("?"), None);
    }

    /// `authdata` skips sources that are neither client nor peer, so a reference clock present in
    /// `sources` and missing from `authdata` shifts every later row. Joining positionally would
    /// hand cloudflare's cookie count to netnod -- a wrong answer that looks entirely plausible.
    #[test]
    fn the_two_reports_are_joined_by_name_not_by_row() {
        let sources_with_refclock = format!("#,*,GPS0,0,4,377,11,-0.000000479,-0.000000621,0.000000134\n{SOURCES}");
        let statuses = statuses(&providers(), &sources_with_refclock, AUTHDATA);

        assert_eq!(statuses[0].nts_ke_count, Some(4), "cloudflare's own key count");
        assert_eq!(statuses[1].nts_ke_count, Some(1), "netnod's own key count");
        assert_eq!(statuses[0].reach, Some(255), "the refclock row must not shift the source join");
    }

    /// The NTS signal that moves while the clock is still perfectly fine: key establishment is
    /// failing, cookies are exhausted, but chrony has not given up on the source yet.
    #[test]
    fn a_failing_key_establishment_is_visible_per_provider() {
        let statuses = statuses(&providers(), SOURCES, AUTHDATA);
        assert_eq!(statuses[2].nts_ke_attempts, Some(7));
        assert_eq!(statuses[2].nts_cookies, Some(0));
        assert_eq!(statuses[0].nts_ke_attempts, Some(0));
        assert_eq!(statuses[0].nts_cookies, Some(8));
    }

    /// A provider chrony reported nothing about still gets a record, with every field absent.
    /// Silence and "unreachable" are different facts, and a vanishing row reads as a
    /// configuration change rather than an outage.
    #[test]
    fn a_provider_chrony_never_mentions_is_null_rather_than_missing() {
        let mut providers = providers();
        providers.push(parse_provider("extra=ntp.example.org@example").unwrap());

        let statuses = statuses(&providers, SOURCES, AUTHDATA);
        assert_eq!(statuses.len(), 5, "one record per configured provider, always");
        assert_eq!(statuses[4], Status::default());
        assert_eq!(statuses[4].reachable, None, "not false: chrony said nothing at all");
    }

    #[test]
    fn provider_specs_name_all_three_components() {
        assert_eq!(
            parse_provider("ptb1=ptbtime1.ptb.de@ptb").unwrap(),
            Provider {
                name: "ptb1".to_owned(),
                hostname: "ptbtime1.ptb.de".to_owned(),
                operator: "ptb".to_owned(),
            }
        );
        assert!(parse_provider("ptb1=ptbtime1.ptb.de").is_err());
        assert!(parse_provider("ptbtime1.ptb.de@ptb").is_err());
        assert!(parse_provider("=ptbtime1.ptb.de@ptb").is_err());
        assert!(parse_provider("ptb1=@ptb").is_err());
        assert!(parse_provider("ptb1=ptbtime1.ptb.de@").is_err());
    }

    /// Output that is not a source report at all must contribute nothing rather than panic on an
    /// index past the end of a short row.
    #[test]
    fn short_and_empty_rows_are_skipped() {
        assert_eq!(parse_sources(""), vec![]);
        assert_eq!(parse_sources("506 Cannot talk to daemon\n"), vec![]);
        assert_eq!(parse_authdata("^,*,a,b\n"), vec![]);
    }
}
