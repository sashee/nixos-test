//! Listen to a JK BMS over USB serial and report it to a local monitoring-platform receiver.
//!
//! A daemon, like its `inverter-monitoring` sibling and for the same reason: finding the port costs
//! tens of seconds of listening, and the systemd unit restarts it 15 minutes after any exit.
//!
//! The difference from the sibling is that nothing here ever writes to the port. The BMS auto-pushes
//! a fixed ~781-byte cycle every ~6.7s -- one `0x02` realtime frame, one `0x01` settings frame, and
//! Modbus records in between -- so a measurement is "wait for the next frame of the kind I want",
//! never a request. `port::Transport` has no write method at all, which is how that stays true.
//!
//! ## What ends a run, and what does not
//!
//! `spec/features/bms-monitoring/bms-monitoring.md` says both "discard the message on [checksum]
//! failure" and "every failure exits the unit". Those cannot both be literally true, and the spec's
//! own `link_frames_discarded` counter only has a value to report under the first reading. So
//! failures are split, exactly as the sibling producer splits them:
//!
//! * **Transient.** A frame that fails its sum8, bytes that resynchronise to nothing, a receiver
//!   that cannot be reached. The frame is dropped, a counter moves, the loop continues. A flipped
//!   bit costs one measurement out of the next 6.7 seconds, not fifteen minutes of darkness -- and
//!   on this line it must, because the interleaved RS485 traffic guarantees a steady supply of bytes
//!   that are not frames.
//! * **Fatal.** No BMS found at startup, an I/O error on the port (the adapter was unplugged), or
//!   [`MAX_SILENT_CYCLES`] consecutive measurements that saw no frame at all. The process exits
//!   non-zero and systemd restarts it after `RestartSec`.
//!
//! The middle case is what the silent-cycle counter is for: a port that is open but has stopped
//! pushing is indistinguishable from a healthy idle one on any single read, and without it a
//! powered-down BMS would leave this process publishing nothing, forever, while `active`.

mod discover;
mod frame;
#[cfg(test)]
mod fixtures;
mod otlp;
mod parse;
mod port;
mod record;
mod uds;

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use frame::{Frame, FrameReader};
use port::{read_until, Opened, SerialPort, Transport};
use record::{Link, Record, Value};

const DEFAULT_SOCKET: &str = "/run/monitoring-platform/monitoring-platform.sock";
const INGEST_PATH: &str = "/v1/logs";
const PROTOBUF: &str = "application/x-protobuf";
const DEFAULT_DEV_DIR: &str = "/dev";
const DEFAULT_BY_PATH_DIR: &str = "/dev/serial/by-path";
const DEFAULT_BY_ID_DIR: &str = "/dev/serial/by-id";
const BAUD: u32 = 115_200;

/// Consecutive measurements that see no frame before the port is declared dead. Three rather than
/// one so a single missed frame -- a burst lost to noise -- is distinguishable from a BMS that has
/// stopped talking.
const MAX_SILENT_CYCLES: u32 = 3;

/// Pause between discovery sweeps inside the startup window. Short, because what is being waited
/// for is either udev finishing or the other producer releasing a port, both of which take seconds.
const RETRY_PAUSE: Duration = Duration::from_secs(3);

struct Options {
    socket: PathBuf,
    dev_dir: PathBuf,
    by_path_dir: PathBuf,
    by_id_dir: PathBuf,
    interval: Duration,
    settings_interval: Duration,
    listen: Duration,
    frame_timeout: Duration,
    discovery_window: Duration,
    resource_attributes: Vec<(String, Value)>,
    dry_run: bool,
    once: bool,
}

const USAGE: &str = "\
usage: bms-monitoring [options]

  --socket PATH             receiver unix socket (default: /run/monitoring-platform/monitoring-platform.sock)
  --resource-attr KEY=VALUE resource attribute to attach to every record; repeatable
  --dev-dir PATH            directory the ttyUSB* devices live in (default: /dev)
  --serial-by-path-dir PATH directory of per-port serial device names, which is what a device
                            is keyed by (default: /dev/serial/by-path)
  --serial-by-id-dir PATH   directory of descriptor-derived serial device names. Reported, not
                            matched on (default: /dev/serial/by-id)
  --interval-seconds N      seconds between realtime measurements (default: 60)
  --settings-interval-seconds N  seconds between settings measurements (default: 86400)
  --listen-seconds N        how long a candidate port is listened to before it is rejected. Must
                            exceed the ~6.7s frame cycle (default: 10)
  --frame-timeout-seconds N how long to wait for a frame before counting the measurement silent.
                            Frames arrive every ~6.7s, so this cannot be small (default: 30)
  --discovery-window-seconds N  how long to keep retrying discovery at startup before giving up.
                            Covers the boot race against udev and against the other producer
                            holding the port (default: 60)
  --once                    take one measurement and exit, rather than looping
  --dry-run                 print each batch instead of posting it
  --help                    this text
