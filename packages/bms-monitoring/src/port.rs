//! The serial line. The only module that talks to the outside world on the device side, which is
//! what lets everything above it be tested without hardware.
//!
//! Read-only by construction. `spec/features/bms-monitoring/bms-monitoring.md` says "only passive
//! monitoring, never sending data, only listening", and the way to keep that true is to not have a
//! write path at all: the fd is opened `O_RDONLY` and [`Transport`] has no write method, so there
//! is nothing to call by accident. The BMS auto-pushes and needs no start command (protocol.md
//! §1), so nothing is given up.

use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::Instant;

use rustix::event::{poll, PollFd, PollFlags, Timespec};
use rustix::fs::{fcntl_setfl, flock, FlockOperation, OFlags};
use rustix::io::Errno;
use rustix::termios::{
    ioctl_tiocexcl, tcgetattr, tcsetattr, ControlModes, InputModes, LocalModes, OptionalActions,
    OutputModes, SpecialCodeIndex,
};

use crate::frame::{Frame, FrameReader};

/// What the reader needs from a port. A trait so the framing and the poll loop can be driven from
/// a scripted fake; the VM test exercises the real implementation against an emulated FTDI.
pub trait Transport {
    /// Read whatever has arrived. `Ok(0)` is "nothing yet", which on this line is the normal state
    /// -- the wire is idle between bursts. An `Err` means the port is finished, which the caller
    /// treats as fatal.
    ///
    /// An implementation must not answer `Ok(0)` without having waited: the caller reads that as
    /// "ask again" and has no pacing of its own. [`SerialPort`] gets that from the `poll(2)` in
    /// [`SerialPort::wait`]. The test fake ignores the contract and answers instantly, which is
    /// why the tests below give it short deadlines.
    fn read_some(&mut self, buffer: &mut [u8]) -> std::io::Result<usize>;
}

/// Pump bytes into `reader` until a frame `accept`s, or the deadline passes.
///
/// The one blocking read loop in the crate. Frames that arrive but are not wanted are consumed and
/// dropped -- which is the whole of "listens for the next suitable frame": waiting for a settings
/// frame means stepping over the realtime frames that interleave with it, and the reader's counters
/// still see them.
///
/// `reader` is borrowed rather than created here so its counters and its partial buffer survive
/// across calls. A fresh reader per measurement would resynchronise from scratch every minute and
/// lose the frame that was half-arrived when the last one returned.
///
/// No sleep on an empty read, because [`Transport::read_some`] is what blocks -- see the contract
/// there. That contract is load-bearing rather than incidental: while the pacing was the driver's
/// `VTIME` instead of this process's own `poll(2)`, a *disconnected* adapter began answering
/// zero-length reads instantly and for ever, and this loop spun a core flat for the whole
/// deadline. Measured on the fleet's Pi on 2026-08-21: 154.995s of CPU across the 154s between the
/// adapter vanishing and the third silent measurement ending the run.
///
/// A fake port answers instantly by design, which is why tests give it short deadlines.
pub fn read_until<T: Transport>(
    transport: &mut T,
    reader: &mut FrameReader,
    deadline: Instant,
    accept: impl Fn(&Frame) -> bool,
) -> std::io::Result<Option<Frame>> {
    // Whatever arrived before this call was made -- a frame can already be complete in the buffer.
    while let Some(frame) = reader.next_frame() {
        if accept(&frame) {
            return Ok(Some(frame));
        }
    }

    let mut chunk = [0u8; 512];
    while Instant::now() < deadline {
        let count = transport.read_some(&mut chunk)?;
        if count == 0 {
            continue;
        }
        reader.feed(&chunk[..count]);
        while let Some(frame) = reader.next_frame() {
            if accept(&frame) {
                return Ok(Some(frame));
            }
        }
    }
    Ok(None)
}

/// How long one wait blocks before reporting an idle line.
///
/// The same 100ms the line's `VTIME` is set to, so the loop above ticks at the rate it always did.
/// What changed is whose clock it is: this process's, not the driver's.
const WAIT: Timespec = Timespec { tv_sec: 0, tv_nsec: 100_000_000 };

/// What one wait on the port found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ready {
    /// Bytes are waiting to be read.
    Readable,
    /// Nothing arrived inside [`WAIT`]. The ordinary state of this line between bursts.
    Idle,
    /// The port is gone. Distinct from [`Ready::Idle`] and that distinction is the point of this
    /// enum: a BMS that has stopped talking is idle and recoverable, an adapter that has been
    /// unplugged is neither.
    Gone,
}

