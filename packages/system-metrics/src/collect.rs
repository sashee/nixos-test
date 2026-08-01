//! Collectors. Every parser is a pure `&str -> T`, so the unit tests below run them against
//! fixture text instead of the live `/proc` -- a test that read the real `/proc/meminfo` could
//! only assert "some number came back", which is not a test of the parsing.
//!
//! I/O lives in `main.rs`; nothing here opens a file except the two `statvfs`-shaped helpers,
//! which have no text form to parse.

use std::collections::HashSet;
use std::path::Path;

/// A value as it goes into a measurement body or attribute set. Mirrors the subset of OTLP's
/// `AnyValue` this producer emits (see `otlp.rs`); anything richer would not survive the
/// receiver's flat attribute model anyway.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Double(f64),
    Bool(bool),
}

impl Value {
    pub fn str(s: impl Into<String>) -> Self {
        Value::Str(s.into())
    }
}

/// One measurement. `event_name` becomes the receiver's `type` column and must be non-empty:
/// the receiver rejects records without it (they are not OTLP Events).
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub event_name: String,
    pub attributes: Vec<(String, Value)>,
    pub body: Vec<(String, Value)>,
}

impl Record {
    pub fn new(event_name: &str) -> Self {
        Record { event_name: event_name.to_owned(), attributes: Vec::new(), body: Vec::new() }
    }

    pub fn with_attr(mut self, key: &str, value: Value) -> Self {
        self.attributes.push((key.to_owned(), value));
        self
    }

    pub fn with_field(mut self, key: &str, value: Value) -> Self {
        self.body.push((key.to_owned(), value));
        self
    }

