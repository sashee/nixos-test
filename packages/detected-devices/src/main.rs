//! Report the devices this host can see -- attached over USB, or detected over WiFi and Bluetooth --
//! to a local monitoring-platform receiver.
//!
//! A separate producer from `system-metrics` rather than more measurement types inside it, because
//! the two answer different questions and want different switches: system metrics are a passive
//! read of this host's own state and run everywhere, while these are an inventory of hardware and
//! radio neighbours that only some hosts should collect at all.
//!
//! Runs as a systemd oneshot on a timer (see `modules/detected-devices.nix`), so this is a
//! collect-encode-post-exit program: no daemon, no buffering, no retry. Only the *transport* can
//! fail a run -- every measurement degrades instead, a field that cannot be read is sent as null,
//! and a collector that cannot run at all contributes a scan record saying so.
//!
//! That last part is the point of the `*_scan` records. USB taught the lesson: a missing device row
//! and an empty socket looked identical until the port record disambiguated them. For a radio scan
//! it is worse, because "no devices" and "the scan never ran" are the same absence -- so each scan
//! emits one record carrying whether it ran, and why not if it did not.

mod ble;
mod collect;
mod otlp;
mod uds;
mod usb;
mod wifi;

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use collect::{Record, Value};

const DEFAULT_SOCKET: &str = "/run/monitoring-platform/monitoring-platform.sock";
const INGEST_PATH: &str = "/v1/logs";
const PROTOBUF: &str = "application/x-protobuf";

/// How long the capture reader gets after the scan window closes. See [`drain`].
const CAPTURE_GRACE: Duration = Duration::from_secs(2);

struct Options {
    socket: PathBuf,
    resource_attributes: Vec<(String, Value)>,
    dry_run: bool,
    usb_devices_root: Option<PathBuf>,
    wifi_interface: Option<String>,
    iw: Option<PathBuf>,
    bluetooth_adapter: String,
    bluetooth_sysfs_root: PathBuf,
    btmon: Option<PathBuf>,
    bluetoothctl: Option<PathBuf>,
    ble_scan_seconds: Duration,
    ble_scan_interval_ms: u64,
    ble_scan_window_ms: u64,
}

const USAGE: &str = "\
usage: detected-devices [options]

  --socket PATH             receiver unix socket (default: /run/monitoring-platform/monitoring-platform.sock)
  --resource-attr KEY=VALUE resource attribute to attach to every record; repeatable
  --usb-devices-root PATH   usb devices directory; without it no usb records
  --wifi-interface NAME     interface to scan; without it no wifi records
  --iw PATH                 iw binary; without it no wifi records
  --bluetooth-adapter NAME  hci adapter to scan on (default: hci0)
  --bluetooth-sysfs-root PATH  where adapters appear (default: /sys/class/bluetooth)
  --btmon PATH              btmon binary; without it no ble records
  --bluetoothctl PATH       bluetoothctl binary, used to drive the scan; without it no ble records
  --ble-scan-seconds N      how long to listen for advertisements (default: 10)
  --ble-scan-interval-ms N  LE scan interval (default: 1280)
  --ble-scan-window-ms N    LE scan window (default: 11). Window/interval is the duty cycle: BlueZ's
                            own default is window == interval == 11.25ms, i.e. 100%, which starves
                            an active connection. The default here is ~1%
  --dry-run                 print the batch instead of posting it
  --help                    this text
";

