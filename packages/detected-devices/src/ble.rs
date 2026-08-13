//! `btmon` advertising-report parsing.
//!
//! Why btmon and not BlueZ's D-Bus API: D-Bus exposes a device's address, RSSI, name, UUIDs and
//! manufacturer data, but *not* the advertising PDU type -- so `connectable` cannot be derived from
//! it at all. The kernel's mgmt socket has the same gap: its `Device Found` event carries the
//! address, RSSI, flags and the raw AD blob but drops the event type. Only the HCI monitor channel
//! keeps it, and `btmon` is the reader for that channel. It is also read-only and coexists with
//! anything else using the controller, which a second host stack would not.
//!
//! One report is not one device: a window yields many advertisements per address, so the parser
//! aggregates by address and keeps first/last/min/max of the RSSI. A single RSSI would be
//! survivor-biased -- only the advertisements that arrived are measured at all.
//!
//! Everything here is a pure `&str -> T`; driving the scan lives in `main.rs`.

use std::collections::BTreeMap;

/// The two address kinds the Bluetooth spec defines. `Random` covers static, resolvable private and
/// non-resolvable private addresses; the resolvable kind rotates roughly every 15 minutes, which is
/// why the two become separate measurement types rather than one with an attribute.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AddressKind {
    Public,
    Random,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Advertiser {
    pub address: String,
    pub kind: AddressKind,
    /// Verbatim from btmon, e.g. `ADV_IND`, `ADV_NONCONN_IND`.
    pub pdu_type: Option<String>,
    pub rssi_last: Option<i64>,
    pub rssi_min: Option<i64>,
    pub rssi_max: Option<i64>,
    pub report_count: i64,
    pub name: Option<String>,
    pub tx_power_dbm: Option<i64>,
    pub company_id: Option<i64>,
    /// Comma-separated 16-bit UUIDs as btmon prints them, e.g. `ffe0,fee7`.
    pub service_uuids: Option<String>,
    pub flags: Option<String>,
}

impl Advertiser {
    /// True for the PDU types a central can connect to. `ADV_NONCONN_IND` and `ADV_SCAN_IND` are
    /// broadcast-only: the advertiser accepts no `CONNECT_IND`, so a connection attempt can only
    /// time out. This is the field the whole measurement exists to carry.
    pub fn connectable(&self) -> Option<bool> {
        let pdu = self.pdu_type.as_deref()?;
        Some(matches!(pdu, "ADV_IND" | "ADV_DIRECT_IND"))
    }
}

/// Everything a scan window observed.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Scan {
    pub advertisers: Vec<Advertiser>,
    pub reports_total: i64,
}

impl Scan {
    pub fn strongest_dbm(&self) -> Option<i64> {
        self.advertisers.iter().filter_map(|a| a.rssi_max).max()
    }

    pub fn count(&self, kind: AddressKind) -> i64 {
        self.advertisers.iter().filter(|a| a.kind == kind).count() as i64
    }

    pub fn connectable_count(&self) -> i64 {
        self.advertisers.iter().filter(|a| a.connectable() == Some(true)).count() as i64
    }

    /// Devices above -60, between -60 and -80, and below -80 dBm. A fixed-width population signal,
    /// so the per-device rows can be capped or the cadence lowered without losing "how busy is it".
    pub fn distance_buckets(&self) -> (i64, i64, i64) {
        let mut near = 0;
        let mut mid = 0;
        let mut far = 0;
        for a in &self.advertisers {
            match a.rssi_max {
                Some(r) if r > -60 => near += 1,
                Some(r) if r >= -80 => mid += 1,
                Some(_) => far += 1,
                None => {}
            }
        }
        (near, mid, far)
    }
}

