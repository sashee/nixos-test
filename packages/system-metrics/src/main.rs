//! Collect basic host metrics once and report them to a local monitoring-platform receiver.
//!
//! Runs as a systemd oneshot on a timer (see `modules/system-metrics.nix`), so this is a
//! collect-encode-post-exit program: no daemon, no buffering, no retry. A failed run exits
//! non-zero and the timer tries again on its next tick, which keeps the failure visible in
//! `systemctl status` instead of hidden in a retry loop.
//!
//! Only the *transport* can fail a run. Every measurement degrades instead: a field that cannot
//! be read is sent as null, and a whole group that cannot be enumerated contributes no records.
//! The alternative -- the collector's original behaviour, where any required field aborted the
//! batch -- meant an unreadable `flake.lock` could cost a tick's CPU, memory and filesystem
//! samples, letting the least important field destroy the most important data.

mod collect;
mod otlp;
mod sensors;
mod smart;
mod systemd;
mod uds;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use collect::{Record, Value};

const DEFAULT_SOCKET: &str = "/run/monitoring-platform/monitoring-platform.sock";
const INGEST_PATH: &str = "/v1/logs";
const PROTOBUF: &str = "application/x-protobuf";
const SYSTEM_PROFILE: &str = "/nix/var/nix/profiles/system";

struct Options {
    socket: PathBuf,
    resource_attributes: Vec<(String, Value)>,
    exclude_fstypes: Vec<String>,
    cpu_sample: Duration,
    dry_run: bool,
    sysfs_root: PathBuf,
    hwmon_root: Option<PathBuf>,
    profiles_dir: PathBuf,
    flake_lock: Option<PathBuf>,
    flake_input: String,
    success_dir: PathBuf,
    units: Vec<String>,
    timers: Vec<String>,
    journal_window: Duration,
    iroh_failsafe_marker: Option<PathBuf>,
    failsafe_rule_tag: String,
    systemctl: Option<PathBuf>,
    busctl: Option<PathBuf>,
    journalctl: Option<PathBuf>,
    smartctl: Option<PathBuf>,
    nft: Option<PathBuf>,
}

const USAGE: &str = "\
usage: system-metrics [options]

  --socket PATH             receiver unix socket (default: /run/monitoring-platform/monitoring-platform.sock)
  --resource-attr KEY=VALUE resource attribute to attach to every record; repeatable
  --exclude-fstype TYPE     filesystem type to skip; repeatable. No types are excluded by
                            default -- the list is owned by the NixOS module so there is only
                            one copy of it
  --cpu-sample-seconds N    seconds between the two /proc/stat samples (default: 1)
  --sysfs-root PATH         root of sysfs, for the zram sweep (default: /sys)
  --hwmon-root PATH         hwmon class directory (default: <sysfs-root>/class/hwmon)
  --profiles-dir PATH       nix profiles directory (default: /nix/var/nix/profiles)
  --flake-lock PATH         deployed flake.lock; without it the common_* fields are null
  --flake-input NAME        flake.lock node to report (default: common)
  --success-dir PATH        directory of <unit>.last-success markers
                            (default: /var/lib/common-monitoring)
  --unit NAME               systemd unit to report on; repeatable. Failing units are always
                            reported whether listed or not
  --timer NAME              systemd timer to report on; repeatable
  --journal-window-seconds N  how far back the journal counts reach (default: 900)
  --iroh-failsafe-marker PATH  last-engaged marker; its presence enables the failsafe record
  --failsafe-rule-tag TAG   nft rule comment marking an engaged failsafe
                            (default: iroh-ssh-failsafe)
  --systemctl PATH          systemctl binary; without it no unit records
  --busctl PATH             busctl binary; without it no timer records. Separate from
                            systemctl because timer elapse properties are only machine-readable
                            over the bus
  --journalctl PATH         journalctl binary; without it no journal records
  --smartctl PATH           smartctl binary; without it no drive records
  --nft PATH                nft binary; without it port_22_open is null
  --dry-run                 print the batch instead of posting it
  --help                    this text
";