    /// Same as `with_field`, but a `None` omits the key entirely rather than writing a null.
    /// Used where the underlying fact may not exist on this host at all (e.g. no system
    /// profile in a freshly booted VM): an absent key is unambiguous, a null is not.
    pub fn with_optional_field(self, key: &str, value: Option<Value>) -> Self {
        match value {
            Some(v) => self.with_field(key, v),
            None => self,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// CPU

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LoadAvg {
    pub one: f64,
    pub five: f64,
    pub fifteen: f64,
}

pub fn parse_loadavg(text: &str) -> Option<LoadAvg> {
    let mut fields = text.split_whitespace();
    Some(LoadAvg {
        one: fields.next()?.parse().ok()?,
        five: fields.next()?.parse().ok()?,
        fifteen: fields.next()?.parse().ok()?,
    })
}

/// The aggregate `cpu` line of `/proc/stat`, reduced to the only two sums that matter here.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CpuTimes {
    pub total: u64,
    pub idle: u64,
}

/// Reads the aggregate `cpu` line. `iowait` counts as idle: the CPU is not executing anything
/// during it, and calling a disk-bound host "busy" would make the number mean two things.
/// `guest`/`guest_nice` are excluded from the total because the kernel already counts them
/// inside `user`/`nice`.
pub fn parse_cpu_times(proc_stat: &str) -> Option<CpuTimes> {
    let line = proc_stat.lines().find(|l| l.starts_with("cpu "))?;
    let values: Vec<u64> =
        line.split_whitespace().skip(1).take(8).filter_map(|v| v.parse().ok()).collect();
    if values.len() < 4 {
        return None;
    }
    let idle = values[3] + values.get(4).copied().unwrap_or(0);
    Some(CpuTimes { total: values.iter().sum(), idle })
}

/// Busy share between two samples. `None` when the counters did not advance (a sample interval
/// too short to have crossed a tick), which is honestly "unknown" rather than 0%.
pub fn utilization_percent(first: &CpuTimes, second: &CpuTimes) -> Option<f64> {
    let total = second.total.checked_sub(first.total)?;
    let idle = second.idle.checked_sub(first.idle)?;
    if total == 0 {
        return None;
    }
    let busy = total.saturating_sub(idle) as f64;
    Some((busy / total as f64) * 100.0)
}

/// Online CPUs, counted from the per-core `cpuN` lines of `/proc/stat` -- the same file the
/// utilisation comes from, so the two can never describe different sets of CPUs.
pub fn parse_cpu_count(proc_stat: &str) -> usize {
    proc_stat
        .lines()
        .filter(|l| l.starts_with("cpu") && l.as_bytes().get(3).is_some_and(u8::is_ascii_digit))
        .count()
}

// ---------------------------------------------------------------------------------------------
// Memory

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Memory {
    pub total: u64,
    pub free: u64,
    pub available: u64,
    pub swap_total: u64,
    pub swap_free: u64,
}

/// `/proc/meminfo` values are kB (1024 bytes), converted to bytes here so every byte-valued
/// field this producer emits has the same unit.
pub fn parse_meminfo(text: &str) -> Option<Memory> {
    let field = |name: &str| -> Option<u64> {
        let line = text.lines().find(|l| l.starts_with(&format!("{name}:")))?;
        let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
        Some(kb * 1024)
    };

    Some(Memory {
        total: field("MemTotal")?,
        free: field("MemFree")?,
        // MemAvailable, not MemTotal - MemFree: reclaimable page cache is available to
        // applications, and counting it as used makes every healthy host look full.
        available: field("MemAvailable")?,
        swap_total: field("SwapTotal").unwrap_or(0),
        swap_free: field("SwapFree").unwrap_or(0),
    })
}

// ---------------------------------------------------------------------------------------------
// Filesystems

#[derive(Debug, Clone, PartialEq)]
pub struct Mount {
    pub device: String,
    pub mountpoint: String,
    pub fstype: String,
}

/// `/proc/mounts` escapes space, tab, newline and backslash in the device and mountpoint fields
/// as three-digit octal. Undoing that matters for real mountpoints ("/mnt/My Disk"), and getting
/// it wrong would silently mislabel a record's `mountpoint` attribute.
fn unescape_mount_field(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = String::with_capacity(field.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 3 < bytes.len() {
            if let Some(byte) = std::str::from_utf8(&bytes[i + 1..i + 4])
                .ok()
                .and_then(|octal| u8::from_str_radix(octal, 8).ok())
            {
                out.push(byte as char);
                i += 4;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

/// Mounts worth measuring, in `/proc/mounts` order, minus the excluded filesystem types.
///
/// A mountpoint that appears twice keeps only its LAST entry: that is the mount actually visible
/// at the path, and the earlier one is shadowed and unreachable.
pub fn parse_mounts(text: &str, exclude_fstypes: &[String]) -> Vec<Mount> {
    let excluded: HashSet<&str> = exclude_fstypes.iter().map(String::as_str).collect();

    let mut mounts: Vec<Mount> = Vec::new();
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let (Some(device), Some(mountpoint), Some(fstype)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        if excluded.contains(fstype) {
            continue;
        }
        let mountpoint = unescape_mount_field(mountpoint);
        mounts.retain(|m| m.mountpoint != mountpoint);
        mounts.push(Mount {
            device: unescape_mount_field(device),
            mountpoint,
            fstype: fstype.to_owned(),
        });
    }
    mounts
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Usage {
    pub fsid: u64,
    pub total: u64,
    pub free: u64,
    pub available: u64,
}

/// Block counts are in `f_frsize` units; `f_bsize` is the preferred I/O size and using it here
/// is the classic way to get sizes wrong on filesystems where the two differ.
///
/// `f_flag` is deliberately not reported. An SD card that has flipped its root filesystem
/// read-only would be worth knowing about, but the collector runs under `ProtectSystem=strict`,
/// which read-only-remounts the whole hierarchy inside its own mount namespace -- so `ST_RDONLY`
/// here describes the sandbox, not the disk, and comes back set for every mount on a perfectly
/// healthy host. A field that is always true measures nothing.
pub fn usage(path: &Path) -> std::io::Result<Usage> {
    let stat = rustix::fs::statvfs(path)?;
    let unit = if stat.f_frsize > 0 { stat.f_frsize } else { stat.f_bsize };
    Ok(Usage {
        fsid: stat.f_fsid,
        total: stat.f_blocks * unit,
        free: stat.f_bfree * unit,
        available: stat.f_bavail * unit,
    })
}

/// `df`'s denominator, not `total`: the blocks reserved for root are counted as neither used
/// nor available, so `used / total` reads a few percent lower than what every other tool on the
/// host prints. The disk-space health check in `modules/monitoring.nix` alerts on `df`'s number,
/// and one filesystem with two disagreeing percentages would be worse than either.
pub fn used_percent(used: u64, available: u64) -> Option<f64> {
    let denominator = used + available;
    if denominator == 0 {
        return None;
    }
    Some((used as f64 / denominator as f64) * 100.0)
}

// ---------------------------------------------------------------------------------------------
// NixOS generation

/// `/nix/var/nix/profiles/system` points at `system-<N>-link`.
pub fn parse_generation(link_target: &str) -> Option<u64> {
    let name = Path::new(link_target).file_name()?.to_str()?;
    name.strip_prefix("system-")?.strip_suffix("-link")?.parse().ok()
}

// ---------------------------------------------------------------------------------------------
// Host

/// First field of `/proc/uptime`, in seconds.
pub fn parse_uptime_seconds(text: &str) -> Option<f64> {
    text.split_whitespace().next()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROC_STAT: &str = "\
cpu  1000 20 300 8000 100 0 30 0 0 0
cpu0 500 10 150 4000 50 0 15 0 0 0
cpu1 500 10 150 4000 50 0 15 0 0 0
intr 12345
ctxt 67890
";

    #[test]
    fn loadavg_takes_the_three_averages() {
        let parsed = parse_loadavg("0.52 0.41 0.38 2/431 1234\n").unwrap();
        assert_eq!(parsed, LoadAvg { one: 0.52, five: 0.41, fifteen: 0.38 });
    }

    #[test]
    fn cpu_times_count_iowait_as_idle_and_ignore_guest() {
        let times = parse_cpu_times(PROC_STAT).unwrap();
        assert_eq!(times.total, 1000 + 20 + 300 + 8000 + 100 + 0 + 30 + 0);
        assert_eq!(times.idle, 8000 + 100);
    }

    #[test]
    fn cpu_count_comes_from_the_per_core_lines_only() {
        assert_eq!(parse_cpu_count(PROC_STAT), 2);
    }

    #[test]
    fn utilization_is_the_busy_share_of_the_delta() {
        let first = CpuTimes { total: 1000, idle: 900 };
        let second = CpuTimes { total: 1200, idle: 1050 };
        // 200 ticks elapsed, 150 of them idle -> 25% busy.
        assert_eq!(utilization_percent(&first, &second), Some(25.0));
    }

    #[test]
    fn utilization_is_unknown_rather_than_zero_when_nothing_elapsed() {
        let same = CpuTimes { total: 1000, idle: 900 };
        assert_eq!(utilization_percent(&same, &same), None);
    }

    #[test]
    fn meminfo_converts_kb_to_bytes_and_prefers_available() {
        let parsed = parse_meminfo(
            "\
MemTotal:       16311428 kB
MemFree:          402060 kB
MemAvailable:   12006884 kB
Buffers:          128000 kB
SwapTotal:       8388604 kB
SwapFree:        8388604 kB
",
        )
        .unwrap();
        assert_eq!(parsed.total, 16311428 * 1024);
        assert_eq!(parsed.available, 12006884 * 1024);
        assert_eq!(parsed.swap_total, 8388604 * 1024);
        assert_ne!(parsed.available, parsed.total - parsed.free);
    }

    #[test]
    fn meminfo_tolerates_a_host_without_swap() {
        let parsed = parse_meminfo("MemTotal: 100 kB\nMemFree: 40 kB\nMemAvailable: 60 kB\n")
            .unwrap();
        assert_eq!(parsed.swap_total, 0);
        assert_eq!(parsed.swap_free, 0);
    }

    fn excludes() -> Vec<String> {
        ["tmpfs", "proc", "sysfs", "9p"].iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn mounts_drop_the_excluded_filesystem_types() {
        let mounts = parse_mounts(
            "\
proc /proc proc rw,relatime 0 0
/dev/disk/by-label/nixos / ext4 rw,relatime 0 0
tmpfs /run tmpfs rw,nosuid 0 0
nixstore /nix/store 9p ro,trans=virtio 0 0
/dev/sda1 /boot vfat rw,relatime 0 0
",
            &excludes(),
        );
        let paths: Vec<&str> = mounts.iter().map(|m| m.mountpoint.as_str()).collect();
        assert_eq!(paths, vec!["/", "/boot"]);
        assert_eq!(mounts[0].fstype, "ext4");
        assert_eq!(mounts[0].device, "/dev/disk/by-label/nixos");
    }

    #[test]
    fn a_shadowed_mountpoint_keeps_only_the_visible_mount() {
        let mounts = parse_mounts(
            "\
/dev/sda1 /data ext4 rw 0 0
/dev/sdb1 /data xfs rw 0 0
",
            &excludes(),
        );
        assert_eq!(mounts.len(), 1);
        assert_eq!(mounts[0].fstype, "xfs");
    }

    #[test]
    fn mount_fields_are_octal_unescaped() {
        let mounts = parse_mounts("/dev/sdc1 /mnt/My\\040Disk ext4 rw 0 0\n", &excludes());
        assert_eq!(mounts[0].mountpoint, "/mnt/My Disk");
    }

    #[test]
    fn used_percent_is_none_for_a_zero_sized_filesystem() {
        assert_eq!(used_percent(0, 0), None);
    }

    /// 1000 total, 250 free of which 50 are root-reserved: `df` calls that 80% full
    /// (750 / (750 + 200)), not 75% (750 / 1000).
    #[test]
    fn used_percent_matches_df_by_ignoring_root_reserved_blocks() {
        assert_eq!(used_percent(750, 200), Some(78.94736842105263));
        assert_eq!(used_percent(750, 250), Some(75.0));
    }

    #[test]
    fn generation_number_comes_from_the_profile_link_target() {
        assert_eq!(parse_generation("/nix/var/nix/profiles/system-42-link"), Some(42));
        assert_eq!(parse_generation("system-1-link"), Some(1));
        assert_eq!(parse_generation("/nix/store/abc-nixos-system-host-26.05"), None);
    }

    #[test]
    fn uptime_takes_the_first_field() {
        assert_eq!(parse_uptime_seconds("12345.67 98765.43\n"), Some(12345.67));
    }

    #[test]
    fn optional_field_omits_rather_than_nulls() {
        let record = Record::new("system.generation").with_optional_field("current", None);
        assert!(record.body.is_empty());
    }
}