fn parse_args(args: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut options = Options {
        socket: PathBuf::from(DEFAULT_SOCKET),
        resource_attributes: Vec::new(),
        dry_run: false,
        usb_devices_root: None,
        wifi_interface: None,
        iw: None,
        bluetooth_adapter: "hci0".to_owned(),
        bluetooth_sysfs_root: PathBuf::from("/sys/class/bluetooth"),
        btmon: None,
        bluetoothctl: None,
        ble_scan_seconds: Duration::from_secs(10),
        ble_scan_interval_ms: 1280,
        ble_scan_window_ms: 11,
    };

    let mut args = args;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| -> Result<String, String> {
            args.next().ok_or_else(|| format!("{name} needs a value"))
        };
        let number = |raw: String, name: &str| -> Result<u64, String> {
            raw.parse().map_err(|_| format!("{name} expects a whole number, got {raw:?}"))
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
            "--usb-devices-root" => {
                options.usb_devices_root = Some(PathBuf::from(value("--usb-devices-root")?))
            }
            "--wifi-interface" => options.wifi_interface = Some(value("--wifi-interface")?),
            "--iw" => options.iw = Some(PathBuf::from(value("--iw")?)),
            "--bluetooth-adapter" => options.bluetooth_adapter = value("--bluetooth-adapter")?,
            "--bluetooth-sysfs-root" => {
                options.bluetooth_sysfs_root = PathBuf::from(value("--bluetooth-sysfs-root")?)
            }
            "--btmon" => options.btmon = Some(PathBuf::from(value("--btmon")?)),
            "--bluetoothctl" => options.bluetoothctl = Some(PathBuf::from(value("--bluetoothctl")?)),
            "--ble-scan-seconds" => {
                let raw = value("--ble-scan-seconds")?;
                let seconds = number(raw, "--ble-scan-seconds")?;
                if seconds == 0 {
                    return Err("--ble-scan-seconds must be positive".to_owned());
                }
                options.ble_scan_seconds = Duration::from_secs(seconds);
            }
            "--ble-scan-interval-ms" => {
                let raw = value("--ble-scan-interval-ms")?;
                options.ble_scan_interval_ms = number(raw, "--ble-scan-interval-ms")?;
            }
            "--ble-scan-window-ms" => {
                let raw = value("--ble-scan-window-ms")?;
                options.ble_scan_window_ms = number(raw, "--ble-scan-window-ms")?;
            }
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

fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
    read(path).map(|s| s.trim().to_owned())
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

// ---------------------------------------------------------------------------------------------
// USB

/// Device nodes an interface owns.
///
/// The motivating case is a serial converter: `ttyUSB0` is a directory under the interface, and
/// which converter owns which number changes across re-enumeration -- so recording it is how a
/// consumer detects that two adapters have swapped nodes.
///
/// "Every subdirectory" was tried first and rejected: an interface's children also include the
/// hub's `*-port*` entries, `physical_location`, `power`, `driver` and the `ep_*` endpoint
/// descriptors, none of which is a node. What is used instead is the kernel's own marker -- a
/// character or block device directory carries a `dev` file holding `major:minor`. That is checked
/// on the interface's own children and one level below them, because subsystems vary in where they
/// put the node (`ttyUSB0` sits at `tty/ttyUSB0`, `video0` at `video4linux/video0`).
///
/// Two consequences of stopping at one level, both accepted: a network interface has no `dev` file
/// at all, so a USB NIC contributes nothing, and HID nodes sit deeper still (under the interface's
/// `0003:VVVV:PPPP.NNNN` child), so a mouse reports none either.
fn interface_nodes(interface_dir: &Path) -> Option<String> {
    fn is_node(path: &Path) -> bool {
        path.join("dev").is_file()
    }

    let entries = fs::read_dir(interface_dir).ok()?;
    let mut nodes = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if is_node(&path) {
            nodes.push(name);
            continue;
        }
        if let Ok(children) = fs::read_dir(&path) {
            for child in children.filter_map(Result::ok) {
                if child.file_type().is_ok_and(|t| t.is_dir()) && is_node(&child.path()) {
                    nodes.push(child.file_name().to_string_lossy().into_owned());
                }
            }
        }
    }
    // read_dir order is filesystem order; sorting keeps the value stable between runs so a
    // consumer diffing two samples sees a real change rather than a reordering.
    nodes.sort();
    Some(nodes.join(","))
}

/// One `usb` per device in `/sys/bus/usb/devices`, plus one `usb.interface` per interface of each.
///
/// Root hubs are included: they are ordinary USB devices with descriptors and a `maxchild`, and
/// leaving them out would orphan every `usb_port` record whose parent they are.
///
/// The identity is the topology path -- `3-1` names a physical socket. `devnum` deliberately stays
/// in the body: it changes on every re-enumeration, so as an attribute a flapping device would mint
/// a new series per cycle instead of showing up as churn on one.
fn usb_records(usb_devices_root: &Path) -> Vec<Record> {
    let Ok(entries) = fs::read_dir(usb_devices_root) else {
        return Vec::new();
    };

    let mut names: Vec<String> =
        entries.filter_map(Result::ok).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    names.sort();

    let mut records = Vec::new();
    for name in &names {
        let path = usb_devices_root.join(name);
        match usb::classify(name) {
            Some(usb::Entry::Device) => {
                records.push(
                    Record::new("detected-devices.usb")
                        .with_attr("path", Value::str(name))
                        .with_attr("bus", read_trimmed(path.join("busnum")).map(Value::Str))
                        .with_attr("vendor_id", read_trimmed(path.join("idVendor")).map(Value::Str))
                        .with_attr("product_id", read_trimmed(path.join("idProduct")).map(Value::Str))
                        .with_attr("serial", read_trimmed(path.join("serial")).map(Value::Str))
                        .with_attr(
                            "manufacturer",
                            read_trimmed(path.join("manufacturer")).map(Value::Str),
                        )
                        .with_attr("product", read_trimmed(path.join("product")).map(Value::Str))
                        .with_field(
                            "devnum",
                            read_trimmed(path.join("devnum"))
                                .and_then(|v| v.parse::<i64>().ok())
                                .map(Value::Int),
                        )
                        .with_field(
                            "speed_mbps",
                            read_trimmed(path.join("speed"))
                                .and_then(|v| usb::parse_speed_mbps(&v))
                                .map(Value::Double),
                        )
                        .with_field(
                            "usb_version",
                            read(path.join("version"))
                                .and_then(|v| usb::parse_usb_version(&v))
                                .map(Value::Str),
                        )
                        .with_field("bcd_device", read_trimmed(path.join("bcdDevice")).map(Value::Str))
                        .with_field(
                            "ports",
                            read_trimmed(path.join("maxchild"))
                                .and_then(|v| v.parse::<i64>().ok())
                                .map(Value::Int),
                        )
                        .with_field(
                            "authorized",
                            read_trimmed(path.join("authorized"))
                                .and_then(|v| usb::parse_zero_one(&v))
                                .map(Value::Bool),
                        )
                        .with_field(
                            "configuration",
                            read_trimmed(path.join("bConfigurationValue"))
                                .and_then(|v| v.parse::<i64>().ok())
                                .map(Value::Int),
                        )
                        .with_field(
                            "configurations",
                            read_trimmed(path.join("bNumConfigurations"))
                                .and_then(|v| v.parse::<i64>().ok())
                                .map(Value::Int),
                        )
                        .with_field(
                            "max_power_ma",
                            read_trimmed(path.join("bMaxPower"))
                                .and_then(|v| usb::parse_max_power_ma(&v))
                                .map(Value::Int),
                        )
                        .with_field(
                            "urbnum",
                            read_trimmed(path.join("urbnum"))
                                .and_then(|v| v.parse::<i64>().ok())
                                .map(Value::Int),
                        )
                        .with_field(
                            "runtime_status",
                            read_trimmed(path.join("power/runtime_status")).map(Value::Str),
                        ),
                );
            }
            Some(usb::Entry::Interface { device_path }) => {
                records.push(
                    Record::new("detected-devices.usb.interface")
                        .with_attr("path", Value::Str(usb::canonical_device_path(&device_path)))
                        .with_attr(
                            "interface",
                            read_trimmed(path.join("bInterfaceNumber")).map(Value::Str),
                        )
                        .with_field(
                            "class",
                            read_trimmed(path.join("bInterfaceClass"))
                                .and_then(|v| usb::parse_hex_byte(&v))
                                .map(Value::Str),
                        )
                        .with_field(
                            "subclass",
                            read_trimmed(path.join("bInterfaceSubClass"))
                                .and_then(|v| usb::parse_hex_byte(&v))
                                .map(Value::Str),
                        )
                        .with_field(
                            "protocol",
                            read_trimmed(path.join("bInterfaceProtocol"))
                                .and_then(|v| usb::parse_hex_byte(&v))
                                .map(Value::Str),
                        )
                        .with_field(
                            "driver",
                            fs::canonicalize(path.join("driver")).ok().and_then(|target| {
                                Some(Value::str(target.file_name()?.to_string_lossy()))
                            }),
                        )
                        .with_field(
                            "endpoints",
                            read_trimmed(path.join("bNumEndpoints"))
                                .and_then(|v| v.parse::<i64>().ok())
                                .map(Value::Int),
                        )
                        .with_field("nodes", interface_nodes(&path).map(Value::Str)),
                );
            }
            None => continue,
        }
    }
    records
}

/// One `usb_port` per port of every hub, attached or not.
///
/// Ports are not children of `/sys/bus/usb/devices` -- they live under a hub's *interface* directory
/// (`usb3/3-0:1.0/usb3-port1`), so they are found by walking the interfaces rather than the devices.
/// Reporting them unconditionally is the point of the type: a device that cannot enumerate has no
/// device directory at all, and the port row is then the only evidence that something is plugged in
/// and failing.
fn usb_port_records(usb_devices_root: &Path) -> Vec<Record> {
    let Ok(entries) = fs::read_dir(usb_devices_root) else {
        return Vec::new();
    };

    let mut interfaces: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| matches!(usb::classify(name), Some(usb::Entry::Interface { .. })))
        .collect();
    interfaces.sort();

    let mut records = Vec::new();
    for interface in &interfaces {
        let interface_dir = usb_devices_root.join(interface);
        let Ok(children) = fs::read_dir(&interface_dir) else {
            continue;
        };
        let mut ports: Vec<String> = children
            .filter_map(Result::ok)
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|name| usb::port_device_path(name).is_some())
            .collect();
        ports.sort();

        for port in &ports {
            let path = interface_dir.join(port);
            // The hub's own directory: the interface name up to the colon, except at a root hub
            // where `3-0` is implied but `usb3` is what exists.
            let hub = usb::canonical_device_path(interface.split(':').next().unwrap_or(interface));
            records.push(
                Record::new("detected-devices.usb_port")
                    .with_attr("port", Value::str(port))
                    .with_attr("path", usb::port_device_path(port).map(Value::Str))
                    .with_attr(
                        "bus",
                        read_trimmed(usb_devices_root.join(hub).join("busnum")).map(Value::Str),
                    )
                    .with_attr(
                        "connect_type",
                        read_trimmed(path.join("connect_type")).map(Value::Str),
                    )
                    .with_attr(
                        "peer",
                        fs::canonicalize(path.join("peer")).ok().and_then(|target| {
                            Some(Value::str(target.file_name()?.to_string_lossy()))
                        }),
                    )
                    .with_field("state", read_trimmed(path.join("state")).map(Value::Str))
                    .with_field(
                        "over_current_count",
                        read_trimmed(path.join("over_current_count"))
                            .and_then(|v| v.parse::<i64>().ok())
                            .map(Value::Int),
                    )
                    .with_field(
                        "disabled",
                        read_trimmed(path.join("disable"))
                            .and_then(|v| usb::parse_zero_one(&v))
                            .map(Value::Bool),
                    )
                    .with_field(
                        "early_stop",
                        read_trimmed(path.join("early_stop"))
                            .and_then(|v| usb::parse_yes_no(&v))
                            .map(Value::Bool),
                    ),
            );
        }
    }
    records
}