fn parse_args(args: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut options = Options {
        socket: PathBuf::from(DEFAULT_SOCKET),
        resource_attributes: Vec::new(),
        exclude_fstypes: Vec::new(),
        cpu_sample: Duration::from_secs(1),
        dry_run: false,
        sysfs_root: PathBuf::from("/sys"),
        hwmon_root: None,
        profiles_dir: PathBuf::from("/nix/var/nix/profiles"),
        flake_lock: None,
        flake_input: "common".to_owned(),
        success_dir: PathBuf::from("/var/lib/common-monitoring"),
        units: Vec::new(),
        timers: Vec::new(),
        journal_window: Duration::from_secs(900),
        iroh_failsafe_marker: None,
        failsafe_rule_tag: "iroh-ssh-failsafe".to_owned(),
        systemctl: None,
        busctl: None,
        journalctl: None,
        smartctl: None,
        nft: None,
    };

    let mut args = args;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| -> Result<String, String> {
            args.next().ok_or_else(|| format!("{name} needs a value"))
        };
        match arg.as_str() {
            "--help" | "-h" => return Ok(None),
            "--socket" => options.socket = PathBuf::from(value("--socket")?),
            "--resource-attr" => {
                let raw = value("--resource-attr")?;
                let (key, val) = raw
                    .split_once('=')
                    .ok_or_else(|| format!("--resource-attr expects KEY=VALUE, got {raw:?}"))?;
                options.resource_attributes.push((key.to_owned(), Value::str(val)));
            }
            "--exclude-fstype" => options.exclude_fstypes.push(value("--exclude-fstype")?),
            "--cpu-sample-seconds" => {
                let raw = value("--cpu-sample-seconds")?;
                let seconds: f64 = raw
                    .parse()
                    .map_err(|_| format!("--cpu-sample-seconds expects a number, got {raw:?}"))?;
                if !(seconds.is_finite() && seconds > 0.0) {
                    return Err(format!("--cpu-sample-seconds must be positive, got {raw:?}"));
                }
                options.cpu_sample = Duration::from_secs_f64(seconds);
            }
            "--sysfs-root" => options.sysfs_root = PathBuf::from(value("--sysfs-root")?),
            "--hwmon-root" => options.hwmon_root = Some(PathBuf::from(value("--hwmon-root")?)),
            "--profiles-dir" => options.profiles_dir = PathBuf::from(value("--profiles-dir")?),
            "--flake-lock" => options.flake_lock = Some(PathBuf::from(value("--flake-lock")?)),
            "--flake-input" => options.flake_input = value("--flake-input")?,
            "--success-dir" => options.success_dir = PathBuf::from(value("--success-dir")?),
            "--unit" => options.units.push(value("--unit")?),
            "--timer" => options.timers.push(value("--timer")?),
            "--journal-window-seconds" => {
                let raw = value("--journal-window-seconds")?;
                let seconds: u64 = raw.parse().map_err(|_| {
                    format!("--journal-window-seconds expects a whole number, got {raw:?}")
                })?;
                if seconds == 0 {
                    return Err("--journal-window-seconds must be positive".to_owned());
                }
                options.journal_window = Duration::from_secs(seconds);
            }
            "--iroh-failsafe-marker" => {
                options.iroh_failsafe_marker = Some(PathBuf::from(value("--iroh-failsafe-marker")?))
            }
            "--failsafe-rule-tag" => options.failsafe_rule_tag = value("--failsafe-rule-tag")?,
            "--systemctl" => options.systemctl = Some(PathBuf::from(value("--systemctl")?)),
            "--busctl" => options.busctl = Some(PathBuf::from(value("--busctl")?)),
            "--journalctl" => options.journalctl = Some(PathBuf::from(value("--journalctl")?)),
            "--smartctl" => options.smartctl = Some(PathBuf::from(value("--smartctl")?)),
            "--nft" => options.nft = Some(PathBuf::from(value("--nft")?)),
            "--dry-run" => options.dry_run = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }

    Ok(Some(options))
}

// ---------------------------------------------------------------------------------------------
// Reading helpers. Each returns an Option, and every caller turns that into a null field.

fn read(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok()
}

/// Trailing-newline-free contents of a `/proc/sys` style file.
fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
    read(path).map(|s| s.trim().to_owned())
}

fn read_link(path: impl AsRef<Path>) -> Option<String> {
    fs::read_link(path).ok().map(|target| target.to_string_lossy().into_owned())
}

/// Standard output of a command that exited zero, or `None` if it could not be run.
///
/// A tool that is absent, unreadable or failing is the same thing as a fact this host cannot
/// report, so it degrades to nulls exactly like an unreadable file does.
fn output(program: &Path, args: &[&str]) -> Option<String> {
    let result = Command::new(program).args(args).output().ok()?;
    if !result.status.success() {
        return None;
    }
    String::from_utf8(result.stdout).ok()
}

fn unix_micros_now() -> Option<u64> {
    SystemTime::now().duration_since(UNIX_EPOCH).ok().map(|d| d.as_micros() as u64)
}

/// CLOCK_MONOTONIC in microseconds, which is what systemd's `*Monotonic` properties are measured
/// against. Wall-clock would be the wrong base on a host whose clock steps by hours at first
/// sync.
fn monotonic_micros_now() -> u64 {
    let now = rustix::time::clock_gettime(rustix::time::ClockId::Monotonic);
    now.tv_sec as u64 * 1_000_000 + now.tv_nsec as u64 / 1_000
}

// ---------------------------------------------------------------------------------------------
// Records