";

fn parse_args(args: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut options = Options {
        socket: PathBuf::from(DEFAULT_SOCKET),
        dev_dir: PathBuf::from(DEFAULT_DEV_DIR),
        by_path_dir: PathBuf::from(DEFAULT_BY_PATH_DIR),
        by_id_dir: PathBuf::from(DEFAULT_BY_ID_DIR),
        interval: Duration::from_secs(60),
        settings_interval: Duration::from_secs(86_400),
        listen: Duration::from_secs(10),
        frame_timeout: Duration::from_secs(30),
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
            "--serial-by-id-dir" => {
                options.by_id_dir = PathBuf::from(value("--serial-by-id-dir")?)
            }
            "--interval-seconds" => {
                options.interval = seconds(&value("--interval-seconds")?, "--interval-seconds")?
            }
            "--settings-interval-seconds" => {
                options.settings_interval =
                    seconds(&value("--settings-interval-seconds")?, "--settings-interval-seconds")?
            }
            "--listen-seconds" => {
                options.listen = seconds(&value("--listen-seconds")?, "--listen-seconds")?
            }
            "--frame-timeout-seconds" => {
                options.frame_timeout =
                    seconds(&value("--frame-timeout-seconds")?, "--frame-timeout-seconds")?
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

/// Everything that outlives one measurement.
struct Session {
    /// The by-path key: what `bms.device` reports. Unique per physical port whatever the chip says
    /// about itself.
    device: String,
    /// What was opened. Kept so the by-id name can be re-resolved every cycle -- see
    /// [`discover::by_id_of`] for why that name is not safe to remember.
    tty: PathBuf,
    connected_at: Instant,
    reader: FrameReader,
}

impl Session {
    fn link(&self, wait: Duration) -> Link {
        Link {
            connected_seconds: self.connected_at.elapsed().as_secs(),
            frames_ok: self.reader.frames_ok,
            frames_discarded: self.reader.frames_discarded,
            wait_seconds: wait.as_secs_f64(),
        }
    }
}

/// Wait for the next frame of one kind, and report how long it took.
///
/// `Ok(None)` is the silent case -- nothing of that kind arrived inside the timeout -- which the
/// caller counts towards giving up on the port. An `Err` is an I/O failure and is fatal: the
/// adapter has gone.
fn next_frame<T: Transport>(
    transport: &mut T,
    session: &mut Session,
    timeout: Duration,
    accept: impl Fn(&Frame) -> bool,
) -> std::io::Result<Option<(Frame, Duration)>> {
    let started = Instant::now();
    let found = read_until(transport, &mut session.reader, started + timeout, accept)?;
    Ok(found.map(|frame| (frame, started.elapsed())))
}

/// The freshest frame of each kind seen so far, with when it arrived.
///
/// This exists because a passive listener may not idle. The BMS pushes ~781 bytes every 6.7s and
/// never waits to be asked, so a producer that slept between measurements would leave ~7 KB
/// accumulating in a 4 KiB tty buffer every minute: the buffer overflows, the kernel drops bytes
/// mid-frame, and what is eventually read is both torn and a minute stale. Worse, an undrained port
/// pushes back all the way to the other end -- under QEMU it can block the emulator's main loop
/// outright.
///
/// So the loop reads continuously and remembers the latest of each kind, and the interval decides
/// only when to *publish*. A measurement is then always the most recent frame on the wire rather
/// than the first one to arrive after a sleep.
#[derive(Default)]
struct Freshest {
    realtime: Option<(Frame, Instant)>,
    settings: Option<(Frame, Instant)>,
}

impl Freshest {
    fn accept(&mut self, frame: Frame) {
        let now = Instant::now();
        if frame.is_realtime() {
            self.realtime = Some((frame, now));
        } else if frame.is_settings() {
            self.settings = Some((frame, now));
        }
        // Any other frame code is not one this producer decodes. The reader counted it; there is
        // nothing else to do with it.
    }
}

/// Read until `deadline`, keeping the freshest frame of each kind.
///
/// Returns when the deadline passes, having consumed everything the port offered in the meantime --
/// which is the point: the port is drained, not sampled.
fn drain_until<T: Transport>(
    transport: &mut T,
    session: &mut Session,
    freshest: &mut Freshest,
    deadline: Instant,
) -> std::io::Result<()> {
    while Instant::now() < deadline {
        match read_until(transport, &mut session.reader, deadline, |_| true)? {
            Some(frame) => freshest.accept(frame),
            // The deadline passed with nothing further on the wire.
            None => break,
        }
    }
    Ok(())
}

fn resource_attributes(options: &Options, session: &Session) -> Vec<(String, Value)> {
    let mut attributes = vec![("service.name".to_owned(), Value::str("bms-monitoring"))];
    if let Some(hostname) = read_trimmed("/proc/sys/kernel/hostname") {
        attributes.push(("host.name".to_owned(), Value::Str(hostname)));
    }
    if let Some(boot_id) = read_trimmed("/proc/sys/kernel/random/boot_id") {
        attributes.push(("boot_id".to_owned(), Value::Str(boot_id)));
    }
    // Resolved here rather than carried on the session: the link this reads can change owner under
    // a running producer, and the point of reporting it is recognisability -- a name that now
    // resolves to the adapter next to it is worse than none.
    let device_name = discover::by_id_of(&options.by_id_dir, &session.tty);
    attributes.extend(record::device_attributes(&session.device, device_name.as_deref()));
    attributes.extend(options.resource_attributes.iter().cloned());
    attributes
}

fn read_trimmed(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|text| text.trim().to_owned())
}

/// Post one batch. A receiver that cannot be reached is transient: `mp-collector` is a separate
/// unit that can restart under us, and this producer has no buffer of its own -- the collector is
/// the buffer. Dropping one measurement is the cost of not having one here.
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
        eprintln!("bms-monitoring: system clock is before the unix epoch; dropping batch");
        return;
    };
    let payload = otlp::encode(&otlp::build_request(resource, records, now.as_nanos() as u64));

    match uds::post(&options.socket, INGEST_PATH, PROTOBUF, &payload) {
        Err(error) => eprintln!("bms-monitoring: dropping batch: {error}"),
        Ok(response) if response.status != 200 => eprintln!(
            "bms-monitoring: receiver answered {} for {} record(s): {}",
            response.status,
            records.len(),
            String::from_utf8_lossy(&response.body).trim()
        ),
        Ok(response) => match otlp::decode_rejections(&response.body) {
            // A 200 does not mean everything landed: OTLP reports per-record rejections in the
            // body, and treating that as success would lose measurements without a trace.
            Ok(rejections) if rejections.count > 0 => eprintln!(
                "bms-monitoring: receiver rejected {} of {} record(s): {}",
                rejections.count,
                records.len(),
                rejections.message
            ),
            Ok(_) => {}
            Err(error) => eprintln!("bms-monitoring: undecodable receiver response: {error}"),
        },
    }
}

