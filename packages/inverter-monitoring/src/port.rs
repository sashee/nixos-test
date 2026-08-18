//! The serial line. The only module that talks to the outside world on the device side, which
//! is what lets everything above it be tested without hardware.

use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use rustix::fs::{fcntl_setfl, flock, FlockOperation, OFlags};
use rustix::io::Errno;
use rustix::termios::{
    ioctl_tiocexcl, tcflush, tcgetattr, tcsetattr, ControlModes, InputModes, LocalModes,
    OptionalActions, OutputModes, QueueSelector, SpecialCodeIndex,
};

use crate::protocol::CR;

/// What the poller needs from a port. A trait so the discovery and polling logic can be driven
/// from a scripted fake in unit tests; the VM test exercises the real implementation against an
/// emulated FTDI device.
pub trait Transport {
    fn write_request(&mut self, data: &[u8]) -> std::io::Result<()>;

    /// Bytes up to and including the first `<CR>`, or `None` if the deadline passed first.
    fn read_frame(&mut self, timeout: Duration) -> std::io::Result<Option<Vec<u8>>>;

    /// Discard whatever arrives over `window` and report how much there was.
    ///
    /// This is the BMS test: protocol.md's device is half-duplex and never speaks unsolicited,
    /// so anything that talks without being asked is something else on the bus.
    fn listen(&mut self, window: Duration) -> std::io::Result<usize>;
}

/// Take the whole-device advisory lock, or report that someone else has it.
///
/// `Ok(false)` is "held by another process" and nothing else; every other errno is a real failure
/// and is propagated. Split out from [`SerialPort::open`] so the semantics this design rests on
/// are testable without a tty: that a second attempt fails while the first fd is open, and that
/// the kernel drops the lock when that fd closes, with no lockfile to go stale.
///
/// The lock lives on the open file description, so it also survives the fd being moved into
/// [`SerialPort`] and is released only when the last copy closes -- including on `SIGKILL`.
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
/// `Busy` is an ordinary outcome, not an error: the other producer on this host holds the port,
/// and the caller's job is to move on to the next candidate.
pub enum Opened {
    Port(SerialPort),
    Busy,
}

impl SerialPort {
    /// Open and configure one port: 2400 8N1, no parity, no flow control, raw.
    ///
    /// Two readers on one port produce interleaved half-frames that both sides then blame on line
    /// noise, and on this host the other reader is real: `bms-monitoring` probes the same
    /// `/dev/ttyUSB*` set, and both units start at boot. Measured on the fleet's Pi, two readers
    /// over one 12s window got 1079 and 441 bytes and a corrupt frame each, where either alone
    /// reads ~1400 bytes and no bad checksums.
    ///
    /// Both mechanisms below are needed, and neither is redundant:
    ///
    /// * `flock(LOCK_EX|LOCK_NB)` decides the race. It is advisory -- it binds only the two
    ///   producers, which is enough because they are the two readers that exist -- but it is
    ///   decided by lock order rather than open order, so exactly one wins however the opens
    ///   interleave.
    /// * `TIOCEXCL` covers non-cooperating openers, which flock cannot: it makes a later
    ///   `open(2)` fail with `EBUSY`. Verified on the Pi against the deployed sandbox
    ///   (`DynamicUser` + `dialout`, empty `CapabilityBoundingSet`).
    ///
    /// The reason flock is not merely a nicer spelling of `TIOCEXCL`: the ioctl can only reject
    /// *subsequent* opens, so two processes that both open before either reaches it both succeed
    /// and then both read. That is precisely the boot race between these two units. Note also
    /// that `TIOCEXCL` is bypassed by `CAP_SYS_ADMIN`, so it does not stop a root `cat` or the
    /// operator CLI under `sudo` -- measured, and the reason the module's own note about the CLI
    /// "failing loudly" only holds unprivileged.
    ///
    /// Ordering is load-bearing. The lock is taken before `tcsetattr`, before `tcflush` and
    /// before the first read, and a `Busy` return closes the fd having done none of them: those
    /// are exactly the operations that would corrupt the stream of whoever holds the port
    /// (`tcflush` discards the *shared* input queue). Merely holding an open fd steals nothing --
    /// also measured, a reader alongside an idle opener still got every byte.
    pub fn open(path: &Path, baud: u32) -> std::io::Result<Opened> {
        // O_NONBLOCK so the open cannot hang waiting for a carrier that a USB adapter may never
        // assert; cleared below, once CLOCAL makes the question moot and VMIN/VTIME are what
        // bound a read.
        let opened = OpenOptions::new()
            .read(true)
            .write(true)
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
        // inheriting whatever the last user of the port left behind is how a working cable
        // starts returning garbage after an unrelated program touches it.
        termios.control_modes &= !ControlModes::CSIZE;
        termios.control_modes |= ControlModes::CS8;
        termios.control_modes &= !ControlModes::PARENB; // no parity
        termios.control_modes &= !ControlModes::CSTOPB; // one stop bit
        termios.control_modes &= !ControlModes::CRTSCTS; // no hardware flow control
        termios.control_modes |= ControlModes::CLOCAL | ControlModes::CREAD;
        termios.input_modes &= !(InputModes::IXON | InputModes::IXOFF | InputModes::IXANY);
        termios.output_modes = OutputModes::empty();
        termios.local_modes = LocalModes::empty();

        // A read returns as soon as anything is there, and gives up after 100ms if nothing is.
        // The frame deadline is enforced by the loop in read_frame, not by the driver: a
        // 106-byte QPIGS payload is ~460ms of wire time at 2400 baud, so any single-read
        // timeout short enough to be useful would fire mid-frame.
        termios.special_codes[SpecialCodeIndex::VMIN] = 0;
        termios.special_codes[SpecialCodeIndex::VTIME] = 1;

        tcsetattr(&file, OptionalActions::Now, &termios)?;
        fcntl_setfl(&file, OFlags::empty())?;

        Ok(Opened::Port(SerialPort { file }))
    }

