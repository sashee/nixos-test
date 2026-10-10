//! Block devices: which ones are drives, what they are, and what the kernel has sent them.
//!
//! Pure parsing only; main.rs does the reading. Everything here comes from sysfs and udev's
//! database, both world-readable, so none of it needs the capability SMART does.

use crate::smart::DriveKind;

/// `/sys/block/<dev>/stat`, the same counters as `/proc/diskstats` without the name columns
/// (Documentation/block/stat.rst). All cumulative since boot.
///
/// Sectors are always 512 bytes here, whatever the device's logical block size: the kernel
/// counts in its own unit, not the drive's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stat {
    pub reads: u64,
    pub read_sectors: u64,
    pub read_ms: u64,
    pub writes: u64,
    pub write_sectors: u64,
    pub write_ms: u64,
    pub io_ms: u64,
    /// Added in 4.18; absent on older kernels rather than zero.
    pub discard_sectors: Option<u64>,
    /// Added in 5.5.
    pub flushes: Option<u64>,
}

pub const SECTOR_BYTES: u64 = 512;

pub fn parse_stat(text: &str) -> Option<Stat> {
    let fields: Vec<u64> = text.split_whitespace().map(|f| f.parse().ok()).collect::<Option<_>>()?;
    // The eleven columns every kernel since 2.6 has; the discard and flush groups are optional.
    if fields.len() < 11 {
        return None;
    }
    Some(Stat {
        reads: fields[0],
        read_sectors: fields[2],
        read_ms: fields[3],
        writes: fields[4],
        write_sectors: fields[6],
        write_ms: fields[7],
        io_ms: fields[9],
        discard_sectors: fields.get(13).copied(),
        flushes: fields.get(15).copied(),
    })
}

/// What `kind` a whole disk is, from its kernel name, the sysfs path it hangs off, and (for MMC)
/// the card's own `device/type`.
///
/// `sd*` is a SCSI disk, which says nothing about the bus: it is told apart by the path, because a
/// USB-attached SATA SSD is still `sd*` and is `usb` for this purpose -- the bridge is what fails.
/// Disks with no spec'd kind (virtio `vd*`, a virtio-scsi `sd*`) get none.
pub fn drive_kind(name: &str, sysfs_path: &str, mmc_type: Option<&str>) -> Option<DriveKind> {
    if name.starts_with("nvme") {
        Some(DriveKind::Nvme)
    } else if name.starts_with("mmcblk") {
        match mmc_type {
            Some("SD") => Some(DriveKind::Sd),
            Some("MMC") => Some(DriveKind::Emmc),
            _ => None,
        }
    } else if name.starts_with("sd") {
        if sysfs_path.contains("/usb") {
            Some(DriveKind::Usb)
        } else if sysfs_path.contains("/ata") {
            Some(DriveKind::Sata)
        } else {
            None
        }
    } else {
        None
    }
}

/// One property out of a udev database entry (`/run/udev/data/b<major>:<minor>`), whose
/// properties are `E:KEY=value` lines.
pub fn udev_property(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (k, v) = line.strip_prefix("E:")?.split_once('=')?;
        (k == key).then(|| v.to_owned())
    })
}

