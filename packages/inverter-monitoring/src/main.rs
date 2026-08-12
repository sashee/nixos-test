//! Poll a Voltronic-protocol inverter over USB serial and report it to a local
//! monitoring-platform receiver.
//!
//! Unlike its sibling `system-metrics`, this is a daemon: finding the port costs tens of seconds
//! of probing, and the unit under test answers a fixed four-command cycle every minute. So it
//! connects once and stays connected, and the systemd unit restarts it 15 minutes after any
//! exit.
//!
//! ## What ends a run, and what does not
//!
//! `spec/features/inverter-monitoring/inverter-monitoring.md` says both "discard the message on
//! [CRC] failure" and "every failure exits the unit"; those cannot both be literally true, and
//! the spec's own `link_discarded_frames` counter -- "CRC failures since connect" -- only has a
//! value to report under the first reading. So failures are split:
//!
//! * **Transient.** A bad CRC, a command that times out, a payload whose field widths moved, a
//!   NAK, a receiver that cannot be reached. The cycle degrades: the affected keys go null, a
//!   counter moves, the reason is logged, and the loop continues. A single bit flipped by line
//!   noise costs one field, not fifteen minutes of darkness.
//! * **Fatal.** No inverter found at startup, an I/O error on the port (the adapter was
//!   unplugged), or [`MAX_SILENT_CYCLES`] consecutive cycles that read nothing at all. The
//!   process exits non-zero and systemd restarts it after `RestartSec`.
//!
//! The middle case is what the silent-cycle counter exists for: a port that is open but answers
//! nothing is indistinguishable from a healthy one on any single command, and without it a
//! yanked-then-replaced cable would leave this process reporting all-null rows forever.

mod crc;
mod discover;
mod otlp;
mod parse;
mod port;
mod protocol;
mod record;
mod uds;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use discover::{Candidate, Probe};
use port::{SerialPort, Transport};
use protocol::{parse_response, Command, Response, LIVE_COMMANDS, STATIC_COMMANDS};
use record::{Cycle, Link, Record, Value};

const DEFAULT_SOCKET: &str = "/run/monitoring-platform/monitoring-platform.sock";
const INGEST_PATH: &str = "/v1/logs";
const PROTOBUF: &str = "application/x-protobuf";
const DEFAULT_DEV_DIR: &str = "/dev";
const DEFAULT_BY_PATH_DIR: &str = "/dev/serial/by-path";
const DEFAULT_BY_ID_DIR: &str = "/dev/serial/by-id";
const DEFAULT_STATE_DIR: &str = "/var/lib/inverter-monitoring";
const REMEMBERED_FILE: &str = "last-device";
const BAUD: u32 = 2400;

/// Consecutive cycles that read nothing before the port is declared dead. Three rather than one
/// so a wedged adapter is distinguishable from a unit that missed a single exchange.
const MAX_SILENT_CYCLES: u32 = 3;

/// Pause between discovery attempts inside the startup window. Short, because the thing being
/// waited for is udev finishing, which takes seconds.
const RETRY_PAUSE: Duration = Duration::from_secs(3);

struct Options {
    socket: PathBuf,
    dev_dir: PathBuf,
    by_path_dir: PathBuf,
    by_id_dir: PathBuf,
    state_dir: PathBuf,
    interval: Duration,
    static_refresh: Duration,
    bms_listen: Duration,
    response_timeout: Duration,
    discovery_window: Duration,
    resource_attributes: Vec<(String, Value)>,
    dry_run: bool,
    once: bool,
}