/// Parses a btmon capture into one entry per address.
///
/// btmon prints an `LE Advertising Report` as an `Event type:` line followed by `Address:`,
/// `Address type:`, the decoded AD structures and finally `RSSI:`. Fields are matched on their
/// trimmed prefix and attributed to the address most recently seen, which is how btmon groups them.
/// The same event also arrives a second time as an `MGMT Event: Device Found`; those blocks are
/// skipped, because they carry no event type and would otherwise double every report count.
pub fn parse_btmon(text: &str) -> Scan {
    // Insertion-independent ordering so a batch's records are stable between runs.
    let mut found: BTreeMap<String, Advertiser> = BTreeMap::new();
    let mut reports_total = 0i64;

    // btmon prints `Event type:` and `Address type:` *before* the `Address:` they describe, so both
    // are buffered and applied when the address arrives. Handling `Address type:` after the address
    // instead is the bug this ordering exists to avoid: every device would come out Public.
    let mut pending_pdu: Option<String> = None;
    let mut pending_kind: Option<AddressKind> = None;
    let mut current: Option<String> = None;
    let mut in_mgmt = false;

    for line in text.lines() {
        let trimmed = line.trim();

        // Block boundaries. btmon prefixes HCI traffic with < or > and mgmt with @. Matched on the
        // trimmed line: the markers sit at column 0 in btmon's own output, but a capture that has
        // been through an indented heredoc still has to be read correctly -- otherwise the mgmt
        // block is not skipped and its duplicate RSSI is attributed to the previous device.
        if trimmed.starts_with('@') {
            in_mgmt = true;
            current = None;
            pending_kind = None;
            pending_pdu = None;
            continue;
        }
        if trimmed.starts_with('<') || trimmed.starts_with('>') {
            in_mgmt = false;
            current = None;
            continue;
        }
        if in_mgmt {
            continue;
        }

        if let Some(rest) = trimmed.strip_prefix("Address type: ") {
            pending_kind =
                Some(if rest.starts_with("Random") { AddressKind::Random } else { AddressKind::Public });
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Event type: ") {
            // `Connectable undirected - ADV_IND (0x00)` -- the symbol after the dash is the name
            // worth storing; the prose before it is btmon's own gloss.
            pending_pdu = rest
                .split(" - ")
                .nth(1)
                .and_then(|s| s.split(" (").next())
                .map(|s| s.trim().to_owned());
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Address: ") {
            let address = rest.split_whitespace().next().unwrap_or("").to_owned();
            if address.is_empty() {
                continue;
            }
            reports_total += 1;
            let entry = found.entry(address.clone()).or_insert_with(|| Advertiser {
                address: address.clone(),
                kind: AddressKind::Public,
                pdu_type: None,
                rssi_last: None,
                rssi_min: None,
                rssi_max: None,
                report_count: 0,
                name: None,
                tx_power_dbm: None,
                company_id: None,
                service_uuids: None,
                flags: None,
            });
            entry.report_count += 1;
            if entry.pdu_type.is_none() {
                entry.pdu_type = pending_pdu.take();
            }
            if let Some(kind) = pending_kind.take() {
                entry.kind = kind;
            }
            current = Some(address);
            continue;
        }

        let Some(key) = current.clone() else {
            continue;
        };
        let Some(entry) = found.get_mut(&key) else {
            continue;
        };

        if let Some(rest) = trimmed.strip_prefix("RSSI: ") {
            // `-61 dBm (0xc3)`
            if let Some(dbm) = rest.split(" dBm").next().and_then(|v| v.trim().parse::<i64>().ok()) {
                entry.rssi_last = Some(dbm);
                entry.rssi_min = Some(entry.rssi_min.map_or(dbm, |m: i64| m.min(dbm)));
                entry.rssi_max = Some(entry.rssi_max.map_or(dbm, |m: i64| m.max(dbm)));
            }
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Flags: ") {
            entry.flags = Some(rest.trim().to_owned());
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Name (complete): ") {
            entry.name = Some(rest.trim().to_owned());
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Name (short): ") {
            if entry.name.is_none() {
                entry.name = Some(rest.trim().to_owned());
            }
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("TX power: ") {
            entry.tx_power_dbm = rest.split(" dB").next().and_then(|v| v.trim().parse().ok());
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Company: ") {
            // `Samsung Electronics Co. Ltd. (117)` / `not assigned (2917)`
            entry.company_id = rest
                .rsplit_once('(')
                .and_then(|(_, id)| id.trim_end_matches(')').trim().parse().ok());
            continue;
        }
        // 16-bit UUID entries are listed one per line under the `16-bit Service UUIDs` header, as
        // `Unknown (0xffe0)` or `Tencent Holdings Limited. (0xfee7)`.
        if let Some((_, uuid)) = trimmed.rsplit_once("(0x") {
            if let Some(hex) = uuid.strip_suffix(')') {
                if hex.len() == 4 && hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                    match &mut entry.service_uuids {
                        Some(existing) => {
                            if !existing.split(',').any(|u| u == hex) {
                                existing.push(',');
                                existing.push_str(hex);
                            }
                        }
                        None => entry.service_uuids = Some(hex.to_owned()),
                    }
                }
            }
        }
    }

    Scan { advertisers: found.into_values().collect(), reports_total }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two real captures from this site: the JK BMS (connectable, public, two service UUIDs) and a
    /// Samsung beacon (non-connectable, manufacturer data only, no flags). Includes the duplicate
    /// `MGMT Event` block that must not be counted twice.
    const REAL_BTMON: &str = "\
> HCI Event: LE Meta Event (0x3e) plen 43                    #7 [hci0] 3.139560
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Public (0x00)
        Address: C8:47:80:29:5E:3B (OUI C8-47-80)
        Data length: 21
        Flags: 0x06
          LE General Discoverable Mode
          BR/EDR Not Supported
        16-bit Service UUIDs (partial): 2 entries
          Unknown (0xffe0)
          Tencent Holdings Limited. (0xfee7)
        Company: not assigned (2917)
          Data[8]: 88a0c847802 95e3b
        RSSI: -61 dBm (0xc3)
@ MGMT Event: Device Found (0x0012) plen 35            {0x0001} [hci0] 3.210375
        LE Address: C8:47:80:29:5E:3B (OUI C8-47-80)
        RSSI: -42 dBm (0xd6)
        Flags: 0x00000000
> HCI Event: LE Meta Event (0x3e) plen 33                    #8 [hci0] 3.309609
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Non connectable undirected - ADV_NONCONN_IND (0x03)
        Address type: Public (0x00)
        Address: 00:7D:3B:FA:08:E5 (Samsung Electronics Co.,Ltd)
        Data length: 28
        Company: Samsung Electronics Co. Ltd. (117)
          Data[24]: 42040180
        RSSI: -72 dBm (0xb8)
> HCI Event: LE Meta Event (0x3e) plen 43                    #9 [hci0] 4.139560
      LE Advertising Report (0x02)
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Public (0x00)
        Address: C8:47:80:29:5E:3B (OUI C8-47-80)
        RSSI: -42 dBm (0xd6)
";

    fn by_address<'a>(scan: &'a Scan, address: &str) -> &'a Advertiser {
        scan.advertisers.iter().find(|a| a.address == address).expect("address not parsed")
    }

    #[test]
    fn the_pdu_type_decides_connectability() {
        let scan = parse_btmon(REAL_BTMON);
        let bms = by_address(&scan, "C8:47:80:29:5E:3B");
        assert_eq!(bms.pdu_type.as_deref(), Some("ADV_IND"));
        assert_eq!(bms.connectable(), Some(true));

        // Visible at -72 dBm and impossible to connect to: the case an RSSI-based reading of
        // "reachable" would get wrong.
        let beacon = by_address(&scan, "00:7D:3B:FA:08:E5");
        assert_eq!(beacon.pdu_type.as_deref(), Some("ADV_NONCONN_IND"));
        assert_eq!(beacon.connectable(), Some(false));
    }

    #[test]
    fn reports_aggregate_per_address_with_an_rssi_range() {
        let scan = parse_btmon(REAL_BTMON);
        let bms = by_address(&scan, "C8:47:80:29:5E:3B");
        assert_eq!(bms.report_count, 2, "two HCI reports, not three -- the mgmt copy is skipped");
        assert_eq!(bms.rssi_min, Some(-61));
        assert_eq!(bms.rssi_max, Some(-42));
        assert_eq!(bms.rssi_last, Some(-42));
    }

    #[test]
    fn the_duplicate_mgmt_event_is_not_counted() {
        // btmon shows every advertisement twice: once from the controller and once as BlueZ's own
        // mgmt event. Counting both would double every report total and add a -42 sample that the
        // HCI view already has.
        let scan = parse_btmon(REAL_BTMON);
        assert_eq!(scan.reports_total, 3, "{:?}", scan.advertisers);
        assert_eq!(scan.advertisers.len(), 2);
    }

    #[test]
    fn service_uuids_and_company_id_come_out_of_the_ad_structures() {
        let scan = parse_btmon(REAL_BTMON);
        let bms = by_address(&scan, "C8:47:80:29:5E:3B");
        assert_eq!(bms.service_uuids.as_deref(), Some("ffe0,fee7"));
        assert_eq!(bms.company_id, Some(2917));
        assert_eq!(bms.flags.as_deref(), Some("0x06"));

        let beacon = by_address(&scan, "00:7D:3B:FA:08:E5");
        assert_eq!(beacon.company_id, Some(117));
        // Advertises manufacturer data only: no flags, no UUIDs, no name.
        assert_eq!(beacon.flags, None);
        assert_eq!(beacon.service_uuids, None);
        assert_eq!(beacon.name, None);
    }

    #[test]
    fn neither_real_device_advertises_tx_power_so_path_loss_is_unknown() {
        let scan = parse_btmon(REAL_BTMON);
        assert_eq!(by_address(&scan, "C8:47:80:29:5E:3B").tx_power_dbm, None);
        assert_eq!(by_address(&scan, "00:7D:3B:FA:08:E5").tx_power_dbm, None);
    }

    #[test]
    fn address_kind_splits_the_population() {
        let scan = parse_btmon(REAL_BTMON);
        // Both devices at this site use permanent addresses.
        assert_eq!(scan.count(AddressKind::Public), 2);
        assert_eq!(scan.count(AddressKind::Random), 0);
        assert_eq!(scan.connectable_count(), 1);

        let random = parse_btmon(
            "> HCI Event: LE Meta Event (0x3e) plen 20\n      LE Advertising Report (0x02)\n\
             \x20       Event type: Connectable undirected - ADV_IND (0x00)\n\
             \x20       Address type: Random (0x01)\n\
             \x20       Address: 4F:1A:2B:3C:4D:5E (Resolvable)\n\
             \x20       RSSI: -55 dBm (0xc9)\n",
        );
        assert_eq!(random.count(AddressKind::Random), 1);
        assert_eq!(random.count(AddressKind::Public), 0);
    }

    #[test]
    fn population_buckets_are_fixed_width_regardless_of_device_count() {
        let scan = parse_btmon(REAL_BTMON);
        // -42 is near, -72 is mid, nothing below -80.
        assert_eq!(scan.distance_buckets(), (1, 1, 0));
        assert_eq!(scan.strongest_dbm(), Some(-42));
    }

    #[test]
    fn indented_block_markers_are_still_block_markers() {
        // A capture where the only -42 is the mgmt duplicate, indented as it would be after going
        // through a heredoc. If the block is not recognised as mgmt, that RSSI lands on the device
        // and every consumer reads a maximum the controller never reported.
        let indented = "\
    > HCI Event: LE Meta Event (0x3e) plen 43                    #7 [hci0] 3.139560
          LE Advertising Report (0x02)
            Event type: Connectable undirected - ADV_IND (0x00)
            Address type: Public (0x00)
            Address: AA:BB:CC:DD:EE:FF (OUI AA-BB-CC)
            RSSI: -61 dBm (0xc3)
    @ MGMT Event: Device Found (0x0012) plen 35            {0x0001} [hci0] 3.210375
            LE Address: AA:BB:CC:DD:EE:FF (OUI AA-BB-CC)
            RSSI: -42 dBm (0xd6)
";
        let scan = parse_btmon(indented);
        let device = by_address(&scan, "AA:BB:CC:DD:EE:FF");
        assert_eq!(device.rssi_max, Some(-61), "the mgmt block's -42 leaked in");
        assert_eq!(device.report_count, 1, "the mgmt copy was counted as a second report");
        assert_eq!(scan.reports_total, 1);
    }

    #[test]
    fn an_empty_capture_is_an_empty_scan_rather_than_a_failure() {
        let scan = parse_btmon("");
        assert!(scan.advertisers.is_empty());
        assert_eq!(scan.reports_total, 0);
        assert_eq!(scan.strongest_dbm(), None);
        assert_eq!(scan.distance_buckets(), (0, 0, 0));
    }
}