/// Read one `poll(2)` result.
///
/// Pure, and deliberately separated from the syscall: this mapping is the whole of the fix, and
/// none of the interesting cases can be produced on demand from a real adapter.
///
/// `HUP` outranks `IN`. A hung-up tty may report both, but the hangup flushes the input queue, so
/// whatever `IN` is promising is not the pack's -- and taking the `IN` branch is precisely what
/// used to happen, whereupon the read returned zero instantly and the caller looped on it.
fn classify(revents: PollFlags) -> Ready {
    if revents.intersects(PollFlags::HUP | PollFlags::ERR | PollFlags::NVAL) {
        Ready::Gone
    } else if revents.contains(PollFlags::IN) {
        Ready::Readable
    } else {
        Ready::Idle
    }
}

/// The error a vanished adapter produces.
///
/// `NotConnected` rather than a bare string so the kind carries the meaning: it is the same kind
/// [`fake::FakePort::failing_after`] has always used to stand in for an unplugged adapter, and the
/// caller's fatal/transient split can be made on it if it ever needs to be finer than "any `Err`".
fn disconnected() -> std::io::Error {
    std::io::Error::new(ErrorKind::NotConnected, "the port hung up; the adapter is gone")
}

/// Take the whole-device advisory lock, or report that someone else has it.
///
/// `Ok(false)` means "held by another process" and nothing else; every other errno is a real
/// failure. Split out so the semantics this design rests on are testable without a tty.
fn try_lock_exclusive(file: &File) -> std::io::Result<bool> {
    match flock(file, FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => Ok(true),
        // EWOULDBLOCK and EAGAIN are the same value on Linux, so this one arm covers both.
        Err(error) if error == Errno::WOULDBLOCK => Ok(false),
        Err(error) => Err(error.into()),
    }
}

pub struct SerialPort {
    file: File,
}

/// What [`SerialPort::open`] found.
///
/// `Busy` is an ordinary outcome, not an error: `inverter-monitoring` holds the port, and the
/// caller's job is to move on to the next candidate.
pub enum Opened {
    Port(SerialPort),
    Busy,
}