const USAGE: &str = "\
usage: inverter-monitoring [options]

  --socket PATH             receiver unix socket (default: /run/monitoring-platform/monitoring-platform.sock)
  --resource-attr KEY=VALUE resource attribute to attach to every record; repeatable
  --dev-dir PATH            directory the ttyUSB* devices live in (default: /dev)
  --serial-by-path-dir PATH directory of per-port serial device names, which is what a device
                            is keyed by (default: /dev/serial/by-path)
  --serial-by-id-dir PATH   directory of descriptor-derived serial device names. Reported, not
                            matched on: a chip with no serial number descriptor shares this
                            name with every other adapter of its model
                            (default: /dev/serial/by-id)
  --state-dir PATH          where the last-connected device is remembered
                            (default: /var/lib/inverter-monitoring)
  --interval-seconds N      seconds between poll cycles (default: 60)
  --static-refresh-seconds N  seconds between re-reads of the identity commands (default: 3600)
  --bms-listen-seconds N    how long a candidate port is listened to before probing it; a port
                            that speaks first is not the inverter (default: 10)
  --response-timeout-seconds N  deadline for one response frame. A 106-byte QPIGS payload is
                            ~0.46s of wire time at 2400 baud, so this cannot be small
                            (default: 2)
  --discovery-window-seconds N  how long to keep retrying discovery at startup before giving up.
                            Covers the boot race against udev, not device loss (default: 60)
  --once                    run one poll cycle and exit, rather than looping
  --dry-run                 print each batch instead of posting it
  --help                    this text
";

fn parse_args(args: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut options = Options {
        socket: PathBuf::from(DEFAULT_SOCKET),
        dev_dir: PathBuf::from(DEFAULT_DEV_DIR),
        by_path_dir: PathBuf::from(DEFAULT_BY_PATH_DIR),
        by_id_dir: PathBuf::from(DEFAULT_BY_ID_DIR),
        state_dir: PathBuf::from(DEFAULT_STATE_DIR),
        interval: Duration::from_secs(60),
        static_refresh: Duration::from_secs(3600),
        bms_listen: Duration::from_secs(10),
        response_timeout: Duration::from_secs(2),
        discovery_window: Duration::from_secs(60),
        resource_attributes: Vec::new(),
        dry_run: false,
        once: false,
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
            "--dev-dir" => options.dev_dir = PathBuf::from(value("--dev-dir")?),
            "--serial-by-path-dir" => {
                options.by_path_dir = PathBuf::from(value("--serial-by-path-dir")?)
            }
            "--serial-by-id-dir" => options.by_id_dir = PathBuf::from(value("--serial-by-id-dir")?),
            "--state-dir" => options.state_dir = PathBuf::from(value("--state-dir")?),
            "--interval-seconds" => options.interval = seconds(&value("--interval-seconds")?, "--interval-seconds")?,
            "--static-refresh-seconds" => {
                options.static_refresh =
                    seconds(&value("--static-refresh-seconds")?, "--static-refresh-seconds")?
            }
            "--bms-listen-seconds" => {
                options.bms_listen = seconds(&value("--bms-listen-seconds")?, "--bms-listen-seconds")?
            }
            "--response-timeout-seconds" => {
                options.response_timeout =
                    seconds(&value("--response-timeout-seconds")?, "--response-timeout-seconds")?
            }
            "--discovery-window-seconds" => {
                options.discovery_window =
                    seconds(&value("--discovery-window-seconds")?, "--discovery-window-seconds")?
            }
            "--once" => options.once = true,
            "--dry-run" => options.dry_run = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }

    Ok(Some(options))
}

fn seconds(raw: &str, name: &str) -> Result<Duration, String> {
    let value: f64 = raw.parse().map_err(|_| format!("{name} expects a number, got {raw:?}"))?;
    if !(value.is_finite() && value > 0.0) {
        return Err(format!("{name} must be positive, got {raw:?}"));
    }
    Ok(Duration::from_secs_f64(value))
}

// ---------------------------------------------------------------------------------------------

/// A failure of one exchange.
enum Failure {
    /// The cycle degrades and the loop continues.
    Transient(String),
    /// The port is gone; the process exits and systemd restarts it.
    Fatal(String),
}