/// Probe candidates until one pushes a valid realtime frame, retrying for a bounded window.
///
/// The retry covers two races, both of which resolve in seconds and neither of which means the BMS
/// is absent. The first is udev: this unit starts at boot and the adapter is enumerated a few
/// seconds in. The second is `inverter-monitoring`, which starts at the same time and may hold the
/// port this producer wants while it probes it -- without the window, losing that coin toss would
/// mean exiting and sitting out a full `RestartSec` with a healthy BMS on the other end of the
/// cable. Since [`discover::order`] shuffles, a later sweep is unlikely to contend the same way.
///
/// Deliberately NOT a reconnect loop: once a port has been found and then lost, that is the fatal
/// case, and it stays fatal.
fn connect_within(
    options: &Options,
    window: Duration,
) -> Result<(SerialPort, discover::Candidate, Frame), String> {
    let deadline = Instant::now() + window;
    loop {
        let last = match connect(options) {
            Ok(found) => return Ok(found),
            Err(reason) => reason,
        };
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return Err(last);
        };
        eprintln!("bms-monitoring: {last}; retrying for another {}s", remaining.as_secs());
        std::thread::sleep(RETRY_PAUSE.min(remaining));
    }
}

fn connect(options: &Options) -> Result<(SerialPort, discover::Candidate, Frame), String> {
    let all = discover::enumerate(&options.dev_dir, &options.by_path_dir, &options.by_id_dir);
    if all.is_empty() {
        return Err(format!("no ttyUSB devices under {}", options.dev_dir.display()));
    }

    for candidate in discover::order(all, shuffle_seed()) {
        let name = candidate.describe();
        let mut serial = match SerialPort::open(&candidate.tty, BAUD) {
            Ok(Opened::Port(port)) => port,
            // Held by inverter-monitoring. Says nothing about whether a BMS is behind it, only
            // that this process may not look right now -- which is why the window above retries
            // rather than treating the sweep as conclusive.
            Ok(Opened::Busy) => {
                eprintln!("bms-monitoring: {name} is held by another process; skipping");
                continue;
            }
            Err(error) => {
                eprintln!("bms-monitoring: cannot open {name}: {error}");
                continue;
            }
        };
        match discover::probe(&mut serial, options.listen) {
            Ok(discover::Probe::Bms(frame)) => {
                eprintln!("bms-monitoring: BMS on {name}");
                // The frame that identified it is a measurement in its own right, and the next one
                // is 6.7 seconds away. Handing it back is what lets the first record be published
                // immediately rather than after another wait.
                return Ok((serial, candidate, *frame));
            }
            Ok(discover::Probe::Silent) => {
                eprintln!("bms-monitoring: {name} said nothing in {:?}; not the BMS", options.listen);
            }
            Ok(discover::Probe::NotABms(reason)) => {
                eprintln!("bms-monitoring: {name} is not the BMS: {reason}");
            }
            Err(error) => {
                eprintln!("bms-monitoring: listening to {name} failed: {error}");
            }
        }
    }

    Err("no BMS found on any USB serial device".to_owned())
}