fn cpu_record(cpu_sample: Duration) -> Record {
    let loadavg = read("/proc/loadavg").as_deref().and_then(collect::parse_loadavg);

    let stat = read("/proc/stat");
    let first = stat.as_deref().and_then(collect::parse_cpu_times);
    std::thread::sleep(cpu_sample);
    let second = read("/proc/stat").as_deref().and_then(collect::parse_cpu_times);
    let utilization = first
        .zip(second)
        .and_then(|(first, second)| collect::utilization_percent(&first, &second));

    Record::new("system.cpu")
        .with_field("load1", loadavg.map(|l| Value::Double(l.one)))
        .with_field("load5", loadavg.map(|l| Value::Double(l.five)))
        .with_field("load15", loadavg.map(|l| Value::Double(l.fifteen)))
        .with_field("cores", stat.as_deref().map(|s| Value::Int(collect::parse_cpu_count(s) as i64)))
        .with_field("utilization_percent", utilization.map(Value::Double))
}

/// Sums a per-zram-device sysfs attribute across every device.
///
/// A host with no zram sums to zero rather than to null: "there is no zram" and "zram holds
/// nothing" are both honestly zero bytes of RAM spent on swap, and the swap size is already
/// reported separately by `swap_total_bytes`.
fn zram_sum(sysfs_root: &Path, attribute: &str, parse: impl Fn(&str) -> Option<u64>) -> u64 {
    let Ok(entries) = fs::read_dir(sysfs_root.join("block")) else {
        return 0;
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("zram"))
        .filter_map(|entry| read(entry.path().join(attribute)))
        .filter_map(|text| parse(text.trim()))
        .sum()
}

fn memory_record(sysfs_root: &Path) -> Record {
    let memory = read("/proc/meminfo").as_deref().and_then(collect::parse_meminfo);
    let vmstat = read("/proc/vmstat");

    Record::new("system.memory")
        .with_field("total_bytes", memory.map(|m| Value::Int(m.total as i64)))
        .with_field("free_bytes", memory.map(|m| Value::Int(m.free as i64)))
        .with_field("available_bytes", memory.map(|m| Value::Int(m.available as i64)))
        .with_field("swap_total_bytes", memory.map(|m| Value::Int(m.swap_total as i64)))
        .with_field("swap_free_bytes", memory.map(|m| Value::Int(m.swap_free as i64)))
        .with_field(
            "zramswap_memory_bytes",
            Value::Int(zram_sum(sysfs_root, "mm_stat", collect::parse_zram_mem_used_total) as i64),
        )
        .with_field(
            "zramswap_total_bytes",
            Value::Int(zram_sum(sysfs_root, "disksize", |text| text.parse().ok()) as i64),
        )
        .with_field(
            "oom_kill",
            vmstat
                .as_deref()
                .and_then(|text| collect::parse_vmstat_counter(text, "oom_kill"))
                .map(|count| Value::Int(count as i64)),
        )
}

/// One record per distinct filesystem. Bind mounts and the NixOS read-only `/nix/store` remount
/// report the same `f_fsid` as the filesystem they come from, so keeping only the first
/// mountpoint per fsid stops one disk being counted several times over.
fn filesystem_records(exclude_fstypes: &[String]) -> Vec<Record> {
    let Some(mounts) = read("/proc/mounts") else {
        return Vec::new();
    };

    let mut seen_fsids = Vec::new();
    let mut records = Vec::new();
    for mount in collect::parse_mounts(&mounts, exclude_fstypes) {
        let usage = match collect::usage(Path::new(&mount.mountpoint)) {
            Ok(usage) => usage,
            // A mount can disappear or refuse statvfs (an unreachable network mount) between
            // reading /proc/mounts and stat'ing it. Reporting it with null sizes would claim the
            // filesystem exists and is unmeasurable, when in practice it is simply gone.
            Err(e) => {
                eprintln!("skipping {}: {e}", mount.mountpoint);
                continue;
            }
        };
        if usage.fsid != 0 && seen_fsids.contains(&usage.fsid) {
            continue;
        }
        seen_fsids.push(usage.fsid);

        records.push(
            Record::new("system.filesystem")
                .with_attr("mountpoint", Value::str(&mount.mountpoint))
                .with_attr("device", Value::str(&mount.device))
                .with_attr("fstype", Value::str(&mount.fstype))
                .with_field("total_bytes", Value::Int(usage.total as i64))
                .with_field("free_bytes", Value::Int(usage.free as i64))
                .with_field("available_bytes", Value::Int(usage.available as i64)),
        );
    }
    records
}