/// Everything that outlives one cycle.
struct Session {
    /// The by-path key: what the remembered-device file holds and what `inverter.device`
    /// reports. Unique per physical port whatever the chip says about itself.
    device: String,
    /// What was opened. Kept so the by-id name can be re-resolved from it every cycle -- see
    /// [`discover::by_id_of`] for why that name is not safe to remember.
    tty: PathBuf,
    connected_at: Instant,
    discarded_frames: u64,
    unsupported_commands: u64,
    /// Commands that answered NAK. Asked once, then never again -- re-asking every minute would
    /// spend wire time on a command the unit has already said it does not implement.
    unsupported: BTreeSet<Command>,
    identity: Vec<(&'static str, Option<String>)>,
}

impl Session {
    fn link(&self) -> Link {
        Link {
            connected_seconds: self.connected_at.elapsed().as_secs(),
            discarded_frames: self.discarded_frames,
            unsupported_commands: self.unsupported_commands,
        }
    }
}

/// Send one command and return its payload, or `None` if the unit NAKed it.
fn exchange<T: Transport>(
    transport: &mut T,
    command: Command,
    timeout: Duration,
) -> Result<Option<Vec<u8>>, Failure> {
    transport
        .write_request(&command.request())
        .map_err(|e| Failure::Fatal(format!("writing {}: {e}", command.text())))?;

    let frame = transport
        .read_frame(timeout)
        .map_err(|e| Failure::Fatal(format!("reading {}: {e}", command.text())))?
        .ok_or_else(|| {
            Failure::Transient(format!("{} timed out after {:?}", command.text(), timeout))
        })?;

    match parse_response(&frame) {
        Ok(Response::Payload(payload)) => Ok(Some(payload)),
        Ok(Response::Nak) => Ok(None),
        Err(error) => Err(Failure::Transient(format!("{}: {error}", command.text()))),
    }
}

/// One command, with the session's bookkeeping applied. `None` means "no usable answer"; the
/// caller nulls the corresponding fields.
fn read_command<T: Transport>(
    transport: &mut T,
    session: &mut Session,
    command: Command,
    timeout: Duration,
) -> Result<Option<Vec<u8>>, String> {
    if session.unsupported.contains(&command) {
        return Ok(None);
    }
    match exchange(transport, command, timeout) {
        Ok(Some(payload)) => Ok(Some(payload)),
        Ok(None) => {
            eprintln!(
                "inverter-monitoring: {} is not supported by this unit (NAK); not asking again",
                command.text()
            );
            session.unsupported.insert(command);
            session.unsupported_commands += 1;
            Ok(None)
        }
        Err(Failure::Transient(reason)) => {
            // Every transient failure is a discarded frame from the link's point of view,
            // whether the CRC failed or the frame never arrived. Both mean one exchange's worth
            // of data did not survive the wire.
            session.discarded_frames += 1;
            eprintln!("inverter-monitoring: discarding {reason}");
            Ok(None)
        }
        Err(Failure::Fatal(reason)) => Err(reason),
    }
}

/// The four live commands.
fn poll_cycle<T: Transport>(
    transport: &mut T,
    session: &mut Session,
    timeout: Duration,
) -> Result<Cycle, String> {
    let mut cycle = Cycle::default();
    for command in LIVE_COMMANDS {
        let Some(payload) = read_command(transport, session, command, timeout)? else {
            continue;
        };
        // A payload that will not parse is the same class of event as a bad CRC: something on
        // the line or in the firmware is not what this parser was written against, and guessing
        // is worse than a null.
        let parsed = match command {
            Command::Qmod => parse::parse_qmod(&payload).map(|m| cycle.mode = Some(m)),
            Command::Qpigs => parse::parse_qpigs(&payload).map(|q| cycle.qpigs = Some(q)),
            Command::Qpigs2 => parse::parse_qpigs2(&payload).map(|q| cycle.qpigs2 = Some(q)),
            Command::Qpiws => parse::parse_qpiws(&payload).map(|q| cycle.qpiws = Some(q)),
            _ => Ok(()),
        };
        if let Err(reason) = parsed {
            session.discarded_frames += 1;
            eprintln!("inverter-monitoring: discarding {reason}");
        }
    }
    cycle.link = session.link();
    Ok(cycle)
}

/// The five identity commands, whose answers become resource attributes.
fn read_identity<T: Transport>(
    transport: &mut T,
    session: &mut Session,
    timeout: Duration,
) -> Result<Vec<(&'static str, Option<String>)>, String> {
    let mut identity = Vec::new();
    for command in STATIC_COMMANDS {
        let key = match command {
            Command::Qid => "serial_number",
            Command::Qvfw => "firmware",
            Command::Qvfw3 => "firmware_panel",
            Command::Qmn => "model",
            Command::Qgmn => "model_code",
            _ => continue,
        };
        let value = match read_command(transport, session, command, timeout)? {
            Some(payload) => match parse::parse_identity(command.text(), &payload) {
                Ok(text) => Some(text),
                Err(reason) => {
                    eprintln!("inverter-monitoring: discarding {reason}");
                    None
                }
            },
            None => None,
        };
        identity.push((key, value));
    }
    Ok(identity)
}

// ---------------------------------------------------------------------------------------------

fn remembered_path(state_dir: &Path) -> PathBuf {
    state_dir.join(REMEMBERED_FILE)
}

fn read_remembered(state_dir: &Path) -> Option<String> {
    std::fs::read_to_string(remembered_path(state_dir))
        .ok()
        .map(|text| text.trim().to_owned())
        .filter(|text| !text.is_empty())
}

fn write_remembered(state_dir: &Path, device: &str) {
    if let Err(error) = std::fs::write(remembered_path(state_dir), format!("{device}\n")) {
        // Losing the hint costs a slower probe next boot and nothing else, so this must not be
        // allowed to fail a run that has a working port in hand.
        eprintln!("inverter-monitoring: cannot remember {device}: {error}");
    }
}

/// Probe candidates until one answers `QID`, retrying for a bounded window.
///
/// The retry is here and nowhere else: it covers the boot race, not device loss. This service
/// starts at boot, and the USB adapter is enumerated by udev a few seconds in -- on the fleet's
/// Pi, `ch341` binds about nine seconds after the kernel starts, which is close enough to
/// `multi-user.target` to lose sometimes. Without the window, losing that race means exiting and
/// sitting out a full `RestartSec` with an inverter that was plugged in the whole time.
///
/// Deliberately NOT a reconnect loop: once a port has been found and then lost, that is the
/// fatal case, and it stays fatal.
fn connect_within(
    options: &Options,
    window: Duration,
) -> Result<(SerialPort, Candidate, String), String> {
    let deadline = Instant::now() + window;
    loop {
        let last = match connect(options) {
            Ok(found) => return Ok(found),
            Err(reason) => reason,
        };
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return Err(last);
        };
        eprintln!("inverter-monitoring: {last}; retrying for another {}s", remaining.as_secs());
        std::thread::sleep(RETRY_PAUSE.min(remaining));
    }
}