// ---------------------------------------------------------------------------------------------
// WiFi

/// One `wifi_scan` plus one `wifi_bss` per BSS heard.
///
/// The scan record is emitted whether or not the sweep ran, because zero BSS rows otherwise cannot
/// be told apart from a skipped scan, a refused one, or a broken collector.
fn wifi_records(iw: &Path, interface: &str) -> Vec<Record> {
    let mut scan = Record::new("detected-devices.wifi_scan").with_attr("interface", Value::str(interface));

    // A radio serving the fallback AP cannot leave its channel, so this is a skip rather than a
    // failure: attempting it would drop the AP the host is reachable through.
    let blocked = output(iw, &["dev"]).and_then(|dev| wifi::scan_blocked_reason(&dev, interface));
    if let Some(reason) = blocked {
        return vec![scan
            .with_field("ran", Value::Bool(false))
            .with_field("skipped_reason", Value::str(reason))
            .with_field("passive", Value::Null)
            .with_field("duration_ms", Value::Null)
            .with_field("bss_count", Value::Null)];
    }

    let started = Instant::now();
    let scanned = output(iw, &["dev", interface, "scan"]);
    let duration_ms = started.elapsed().as_millis() as i64;

    let Some(text) = scanned else {
        // The kernel serialises scan requests: one already in flight from the manager makes this
        // return -EBUSY, which is a retry-next-tick condition rather than a fault.
        return vec![scan
            .with_field("ran", Value::Bool(false))
            .with_field("skipped_reason", Value::str("busy"))
            .with_field("passive", Value::Null)
            .with_field("duration_ms", Value::Int(duration_ms))
            .with_field("bss_count", Value::Null)];
    };

    let bsses = wifi::parse_scan(&text);
    scan = scan
        .with_field("ran", Value::Bool(true))
        .with_field("skipped_reason", Value::Null)
        // Always a real sweep: `scan dump` would be free but under iwd the kernel's BSS cache holds
        // only the associated BSS, so it cannot answer what else is audible.
        .with_field("passive", Value::Bool(false))
        .with_field("duration_ms", Value::Int(duration_ms))
        .with_field("bss_count", Value::Int(bsses.len() as i64));

    let mut records = vec![scan];
    for bss in bsses {
        records.push(
            Record::new("detected-devices.wifi_bss")
                .with_attr("bssid", Value::str(&bss.bssid))
                .with_attr("interface", Value::str(interface))
                .with_field("ssid", bss.ssid.map(Value::Str))
                .with_field("frequency_mhz", bss.frequency_mhz.map(Value::Double))
                .with_field("channel", bss.channel.map(Value::Int))
                .with_field("signal_dbm", bss.signal_dbm.map(Value::Double))
                .with_field("last_seen_ms", bss.last_seen_ms.map(Value::Int))
                .with_field("beacon_interval_tu", bss.beacon_interval_tu.map(Value::Int))
                .with_field("associated", Value::Bool(bss.associated))
                .with_field("security", bss.security.map(Value::Str))
                .with_field("pairwise_ciphers", bss.pairwise_ciphers.map(Value::Str))
                .with_field("auth_suites", bss.auth_suites.map(Value::Str))
                .with_field("wps", bss.wps.map(Value::Bool))
                .with_field("width_mhz", bss.width_mhz.map(Value::Int))
                .with_field("standards", bss.standards.map(Value::Str))
                .with_field("country", bss.country.map(Value::Str)),
        );
    }
    records
}