impl SerialPort {
    /// Open and configure one port: 115200 8N1, raw, no flow control (protocol.md §1).
    ///
    /// ## Why the line must be raw, and why that is not boilerplate
    ///
    /// The payload is binary and routinely contains the bytes a cooked line discipline eats. A
    /// cell at 3.253 V is `b5 0c`, so `0x0d` (CR) and `0x0a` (LF) occur constantly in the cell
    /// block and would be NL/CR-translated; `0x11`/`0x13` (XON/XOFF) turn up in the current and
    /// temperature fields and would be swallowed by software flow control. Both corrupt frames at
    /// a low, maddening rate rather than failing outright -- and the failure mode is visible: a
    /// `cat` of this device with the port left at its 9600 cooked default returned **2 bytes** in
    /// 60 seconds where a raw one reads ~7000.
    ///
    /// ## Why the port is locked, and why both mechanisms are here
    ///
    /// This host has a second producer probing the same `/dev/ttyUSB*` set, and a tty has one
    /// input queue: `read(2)` is destructive, so two readers get an arbitrary split of the bytes
    /// rather than a copy each. Measured on the fleet's Pi over one 12s window, two readers got
    /// 1079 and 441 bytes and a corrupt frame each, where either alone reads ~1400 with no bad
    /// checksums.
    ///
    /// * `flock(LOCK_EX|LOCK_NB)` decides the race. Advisory -- it binds only the two producers,
    ///   which is enough because they are the two readers that exist -- but decided by lock order
    ///   rather than open order, so exactly one wins however the opens interleave. That is the
    ///   case that matters: both units start at boot.
    /// * `TIOCEXCL` turns away non-cooperating openers by making a later `open(2)` fail `EBUSY`.
    ///   Verified against the deployed sandbox (`DynamicUser` + `dialout`, empty
    ///   `CapabilityBoundingSet`). It cannot replace the flock: it only rejects opens that come
    ///   *after* it, so two processes that both open before either reaches the ioctl both succeed,
    ///   and it is bypassed by `CAP_SYS_ADMIN` anyway.
    ///
    /// Ordering is load-bearing: the lock is taken before `tcsetattr` and before the first read,
    /// and a `Busy` return closes the fd having done neither. Those are the operations that would
    /// disturb whoever holds the port. Holding an idle fd steals nothing -- also measured.
    pub fn open(path: &Path, baud: u32) -> std::io::Result<Opened> {
        // O_NONBLOCK so the open cannot hang waiting for a carrier a USB adapter may never assert;
        // cleared below, once CLOCAL makes the question moot and VMIN/VTIME bound a read.
        let opened = OpenOptions::new()
            .read(true)
            .custom_flags((OFlags::NOCTTY | OFlags::NONBLOCK).bits() as i32)
            .open(path);

        let file = match opened {
            Ok(file) => file,
            // The port being taken can arrive by either mechanism, depending on how far the other
            // producer had got: if it already set `TIOCEXCL`, the kernel refuses this open(2) with
            // EBUSY before the flock below is ever reached. Same situation, same answer -- and
            // reporting it as an error instead would put "cannot open: Device or resource busy" in
            // the journal, which reads like a broken adapter rather than a busy one.
            Err(error) if Errno::from_io_error(&error) == Some(Errno::BUSY) => {
                return Ok(Opened::Busy)
            }
            Err(error) => return Err(error),
        };

        if !try_lock_exclusive(&file)? {
            return Ok(Opened::Busy);
        }

        ioctl_tiocexcl(&file)?;

        let mut termios = tcgetattr(&file)?;
        termios.make_raw();
        termios.set_speed(baud)?;

        // 8N1. make_raw() leaves the frame format alone, so each of these is load-bearing:
        // inheriting whatever the last user of the port left behind is how a working cable starts
        // returning garbage after an unrelated program touches it.
        termios.control_modes &= !ControlModes::CSIZE;
        termios.control_modes |= ControlModes::CS8;
        termios.control_modes &= !ControlModes::PARENB; // no parity
        termios.control_modes &= !ControlModes::CSTOPB; // one stop bit
        termios.control_modes &= !ControlModes::CRTSCTS; // no hardware flow control
        termios.control_modes |= ControlModes::CLOCAL | ControlModes::CREAD;
        termios.input_modes &= !(InputModes::IXON | InputModes::IXOFF | InputModes::IXANY);
        termios.output_modes = OutputModes::empty();
        termios.local_modes = LocalModes::empty();

        // A read returns as soon as anything is there and gives up after 100ms if nothing is. The
        // frame deadline is enforced by the loop above this, not by the driver: one frame is 300
        // bytes and ~26ms of wire time at 115200, but they arrive 6.7 seconds apart, so any
        // single-read timeout long enough to span that gap would be far too coarse to cancel on.
        //
        // These are no longer what paces the read loop -- `wait()` is -- but they stay, because
        // they bound the one read that follows a `poll(2)` claiming the port is readable. That is
        // the case where poll and the read can disagree, and without VTIME it would block.
        termios.special_codes[SpecialCodeIndex::VMIN] = 0;
        termios.special_codes[SpecialCodeIndex::VTIME] = 1;

        tcsetattr(&file, OptionalActions::Now, &termios)?;
        fcntl_setfl(&file, OFlags::empty())?;

        Ok(Opened::Port(SerialPort { file }))
    }

    /// Block until the port has something to say, [`WAIT`] passes, or the port goes away.
    ///
    /// The only place the read path blocks, and asking `poll(2)` rather than letting the driver's
    /// `VTIME` do it is what separates an idle line from a disconnected one. A zero-length read
    /// cannot separate them: the tty layer answers a hung-up port with an instant end-of-file that
    /// is byte-for-byte indistinguishable from an idle port's VTIME expiry.
    ///
    /// That ambiguity is what cost the fleet's Pi a core of CPU for 154 seconds on 2026-08-21, when
    /// a dying USB controller took the adapter with it. The lost measurements were the controller's
    /// doing and no read loop could have saved them; the spin, and the 90 seconds spent reaching a
    /// conclusion the first read already had the evidence for, were this function's absence.
    fn wait(&self) -> std::io::Result<Ready> {
        let mut fds = [PollFd::new(&self.file, PollFlags::IN)];
        match poll(&mut fds, Some(&WAIT)) {
            Ok(_) => Ok(classify(fds[0].revents())),
            // A signal is not news about the port, and the caller's next turn asks again.
            Err(Errno::INTR) => Ok(Ready::Idle),
            Err(error) => Err(error.into()),
        }
    }
}