/// Seed for the candidate shuffle. The clock is the only entropy this process needs and the only
/// one it can get without a dependency; a collision just means two boots probe in the same order.
fn shuffle_seed() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1)
}

fn run(options: Options) -> Result<(), String> {
    let (mut transport, candidate, first_frame) =
        connect_within(&options, options.discovery_window)?;

    let mut session = Session {
        device: candidate.path_id,
        tty: candidate.tty,
        connected_at: Instant::now(),
        reader: FrameReader::default(),
    };

    // The settings measurement goes first, once, before any status record: it carries cell_count
    // and the protection limits, which is the context every later status record is read against.
    // Waiting the full frame timeout for it is safe -- a settings frame follows every realtime
    // frame by ~8 bytes, so it is at most one cycle away.
    match next_frame(&mut transport, &mut session, options.frame_timeout, Frame::is_settings) {
        Ok(Some((frame, _))) => publish_settings(&options, &session, &frame),
        Ok(None) => eprintln!(
            "bms-monitoring: no settings frame within {:?}; carrying on with status only",
            options.frame_timeout
        ),
        Err(error) => return Err(format!("{}: {error}", session.device)),
    }

    let mut silent_cycles = 0u32;
    let mut last_settings = Instant::now();
    let started = Instant::now();
    // Seeded with the frame discovery already read, so the first status record is published at
    // once rather than an interval later.
    let mut freshest = Freshest::default();
    freshest.accept(first_frame);

    for tick in 0u64.. {
        // Read the port for the whole interval rather than sleeping through it. The deadline is
        // anchored to the start, so the cadence cannot drift: a measurement that took a second of
        // wire time does not push the next one a second later, every time, until the samples have
        // wandered minutes off the hour.
        let publish_at = started + options.interval * (tick as u32 + 1);
        drain_until(&mut transport, &mut session, &mut freshest, publish_at)
            .map_err(|error| format!("{}: {error}", session.device))?;

        // A frame older than the timeout is not a measurement, it is the last thing this port said
        // before it went quiet. Publishing it would report a stale pack indefinitely, and the
        // silent-cycle counter would never notice.
        let fresh = freshest
            .realtime
            .as_ref()
            .filter(|(_, arrived)| arrived.elapsed() <= options.frame_timeout);

        match fresh {
            Some((frame, arrived)) => {
                silent_cycles = 0;
                match parse::parse_realtime(frame) {
                    Ok(realtime) => {
                        let link = session.link(arrived.elapsed());
                        let records = record::status_records(&realtime, &link);
                        publish(&options, &resource_attributes(&options, &session), &records);
                    }
                    // A frame that passed its checksum and still will not decode means the layout
                    // this parser was written against has moved. Transient, like a bad checksum:
                    // guessing is worse than a gap, and the next frame may be fine.
                    Err(reason) => eprintln!("bms-monitoring: discarding realtime frame: {reason}"),
                }
            }
            None => {
                silent_cycles += 1;
                eprintln!(
                    "bms-monitoring: no realtime frame within {:?} ({silent_cycles} in a row)",
                    options.frame_timeout
                );
                if silent_cycles >= MAX_SILENT_CYCLES {
                    return Err(format!(
                        "{} pushed nothing for {silent_cycles} consecutive measurements",
                        session.device
                    ));
                }
            }
        }

        if options.once {
            return Ok(());
        }

        // The settings frame follows every realtime frame by ~8 bytes, so draining the interval has
        // certainly seen one. Nothing extra is read for it.
        if last_settings.elapsed() >= options.settings_interval {
            match freshest
                .settings
                .as_ref()
                .filter(|(_, arrived)| arrived.elapsed() <= options.frame_timeout)
            {
                Some((frame, _)) => {
                    publish_settings(&options, &session, frame);
                    last_settings = Instant::now();
                }
                // Not fatal, and not retried out of turn: the realtime loop is what proves the link
                // is alive, and a settings frame missed once is a day-old row, not an outage.
                None => eprintln!("bms-monitoring: no settings frame this cycle; will retry"),
            }
        }
    }

    Ok(())
}