// ---------------------------------------------------------------------------------------------
// Bluetooth LE

fn ble_skipped(adapter: &str, reason: &str, options: &Options) -> Vec<Record> {
    vec![Record::new("detected-devices.ble_scan")
        .with_attr("adapter", Value::str(adapter))
        .with_field("ran", Value::Bool(false))
        .with_field("skipped_reason", Value::str(reason))
        .with_field("active", Value::Null)
        .with_field("scan_interval_ms", Value::Int(options.ble_scan_interval_ms as i64))
        .with_field("scan_window_ms", Value::Int(options.ble_scan_window_ms as i64))
        .with_field("duration_ms", Value::Null)
        .with_field("devices_public", Value::Null)
        .with_field("devices_random", Value::Null)
        .with_field("devices_connectable", Value::Null)
        .with_field("reports_total", Value::Null)
        .with_field("strongest_dbm", Value::Null)
        .with_field("near_count", Value::Null)
        .with_field("mid_count", Value::Null)
        .with_field("far_count", Value::Null)]
}

/// Everything the reader has produced, waiting no longer than `grace` for a straggler.
///
/// The reader thread drops its sender at EOF, so a btmon that died with the pipe to itself ends this
/// immediately; the grace is what a still-open pipe costs, a bounded delay instead of the unit's
/// whole start timeout. Whatever arrived before the deadline is kept -- a truncated capture parses
/// into the reports it does contain, which beats reporting none of them.
fn drain(rx: &mpsc::Receiver<Vec<u8>>, grace: Duration) -> Vec<u8> {
    let deadline = Instant::now() + grace;
    let mut capture = Vec::new();
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        match rx.recv_timeout(left) {
            Ok(chunk) => capture.extend_from_slice(&chunk),
            // Disconnected (the reader saw EOF) or the grace ran out.
            Err(_) => break,
        }
    }
    capture
}