impl Transport for SerialPort {
    fn read_some(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        match self.wait()? {
            Ready::Idle => Ok(0),
            Ready::Gone => Err(disconnected()),
            Ready::Readable => match self.file.read(buffer) {
                // Readable and yet empty is end-of-file, and a tty gets there only by being hung
                // up. It is NOT silence: the wait above has just said there were bytes, so a read
                // that finds none is the port ending rather than the line being quiet.
                Ok(0) => Err(disconnected()),
                Ok(count) => Ok(count),
                // A spurious wakeup, which costs nothing now that the wait is what paces the loop.
                Err(error) if error.kind() == ErrorKind::WouldBlock => Ok(0),
                Err(error) if error.kind() == ErrorKind::Interrupted => Ok(0),
                Err(error) => Err(error),
            },
        }
    }
}

#[cfg(test)]
pub mod fake {
    use std::collections::VecDeque;

    use super::Transport;

    /// A scripted port: a queue of chunks to hand out, one per read, then silence.
    ///
    /// Silence rather than EOF, because that is what the hardware does -- a BMS that has stopped
    /// talking leaves the port open and readable, returning nothing. An EOF would make the
    /// go-silent path look like an I/O error and take a different branch.
    ///
    /// That is exactly the [`Ready::Idle`] / [`Ready::Gone`] split, and the two fakes line up with
    /// it: [`FakePort::silent`] is a live pack saying nothing, [`FakePort::failing_after`] is the
    /// adapter being pulled. What this fake cannot model is the ambiguity underneath -- the real
    /// port answers both with a zero-length read, and separating them is `SerialPort`'s job and is
    /// tested against a real fd rather than here.
    pub struct FakePort {
        pub chunks: VecDeque<Vec<u8>>,
        pub reads: usize,
        pub error_after: Option<usize>,
    }

    impl FakePort {
        pub fn streaming(chunks: Vec<Vec<u8>>) -> FakePort {
            FakePort { chunks: chunks.into(), reads: 0, error_after: None }
        }

        pub fn silent() -> FakePort {
            FakePort::streaming(Vec::new())
        }

        /// A port that hands out `chunks` and then fails, as an unplugged adapter does.
        pub fn failing_after(chunks: Vec<Vec<u8>>, reads: usize) -> FakePort {
            FakePort { chunks: chunks.into(), reads: 0, error_after: Some(reads) }
        }
    }