/// Probe candidates until one answers `QID`.
fn connect(options: &Options) -> Result<(SerialPort, Candidate, String), String> {
    let all = discover::enumerate(&options.dev_dir, &options.by_path_dir, &options.by_id_dir);
    if all.is_empty() {
        return Err(format!("no ttyUSB devices under {}", options.dev_dir.display()));
    }
    let remembered = read_remembered(&options.state_dir);
    let candidates = discover::order(all, remembered.as_deref(), shuffle_seed());

    for candidate in candidates {
        let name = candidate.describe();
        let mut serial = match SerialPort::open(&candidate.tty, BAUD) {
            Ok(port) => port,
            Err(error) => {
                eprintln!("inverter-monitoring: cannot open {name}: {error}");
                continue;
            }
        };
        match discover::probe(&mut serial, options.bms_listen, options.response_timeout) {
            Ok(Probe::Inverter(serial_number)) => {
                eprintln!("inverter-monitoring: inverter {serial_number} on {name}");
                return Ok((serial, candidate, serial_number));
            }
            Ok(Probe::Chatty(bytes)) => {
                eprintln!("inverter-monitoring: {name} sent {bytes} unsolicited byte(s); not the inverter");
            }
            Ok(Probe::NotAnInverter(reason)) => {
                eprintln!("inverter-monitoring: {name} is not the inverter: {reason}");
            }
            Err(error) => {
                eprintln!("inverter-monitoring: probing {name} failed: {error}");
            }
        }
    }

    Err("no inverter found on any USB serial device".to_owned())
}

/// Seed for the candidate shuffle. The clock is the only entropy this process needs and the only
/// one it can get without a dependency; a collision just means two boots probe in the same order.
fn shuffle_seed() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1)
}

