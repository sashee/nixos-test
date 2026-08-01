//! Collect basic host metrics once and report them to a local monitoring-platform receiver.
//!
//! Runs as a systemd oneshot on a timer (see `modules/system-metrics.nix`), so this is a
//! collect-encode-post-exit program: no daemon, no buffering, no retry. A failed run exits
//! non-zero and the timer tries again on its next tick, which keeps the failure visible in
//! `systemctl status` instead of hidden in a retry loop.

mod collect;
mod otlp;
mod uds;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
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
}

const USAGE: &str = "\
usage: system-metrics [options]

  --socket PATH             receiver unix socket (default: /run/monitoring-platform/monitoring-platform.sock)
  --resource-attr KEY=VALUE resource attribute to attach to every record; repeatable
  --exclude-fstype TYPE     filesystem type to skip; repeatable. No types are excluded by
                            default -- the list is owned by the NixOS module so there is only
                            one copy of it
  --cpu-sample-seconds N    seconds between the two /proc/stat samples (default: 1)
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
            "--dry-run" => options.dry_run = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }

    Ok(Some(options))
}

fn read(path: &str) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))
}

/// Trailing-newline-free contents of a `/proc/sys` style file.
fn read_trimmed(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_owned())
}

fn cpu_record(cpu_sample: Duration) -> Result<Record, String> {
    let loadavg = collect::parse_loadavg(&read("/proc/loadavg")?)
        .ok_or_else(|| "unparsable /proc/loadavg".to_owned())?;

    let stat = read("/proc/stat")?;
    let first = collect::parse_cpu_times(&stat)
        .ok_or_else(|| "no aggregate cpu line in /proc/stat".to_owned())?;
    std::thread::sleep(cpu_sample);
    let second = collect::parse_cpu_times(&read("/proc/stat")?)
        .ok_or_else(|| "no aggregate cpu line in /proc/stat".to_owned())?;

    Ok(Record::new("system.cpu")
        .with_field("load1", Value::Double(loadavg.one))
        .with_field("load5", Value::Double(loadavg.five))
        .with_field("load15", Value::Double(loadavg.fifteen))
        .with_field("cores", Value::Int(collect::parse_cpu_count(&stat) as i64))
        .with_optional_field(
            "utilization_percent",
            collect::utilization_percent(&first, &second).map(Value::Double),
        ))
}

fn memory_record() -> Result<Record, String> {
    let memory = collect::parse_meminfo(&read("/proc/meminfo")?)
        .ok_or_else(|| "unparsable /proc/meminfo".to_owned())?;

    Ok(Record::new("system.memory")
        .with_field("total_bytes", Value::Int(memory.total as i64))
        .with_field("free_bytes", Value::Int(memory.free as i64))
        .with_field("available_bytes", Value::Int(memory.available as i64))
        .with_field(
            "used_bytes",
            Value::Int(memory.total.saturating_sub(memory.available) as i64),
        )
        .with_field("swap_total_bytes", Value::Int(memory.swap_total as i64))
        .with_field(
            "swap_used_bytes",
            Value::Int(memory.swap_total.saturating_sub(memory.swap_free) as i64),
        ))
}

/// One record per distinct filesystem. Bind mounts and the NixOS read-only `/nix/store` remount
/// report the same `f_fsid` as the filesystem they come from, so keeping only the first
/// mountpoint per fsid stops one disk being counted several times over.
fn filesystem_records(exclude_fstypes: &[String]) -> Result<Vec<Record>, String> {
    let mounts = collect::parse_mounts(&read("/proc/mounts")?, exclude_fstypes);

    let mut seen_fsids = Vec::new();
    let mut records = Vec::new();
    for mount in mounts {
        let usage = match collect::usage(Path::new(&mount.mountpoint)) {
            Ok(usage) => usage,
            // A mount can disappear or refuse statvfs (an unreachable network mount) between
            // reading /proc/mounts and stat'ing it. That is not a reason to lose the whole batch.
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
                .with_field("available_bytes", Value::Int(usage.available as i64))
                .with_field(
                    "used_bytes",
                    Value::Int(usage.total.saturating_sub(usage.free) as i64),
                )
                .with_optional_field(
                    "used_percent",
                    collect::used_percent(usage.total.saturating_sub(usage.free), usage.available)
                        .map(Value::Double),
                ),
        );
    }
    Ok(records)
}

fn read_link(path: &str) -> Option<String> {
    fs::read_link(path).ok().map(|target| target.to_string_lossy().into_owned())
}

/// The system profile symlink only exists once something has set it (`nixos-rebuild`, or
/// `nix-env -p`), so a freshly booted VM has no generation number at all. That omits the
/// `current` key rather than reporting a made-up 0.
fn generation_record() -> Record {
    let profile = read_link(SYSTEM_PROFILE);
    let current_system = read_link("/run/current-system");
    let booted_system = read_link("/run/booted-system");

    // Compares whole system closures, so it also catches an activation that changed nothing the
    // kernel cares about; "there is a newer system than the running one" is the useful signal.
    let activated_since_boot = match (&current_system, &booted_system) {
        (Some(current), Some(booted)) => Some(Value::Bool(current != booted)),
        _ => None,
    };

    Record::new("system.generation")
        .with_optional_field(
            "current",
            profile.as_deref().and_then(collect::parse_generation).map(|n| Value::Int(n as i64)),
        )
        .with_optional_field("current_system", current_system.map(Value::Str))
        .with_optional_field("booted_system", booted_system.map(Value::Str))
        .with_optional_field("activated_since_boot", activated_since_boot)
}

fn host_record() -> Result<Record, String> {
    let uptime = collect::parse_uptime_seconds(&read("/proc/uptime")?)
        .ok_or_else(|| "unparsable /proc/uptime".to_owned())?;

    Ok(Record::new("system.host")
        .with_field("uptime_seconds", Value::Double(uptime))
        .with_optional_field(
            "kernel_release",
            read_trimmed("/proc/sys/kernel/osrelease").map(Value::Str),
        )
        .with_optional_field(
            "nixos_version",
            read_trimmed("/run/current-system/nixos-version").map(Value::Str),
        ))
}

fn format_pairs(pairs: &[(String, Value)]) -> String {
    pairs
        .iter()
        .map(|(key, value)| match value {
            Value::Str(s) => format!("{key}={s}"),
            Value::Int(i) => format!("{key}={i}"),
            Value::Double(d) => format!("{key}={d}"),
            Value::Bool(b) => format!("{key}={b}"),
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

    let mut resource_attributes = vec![("service.name".to_owned(), Value::str("system-metrics"))];
    if let Some(hostname) = read_trimmed("/proc/sys/kernel/hostname") {
        resource_attributes.push(("host.name".to_owned(), Value::Str(hostname)));
    }
    resource_attributes.extend(options.resource_attributes.iter().cloned());

    let mut records = vec![cpu_record(options.cpu_sample)?, memory_record()?];
    records.extend(filesystem_records(&options.exclude_fstypes)?);
    records.push(generation_record());
    records.push(host_record()?);

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
        assert!(parse_args(args(&["--nope"]).into_iter()).is_err());
    }

    #[test]
    fn help_short_circuits_before_collecting_anything() {
        assert!(parse_args(args(&["--help"]).into_iter()).unwrap().is_none());
    }
}