/// Every hwmon chip's readable attributes, one record per attribute.
///
/// Chips are matched by their `name` file and disambiguated by the `device` symlink, never by
/// the hwmonN index: the numbering is assignment order and moves between boots, so `hwmon3` is
/// `rpi_volt` on one boot and something else on the next.
fn sensor_records(hwmon_root: &Path) -> Vec<Record> {
    let Ok(chips) = fs::read_dir(hwmon_root) else {
        return Vec::new();
    };

    let mut records = Vec::new();
    for chip in chips.filter_map(Result::ok) {
        let path = chip.path();
        let chip_name = read_trimmed(path.join("name"));
        let device = fs::canonicalize(path.join("device"))
            .ok()
            .and_then(|target| Some(target.file_name()?.to_string_lossy().into_owned()));

        let Ok(files) = fs::read_dir(&path) else {
            continue;
        };
        let mut names: Vec<String> =
            files.filter_map(Result::ok).map(|f| f.file_name().to_string_lossy().into_owned()).collect();
        // read_dir order is filesystem order; sorting keeps a batch's records stable between
        // runs, which makes a diff of two dry-runs readable.
        names.sort();

        for name in names {
            let Some(parsed) = sensors::parse_sensor_filename(&name) else {
                continue;
            };
            let Some(raw) = read_trimmed(path.join(&name)) else {
                continue;
            };

            let (body_key, value) = match &parsed.reading {
                sensors::Reading::Input { body_key } => {
                    (*body_key, raw.parse::<i64>().ok().map(Value::Int))
                }
                // hwmon alarms are 0/1; anything else is a driver this producer does not
                // understand, and a null says so.
                sensors::Reading::Alarm { .. } => (
                    "triggered",
                    match raw.as_str() {
                        "0" => Some(Value::Bool(false)),
                        "1" => Some(Value::Bool(true)),
                        _ => None,
                    },
                ),
            };
            let threshold = match &parsed.reading {
                sensors::Reading::Alarm { threshold } => threshold.clone(),
                sensors::Reading::Input { .. } => None,
            };

            records.push(
                Record::new("system.sensor")
                    .with_attr("chip", chip_name.clone().map(Value::Str))
                    .with_attr("sensor", Value::str(&parsed.sensor))
                    .with_attr("kind", Value::str(&parsed.kind))
                    .with_attr(
                        "label",
                        read_trimmed(path.join(format!("{}_label", parsed.sensor))).map(Value::Str),
                    )
                    .with_attr("threshold", threshold.map(Value::Str))
                    .with_attr("device", device.clone().map(Value::Str))
                    .with_field(body_key, value),
            );
        }
    }
    records
}

/// One `system.drive` per SMART-capable device, plus a family-specific sub measurement.
///
/// The families are separate measurement types rather than one record with a `kind` attribute
/// because `type` is the only indexed column in the receiver's store: as `system.drive.nvme` a
/// query for wear rides the index, while as an attribute it would scan every row ever written.
fn drive_records(smartctl: &Path) -> Vec<Record> {
    let Some(scan) = output(smartctl, &["--scan-open", "--json"]) else {
        return Vec::new();
    };

    let mut records = Vec::new();
    for device in smart::parse_scan(&scan) {
        let mut args = vec!["--json", "--health", "--all"];
        if let Some(dev_type) = &device.dev_type {
            args.push("-d");
            args.push(dev_type);
        }
        args.push(&device.name);

        // smartctl exits non-zero for conditions that are still perfectly readable (bit 2 is
        // "some SMART command failed"), so the JSON is parsed regardless of status.
        let Some(text) = Command::new(smartctl)
            .args(&args)
            .output()
            .ok()
            .and_then(|out| String::from_utf8(out.stdout).ok())
        else {
            continue;
        };
        let Some(drive) = smart::parse_smart(&text) else {
            continue;
        };

        let identify = |record: Record| {
            record
                .with_attr("sn", drive.serial.clone().map(Value::Str))
                .with_attr("model", drive.model.clone().map(Value::Str))
        };

        records.push(
            identify(Record::new("system.drive"))
                .with_attr("kind", drive.kind.map(|k| Value::str(k.as_str())))
                .with_field("passed", drive.passed.map(Value::Bool))
                .with_field("power_on_hours", drive.power_on_hours.map(Value::Int)),
        );

        if let Some(nvme) = &drive.nvme {
            records.push(
                identify(Record::new("system.drive.nvme"))
                    .with_field("percentage_used", nvme.percentage_used.map(Value::Int))
                    .with_field("available_spare", nvme.available_spare.map(Value::Int))
                    .with_field("media_errors", nvme.media_errors.map(Value::Int))
                    .with_field("unsafe_shutdowns", nvme.unsafe_shutdowns.map(Value::Int))
                    .with_field("critical_warning", nvme.critical_warning.map(Value::Int)),
            );
        }

        if let Some(sata) = &drive.sata {
            let attribute = |name: &str| sata.attributes.get(name).copied().map(Value::Int);
            records.push(
                identify(Record::new("system.drive.sata"))
                    .with_field("reallocated_sector_ct", attribute("reallocated_sector_ct"))
                    .with_field("reported_uncorrect", attribute("reported_uncorrect"))
                    .with_field("command_timeout", attribute("command_timeout"))
                    .with_field("current_pending_sector", attribute("current_pending_sector"))
                    .with_field("offline_uncorrectable", attribute("offline_uncorrectable"))
                    .with_field("power_cycle_count", attribute("power_cycle_count"))
                    .with_field("udma_crc_error_count", attribute("udma_crc_error_count"))
                    .with_field("wear_leveling_count", attribute("wear_leveling_count"))
                    .with_field("total_lbas_written", attribute("total_lbas_written"))
                    .with_field("failing_now", Value::Int(sata.failing_now as i64))
                    .with_field("failed_past", Value::Int(sata.failed_past as i64)),
            );
        }
    }
    records
}