    impl Transport for FakePort {
        fn read_some(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.reads += 1;
            if let Some(limit) = self.error_after {
                if self.reads > limit {
                    return Err(std::io::Error::from(std::io::ErrorKind::NotConnected));
                }
            }
            let Some(chunk) = self.chunks.pop_front() else {
                return Ok(0);
            };
            let count = chunk.len().min(buffer.len());
            buffer[..count].copy_from_slice(&chunk[..count]);
            // A chunk longer than the caller's buffer keeps its tail for the next read, which is
            // what a real driver does.
            if count < chunk.len() {
                self.chunks.push_front(chunk[count..].to_vec());
            }
            Ok(count)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::path::PathBuf;
    use std::time::Duration;

    use super::fake::FakePort;
    use super::*;
    use crate::fixtures::{cycle_bytes, realtime_bytes, settings_bytes};

    const WINDOW: Duration = Duration::from_millis(50);

    fn deadline() -> Instant {
        Instant::now() + WINDOW
    }

    #[test]
    fn read_until_returns_the_first_accepted_frame() {
        let mut port = FakePort::streaming(vec![cycle_bytes()]);
        let mut reader = FrameReader::default();
        let frame = read_until(&mut port, &mut reader, deadline(), Frame::is_realtime)
            .unwrap()
            .expect("the cycle contains a realtime frame");
        assert!(frame.is_realtime());
    }

    /// Waiting for a settings frame steps over the realtime frame in front of it, and the skipped
    /// frame is still counted -- the counters describe the line, not this call.
    #[test]
    fn unwanted_frames_are_consumed_while_waiting_for_the_wanted_one() {
        let mut port = FakePort::streaming(vec![cycle_bytes()]);
        let mut reader = FrameReader::default();
        let frame = read_until(&mut port, &mut reader, deadline(), Frame::is_settings)
            .unwrap()
            .expect("the cycle contains a settings frame");
        assert!(frame.is_settings());
        assert_eq!(reader.frames_ok, 2, "the realtime frame it stepped over must still be counted");
    }

    /// A frame arriving in one call and being asked for in the next must not be lost: the reader's
    /// buffer is what carries it across, which is why it is not created per call.
    #[test]
    fn a_frame_already_buffered_is_returned_without_another_read() {
        let mut port = FakePort::streaming(vec![realtime_bytes(), settings_bytes()]);
        let mut reader = FrameReader::default();

        // First call takes the realtime frame and, in doing so, buffers nothing extra.
        read_until(&mut port, &mut reader, deadline(), Frame::is_realtime).unwrap().unwrap();
        // Feed the settings frame in, then ask with an already-expired deadline: it can only be
        // answered from the buffer.
        let mut chunk = [0u8; 512];
        let count = port.read_some(&mut chunk).unwrap();
        reader.feed(&chunk[..count]);
        let frame = read_until(&mut port, &mut reader, Instant::now(), Frame::is_settings)
            .unwrap()
            .expect("a buffered frame must be returned even past the deadline");
        assert!(frame.is_settings());
    }

    #[test]
    fn a_silent_line_yields_nothing_rather_than_blocking_forever() {
        let mut port = FakePort::silent();
        let mut reader = FrameReader::default();
        let started = Instant::now();
        let frame = read_until(&mut port, &mut reader, deadline(), Frame::is_realtime).unwrap();
        assert!(frame.is_none());
        assert!(started.elapsed() >= WINDOW, "the deadline must be honoured, not short-circuited");
    }

    /// An unplugged adapter is an I/O error, and must surface rather than look like silence: the
    /// two take different branches in the caller, one fatal and one not.
    #[test]
    fn an_io_error_propagates() {
        let mut port = FakePort::failing_after(vec![realtime_bytes()], 1);
        let mut reader = FrameReader::default();
        // The first read succeeds and yields the frame.
        assert!(read_until(&mut port, &mut reader, deadline(), Frame::is_realtime)
            .unwrap()
            .is_some());
        // The next one fails.
        assert!(read_until(&mut port, &mut reader, deadline(), Frame::is_settings).is_err());
    }

    /// Byte-at-a-time delivery, which is what a real driver does on a busy line.
    #[test]
    fn reassembles_across_tiny_reads() {
        let chunks: Vec<Vec<u8>> = cycle_bytes().chunks(3).map(<[u8]>::to_vec).collect();
        let mut port = FakePort::streaming(chunks);
        let mut reader = FrameReader::default();
        let frame = read_until(&mut port, &mut reader, deadline(), Frame::is_realtime)
            .unwrap()
            .expect("a frame split into 3-byte reads is still a frame");
        assert!(frame.is_realtime());
    }

    #[test]
    fn a_hangup_outranks_everything_else_poll_can_say() {
        assert_eq!(classify(PollFlags::IN), Ready::Readable);
        assert_eq!(classify(PollFlags::empty()), Ready::Idle);
        assert_eq!(classify(PollFlags::HUP), Ready::Gone);
        // Both at once, which is what a tty can report at the moment it is unplugged. Readable
        // wins here and the port spins; Gone wins and the run ends.
        assert_eq!(classify(PollFlags::HUP | PollFlags::IN), Ready::Gone);
        assert_eq!(classify(PollFlags::ERR), Ready::Gone);
        assert_eq!(classify(PollFlags::NVAL), Ready::Gone);
    }

    /// A port over a pipe. Not a tty, and it does not need to be: what these tests are about is the
    /// `poll(2)`/`read(2)` pair and the three answers it can give, and a pipe produces all three on
    /// demand where an FTDI adapter produces the interesting ones only by being unplugged. That the
    /// *hardware* reaches them at all is what tests/bms-monitoring.nix checks, against a QEMU
    /// usb-serial device it detaches mid-run.
    fn pipe_port() -> (SerialPort, File) {
        let (read, write) = rustix::pipe::pipe().expect("a pipe");
        (SerialPort { file: File::from(read) }, File::from(write))
    }

    /// The regression this whole arrangement exists for. A port whose other end has gone must be an
    /// error, not silence: as silence it costs three frame timeouts to reach the same conclusion,
    /// and spends them spinning.
    #[test]
    fn a_vanished_peer_is_an_error_rather_than_silence() {
        let (mut port, write) = pipe_port();
        drop(write);

        let mut chunk = [0u8; 8];
        let error = port.read_some(&mut chunk).expect_err("a hangup must not read as an idle line");
        assert_eq!(error.kind(), ErrorKind::NotConnected, "{error}");
    }

    /// And the loop above must end on it at once rather than burning the deadline. This is the
    /// shape of the Pi's 2026-08-21 failure: a 30-second frame timeout, an adapter that is gone,
    /// and -- before the fix -- 30 seconds of hot loop per measurement.
    #[test]
    fn a_vanished_peer_ends_the_read_loop_without_spinning() {
        let (mut port, write) = pipe_port();
        drop(write);

        let mut reader = FrameReader::default();
        let started = Instant::now();
        let outcome = read_until(
            &mut port,
            &mut reader,
            Instant::now() + Duration::from_secs(30),
            Frame::is_realtime,
        );

        assert!(outcome.is_err(), "a gone port must not be waited out");
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "took {:?} of a 30s deadline",
            started.elapsed()
        );
    }