/// One `ble_scan`, plus one `ble_device.public` or `ble_device.random` per address heard.
///
/// The two device types are separate rather than one type with an `address_type` attribute because
/// `type` is the only indexed column in the receiver's store -- the same reason `system.drive`
/// splits into `.nvme` and `.sata`. It also puts the privacy property in the schema: the public type
/// carries the address as a filterable attribute, the random type does not carry it as an attribute
/// at all, because resolvable private addresses rotate and a dimension would invite tracking
/// strangers across rotations.
fn ble_records(options: &Options) -> Vec<Record> {
    let adapter = &options.bluetooth_adapter;
    let (Some(btmon), Some(bluetoothctl)) = (&options.btmon, &options.bluetoothctl) else {
        return Vec::new();
    };

    if !options.bluetooth_sysfs_root.join(adapter).exists() {
        return ble_skipped(adapter, "no-adapter", options);
    }

    // btmon reads the HCI monitor channel, which is read-only and coexists with whatever else has
    // the controller. It is spawned first so no advertisement is missed between enabling the scan
    // and attaching the reader.
    let mut monitor = match Command::new(btmon)
        .arg("--index")
        .arg(adapter.trim_start_matches("hci"))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return ble_skipped(adapter, "adapter-down", options),
    };

    // Drained as btmon writes rather than collected at the end: a pipe nobody is reading fills at
    // 64 KiB and blocks the writer, which in a busy neighbourhood means advertisements are dropped
    // for the rest of the window and the capture looks like a quiet one.
    let mut stdout = monitor.stdout.take().expect("stdout is piped");
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buffer = [0u8; 8192];
        while let Ok(read) = stdout.read(&mut buffer) {
            if read == 0 || tx.send(buffer[..read].to_vec()).is_err() {
                break;
            }
        }
    });

    let started = Instant::now();
    // The duty cycle is pinned rather than inherited. BlueZ's own default is window == interval,
    // i.e. the radio listens continuously, which starves any active connection on the same
    // controller and -- since WiFi and Bluetooth share one antenna here -- the host's own uplink.
    let seconds = options.ble_scan_seconds.as_secs().to_string();
    let scanned = Command::new(bluetoothctl)
        .args(["--timeout", &seconds, "scan", "le"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let duration_ms = started.elapsed().as_millis() as i64;

    // kill then wait, not wait_with_output: the latter reads to EOF, and EOF needs every holder of
    // the write end to close it, not just the process signalled here. Anything else sharing that
    // descriptor -- a wrapper's surviving child -- would otherwise hold the run open until systemd's
    // start timeout kills it.
    let _ = monitor.kill();
    let _ = monitor.wait();
    let capture = String::from_utf8(drain(&rx, CAPTURE_GRACE)).unwrap_or_default();

    if scanned.map(|s| !s.success()).unwrap_or(true) {
        // A userspace host stack holding the controller on an HCI user channel makes scanning
        // impossible rather than merely degraded, and this is how it surfaces.
        return ble_skipped(adapter, "controller-busy", options);
    }

    let scan = ble::parse_btmon(&capture);
    let (near, mid, far) = scan.distance_buckets();

    let mut records = vec![Record::new("detected-devices.ble_scan")
        .with_attr("adapter", Value::str(adapter))
        .with_field("ran", Value::Bool(true))
        .with_field("skipped_reason", Value::Null)
        .with_field("active", Value::Bool(true))
        .with_field("scan_interval_ms", Value::Int(options.ble_scan_interval_ms as i64))
        .with_field("scan_window_ms", Value::Int(options.ble_scan_window_ms as i64))
        .with_field("duration_ms", Value::Int(duration_ms))
        .with_field("devices_public", Value::Int(scan.count(ble::AddressKind::Public)))
        .with_field("devices_random", Value::Int(scan.count(ble::AddressKind::Random)))
        .with_field("devices_connectable", Value::Int(scan.connectable_count()))
        .with_field("reports_total", Value::Int(scan.reports_total))
        .with_field("strongest_dbm", scan.strongest_dbm().map(Value::Int))
        .with_field("near_count", Value::Int(near))
        .with_field("mid_count", Value::Int(mid))
        .with_field("far_count", Value::Int(far))];

    for device in &scan.advertisers {
        let body = |record: Record| -> Record {
            record
                .with_field("connectable", device.connectable().map(Value::Bool))
                .with_field("pdu_type", device.pdu_type.clone().map(Value::Str))
                .with_field("rssi_last", device.rssi_last.map(Value::Int))
                .with_field("rssi_min", device.rssi_min.map(Value::Int))
                .with_field("rssi_max", device.rssi_max.map(Value::Int))
                .with_field("report_count", Value::Int(device.report_count))
                .with_field("name", device.name.clone().map(Value::Str))
                .with_field("tx_power_dbm", device.tx_power_dbm.map(Value::Int))
                .with_field("company_id", device.company_id.map(Value::Int))
                .with_field("service_uuids", device.service_uuids.clone().map(Value::Str))
                .with_field("flags", device.flags.clone().map(Value::Str))
        };
        records.push(match device.kind {
            ble::AddressKind::Public => body(
                Record::new("detected-devices.ble_device.public").with_attr("address", Value::str(&device.address)),
            ),
            // No address attribute: the address goes in the body, where the receiver's query API
            // cannot filter on it, so following a rotating address across scans is awkward by
            // construction. A speed bump, not a guarantee.
            ble::AddressKind::Random => {
                body(Record::new("detected-devices.ble_device.random")).with_field("address", Value::str(&device.address))
            }
        });
    }
    records
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
    let time_unix_nano = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock is before the unix epoch: {e}"))?
        .as_nanos() as u64;

    let mut resource_attributes = vec![("service.name".to_owned(), Value::str("detected-devices"))];
    if let Some(hostname) = read_trimmed("/proc/sys/kernel/hostname") {
        resource_attributes.push(("host.name".to_owned(), Value::Str(hostname)));
    }
    if let Some(boot_id) = read_trimmed("/proc/sys/kernel/random/boot_id") {
        resource_attributes.push(("boot_id".to_owned(), Value::Str(boot_id)));
    }
    resource_attributes.extend(options.resource_attributes.iter().cloned());

    let mut records = Vec::new();
    if let Some(root) = &options.usb_devices_root {
        records.extend(usb_records(root));
        records.extend(usb_port_records(root));
    }
    if let (Some(iw), Some(interface)) = (&options.iw, &options.wifi_interface) {
        records.extend(wifi_records(iw, interface));
    }
    records.extend(ble_records(&options));

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
    // clients stop retrying data that will never be accepted.
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
                eprintln!("detected-devices: {message}");
                ExitCode::FAILURE
            }
        },
        Err(message) => {
            eprintln!("detected-devices: {message}");
            eprint!("\n{USAGE}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reader_that_reached_eof_ends_the_drain_without_waiting_out_the_grace() {
        let (tx, rx) = mpsc::channel();
        tx.send(b"one".to_vec()).unwrap();
        tx.send(b"two".to_vec()).unwrap();
        drop(tx);

        let started = Instant::now();
        assert_eq!(drain(&rx, Duration::from_secs(30)), b"onetwo".to_vec());
        assert!(started.elapsed() < Duration::from_secs(1), "waited on a dropped sender");
    }

    /// The regression: btmon's pipe outlives the process that was killed -- a wrapper's surviving
    /// child still holds the write end -- so the reader never sees EOF. That has to cost the grace
    /// and nothing more, or the run hangs until systemd's start timeout kills it.
    #[test]
    fn a_pipe_that_never_closes_costs_the_grace_and_keeps_what_arrived() {
        let (tx, rx) = mpsc::channel();
        tx.send(b"captured".to_vec()).unwrap();

        let grace = Duration::from_millis(200);
        let started = Instant::now();
        assert_eq!(drain(&rx, grace), b"captured".to_vec());
        assert!(started.elapsed() >= grace);
        assert!(started.elapsed() < grace * 10, "the grace did not bound the wait");
    }
}