/// The system profile symlink only exists once something has set it (`nixos-rebuild`, or
/// `nix-env -p`), so a freshly booted VM has no generation number at all.
fn generation_record(profiles_dir: &Path) -> Record {
    let profile = read_link(SYSTEM_PROFILE);
    let count = fs::read_dir(profiles_dir).ok().map(|entries| {
        entries
            .filter_map(Result::ok)
            .filter(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                name.starts_with("system-") && name.ends_with("-link")
            })
            .count()
    });

    Record::new("system.generation")
        .with_field(
            "current",
            profile.as_deref().and_then(collect::parse_generation).map(|n| Value::Int(n as i64)),
        )
        .with_field("current_system", read_link("/run/current-system").map(Value::Str))
        .with_field("booted_system", read_link("/run/booted-system").map(Value::Str))
        .with_field("count", count.map(|c| Value::Int(c as i64)))
}

fn host_record(flake_lock: Option<&PathBuf>, input: &str) -> Record {
    let locked = flake_lock
        .and_then(read)
        .and_then(|text| collect::parse_flake_lock(&text, input));

    Record::new("system.host")
        .with_field(
            "uptime_seconds",
            read("/proc/uptime").as_deref().and_then(collect::parse_uptime_seconds).map(Value::Double),
        )
        .with_field("kernel_release", read_trimmed("/proc/sys/kernel/osrelease").map(Value::Str))
        .with_field(
            "nixos_version",
            read_trimmed("/run/current-system/nixos-version").map(Value::Str),
        )
        .with_field(
            "common_commit_id",
            locked.as_ref().and_then(|l| l.rev.clone()).map(Value::Str),
        )
        .with_field("common_last_modified", locked.as_ref().and_then(|l| l.last_modified).map(Value::Int))
        .with_field("common_ref", locked.as_ref().and_then(|l| l.reference.clone()).map(Value::Str))
}

/// Whether the iroh-ssh failsafe has opened port 22, and when it last did.
///
/// "Port 22 closed" is the absence of the failsafe's tagged runtime rule: there is no static
/// 22-accept in the firewall, so the tag is the only thing that ever opens it.
fn iroh_failsafe_record(
    marker: &Path,
    rule_tag: &str,
    nft: Option<&PathBuf>,
    now_unix_micros: Option<u64>,
) -> Record {
    let port_22_open = nft
        .and_then(|nft| output(nft, &["list", "chain", "inet", "nixos-fw", "input-allow"]))
        .map(|chain| chain.contains(rule_tag));

    let last_engaged = read_trimmed(marker)
        .and_then(|text| text.parse::<u64>().ok())
        .zip(now_unix_micros)
        .and_then(|(engaged_unix_seconds, now)| {
            systemd::seconds_since(now, engaged_unix_seconds.checked_mul(1_000_000)?)
        });

    Record::new("system.iroh_failsafe")
        .with_field("port_22_open", port_22_open.map(Value::Bool))
        .with_field("last_engaged_seconds_ago", last_engaged.map(Value::Double))
}

/// Units to report on: the configured watch list, plus anything currently failing.
///
/// "Failing" includes `auto-restart`, not just `failed`: a unit crash-looping under `Restart=`
/// never settles into `failed`, and that is precisely the state `n_restarts` exists to expose.
fn units_to_report(systemctl: &Path, watch: &[String]) -> Vec<String> {
    let mut units: Vec<String> = watch.to_vec();
    if let Some(text) = output(
        systemctl,
        &["list-units", "--state=failed,auto-restart", "--plain", "--no-legend", "--no-pager"],
    ) {
        for unit in systemd::parse_unit_names(&text) {
            if !units.contains(&unit) {
                units.push(unit);
            }
        }
    }
    units
}

