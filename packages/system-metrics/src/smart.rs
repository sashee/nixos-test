//! `smartctl --json` parsing.
//!
//! Split into a universal part and one per drive family, because NVMe and SATA report genuinely
//! different things: NVMe has a fixed health log, SATA has a vendor-defined attribute table. Only
//! `passed` and the power-on hours mean the same thing on both, and those are the only two the
//! shared record carries.
//!
//! SATA attributes are matched on their numeric id, never on `name`: vendors rename them freely
//! while the ids are stable. The raw values are deliberately not rescaled -- id 9 is hours on most
//! drives and minutes on a few -- so they are trend lines rather than absolutes.

use std::collections::BTreeMap;

/// One entry of `smartctl --scan-open --json`.
#[derive(Debug, Clone, PartialEq)]
pub struct ScanDevice {
    pub name: String,
    /// The `-d` argument smartctl reported for this device. Passing it back is what makes USB
    /// bridges and RAID members addressable; an empty type means "let smartctl decide again".
    pub dev_type: Option<String>,
}

pub fn parse_scan(text: &str) -> Vec<ScanDevice> {
    let Ok(root) = serde_json::from_str::<serde_json::Value>(text) else {
        return Vec::new();
    };
    root.get("devices")
        .and_then(|d| d.as_array())
        .map(|devices| {
            devices
                .iter()
                .filter_map(|device| {
                    Some(ScanDevice {
                        name: device.get("name")?.as_str()?.to_owned(),
                        dev_type: device
                            .get("type")
                            .and_then(|t| t.as_str())
                            .filter(|t| !t.is_empty())
                            .map(str::to_owned),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriveKind {
    Nvme,
    Sata,
}

impl DriveKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DriveKind::Nvme => "nvme",
            DriveKind::Sata => "sata",
        }
    }
}

/// The NVMe health log, which every NVMe drive implements identically.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NvmeHealth {
    pub percentage_used: Option<i64>,
    pub available_spare: Option<i64>,
    pub media_errors: Option<i64>,
    pub unsafe_shutdowns: Option<i64>,
    pub critical_warning: Option<i64>,
}

/// The SATA attribute table, reduced to the ids worth reporting plus the two counts that
/// generalise past them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SataHealth {
    /// Keyed by the body field name, so a drive that does not implement an id simply has no
    /// entry -- which is most of them on most drives.
    pub attributes: BTreeMap<&'static str, i64>,
    /// Attributes whose `when_failed` is set. These catch a vendor-specific attribute crossing
    /// its threshold even though it is not in the table below, which is why they are counted
    /// rather than enumerated.
    pub failing_now: u64,
    pub failed_past: u64,
}

/// The ids this producer names. The five that Backblaze's fleet data found predictive come
/// first; the rest are context.
const SATA_ATTRIBUTES: &[(u64, &str)] = &[
    (5, "reallocated_sector_ct"),
    (187, "reported_uncorrect"),
    (188, "command_timeout"),
    (197, "current_pending_sector"),
    (198, "offline_uncorrectable"),
    (12, "power_cycle_count"),
    (199, "udma_crc_error_count"),
    (177, "wear_leveling_count"),
    (241, "total_lbas_written"),
];

#[derive(Debug, Clone, PartialEq)]
pub struct Drive {
    pub serial: Option<String>,
    pub model: Option<String>,
    pub kind: Option<DriveKind>,
    pub passed: Option<bool>,
    pub power_on_hours: Option<i64>,
    pub nvme: Option<NvmeHealth>,
    pub sata: Option<SataHealth>,
}

fn drive_kind(root: &serde_json::Value) -> Option<DriveKind> {
    // `device.protocol` is the direct answer; the health log is the fallback for the older
    // smartctl output that omits it.
    match root.get("device").and_then(|d| d.get("protocol")).and_then(|p| p.as_str()) {
        Some("NVMe") => return Some(DriveKind::Nvme),
        Some("ATA") | Some("SATA") => return Some(DriveKind::Sata),
        _ => {}
    }
    if root.get("nvme_smart_health_information_log").is_some() {
        return Some(DriveKind::Nvme);
    }
    if root.get("ata_smart_attributes").is_some() {
        return Some(DriveKind::Sata);
    }
    None
}

fn nvme_health(root: &serde_json::Value) -> Option<NvmeHealth> {
    let log = root.get("nvme_smart_health_information_log")?;
    let field = |name: &str| log.get(name).and_then(|v| v.as_i64());
    Some(NvmeHealth {
        percentage_used: field("percentage_used"),
        available_spare: field("available_spare"),
        media_errors: field("media_errors"),
        unsafe_shutdowns: field("unsafe_shutdowns"),
        critical_warning: field("critical_warning"),
    })
}

fn sata_health(root: &serde_json::Value) -> Option<SataHealth> {
    let table = root.get("ata_smart_attributes")?.get("table")?.as_array()?;

    let mut health = SataHealth::default();
    for entry in table {
        match entry.get("when_failed").and_then(|w| w.as_str()) {
            Some("now") => health.failing_now += 1,
            Some("past") => health.failed_past += 1,
            _ => {}
        }

        let Some(id) = entry.get("id").and_then(|i| i.as_u64()) else {
            continue;
        };
        let Some((_, name)) = SATA_ATTRIBUTES.iter().find(|(known, _)| *known == id) else {
            continue;
        };
        // The raw value, not the normalised `value`: a count of reallocated sectors is the fact,
        // while the 0-255 normalisation is the vendor's opinion about it.
        if let Some(raw) = entry.get("raw").and_then(|r| r.get("value")).and_then(|v| v.as_i64()) {
            health.attributes.insert(name, raw);
        }
    }
    Some(health)
}

pub fn parse_smart(text: &str) -> Option<Drive> {
    let root: serde_json::Value = serde_json::from_str(text).ok()?;
    let kind = drive_kind(&root);
    Some(Drive {
        serial: root.get("serial_number").and_then(|v| v.as_str()).map(str::to_owned),
        model: root.get("model_name").and_then(|v| v.as_str()).map(str::to_owned),
        kind,
        passed: root.get("smart_status").and_then(|s| s.get("passed")).and_then(|v| v.as_bool()),
        // Present for both families in modern smartctl, which spares this from having to read
        // hours out of NVMe's health log and SATA's attribute 9 separately -- two encodings that
        // disagree about units on some drives.
        power_on_hours: root.get("power_on_time").and_then(|t| t.get("hours")).and_then(|v| v.as_i64()),
        nvme: match kind {
            Some(DriveKind::Nvme) => nvme_health(&root),
            _ => None,
        },
        sata: match kind {
            Some(DriveKind::Sata) => sata_health(&root),
            _ => None,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_keeps_the_device_type_so_it_can_be_passed_back() {
        let devices = parse_scan(
            r#"{"devices":[{"name":"/dev/nvme0","type":"nvme"},{"name":"/dev/sda","type":""}]}"#,
        );
        assert_eq!(
            devices,
            vec![
                ScanDevice { name: "/dev/nvme0".into(), dev_type: Some("nvme".into()) },
                ScanDevice { name: "/dev/sda".into(), dev_type: None },
            ]
        );
    }

    /// The Pi's answer: the SD card exposes no SMART, so the scan is empty and no drive record
    /// is produced at all.
    #[test]
    fn a_host_without_smart_devices_scans_to_nothing() {
        assert_eq!(parse_scan(r#"{"json_format_version":[1,0]}"#), Vec::new());
        assert_eq!(parse_scan("not json"), Vec::new());
    }

    const NVME: &str = r#"{
      "device": {"name": "/dev/nvme0", "type": "nvme", "protocol": "NVMe"},
      "model_name": "WD_BLACK SN770 1TB",
      "serial_number": "22336K800123",
      "smart_status": {"passed": true},
      "power_on_time": {"hours": 4321},
      "nvme_smart_health_information_log": {
        "critical_warning": 0, "temperature": 316, "available_spare": 100,
        "percentage_used": 3, "media_errors": 0, "unsafe_shutdowns": 41
      }
    }"#;

    #[test]
    fn nvme_health_comes_from_the_fixed_log() {
        let drive = parse_smart(NVME).unwrap();
        assert_eq!(drive.kind, Some(DriveKind::Nvme));
        assert_eq!(drive.serial.as_deref(), Some("22336K800123"));
        assert_eq!(drive.model.as_deref(), Some("WD_BLACK SN770 1TB"));
        assert_eq!(drive.passed, Some(true));
        assert_eq!(drive.power_on_hours, Some(4321));
        assert_eq!(
            drive.nvme,
            Some(NvmeHealth {
                percentage_used: Some(3),
                available_spare: Some(100),
                media_errors: Some(0),
                unsafe_shutdowns: Some(41),
                critical_warning: Some(0),
            })
        );
        assert_eq!(drive.sata, None);
    }

    const SATA: &str = r#"{
      "device": {"name": "/dev/sda", "type": "sat", "protocol": "ATA"},
      "model_name": "Samsung SSD 860 EVO 1TB",
      "serial_number": "S3Z8NB0K123456X",
      "smart_status": {"passed": true},
      "power_on_time": {"hours": 19004},
      "ata_smart_attributes": {"table": [
        {"id": 5,   "name": "Reallocated_Sector_Ct", "value": 100, "when_failed": "",
         "raw": {"value": 0, "string": "0"}},
        {"id": 9,   "name": "Power_On_Hours",        "value": 97,  "when_failed": "",
         "raw": {"value": 19004, "string": "19004"}},
        {"id": 12,  "name": "Power_Cycle_Count",     "value": 99,  "when_failed": "",
         "raw": {"value": 1183, "string": "1183"}},
        {"id": 177, "name": "Wear_Leveling_Count",   "value": 94,  "when_failed": "",
         "raw": {"value": 76, "string": "76"}},
        {"id": 197, "name": "Current_Pending_Sector","value": 100, "when_failed": "now",
         "raw": {"value": 8, "string": "8"}},
        {"id": 199, "name": "UDMA_CRC_Error_Count",  "value": 100, "when_failed": "past",
         "raw": {"value": 2, "string": "2"}},
        {"id": 241, "name": "Total_LBAs_Written",    "value": 99,  "when_failed": "",
         "raw": {"value": 41203344, "string": "41203344"}}
      ]}
    }"#;

    #[test]
    fn sata_attributes_are_matched_by_id_and_read_raw() {
        let drive = parse_smart(SATA).unwrap();
        assert_eq!(drive.kind, Some(DriveKind::Sata));
        assert_eq!(drive.power_on_hours, Some(19004));
        assert_eq!(drive.nvme, None);

        let sata = drive.sata.unwrap();
        assert_eq!(sata.attributes["reallocated_sector_ct"], 0);
        assert_eq!(sata.attributes["power_cycle_count"], 1183);
        assert_eq!(sata.attributes["wear_leveling_count"], 76);
        assert_eq!(sata.attributes["current_pending_sector"], 8);
        assert_eq!(sata.attributes["total_lbas_written"], 41203344);
        // Not implemented by this drive, so absent rather than zero.
        assert!(!sata.attributes.contains_key("reported_uncorrect"));
        assert!(!sata.attributes.contains_key("command_timeout"));
    }

    /// The catch-all: these count every failing attribute, including ids this producer does not
    /// name, which is the point of having them.
    #[test]
    fn when_failed_is_counted_across_the_whole_table() {
        let sata = parse_smart(SATA).unwrap().sata.unwrap();
        assert_eq!(sata.failing_now, 1);
        assert_eq!(sata.failed_past, 1);
    }

    #[test]
    fn a_drive_that_reports_nothing_useful_is_still_a_record() {
        let drive = parse_smart(r#"{"device":{"name":"/dev/sdb"}}"#).unwrap();
        assert_eq!(drive.kind, None);
        assert_eq!(drive.passed, None);
        assert_eq!(drive.serial, None);
        assert_eq!(drive.nvme, None);
        assert_eq!(drive.sata, None);
    }
}