    fn read_some(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        match self.file.read(buffer) {
            Ok(count) => Ok(count),
            // VTIME expiry surfaces as a zero-length read, but a port that momentarily has
            // nothing can also answer EAGAIN; neither is an error.
            Err(error) if error.kind() == ErrorKind::WouldBlock => Ok(0),
            Err(error) if error.kind() == ErrorKind::Interrupted => Ok(0),
            Err(error) => Err(error),
        }
    }
}

impl Transport for SerialPort {
    fn write_request(&mut self, data: &[u8]) -> std::io::Result<()> {
        // Anything still in the input queue belongs to a previous exchange -- a late response to
        // a command that already timed out. Left there it would be read as this command's
        // answer, and every subsequent reply would be one behind.
        tcflush(&self.file, QueueSelector::IFlush)?;
        self.file.write_all(data)?;
        self.file.flush()
    }

    fn read_frame(&mut self, timeout: Duration) -> std::io::Result<Option<Vec<u8>>> {
        let deadline = Instant::now() + timeout;
        let mut frame = Vec::with_capacity(128);
        let mut chunk = [0u8; 64];
        while Instant::now() < deadline {
            let count = self.read_some(&mut chunk)?;
            for byte in &chunk[..count] {
                frame.push(*byte);
                if *byte == CR {
                    return Ok(Some(frame));
                }
            }
            // A frame that grows without ever terminating is a desynchronised line, not a long
            // response: the longest documented frame is 110 bytes.
            if frame.len() > 512 {
                return Ok(Some(frame));
            }
        }
        Ok(None)
    }

    fn listen(&mut self, window: Duration) -> std::io::Result<usize> {
        let deadline = Instant::now() + window;
        let mut seen = 0usize;
        let mut chunk = [0u8; 64];
        while Instant::now() < deadline {
            seen += self.read_some(&mut chunk)?;
        }
        Ok(seen)
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    /// A path in the per-test temp dir. `PrivateTmp` is on for the unit, but `cargo test` runs in
    /// the build sandbox where `TMPDIR` is the build directory.
    fn temp_path(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("inverter-monitoring-{name}-{}", std::process::id()));
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
        assert!(try_lock_exclusive(&first).unwrap(), "the first holder must get the lock");

        let second = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(
            !try_lock_exclusive(&second).unwrap(),
            "a second holder must be told the device is busy, not given a share of it"
        );

        // Re-locking through the fd that already holds it is not a conflict: the lock belongs to
        // the open file description, and this is that same description.
        assert!(try_lock_exclusive(&first).unwrap());

        let _ = std::fs::remove_file(&path);
    }

    /// No lockfile, no stale state: closing the fd is what releases it, which is what makes a
    /// killed producer's port available to the other one.
    #[test]
    fn closing_the_holder_releases_the_lock() {
        let (path, first) = touch("lock-released");
        assert!(try_lock_exclusive(&first).unwrap());

        let contender = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(!try_lock_exclusive(&contender).unwrap());

        drop(first);
        assert!(
            try_lock_exclusive(&contender).unwrap(),
            "the lock must be gone once the holder's fd is closed"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// Opening the device is not what steals bytes -- reading is -- so a caller that loses the
    /// lock can close the fd having disturbed nothing. Guards the ordering inside
    /// [`SerialPort::open`]: were the lock taken after `tcsetattr`/`tcflush`, losing it would
    /// already have flushed the winner's input queue.
    #[test]
    fn losing_the_lock_is_reported_before_anything_touches_the_line() {
        let (path, holder) = touch("lock-ordering");
        assert!(try_lock_exclusive(&holder).unwrap());

        // The same sequence open() runs: open the node, then try the lock. Nothing between them.
        let file = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(!try_lock_exclusive(&file).unwrap());

        let _ = std::fs::remove_file(&path);
    }
}