fn resource_attributes(options: &Options, session: &Session) -> Vec<(String, Value)> {
    let mut attributes = vec![("service.name".to_owned(), Value::str("inverter-monitoring"))];
    if let Some(hostname) = read_trimmed("/proc/sys/kernel/hostname") {
        attributes.push(("host.name".to_owned(), Value::Str(hostname)));
    }
    if let Some(boot_id) = read_trimmed("/proc/sys/kernel/random/boot_id") {
        attributes.push(("boot_id".to_owned(), Value::Str(boot_id)));
    }
    // Resolved here rather than carried on the session: the link this reads can change owner
    // under a running producer, and the point of reporting it is recognisability -- a name that
    // now resolves to the adapter next to it is worse than none.
    let device_name = discover::by_id_of(&options.by_id_dir, &session.tty);
    attributes.extend(record::identity_attributes(
        &session.device,
        device_name.as_deref(),
        &session.identity,
    ));
    attributes.extend(options.resource_attributes.iter().cloned());
    attributes
}

fn read_trimmed(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|text| text.trim().to_owned())
}

/// Post one cycle. A receiver that cannot be reached is transient: `mp-collector` is a separate
/// unit that can restart under us, and this producer has no buffer of its own -- the collector
/// is the buffer. Dropping one cycle is the cost of not having one here.
fn publish(options: &Options, resource: &[(String, Value)], records: &[Record]) {
    if options.dry_run {
        println!("resource {}", record::format_pairs(resource));
        println!("scope {} {}", otlp::SCOPE_NAME, otlp::SCOPE_VERSION);
        for record in records {
            println!(
                "record {} | attrs: {} | body: {}",
                record.event_name,
                record::format_pairs(&record.attributes),
                record::format_pairs(&record.body)
            );
        }
        return;
    }

    let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        eprintln!("inverter-monitoring: system clock is before the unix epoch; dropping batch");
        return;
    };
    let payload = otlp::encode(&otlp::build_request(resource, records, now.as_nanos() as u64));

    match uds::post(&options.socket, INGEST_PATH, PROTOBUF, &payload) {
        Err(error) => eprintln!("inverter-monitoring: dropping batch: {error}"),
        Ok(response) if response.status != 200 => eprintln!(
            "inverter-monitoring: receiver answered {} for {} record(s): {}",
            response.status,
            records.len(),
            String::from_utf8_lossy(&response.body).trim()
        ),
        Ok(response) => match otlp::decode_rejections(&response.body) {
            // A 200 does not mean everything landed: OTLP reports per-record rejections in the
            // body, and treating that as success would lose measurements without a trace.
            Ok(rejections) if rejections.count > 0 => eprintln!(
                "inverter-monitoring: receiver rejected {} of {} record(s): {}",
                rejections.count,
                records.len(),
                rejections.message
            ),
            Ok(_) => {}
            Err(error) => {
                eprintln!("inverter-monitoring: undecodable receiver response: {error}")
            }
        },
    }
}