    /// The other half, and the property that actually bounds the CPU: an open port with nothing on
    /// it is silence, and one empty answer costs a wait rather than a turn of a hot loop. Without
    /// this, `read_until` is free to spin however correct its hangup handling is.
    #[test]
    fn an_idle_port_costs_a_wait_rather_than_a_spin() {
        // The write end is held open and nothing is written: a live pack between bursts.
        let (mut port, _write) = pipe_port();

        let mut chunk = [0u8; 8];
        let started = Instant::now();
        assert_eq!(port.read_some(&mut chunk).unwrap(), 0, "an idle port is not an error");
        assert!(
            started.elapsed() >= Duration::from_millis(50),
            "an empty read returned in {:?}, so the caller is free to spin on it",
            started.elapsed()
        );
    }

    /// And bytes still arrive, which is the case the added `poll(2)` must not get in the way of.
    #[test]
    fn bytes_on_a_live_port_are_still_returned() {
        let (mut port, mut write) = pipe_port();
        write.write_all(b"hello").unwrap();

        let mut chunk = [0u8; 8];
        assert_eq!(port.read_some(&mut chunk).unwrap(), 5);
        assert_eq!(&chunk[..5], b"hello");
    }

    fn temp_path(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("bms-monitoring-{name}-{}", std::process::id()));
        path
    }

    fn touch(name: &str) -> (PathBuf, File) {
        let path = temp_path(name);
        let file = OpenOptions::new().create(true).truncate(true).write(true).open(&path).unwrap();
        (path, file)
    }

    /// The property the whole arrangement rests on: the second holder is turned away rather than
    /// being allowed to read alongside the first.
    #[test]
    fn a_second_holder_is_refused_while_the_first_has_it() {
        let (path, first) = touch("lock-refused");
        assert!(try_lock_exclusive(&first).unwrap());

        let second = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(
            !try_lock_exclusive(&second).unwrap(),
            "a second holder must be told the device is busy, not given a share of it"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// No lockfile, no stale state: closing the fd is what releases it, which is what lets the
    /// other producer take a port this one has given up.
    #[test]
    fn closing_the_holder_releases_the_lock() {
        let (path, first) = touch("lock-released");
        assert!(try_lock_exclusive(&first).unwrap());

        let contender = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(!try_lock_exclusive(&contender).unwrap());

        drop(first);
        assert!(try_lock_exclusive(&contender).unwrap(), "the lock must go with the fd");

        let _ = std::fs::remove_file(&path);
    }

    /// The two producers must contend on the same lock even when they name the device
    /// differently: one may open `/dev/ttyUSB0` and the other a `/dev/serial/by-path` symlink to
    /// it. flock is per-inode, and this is what says so.
    #[test]
    fn a_symlink_to_the_device_shares_its_lock() {
        let (path, holder) = touch("lock-symlink");
        let link = temp_path("lock-symlink-alias");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&path, &link).unwrap();

        assert!(try_lock_exclusive(&holder).unwrap());
        let through_link = OpenOptions::new().read(true).open(&link).unwrap();
        assert!(
            !try_lock_exclusive(&through_link).unwrap(),
            "the same device under another name must be the same lock"
        );

        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_file(&path);
    }
}