fn publish_settings(options: &Options, session: &Session, frame: &Frame) {
    match parse::parse_settings(frame) {
        Ok(settings) => {
            let records = record::settings_records(&settings);
            publish(options, &resource_attributes(options, session), &records);
        }
        Err(reason) => eprintln!("bms-monitoring: discarding settings frame: {reason}"),
    }
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
                eprintln!("bms-monitoring: {message}");
                ExitCode::FAILURE
            }
        },
        Err(message) => {
            eprintln!("bms-monitoring: {message}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{cycle_bytes, realtime_bytes, settings_bytes};
    use crate::port::fake::FakePort;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    const TIMEOUT: Duration = Duration::from_millis(50);

    fn session() -> Session {
        Session {
            device: "platform-xhci-hcd.0-usb-0:1:1.0-port0".to_owned(),
            tty: PathBuf::from("/dev/ttyUSB0"),
            connected_at: Instant::now(),
            reader: FrameReader::default(),
        }
    }

    #[test]
    fn defaults_match_the_spec_cadence() {
        let options = parse_args(args(&[]).into_iter()).unwrap().unwrap();
        assert_eq!(options.socket, PathBuf::from(DEFAULT_SOCKET));
        assert_eq!(options.dev_dir, PathBuf::from(DEFAULT_DEV_DIR));
        assert_eq!(options.by_path_dir, PathBuf::from(DEFAULT_BY_PATH_DIR));
        // The spec's two cadences: every minute, and every 24 hours.
        assert_eq!(options.interval, Duration::from_secs(60));
        assert_eq!(options.settings_interval, Duration::from_secs(86_400));
        // The spec's 10-second listen, which must exceed the ~6.7s frame cycle.
        assert_eq!(options.listen, Duration::from_secs(10));
        assert!(options.listen.as_secs_f64() > 6.7, "a healthy BMS must not miss the window");
        // And the frame timeout must span several cycles, or ordinary jitter reads as silence.
        assert!(options.frame_timeout.as_secs_f64() > 3.0 * 6.7);
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

    #[test]
    fn a_realtime_frame_is_taken_off_a_full_cycle() {
        let mut port = FakePort::streaming(vec![cycle_bytes()]);
        let mut session = session();
        let (frame, waited) =
            next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().unwrap();
        assert!(frame.is_realtime());
        assert!(waited < TIMEOUT);
        let realtime = parse::parse_realtime(&frame).unwrap();
        assert_eq!(realtime.soc, 63);
    }

    /// The counters are cumulative across measurements, which is what makes them describe the link
    /// rather than one read.
    #[test]
    fn the_link_counters_accumulate_across_measurements() {
        let mut port = FakePort::streaming(vec![cycle_bytes(), cycle_bytes()]);
        let mut session = session();
        next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().unwrap();
        let first = session.link(Duration::from_secs(7));
        next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().unwrap();
        let second = session.link(Duration::from_secs(7));

        assert!(second.frames_ok > first.frames_ok);
        assert_eq!(second.frames_discarded, 0);
        assert_eq!(second.wait_seconds, 7.0);
    }

    /// The central claim of the failure taxonomy: a corrupt frame costs one frame, not the run.
    #[test]
    fn a_bad_checksum_is_counted_and_the_next_frame_still_arrives() {
        let mut corrupt = realtime_bytes();
        corrupt[299] ^= 0xFF;
        let mut port = FakePort::streaming(vec![corrupt, realtime_bytes()]);
        let mut session = session();

        let (frame, _) =
            next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().unwrap();
        assert!(parse::parse_realtime(&frame).is_ok());
        let link = session.link(Duration::ZERO);
        assert_eq!(link.frames_discarded, 1, "the corrupt frame must be counted");
        assert_eq!(link.frames_ok, 1);
    }

    /// A port that has gone quiet yields nothing rather than blocking or erroring -- the caller
    /// counts it, and only gives up after MAX_SILENT_CYCLES of them.
    #[test]
    fn a_silent_port_is_reported_as_no_frame() {
        let mut port = FakePort::silent();
        let mut session = session();
        assert!(next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().is_none());
    }

    /// The threshold has to be far enough out that ordinary jitter cannot reach it, because what
    /// it costs is a 15-minute restart. Three measurements at the default timeout is ~90 seconds,
    /// or over thirteen frame cycles, of complete silence.
    #[test]
    fn the_silence_threshold_is_many_frame_cycles_wide() {
        let options = parse_args(args(&[]).into_iter()).unwrap().unwrap();
        let blind = options.frame_timeout * MAX_SILENT_CYCLES;
        assert!(blind >= Duration::from_secs(90), "{blind:?} is too short to be conclusive");
        assert!(
            blind.as_secs_f64() / 6.7 > 13.0,
            "a burst of lost frames must not be mistaken for a dead port"
        );
    }

    /// An unplugged adapter must be distinguishable from a quiet one: one is fatal, the other is
    /// counted.
    #[test]
    fn an_io_error_is_not_silence() {
        let mut port = FakePort::failing_after(Vec::new(), 0);
        let mut session = session();
        assert!(next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).is_err());
    }

    /// Waiting for settings steps over the realtime frames in front of it, which is the whole of
    /// "listens for the next suitable frame".
    #[test]
    fn the_settings_frame_is_found_behind_the_realtime_one() {
        let mut port = FakePort::streaming(vec![cycle_bytes()]);
        let mut session = session();
        let (frame, _) =
            next_frame(&mut port, &mut session, TIMEOUT, Frame::is_settings).unwrap().unwrap();
        assert!(frame.is_settings());
        let settings = parse::parse_settings(&frame).unwrap();
        assert_eq!(settings.cell_count, 16);
    }

    /// A BMS that pushes realtime frames but no settings must still produce status records: the
    /// settings read is best-effort, and losing it cannot cost the measurement this service is for.
    #[test]
    fn a_missing_settings_frame_does_not_stop_the_realtime_measurements() {
        let mut port = FakePort::streaming(vec![realtime_bytes(), realtime_bytes()]);
        let mut session = session();
        assert!(next_frame(&mut port, &mut session, TIMEOUT, Frame::is_settings).unwrap().is_none());
        // And the realtime frames behind it are still readable.
        let mut port = FakePort::streaming(vec![realtime_bytes()]);
        assert!(next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime)
            .unwrap()
            .is_some());
    }

    #[test]
    fn settings_frames_alone_never_satisfy_a_realtime_wait() {
        let mut port = FakePort::streaming(vec![settings_bytes(), settings_bytes()]);
        let mut session = session();
        assert!(next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().is_none());
        // They were read, though -- the reader counted them.
        assert_eq!(session.link(Duration::ZERO).frames_ok, 2);
    }

    /// The property that keeps the port drained: everything on the wire is consumed within the
    /// interval, not just the one frame a measurement needs.
    #[test]
    fn draining_consumes_every_frame_in_the_window() {
        // Three cycles' worth, which is six frames.
        let mut port =
            FakePort::streaming(vec![cycle_bytes(), cycle_bytes(), cycle_bytes()]);
        let mut session = session();
        let mut freshest = Freshest::default();
        drain_until(&mut port, &mut session, &mut freshest, Instant::now() + TIMEOUT).unwrap();

        assert_eq!(session.link(Duration::ZERO).frames_ok, 6, "every frame must be consumed");
        assert!(freshest.realtime.is_some());
        assert!(freshest.settings.is_some());
    }

    /// And what it keeps is the newest, not the first: a measurement must report the pack as it is
    /// now, not as it was at the top of the interval.
    #[test]
    fn draining_keeps_the_freshest_frame_not_the_first() {
        let mut stale = realtime_bytes();
        stale[173] = 20; // SOC 20% in the older frame
        let mut port = FakePort::streaming(vec![stale, realtime_bytes()]);
        let mut session = session();
        let mut freshest = Freshest::default();
        drain_until(&mut port, &mut session, &mut freshest, Instant::now() + TIMEOUT).unwrap();

        let (frame, _) = freshest.realtime.as_ref().expect("a realtime frame");
        assert_eq!(parse::parse_realtime(frame).unwrap().soc, 63, "kept the stale frame");
    }

    /// A settings frame is not displaced by the realtime frames that interleave with it: the two
    /// are remembered independently, which is what lets the daily settings record be published
    /// without a second read of the port.
    #[test]
    fn realtime_and_settings_are_remembered_separately() {
        let mut port = FakePort::streaming(vec![cycle_bytes(), realtime_bytes(), realtime_bytes()]);
        let mut session = session();
        let mut freshest = Freshest::default();
        drain_until(&mut port, &mut session, &mut freshest, Instant::now() + TIMEOUT).unwrap();

        let (settings, _) = freshest.settings.as_ref().expect("the settings frame must survive");
        assert_eq!(parse::parse_settings(settings).unwrap().cell_count, 16);
        assert!(freshest.realtime.is_some());
    }

    /// A port that says nothing leaves nothing behind, which is what the silent-cycle counter is
    /// looking at.
    #[test]
    fn draining_a_silent_port_finds_no_frame() {
        let mut port = FakePort::silent();
        let mut session = session();
        let mut freshest = Freshest::default();
        drain_until(&mut port, &mut session, &mut freshest, Instant::now() + TIMEOUT).unwrap();
        assert!(freshest.realtime.is_none());
        assert!(freshest.settings.is_none());
    }

    #[test]
    fn draining_propagates_an_io_error() {
        let mut port = FakePort::failing_after(Vec::new(), 0);
        let mut session = session();
        let mut freshest = Freshest::default();
        assert!(
            drain_until(&mut port, &mut session, &mut freshest, Instant::now() + TIMEOUT).is_err()
        );
    }

    /// One full cycle produces exactly the records the spec asks for: a status record, sixteen
    /// cells, no alarms, and a settings record with sixteen cells of its own.
    #[test]
    fn one_cycle_produces_the_documented_record_set() {
        let mut port = FakePort::streaming(vec![cycle_bytes()]);
        let mut session = session();

        let (realtime_frame, waited) =
            next_frame(&mut port, &mut session, TIMEOUT, Frame::is_realtime).unwrap().unwrap();
        let realtime = parse::parse_realtime(&realtime_frame).unwrap();
        let status = record::status_records(&realtime, &session.link(waited));
        assert_eq!(status.len(), 17);
        assert_eq!(status[0].event_name, record::STATUS);
        assert!(status[1..].iter().all(|r| r.event_name == record::STATUS_CELL));

        let (settings_frame, _) =
            next_frame(&mut port, &mut session, TIMEOUT, Frame::is_settings).unwrap().unwrap();
        let settings = parse::parse_settings(&settings_frame).unwrap();
        let records = record::settings_records(&settings);
        assert_eq!(records.len(), 17);
        assert_eq!(records[0].event_name, record::SETTINGS);
    }
}