fn run(options: Options) -> Result<(), String> {
    let (mut transport, candidate, serial_number) = connect_within(&options, options.discovery_window)?;
    write_remembered(&options.state_dir, &candidate.path_id);

    let mut session = Session {
        device: candidate.path_id,
        tty: candidate.tty,
        connected_at: Instant::now(),
        discarded_frames: 0,
        unsupported_commands: 0,
        unsupported: BTreeSet::new(),
        identity: vec![("serial_number", Some(serial_number))],
    };
    session.identity = read_identity(&mut transport, &mut session, options.response_timeout)?;

    let mut silent_cycles = 0u32;
    let mut last_static = Instant::now();
    let started = Instant::now();

    for tick in 0u64.. {
        let cycle = poll_cycle(&mut transport, &mut session, options.response_timeout)?;

        if cycle.is_empty() {
            silent_cycles += 1;
            if silent_cycles >= MAX_SILENT_CYCLES {
                return Err(format!(
                    "{} answered nothing for {silent_cycles} consecutive cycles",
                    session.device
                ));
            }
        } else {
            silent_cycles = 0;
        }

        let mut records = vec![record::status_record(&cycle)];
        records.extend(record::flag_records(&cycle));
        publish(&options, &resource_attributes(&options, &session), &records);

        if options.once {
            return Ok(());
        }

        // Re-read the identity commands on schedule. protocol.md says these cannot change while
        // the unit is powered, so in the ordinary case this changes nothing -- its value is that
        // a unit swapped behind the same adapter stops being reported under the old serial
        // number.
        if last_static.elapsed() >= options.static_refresh {
            session.identity =
                read_identity(&mut transport, &mut session, options.response_timeout)?;
            last_static = Instant::now();
        }

        // Anchored to the start rather than sleeping a fixed interval after each cycle: the
        // cycle itself takes about a second of wire time, which a plain sleep would add to
        // every interval until the samples had drifted a minute off the hour.
        let next = started + options.interval * (tick as u32 + 1);
        if let Some(remaining) = next.checked_duration_since(Instant::now()) {
            std::thread::sleep(remaining);
        }
    }

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
                eprintln!("inverter-monitoring: {message}");
                ExitCode::FAILURE
            }
        },
        Err(message) => {
            eprintln!("inverter-monitoring: {message}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discover::fake::FakePort;
    use crate::protocol::build_response;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    const QPIGS_SAMPLE: &[u8] = b"000.0 00.0 226.7 50.0 0997 0825 012 429 54.20 041 080 0062 09.2 196.4 00.00 00000 00010110 00 00 01819 010";
    const TIMEOUT: Duration = Duration::from_millis(1);

    fn session() -> Session {
        Session {
            device: "platform-xhci-hcd.0-usb-0:1:1.0-port0".to_owned(),
            tty: PathBuf::from("/dev/ttyUSB0"),
            connected_at: Instant::now(),
            discarded_frames: 0,
            unsupported_commands: 0,
            unsupported: BTreeSet::new(),
            identity: Vec::new(),
        }
    }

    #[test]
    fn defaults_match_the_spec_cadence() {
        let options = parse_args(args(&[]).into_iter()).unwrap().unwrap();
        assert_eq!(options.socket, PathBuf::from(DEFAULT_SOCKET));
        assert_eq!(options.dev_dir, PathBuf::from(DEFAULT_DEV_DIR));
        assert_eq!(options.by_path_dir, PathBuf::from(DEFAULT_BY_PATH_DIR));
        assert_eq!(options.by_id_dir, PathBuf::from(DEFAULT_BY_ID_DIR));
        assert_eq!(options.interval, Duration::from_secs(60));
        assert_eq!(options.static_refresh, Duration::from_secs(3600));
        assert_eq!(options.bms_listen, Duration::from_secs(10));
        assert_eq!(options.discovery_window, Duration::from_secs(60));
        assert!(!options.once);
        assert!(!options.dry_run);
    }

    #[test]
    fn malformed_arguments_are_refused_rather_than_guessed() {
        assert!(parse_args(args(&["--interval-seconds", "0"]).into_iter()).is_err());
        assert!(parse_args(args(&["--interval-seconds", "-5"]).into_iter()).is_err());
        assert!(parse_args(args(&["--resource-attr", "nokey"]).into_iter()).is_err());
        assert!(parse_args(args(&["--socket"]).into_iter()).is_err());
        assert!(parse_args(args(&["--nope"]).into_iter()).is_err());
        assert!(parse_args(args(&["--help"]).into_iter()).unwrap().is_none());
    }

    /// The whole four-command cycle against a unit that answers everything.
    #[test]
    fn a_good_cycle_reads_all_four_commands() {
        let mut port = FakePort::answering(vec![
            Some(build_response(b"B")),
            Some(build_response(QPIGS_SAMPLE)),
            Some(build_response(b"05.4 212.5 01156 ")),
            Some(build_response(b"000000000000000000000000000000000000")),
        ]);
        let mut session = session();
        let cycle = poll_cycle(&mut port, &mut session, TIMEOUT).unwrap();

        assert!(!cycle.is_empty());
        assert_eq!(cycle.qpigs.as_ref().unwrap().battery_voltage, 54.2);
        assert_eq!(cycle.qpigs2.as_ref().unwrap().pv2_charging_power, 1156);
        assert_eq!(session.discarded_frames, 0);
        assert_eq!(
            port.written,
            LIVE_COMMANDS.iter().map(|c| c.request()).collect::<Vec<_>>()
        );
    }

    /// The central claim of the failure taxonomy: a corrupt frame costs one command, not the run.
    #[test]
    fn a_bad_crc_is_counted_and_the_rest_of_the_cycle_continues() {
        let mut corrupt = build_response(QPIGS_SAMPLE);
        let last = corrupt.len() - 3;
        corrupt[last] ^= 0xFF;

        let mut port = FakePort::answering(vec![
            Some(build_response(b"B")),
            Some(corrupt),
            Some(build_response(b"05.4 212.5 01156 ")),
            Some(build_response(b"000000000000000000000000000000000000")),
        ]);
        let mut session = session();
        let cycle = poll_cycle(&mut port, &mut session, TIMEOUT).unwrap();

        assert_eq!(session.discarded_frames, 1);
        assert!(cycle.qpigs.is_none(), "the corrupt frame must not be parsed");
        assert!(cycle.mode.is_some(), "the commands around it must still be read");
        assert!(cycle.qpigs2.is_some());
        assert!(cycle.qpiws.is_some());
    }

    /// A NAK is a supported answer, not a fault, and it is asked exactly once.
    #[test]
    fn a_naked_command_is_never_asked_again() {
        let nak = || Some(build_response(b"NAK"));
        let mut port = FakePort::answering(vec![
            Some(build_response(b"B")),
            Some(build_response(QPIGS_SAMPLE)),
            nak(),
            Some(build_response(b"000000000000000000000000000000000000")),
            // Second cycle: three commands, because QPIGS2 is not asked.
            Some(build_response(b"B")),
            Some(build_response(QPIGS_SAMPLE)),
            Some(build_response(b"000000000000000000000000000000000000")),
        ]);
        let mut session = session();

        let first = poll_cycle(&mut port, &mut session, TIMEOUT).unwrap();
        assert!(first.qpigs2.is_none());
        assert_eq!(session.unsupported_commands, 1);
        // A NAK is not a discarded frame: nothing was lost, the unit answered.
        assert_eq!(session.discarded_frames, 0);

        let second = poll_cycle(&mut port, &mut session, TIMEOUT).unwrap();
        assert!(second.qpigs2.is_none());
        assert!(second.qpigs.is_some());
        assert_eq!(session.unsupported_commands, 1, "the NAK must not be re-counted");
        assert_eq!(port.written.len(), 7, "QPIGS2 must not be sent a second time");
    }

    /// A firmware that widens a field is a parse failure, and must degrade like a CRC failure
    /// rather than take the process down.
    #[test]
    fn an_unparsable_payload_is_transient() {
        let mut port = FakePort::answering(vec![
            Some(build_response(b"B")),
            Some(build_response(b"nonsense")),
            Some(build_response(b"05.4 212.5 01156 ")),
            Some(build_response(b"000000000000000000000000000000000000")),
        ]);
        let mut session = session();
        let cycle = poll_cycle(&mut port, &mut session, TIMEOUT).unwrap();
        assert_eq!(session.discarded_frames, 1);
        assert!(cycle.qpigs.is_none());
        assert!(!cycle.is_empty());
    }

    #[test]
    fn a_cycle_that_reads_nothing_is_reported_as_empty() {
        let mut port = FakePort::answering(vec![None, None, None, None]);
        let mut session = session();
        let cycle = poll_cycle(&mut port, &mut session, TIMEOUT).unwrap();
        assert!(cycle.is_empty());
        assert_eq!(session.discarded_frames, 4);
        assert_eq!(cycle.link.discarded_frames, 4);
    }

    #[test]
    fn identity_reads_all_five_and_tolerates_a_missing_one() {
        let mut port = FakePort::answering(vec![
            Some(build_response(b"92932210103714")),
            Some(build_response(b"VERFW:00072.04")),
            Some(build_response(b"NAK")),
            Some(build_response(b"MKS2-8000")),
            Some(build_response(b"044")),
        ]);
        let mut session = session();
        let identity = read_identity(&mut port, &mut session, TIMEOUT).unwrap();
        assert_eq!(
            identity,
            vec![
                ("serial_number", Some("92932210103714".to_owned())),
                ("firmware", Some("VERFW:00072.04".to_owned())),
                ("firmware_panel", None),
                ("model", Some("MKS2-8000".to_owned())),
                ("model_code", Some("044".to_owned())),
            ]
        );
    }
}