/// udev's `*_ENC` values escape bytes as `\xNN` (spaces among them), which is the only form of the
/// model that keeps them: the plain `ID_MODEL` has them replaced with underscores.
pub fn decode_udev_enc(encoded: &str) -> String {
    let bytes = encoded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && bytes.get(i + 1) == Some(&b'x') {
            if let Some(byte) = bytes
                .get(i + 2..i + 4)
                .and_then(|hex| std::str::from_utf8(hex).ok())
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
            {
                out.push(byte);
                i += 4;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Whether smartctl's device name addresses this block device: the same node (`/dev/sda` is `sda`),
/// or the NVMe controller (`/dev/nvme0`) of one of its namespaces (`nvme0n1`) -- which is how
/// `--scan-open` names NVMe drives.
pub fn smart_name_matches(scan_name: &str, disk: &str) -> bool {
    let Some(node) = scan_name.strip_prefix("/dev/") else {
        return false;
    };
    let namespace_of = |controller: &str| {
        controller.starts_with("nvme")
            && disk
                .strip_prefix(controller)
                .and_then(|rest| rest.strip_prefix('n'))
                .is_some_and(|ns| !ns.is_empty() && ns.bytes().all(|b| b.is_ascii_digit()))
    };
    node == disk || namespace_of(node)
}

/// For each disk, which SMART report (by index) describes it, given `(name, serial)` for both.
///
/// By serial first: it is what the block layer and smartctl agree on even where their names do not.
/// Then by name, for the reports no serial claimed -- the safety net for a serial the two sides
/// spell differently (a USB bridge's own serial in udev, the drive's through SAT), which would
/// otherwise drop that drive's SMART data with nothing but a log line to show for it. A report a
/// serial already claimed is never handed to a second disk by name.
pub fn match_smart(disks: &[(&str, Option<&str>)], smart: &[(&str, Option<&str>)]) -> Vec<Option<usize>> {
    let by_serial: Vec<Option<usize>> = disks
        .iter()
        .map(|(_, serial)| serial.and_then(|s| smart.iter().position(|(_, sn)| *sn == Some(s))))
        .collect();
    disks
        .iter()
        .zip(&by_serial)
        .map(|((disk, _), matched)| {
            matched.or_else(|| {
                smart
                    .iter()
                    .enumerate()
                    .find(|(i, (scan_name, _))| {
                        !by_serial.contains(&Some(*i)) && smart_name_matches(scan_name, disk)
                    })
                    .map(|(i, _)| i)
            })
        })
        .collect()
}

/// Identity strings as smartctl reports them: trimmed, and nothing at all rather than an empty
/// string. sysfs pads NVMe models with trailing spaces to the field width, so an untrimmed model
/// would name the same drive differently from the SMART record of it.
pub fn identity(raw: Option<String>) -> Option<String> {
    raw.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Pi's SD card, read on 2026-10-10: every group present.
    const PI_STAT: &str =
        "   78517    39604  4050290   143115   111290    85930 11231328  6284981        0   379532  6433571        0        0        0        0     5493     5474\n";

    #[test]
    fn stat_columns_land_in_the_right_fields() {
        let stat = parse_stat(PI_STAT).unwrap();
        assert_eq!(stat.reads, 78517);
        assert_eq!(stat.read_sectors, 4050290);
        assert_eq!(stat.read_ms, 143115);
        assert_eq!(stat.writes, 111290);
        assert_eq!(stat.write_sectors, 11231328);
        assert_eq!(stat.write_ms, 6284981);
        assert_eq!(stat.io_ms, 379532);
        assert_eq!(stat.discard_sectors, Some(0));
        assert_eq!(stat.flushes, Some(5493));
    }

    /// A pre-4.18 kernel's eleven columns: the counters it has, and no invented zeroes for the
    /// ones it does not.
    #[test]
    fn an_older_kernel_has_no_discard_or_flush_counts() {
        let stat = parse_stat("1 2 3 4 5 6 7 8 9 10 11").unwrap();
        assert_eq!(stat.write_sectors, 7);
        assert_eq!(stat.io_ms, 10);
        assert_eq!(stat.discard_sectors, None);
        assert_eq!(stat.flushes, None);
    }

    #[test]
    fn a_truncated_or_garbled_stat_is_unreadable() {
        assert_eq!(parse_stat("1 2 3"), None);
        assert_eq!(parse_stat("1 2 3 4 5 6 7 8 9 10 x"), None);
        assert_eq!(parse_stat(""), None);
    }

    #[test]
    fn kinds_follow_the_name_and_the_bus() {
        assert_eq!(drive_kind("nvme0n1", "/sys/devices/pci0000:00/nvme/nvme0/nvme0n1", None), Some(DriveKind::Nvme));
        assert_eq!(drive_kind("mmcblk0", "/sys/devices/platform/mmc_host/mmc0", Some("SD")), Some(DriveKind::Sd));
        assert_eq!(drive_kind("mmcblk0", "/sys/devices/platform/mmc_host/mmc0", Some("MMC")), Some(DriveKind::Emmc));
        assert_eq!(drive_kind("mmcblk0", "/sys/devices/platform/mmc_host/mmc0", None), None);
        assert_eq!(
            drive_kind("sda", "/sys/devices/pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0/block/sda", None),
            Some(DriveKind::Sata)
        );
        assert_eq!(
            drive_kind("sdb", "/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host1/target1:0:0/1:0:0:0/block/sdb", None),
            Some(DriveKind::Usb)
        );
        // A test VM's disks: virtio-blk, and virtio-scsi showing up as sd*.
        assert_eq!(drive_kind("vda", "/sys/devices/pci0000:00/0000:00:04.0/virtio1/block/vda", None), None);
        assert_eq!(drive_kind("sdc", "/sys/devices/pci0000:00/0000:00:05.0/virtio2/host2/target2:0:0/2:0:0:0/block/sdc", None), None);
    }

    #[test]
    fn udev_properties_are_read_by_exact_key() {
        let entry = "S:disk/by-id/ata-FAKE\nE:ID_SERIAL=FAKE_SSD_S123\nE:ID_SERIAL_SHORT=S123\nE:ID_MODEL_ENC=FAKE\\x20SSD\\x20\\x20\n";
        assert_eq!(udev_property(entry, "ID_SERIAL_SHORT").as_deref(), Some("S123"));
        assert_eq!(udev_property(entry, "ID_SERIAL").as_deref(), Some("FAKE_SSD_S123"));
        assert_eq!(udev_property(entry, "ID_MODEL"), None);
        assert_eq!(udev_property(entry, "disk/by-id/ata-FAKE"), None);
    }

    #[test]
    fn encoded_models_get_their_spaces_back() {
        assert_eq!(decode_udev_enc("Samsung\\x20SSD\\x20860"), "Samsung SSD 860");
        // Not an escape: kept as it is.
        assert_eq!(decode_udev_enc("a\\xZZb\\"), "a\\xZZb\\");
    }

    #[test]
    fn smart_names_address_the_node_or_the_nvme_controller() {
        assert!(smart_name_matches("/dev/sda", "sda"));
        assert!(smart_name_matches("/dev/nvme0", "nvme0n1"));
        assert!(smart_name_matches("/dev/nvme0", "nvme0n12"));
        assert!(smart_name_matches("/dev/nvme0n1", "nvme0n1"));
        // nvme1 is not nvme10's controller, and a partition-shaped tail is not a namespace.
        assert!(!smart_name_matches("/dev/nvme1", "nvme10n1"));
        assert!(!smart_name_matches("/dev/nvme0", "nvme0n1p1"));
        assert!(!smart_name_matches("/dev/sda", "sdb"));
        assert!(!smart_name_matches("/dev/sd", "sda"));
        assert!(!smart_name_matches("sda", "sda"));
    }

    #[test]
    fn smart_is_matched_by_serial_first() {
        // The test VM: virtio disks whose serials the fake smartctl reports under other names.
        let disks = [("vda", Some("root")), ("vdb", Some("NVME-SERIAL-1")), ("vdc", Some("SATA-SERIAL-2"))];
        let smart = [("/dev/nvme0", Some("NVME-SERIAL-1")), ("/dev/sda", Some("SATA-SERIAL-2"))];
        assert_eq!(match_smart(&disks, &smart), vec![None, Some(0), Some(1)]);
    }

    #[test]
    fn a_serial_spelled_differently_falls_back_to_the_name() {
        // A USB disk: udev has the bridge's serial, smartctl the drive's through SAT.
        assert_eq!(match_smart(&[("sda", Some("BRIDGE-1"))], &[("/dev/sda", Some("ATA-123"))]), vec![Some(0)]);
        // And an NVMe namespace with no serial readable at all.
        assert_eq!(match_smart(&[("nvme0n1", None)], &[("/dev/nvme0", Some("X"))]), vec![Some(0)]);
    }

    #[test]
    fn a_report_claimed_by_serial_is_not_handed_to_another_disk_by_name() {
        // /dev/sda's report carries sdb's serial: it is sdb's, and sda gets none.
        let disks = [("sda", Some("S2")), ("sdb", Some("S1"))];
        assert_eq!(match_smart(&disks, &[("/dev/sda", Some("S1"))]), vec![None, Some(0)]);
    }

    #[test]
    fn a_disk_with_no_report_has_none() {
        assert_eq!(match_smart(&[("mmcblk0", Some("0x30645aea"))], &[]), vec![None]);
        assert_eq!(match_smart(&[], &[("/dev/sda", Some("S1"))]), Vec::<Option<usize>>::new());
    }

    #[test]
    fn identities_are_trimmed_and_empty_is_absent() {
        assert_eq!(
            identity(Some("KINGSTON OM8PDP3512B-AA1                \n".to_owned())).as_deref(),
            Some("KINGSTON OM8PDP3512B-AA1")
        );
        assert_eq!(identity(Some("   ".to_owned())), None);
        assert_eq!(identity(None), None);
    }
}
