//! `iw dev <interface> scan` output parsing.
//!
//! `iw` rather than a manager's own CLI because it is the only tool present under both wireless
//! managers this fleet runs: `iwctl` exists on the Pi and `nmcli` on the laptops, but both iwd and
//! NetworkManager are nl80211 clients and `iw` talks nl80211 directly. Its output is also the only
//! one carrying the information elements -- `iwctl station <dev> get-networks` reduces a BSS to a
//! name, a security word and a signal bar.
//!
//! A scan cannot be replaced by reading the kernel's BSS cache (`iw ... scan dump`) on this fleet:
//! under iwd that cache holds only the associated BSS, because iwd keeps its own list. A
//! wpa_supplicant host does populate it, which is what `wifi_scan.passive` records.
//!
//! Everything here is a pure `&str -> T`; running `iw` lives in `main.rs`.

/// One BSS as `iw` reports it. Every field is optional because `iw` prints only the elements an AP
/// actually advertises, and an AP that omits one is the normal case, not an error.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Bss {
    pub bssid: String,
    pub associated: bool,
    pub ssid: Option<String>,
    pub frequency_mhz: Option<f64>,
    pub channel: Option<i64>,
    pub signal_dbm: Option<f64>,
    pub last_seen_ms: Option<i64>,
    pub beacon_interval_tu: Option<i64>,
    /// Strongest of the security elements present, not a list: an AP advertising both a WPA and an
    /// RSN element is WPA2, and reporting "wpa" for it would understate what a client negotiates.
    pub security: Option<String>,
    pub pairwise_ciphers: Option<String>,
    pub auth_suites: Option<String>,
    pub wps: Option<bool>,
    pub width_mhz: Option<i64>,
    /// Which capability element families appeared, in ascending order: `ht`, `vht`, `he`.
    pub standards: Option<String>,
    pub country: Option<String>,
}

/// Whether a token is a MAC address, i.e. an actual BSSID.
///
/// The check exists because `BSS ` is not a unique prefix in `iw` output: a block's own information
/// elements include `BSS Load:` and, on an HE AP, `BSS Color:`. Treating those as delimiters starts
/// a bogus block whose "bssid" is `Load:` -- and, worse, steals the remaining elements from the real
/// BSS they belong to, so the record before it loses its security and capability fields. Matching on
/// the shape of the value rather than on indentation keeps that independent of `iw`'s layout.
fn looks_like_bssid(token: &str) -> bool {
    let mut octets = 0;
    for part in token.split(':') {
        if part.len() != 2 || !part.bytes().all(|b| b.is_ascii_hexdigit()) {
            return false;
        }
        octets += 1;
    }
    octets == 6
}

