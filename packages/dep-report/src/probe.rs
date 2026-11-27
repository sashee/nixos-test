//! `--probe-sandbox`: apply both stages exactly as a real run does, then try what each stage must
//! refuse and a few things it must still allow. A sandbox's configuration says what was meant;
//! only these attempts show what the kernel actually enforces.
//!
//! Listeners are opened before any restriction, so a refused connection to one can only be the
//! sandbox (there is something listening), never an empty port.

use std::fs::{self, File};
use std::io;
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::os::linux::net::SocketAddrExt;
use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};
use std::process::Command;

use landlock::RulesetStatus;

use crate::sandbox::{self, Layout, errno_name};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Expect {
    Denied,
    Allowed,
    /// A connection that may be made: success, or refused because nothing listens there.
    Reachable,
}

struct Check {
    name: String,
    expect: Expect,
    outcome: Result<(), io::Error>,
}

impl Check {
    fn passed(&self) -> bool {
        let errno = self.outcome.as_ref().err().and_then(io::Error::raw_os_error);
        match self.expect {
            Expect::Denied => matches!(errno, Some(libc::EACCES | libc::EPERM | libc::EROFS)),
            Expect::Allowed => self.outcome.is_ok(),
            Expect::Reachable => self.outcome.is_ok() || errno == Some(libc::ECONNREFUSED),
        }
    }

    fn line(&self) -> String {
        let want = match self.expect {
            Expect::Denied => "must be denied",
            Expect::Allowed => "must be allowed",
            Expect::Reachable => "must be reachable",
        };
        let got = match &self.outcome {
            Ok(()) => "allowed".to_string(),
            Err(e) => errno_name(e),
        };
        format!("{}  {:<58} {:<18} {}", if self.passed() { "ok  " } else { "FAIL" }, self.name, want, got)
    }
}

fn check<T>(name: &str, expect: Expect, outcome: io::Result<T>) -> Check {
    Check { name: name.to_string(), expect, outcome: outcome.map(|_| ()) }
}

fn ran(cmd: &mut Command) -> io::Result<()> {
    cmd.output().map(|_| ())
}

pub fn run(layout: &Layout) -> Result<bool, String> {
    let io = |e: io::Error| format!("probe setup: {e}");
    let tcp = TcpListener::bind("127.0.0.1:0").map_err(io)?;
    let tcp_port = tcp.local_addr().map_err(io)?.port();
    let udp = UdpSocket::bind("127.0.0.1:0").map_err(io)?;
    let udp_port = udp.local_addr().map_err(io)?.port();
    let socket_path = layout.tmp().join(format!("probe-{}.sock", std::process::id()));
    let _ = fs::remove_file(&socket_path);
    let _unix = UnixListener::bind(&socket_path).map_err(io)?;
    let abstract_addr = SocketAddr::from_abstract_name(format!("dep-report-probe-{}", std::process::id())).map_err(io)?;
    let _abstract = UnixListener::bind_addr(&abstract_addr).map_err(io)?;
    let udp_send = || UdpSocket::bind("127.0.0.1:0").and_then(|s| s.send_to(b"probe", ("127.0.0.1", udp_port)));

    let one = sandbox::enforce(&sandbox::stage_one(layout))?;
    sandbox::seccomp_stage_one()?;
    println!("stage 1 landlock: {}", sandbox::describe(&one));
    let full = one == RulesetStatus::FullyEnforced;
    let mut checks = vec![
        check("stage 1: run nix", Expect::Allowed, ran(Command::new(&layout.nix).arg("--version"))),
        check("stage 1: list the checkout", Expect::Allowed, fs::read_dir(&layout.checkout)),
        check("stage 1: open /dev/zero (not on the allowlist)", Expect::Denied, File::open("/dev/zero")),
        check("stage 1: create a file in the checkout", Expect::Denied, File::create(layout.checkout.join(".dep-report-probe"))),
        check("stage 1: TCP to a listening local port other than 443/53", Expect::Denied, TcpStream::connect(("127.0.0.1", tcp_port))),
        check("stage 1: TCP to port 443", Expect::Reachable, TcpStream::connect("127.0.0.1:443")),
        check("stage 1: connect to a listening abstract unix socket", Expect::Denied, UnixStream::connect_addr(&abstract_addr)),
    ];
    if full {
        checks.push(check("stage 1: connect to a listening unix socket in the cache", Expect::Denied, UnixStream::connect(&socket_path)));
        checks.push(check("stage 1: UDP to a port other than 53", Expect::Denied, udp_send()));
    }

    let two = sandbox::enforce(&sandbox::stage_two(layout))?;
    sandbox::seccomp_stage_two()?;
    println!("stage 2 landlock: {}", sandbox::describe(&two));
    let probe_file = layout.output_dir().join(".dep-report-probe");
    checks.extend([
        check("stage 2: run nix", Expect::Denied, ran(Command::new(&layout.nix).arg("--version"))),
        check("stage 2: list the checkout", Expect::Denied, fs::read_dir(&layout.checkout)),
        check("stage 2: list Nix's HOME in the cache", Expect::Denied, fs::read_dir(layout.home())),
        check("stage 2: write the output directory", Expect::Allowed, fs::write(&probe_file, "").and_then(|()| fs::remove_file(&probe_file))),
        check("stage 2: TCP to a listening local port other than 443/53", Expect::Denied, TcpStream::connect(("127.0.0.1", tcp_port))),
        check("stage 2: TCP to port 443", Expect::Reachable, TcpStream::connect("127.0.0.1:443")),
        check("stage 2: connect to a listening unix socket in the cache", Expect::Denied, UnixStream::connect(&socket_path)),
        check("stage 2: connect to a listening abstract unix socket", Expect::Denied, UnixStream::connect_addr(&abstract_addr)),
    ]);
    if full {
        checks.push(check("stage 2: UDP to a port other than 53", Expect::Denied, udp_send()));
    }
    for c in &checks {
        println!("{}", c.line());
    }
    Ok(checks.iter().all(Check::passed))
}