fn show(systemctl: &Path, unit: &str, properties: &[&str]) -> BTreeMap<String, String> {
    // Every property read here is rendered raw by `show` (states are plain strings, monotonic
    // timestamps plain integers). Timespan-valued properties are NOT -- see timer_records --
    // so anything added to this list wants checking against `busctl` first.
    let mut args = vec!["show", unit, "--no-pager"];
    let property_args: Vec<String> = properties.iter().map(|p| format!("--property={p}")).collect();
    args.extend(property_args.iter().map(String::as_str));
    output(systemctl, &args).map(|text| systemd::parse_show_properties(&text)).unwrap_or_default()
}

fn unit_records(
    systemctl: &Path,
    watch: &[String],
    success_dir: &Path,
    now_monotonic_micros: u64,
    now_unix_micros: Option<u64>,
) -> Vec<Record> {
    units_to_report(systemctl, watch)
        .into_iter()
        .map(|unit| {
            let properties = show(
                systemctl,
                &unit,
                &[
                    "ActiveState",
                    "SubState",
                    "Result",
                    "NRestarts",
                    "ActiveEnterTimestampMonotonic",
                ],
            );
            let property = |name: &str| properties.get(name).filter(|v| !v.is_empty()).cloned();

            let active_enter = property("ActiveEnterTimestampMonotonic")
                .as_deref()
                .and_then(systemd::parse_micros)
                .and_then(|then| systemd::seconds_since(now_monotonic_micros, then));

            // The marker is written by the unit's own OnSuccess handler, so a run that failed
            // never touches it -- which is the whole reason this is not derivable from
            // ActiveEnterTimestamp, a value a failing unit keeps refreshing.
            let last_success = read_trimmed(success_dir.join(format!("{unit}.last-success")))
                .and_then(|text| text.parse::<u64>().ok())
                .zip(now_unix_micros)
                .and_then(|(unix_seconds, now)| {
                    systemd::seconds_since(now, unix_seconds.checked_mul(1_000_000)?)
                });

            Record::new("system.unit")
                .with_attr("unit", Value::str(&unit))
                .with_field("active_state", property("ActiveState").map(Value::Str))
                .with_field("sub_state", property("SubState").map(Value::Str))
                .with_field("result", property("Result").map(Value::Str))
                .with_field(
                    "n_restarts",
                    property("NRestarts").and_then(|v| v.parse::<i64>().ok()).map(Value::Int),
                )
                .with_field("active_enter_seconds_ago", active_enter.map(Value::Double))
                .with_field("last_success_seconds_ago", last_success.map(Value::Double))
        })
        .collect()
}

/// Read over D-Bus rather than through `systemctl show`.
///
/// `show` is systemd's human-facing renderer, and for these two properties that matters:
/// it prints `NextElapseUSecMonotonic` as the timespan `1d 1h 9min 11.561569s`, where the
/// property itself is a plain `t 90551561569`. Asking the bus for the value skips the
/// formatting entirely instead of re-parsing prose back into a number.
fn timer_records(
    busctl: &Path,
    watch: &[String],
    now_monotonic_micros: u64,
    now_unix_micros: Option<u64>,
) -> Vec<Record> {
    watch
        .iter()
        .map(|timer| {
            let path = systemd::bus_unit_path(timer);
            let elapse = output(
                busctl,
                &[
                    "get-property",
                    "org.freedesktop.systemd1",
                    &path,
                    "org.freedesktop.systemd1.Timer",
                    "NextElapseUSecMonotonic",
                    "NextElapseUSecRealtime",
                ],
            )
            .map(|text| systemd::parse_busctl_micros(&text))
            .unwrap_or_default();
            let property = |index: usize| elapse.get(index).copied().flatten();

            // A calendar timer schedules in realtime and reports USEC_INFINITY on the monotonic
            // side; an OnBootSec timer does the opposite, and once it has elapsed it reports
            // neither -- normal operation, not a fault, and it lands as a null.
            let monotonic =
                property(0).and_then(|then| systemd::seconds_until(now_monotonic_micros, then));
            let realtime = property(1)
                .zip(now_unix_micros)
                .and_then(|(then, now)| systemd::seconds_until(now, then));

            Record::new("system.timer")
                .with_attr("unit", Value::str(timer))
                .with_field("next_elapse_seconds_until", monotonic.or(realtime).map(Value::Double))
        })
        .collect()
}

/// One record per unit that logged at warning or worse in the window; none for a quiet host.
///
/// The window is `now - interval` rather than a journal cursor, because a cursor is state and
/// this producer deliberately has none. A message landing exactly on the boundary may be counted
/// twice or missed, which is tolerable for a count in a way it would not be for log text.
fn journal_records(journalctl: &Path, window: Duration) -> Vec<Record> {
    let since = format!("-{}s", window.as_secs());
    let Some(text) = output(
        journalctl,
        &[
            "--since",
            &since,
            "--priority=warning",
            "--output=json",
            "--output-fields=PRIORITY,_SYSTEMD_UNIT,_TRANSPORT",
            "--no-pager",
        ],
    ) else {
        return Vec::new();
    };

    systemd::parse_journal_counts(&text)
        .into_iter()
        .map(|(unit, counts)| {
            Record::new("system.journal")
                .with_attr("unit", Value::str(&unit))
                .with_field("warning", Value::Int(counts.warning as i64))
                .with_field("err", Value::Int(counts.err as i64))
                .with_field("crit", Value::Int(counts.crit as i64))
        })
        .collect()
}