/// Splits a scan into BSS blocks and parses each.
///
/// Blocks are delimited by a line starting `BSS `, and everything until the next such line belongs
/// to it. Nested element lines are indented but the indentation is not load-bearing here: the
/// element names are unique enough within a block that matching on the trimmed prefix is both
/// simpler and more tolerant of the layout changing between `iw` versions.
pub fn parse_scan(text: &str) -> Vec<Bss> {
    let mut out: Vec<Bss> = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();

        if let Some(rest) = trimmed.strip_prefix("BSS ") {
            // `BSS aa:bb:cc:dd:ee:ff(on wlan0) -- associated`
            let bssid = rest.split(['(', ' ']).next().unwrap_or("").to_owned();
            if !looks_like_bssid(&bssid) {
                continue;
            }
            out.push(Bss {
                bssid,
                associated: rest.contains("-- associated"),
                ..Default::default()
            });
            continue;
        }

        let Some(bss) = out.last_mut() else {
            continue;
        };

        // `last seen` appears twice per block: once as a boottime stamp and once as an age. Only
        // the age is useful, and it is the one carrying "ms ago".
        if let Some(rest) = trimmed.strip_prefix("last seen: ") {
            if let Some(ms) = rest.strip_suffix(" ms ago") {
                bss.last_seen_ms = ms.trim().parse().ok();
            }
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("SSID: ") {
            // A hidden network advertises a zero-length SSID; `iw` prints the key with nothing
            // after it, which must stay null rather than becoming an empty-string network name.
            let ssid = rest.trim();
            if !ssid.is_empty() {
                bss.ssid = Some(ssid.to_owned());
            }
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("freq: ") {
            bss.frequency_mhz = rest.trim().parse().ok();
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("signal: ") {
            bss.signal_dbm = rest.trim().trim_end_matches(" dBm").trim().parse().ok();
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("beacon interval: ") {
            bss.beacon_interval_tu = rest.trim().trim_end_matches(" TUs").trim().parse().ok();
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("DS Parameter set: channel ") {
            bss.channel = rest.trim().parse().ok();
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Country: ") {
            // The Pi's own AP advertises a malformed code that `iw` renders unprintable; anything
            // that is not two ASCII letters is reported as absent rather than as garbage.
            let code: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
            if code.len() == 2 {
                bss.country = Some(code);
            }
            continue;
        }
        if trimmed.starts_with("RSN:") {
            // RSN is WPA2 unless the auth suites say SAE, which is WPA3. Refined below when the
            // suite line arrives.
            bss.security = Some("wpa2".to_owned());
            continue;
        }
        if trimmed.starts_with("WPA:") {
            // Only downgrade-safe: an AP with both elements has already been marked wpa2 above,
            // and the block order puts WPA first, so this never overwrites RSN.
            if bss.security.is_none() {
                bss.security = Some("wpa".to_owned());
            }
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("* Pairwise ciphers: ") {
            bss.pairwise_ciphers = Some(rest.split_whitespace().collect::<Vec<_>>().join(","));
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("* Authentication suites: ") {
            let suites: Vec<&str> = rest.split_whitespace().collect();
            if suites.contains(&"SAE") {
                bss.security = Some("wpa3".to_owned());
            }
            bss.auth_suites = Some(suites.join(","));
            continue;
        }
        if trimmed.starts_with("WPS:") {
            bss.wps = Some(true);
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("* STA channel width: ") {
            bss.width_mhz = rest.trim().trim_end_matches(" MHz").trim().parse().ok();
            continue;
        }
        if trimmed.starts_with("HT capabilities:") {
            push_standard(bss, "ht");
            continue;
        }
        if trimmed.starts_with("VHT capabilities:") {
            push_standard(bss, "vht");
            continue;
        }
        if trimmed.starts_with("HE capabilities:") {
            push_standard(bss, "he");
            continue;
        }
    }

    // An AP with Privacy set but no RSN/WPA element is WEP; one without either is open. Done after
    // the sweep because the capability line can precede the security elements.
    for bss in &mut out {
        if bss.security.is_none() {
            bss.security = Some("open".to_owned());
        }
    }
    out
}

fn push_standard(bss: &mut Bss, name: &str) {
    match &mut bss.standards {
        Some(existing) => {
            if !existing.split(',').any(|s| s == name) {
                existing.push(',');
                existing.push_str(name);
            }
        }
        None => bss.standards = Some(name.to_owned()),
    }
}

/// Whether an interface can be scanned at all, from `iw dev` output for that interface.
///
/// A radio running the connectivity fallback AP cannot scan: the phy advertises
/// `#{managed} <= 1, #{AP} <= 1 ... #channels <= 1`, so leaving the operating channel would drop
/// the AP. Reported as a skip rather than attempted and failed, because the failure would otherwise
/// look identical to a quiet neighbourhood.
pub fn scan_blocked_reason(iw_dev_output: &str, interface: &str) -> Option<&'static str> {
    let mut in_interface = false;
    for line in iw_dev_output.lines() {
        let trimmed = line.trim();
        if let Some(name) = trimmed.strip_prefix("Interface ") {
            in_interface = name.trim() == interface;
            continue;
        }
        if !in_interface {
            continue;
        }
        if let Some(kind) = trimmed.strip_prefix("type ") {
            return match kind.trim() {
                "managed" => None,
                "AP" => Some("ap-mode"),
                _ => Some("interface-down"),
            };
        }
    }
    Some("interface-down")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Pi's own AP as `iw` printed it, trimmed to the lines this parser reads. Kept verbatim
    /// including the two `last seen` spellings and the unprintable country code, because those are
    /// the shapes that broke naive parsing.
    const REAL_SCAN: &str = "\
BSS 08:3f:bc:ea:39:41(on wlan0) -- associated
\tlast seen: 23960.665s [boottime]
\tTSF: 0 usec (0d, 00:00:00)
\tfreq: 2437.0
\tbeacon interval: 100 TUs
\tcapability: ESS Privacy RadioMeasure (0x1011)
\tsignal: -58.00 dBm
\tlast seen: 0 ms ago
\tSSID: DIGI-01067405
\tSupported rates: 1.0* 2.0* 5.5* 11.0* 18.0 24.0 36.0 54.0
\tDS Parameter set: channel 6
\tCountry: \u{1}a\tEnvironment: Indoor/Outdoor
\tRSN:\t * Version: 1
\t\t * Group cipher: CCMP
\t\t * Pairwise ciphers: CCMP
\t\t * Authentication suites: PSK
\t\t * Capabilities: 16-PTKSA-RC 1-GTKSA-RC (0x000c)
\tHT capabilities:
\t\tCapabilities: 0x199c
\tHT operation:
\t\t * primary channel: 6
\t\t * secondary channel offset: no secondary
\t\t * STA channel width: 20 MHz
\tWPS:\t * Version: 1.0
\t\t * Wi-Fi Protected Setup State: 2 (Configured)
BSS 94:04:e3:80:42:30(on wlan0)
\tfreq: 5180.0
\tsignal: -72.00 dBm
\tlast seen: 120 ms ago
\tSSID: Telekom-103992
\tRSN:\t * Version: 1
\t\t * Pairwise ciphers: CCMP TKIP
\t\t * Authentication suites: PSK SAE
\tHT capabilities:
\tVHT capabilities:
\t\t * STA channel width: 80 MHz
";

    #[test]
    fn the_associated_bss_is_flagged_and_fully_described() {
        let bsses = parse_scan(REAL_SCAN);
        assert_eq!(bsses.len(), 2, "{bsses:?}");
        let a = &bsses[0];
        assert_eq!(a.bssid, "08:3f:bc:ea:39:41");
        assert!(a.associated);
        assert_eq!(a.ssid.as_deref(), Some("DIGI-01067405"));
        assert_eq!(a.frequency_mhz, Some(2437.0));
        assert_eq!(a.channel, Some(6));
        assert_eq!(a.signal_dbm, Some(-58.0));
        assert_eq!(a.beacon_interval_tu, Some(100));
        assert_eq!(a.width_mhz, Some(20));
        assert_eq!(a.standards.as_deref(), Some("ht"));
        assert_eq!(a.security.as_deref(), Some("wpa2"));
        assert_eq!(a.pairwise_ciphers.as_deref(), Some("CCMP"));
        assert_eq!(a.auth_suites.as_deref(), Some("PSK"));
        assert_eq!(a.wps, Some(true));
    }

    #[test]
    fn the_age_is_taken_from_the_ms_spelling_not_the_boottime_stamp() {
        // Both lines start "last seen:"; taking the first would store 23960 as milliseconds.
        assert_eq!(parse_scan(REAL_SCAN)[0].last_seen_ms, Some(0));
        assert_eq!(parse_scan(REAL_SCAN)[1].last_seen_ms, Some(120));
    }

    #[test]
    fn a_malformed_country_code_is_absent_rather_than_garbage() {
        // The real AP advertises an unprintable byte; storing it would put control characters in
        // an attribute the receiver has to hold as text.
        assert_eq!(parse_scan(REAL_SCAN)[0].country, None);
    }

    #[test]
    fn sae_in_the_auth_suites_upgrades_the_verdict_to_wpa3() {
        let b = &parse_scan(REAL_SCAN)[1];
        assert_eq!(b.security.as_deref(), Some("wpa3"));
        assert_eq!(b.auth_suites.as_deref(), Some("PSK,SAE"));
        assert_eq!(b.pairwise_ciphers.as_deref(), Some("CCMP,TKIP"));
    }

    #[test]
    fn capability_families_accumulate_in_order() {
        assert_eq!(parse_scan(REAL_SCAN)[1].standards.as_deref(), Some("ht,vht"));
        assert_eq!(parse_scan(REAL_SCAN)[1].width_mhz, Some(80));
    }

    #[test]
    fn an_ap_with_no_security_element_is_open() {
        let open = parse_scan("BSS aa:bb:cc:dd:ee:ff(on wlan0)\n\tSSID: guest\n");
        assert_eq!(open[0].security.as_deref(), Some("open"));
        assert_eq!(open[0].wps, None);
    }

    #[test]
    fn a_hidden_network_has_a_null_ssid_not_an_empty_one() {
        let hidden = parse_scan("BSS aa:bb:cc:dd:ee:ff(on wlan0)\n\tSSID: \n\tfreq: 2412.0\n");
        assert_eq!(hidden[0].ssid, None);
        assert_eq!(hidden[0].frequency_mhz, Some(2412.0));
    }

    #[test]
    fn bss_information_elements_are_not_bss_delimiters() {
        // `BSS Load:` and `BSS Color:` are elements inside a block. Real output from the Pi: taking
        // them as delimiters produced records whose bssid was "Load:" and left the real BSS without
        // the fields that followed.
        let with_elements = "\
BSS 08:3f:bc:ea:39:41(on wlan0) -- associated
\tsignal: -51.00 dBm
\tBSS Load:
\t\t * station count: 3
\tRSN:\t * Version: 1
\t\t * Authentication suites: PSK
\tHE capabilities:
\t\t * BSS Color: 12
\tWPS:\t * Version: 1.0
";
        let bsses = parse_scan(with_elements);
        assert_eq!(bsses.len(), 1, "an element started a bogus block: {bsses:?}");
        // The fields after the element still belong to the real BSS.
        assert_eq!(bsses[0].security.as_deref(), Some("wpa2"));
        assert_eq!(bsses[0].auth_suites.as_deref(), Some("PSK"));
        assert_eq!(bsses[0].wps, Some(true));
        assert_eq!(bsses[0].standards.as_deref(), Some("he"));
    }

    #[test]
    fn an_empty_scan_is_no_bsses_rather_than_a_failure() {
        assert!(parse_scan("").is_empty());
        assert!(parse_scan("BSS \n").is_empty());
    }

    #[test]
    fn ap_mode_is_reported_as_a_skip_reason() {
        let ap = "phy#0\n\tInterface wlan0\n\t\tifindex 3\n\t\ttype AP\n";
        assert_eq!(scan_blocked_reason(ap, "wlan0"), Some("ap-mode"));

        let managed = "phy#0\n\tInterface wlan0\n\t\tifindex 3\n\t\ttype managed\n";
        assert_eq!(scan_blocked_reason(managed, "wlan0"), None);

        // A named interface that is not in the output at all cannot be scanned.
        assert_eq!(scan_blocked_reason(managed, "wlan1"), Some("interface-down"));
    }
}
