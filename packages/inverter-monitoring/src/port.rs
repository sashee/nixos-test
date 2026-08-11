//! The serial line. The only module that talks to the outside world on the device side, which
//! is what lets everything above it be tested without hardware.

use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use rustix::fs::{fcntl_setfl, OFlags};
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

pub struct SerialPort {
    file: File,
}

impl SerialPort {
    /// Open and configure one port: 2400 8N1, no parity, no flow control, raw.
    ///
    /// `TIOCEXCL` is set before anything is written. Two readers on one inverter port produce
    /// interleaved half-frames that both sides then blame on line noise, and on this host the
    /// other plausible reader -- whatever eventually talks to the BMS -- would be probing the
    /// same `/dev/ttyUSB*` set.
    pub fn open(path: &Path, baud: u32) -> std::io::Result<SerialPort> {
        // O_NONBLOCK so the open cannot hang waiting for a carrier that a USB adapter may never
        // assert; cleared below, once CLOCAL makes the question moot and VMIN/VTIME are what
        // bound a read.
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags((OFlags::NOCTTY | OFlags::NONBLOCK).bits() as i32)
            .open(path)?;

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

        Ok(SerialPort { file })
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