// ---------------------------------------------------------------------------------------------

fn format_pairs(pairs: &[(String, Value)]) -> String {
    pairs
        .iter()
        .map(|(key, value)| match value {
            Value::Str(s) => format!("{key}={s}"),
            Value::Int(i) => format!("{key}={i}"),
            Value::Double(d) => format!("{key}={d}"),
            Value::Bool(b) => format!("{key}={b}"),
            Value::Null => format!("{key}=null"),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn run(options: Options) -> Result<(), String> {
    // Captured before collection so every record in the batch carries one reading of the clock;
    // the receiver does the same with its own processed_time.
    let time_unix_nano = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock is before the unix epoch: {e}"))?
        .as_nanos() as u64;
    let now_unix_micros = unix_micros_now();
    let now_monotonic_micros = monotonic_micros_now();

    let mut resource_attributes = vec![("service.name".to_owned(), Value::str("system-metrics"))];
    if let Some(hostname) = read_trimmed("/proc/sys/kernel/hostname") {
        resource_attributes.push(("host.name".to_owned(), Value::Str(hostname)));
    }
    if let Some(boot_id) = read_trimmed("/proc/sys/kernel/random/boot_id") {
        resource_attributes.push(("boot_id".to_owned(), Value::Str(boot_id)));
    }
    resource_attributes.extend(options.resource_attributes.iter().cloned());

    let mut records = vec![cpu_record(options.cpu_sample), memory_record(&options.sysfs_root)];
    records.extend(filesystem_records(&options.exclude_fstypes));
    if let Some(smartctl) = &options.smartctl {
        records.extend(drive_records(smartctl));
    }
    records.push(generation_record(&options.profiles_dir));
    records.push(host_record(options.flake_lock.as_ref(), &options.flake_input));
    if let Some(marker) = &options.iroh_failsafe_marker {
        records.push(iroh_failsafe_record(
            marker,
            &options.failsafe_rule_tag,
            options.nft.as_ref(),
            now_unix_micros,
        ));
    }
    let hwmon_root = options
        .hwmon_root
        .clone()
        .unwrap_or_else(|| options.sysfs_root.join("class/hwmon"));
    records.extend(sensor_records(&hwmon_root));
    if let Some(systemctl) = &options.systemctl {
        records.extend(unit_records(
            systemctl,
            &options.units,
            &options.success_dir,
            now_monotonic_micros,
            now_unix_micros,
        ));
    }
    if let Some(busctl) = &options.busctl {
        records.extend(timer_records(
            busctl,
            &options.timers,
            now_monotonic_micros,
            now_unix_micros,
        ));
    }
    if let Some(journalctl) = &options.journalctl {
        records.extend(journal_records(journalctl, options.journal_window));
    }

    if options.dry_run {
        println!("resource {}", format_pairs(&resource_attributes));
        println!("scope {} {}", otlp::SCOPE_NAME, otlp::SCOPE_VERSION);
        for record in &records {
            println!(
                "record {} | attrs: {} | body: {}",
                record.event_name,
                format_pairs(&record.attributes),
                format_pairs(&record.body)
            );
        }
        return Ok(());
    }

    let payload = otlp::encode(&otlp::build_request(&resource_attributes, &records, time_unix_nano));
    let response = uds::post(&options.socket, INGEST_PATH, PROTOBUF, &payload)?;

    if response.status != 200 {
        return Err(format!(
            "receiver answered {} for {} record(s): {}",
            response.status,
            records.len(),
            String::from_utf8_lossy(&response.body).trim()
        ));
    }

    // A 200 does not mean everything landed: OTLP reports per-record rejections in the body so
    // clients stop retrying data that will never be accepted. Treating that as success would
    // lose measurements without a trace.
    let rejections = otlp::decode_rejections(&response.body)
        .map_err(|e| format!("undecodable ExportLogsServiceResponse: {e}"))?;
    if rejections.count > 0 {
        return Err(format!(
            "receiver rejected {} of {} record(s): {}",
            rejections.count,
            records.len(),
            rejections.message
        ));
    }

    println!("reported {} measurements to {}", records.len(), options.socket.display());
    Ok(())
}

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1)) {
        Ok(None) => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Ok(Some(options)) => match run(options) {
            Ok(()) => ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("system-metrics: {message}");
                ExitCode::FAILURE
            }
        },
        Err(message) => {
            eprintln!("system-metrics: {message}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn defaults_point_at_the_module_provided_socket() {
        let options = parse_args(args(&[]).into_iter()).unwrap().unwrap();
        assert_eq!(options.socket, PathBuf::from(DEFAULT_SOCKET));
        assert_eq!(options.cpu_sample, Duration::from_secs(1));
        assert!(!options.dry_run);
        assert!(options.exclude_fstypes.is_empty());
        assert_eq!(options.sysfs_root, PathBuf::from("/sys"));
        assert_eq!(options.flake_input, "common");
    }

    /// Every tool is opt-in: without a path the records that need it are simply not produced,
    /// which is what keeps a host that has no smartctl from failing every tick.
    #[test]
    fn tools_are_absent_until_the_module_supplies_them() {
        let options = parse_args(args(&[]).into_iter()).unwrap().unwrap();
        assert!(options.systemctl.is_none());
        assert!(options.journalctl.is_none());
        assert!(options.smartctl.is_none());
        assert!(options.nft.is_none());
        assert!(options.flake_lock.is_none());
        assert!(options.iroh_failsafe_marker.is_none());
    }

    #[test]
    fn repeatable_options_accumulate() {
        let options = parse_args(
            args(&[
                "--resource-attr",
                "device.id=dev-7",
                "--resource-attr",
                "site=budapest",
                "--exclude-fstype",
                "tmpfs",
                "--exclude-fstype",
                "9p",
                "--unit",
                "chronyd.service",
                "--unit",
                "nix-gc.service",
                "--timer",
                "nix-gc.timer",
                "--dry-run",
            ])
            .into_iter(),
        )
        .unwrap()
        .unwrap();

        assert_eq!(
            options.resource_attributes,
            vec![
                ("device.id".to_owned(), Value::str("dev-7")),
                ("site".to_owned(), Value::str("budapest")),
            ]
        );
        assert_eq!(options.exclude_fstypes, vec!["tmpfs".to_owned(), "9p".to_owned()]);
        assert_eq!(options.units, vec!["chronyd.service", "nix-gc.service"]);
        assert_eq!(options.timers, vec!["nix-gc.timer"]);
        assert!(options.dry_run);
    }

    #[test]
    fn a_resource_attr_value_may_contain_equals_signs() {
        let options =
            parse_args(args(&["--resource-attr", "note=a=b"]).into_iter()).unwrap().unwrap();
        assert_eq!(options.resource_attributes, vec![("note".to_owned(), Value::str("a=b"))]);
    }

    #[test]
    fn malformed_arguments_are_refused_rather_than_guessed() {
        assert!(parse_args(args(&["--resource-attr", "nokey"]).into_iter()).is_err());
        assert!(parse_args(args(&["--socket"]).into_iter()).is_err());
        assert!(parse_args(args(&["--cpu-sample-seconds", "0"]).into_iter()).is_err());
        assert!(parse_args(args(&["--cpu-sample-seconds", "-1"]).into_iter()).is_err());
        assert!(parse_args(args(&["--journal-window-seconds", "0"]).into_iter()).is_err());
        assert!(parse_args(args(&["--nope"]).into_iter()).is_err());
    }

    #[test]
    fn help_short_circuits_before_collecting_anything() {
        assert!(parse_args(args(&["--help"]).into_iter()).unwrap().is_none());
    }

    /// A body key is never dropped: a consumer reading `system.host` gets the same six keys from
    /// every host, whether or not this one has a flake.lock to read.
    #[test]
    fn unreadable_sources_produce_null_fields_rather_than_shorter_records() {
        let record = host_record(Some(&PathBuf::from("/nonexistent/flake.lock")), "common");
        let keys: Vec<&str> = record.body.iter().map(|(key, _)| key.as_str()).collect();
        assert_eq!(
            keys,
            vec![
                "uptime_seconds",
                "kernel_release",
                "nixos_version",
                "common_commit_id",
                "common_last_modified",
                "common_ref"
            ]
        );
        assert_eq!(record.body[3].1, Value::Null);
        assert_eq!(record.body[4].1, Value::Null);
        assert_eq!(record.body[5].1, Value::Null);
    }

    /// A host with no zram sums to zero, not to null: no zram means no RAM spent on swap.
    #[test]
    fn zram_sums_to_zero_when_there_are_no_devices() {
        assert_eq!(zram_sum(Path::new("/nonexistent"), "mm_stat", |_| Some(1)), 0);
    }

    #[test]
    fn sensor_and_drive_sweeps_are_empty_rather_than_failing_without_hardware() {
        assert!(sensor_records(Path::new("/nonexistent")).is_empty());
        assert!(drive_records(Path::new("/nonexistent/smartctl")).is_empty());
    }
}
