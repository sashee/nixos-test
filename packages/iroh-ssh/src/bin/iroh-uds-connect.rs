//! Listen on a local unix socket and forward each accepted connection over iroh
//! to the endpoint named by a ticket. The dialing half of a UDS-over-iroh
//! tunnel: whatever connects here reaches the socket `iroh-uds-listen` fronts on
//! the far side, and needs to know nothing about iroh.
//!
//! Usage: iroh-uds-connect <socket-path> [ticket]
//! The ticket is read from $CREDENTIALS_DIRECTORY/iroh-ticket (set by systemd
//! via LoadCredentialEncrypted) or the IROH_TICKET env var. Unlike the
//! listener's secret it is not itself a secret -- it is an address -- so an
//! explicit one on the command line is fine, and is how an operator dials by hand.
use std::io::ErrorKind;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use iroh::{Endpoint, EndpointAddr, SecretKey};
use iroh_ssh::{create_endpoint, forward_bidi, load_ticket, ALPN, HANDSHAKE};
use n0_error::{bail_any, Result, StdResultExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::select;

/// How long one dial may take before the connection is given up on.
///
/// Not the user-visible bound: whatever is talking to the local socket has its
/// own timeout and, having started its clock first, always gives up before this
/// does (mp-collector's is 30s, covering connect and exchange together). This is
/// a leak guard, so that a far side which is unreachable for hours cannot
/// accumulate one stuck task per reconnect attempt.
const DIAL_TIMEOUT: Duration = Duration::from_secs(30);

fn main() -> ! {
    iroh_ssh::run(connect())
}

async fn connect() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let Some(socket_path) = args.next().map(PathBuf::from) else {
        bail_any!("usage: iroh-uds-connect <socket-path> [ticket]");
    };
    let addr = load_ticket(args.next())?.endpoint_addr().clone();

    // the connecting side needs no stable identity
    let endpoint = create_endpoint(SecretKey::generate(), vec![]).await?;

    let listener = bind(&socket_path).await?;
    eprintln!(
        "Forwarding connections on '{}' to {}.",
        socket_path.display(),
        addr.id
    );

    loop {
        let accepted = select! {
            accepted = listener.accept() => accepted,
            _ = tokio::signal::ctrl_c() => {
                eprintln!("got ctrl-c, exiting");
                break;
            }
        };
        // Deliberately fatal rather than logged-and-retried: a listener that has
        // stopped accepting does not recover by being asked again, and spinning
        // on the error would burn a core to hide it. Exiting hands the problem
        // to the service manager, which restarts on a delay.
        let (uds, _) = accepted.std_context("error accepting a local connection")?;

        // Cheap: Endpoint is an Arc handle, so every connection dials through
        // the one bound socket rather than binding its own.
        let endpoint = endpoint.clone();
        let addr = addr.clone();
        tokio::spawn(async move {
            if let Err(cause) = handle_accept(uds, endpoint, addr).await {
                // The local connection is dropped with this task, which is what
                // tells the client to stop waiting and reconnect -- a socket
                // held open after a failed dial reads as a healthy peer that
                // has simply gone quiet.
                eprintln!("error handling connection: {cause}");
            }
        });
    }
    Ok(())
}

/// Bind the local socket, clearing a leftover inode from a previous run.
///
/// A unix socket's file outlives the process that bound it, so an address
/// already in use here is more often our own corpse -- a crash, a kill -9, a
/// directory the service manager did not clean up -- than a live peer. The two
/// are told apart by connecting to it: a refused connect means nothing is
/// listening and the file is safe to remove, while a successful one means a
/// second instance really is running and this one must not steal its socket.
async fn bind(path: &Path) -> Result<UnixListener> {
    match UnixListener::bind(path) {
        Err(e) if e.kind() == ErrorKind::AddrInUse => {
            if UnixStream::connect(path).await.is_ok() {
                bail_any!("{} is already served by a running instance", path.display());
            }
            std::fs::remove_file(path)
                .with_std_context(|_| format!("failed to clear stale socket {}", path.display()))?;
            finish_bind(UnixListener::bind(path), path)
        }
        result => finish_bind(result, path),
    }
}

fn finish_bind(result: std::io::Result<UnixListener>, path: &Path) -> Result<UnixListener> {
    let listener =
        result.with_std_context(|_| format!("failed to bind {}", path.display()))?;
    // Defence in depth only. Between bind() and here the socket carries
    // 0777 & ~umask, so real access control is the containing directory's mode
    // -- the same reasoning as the monitoring platform's own socket.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660))
        .with_std_context(|_| format!("failed to set the mode of {}", path.display()))?;
    Ok(listener)
}

async fn handle_accept(uds: UnixStream, endpoint: Endpoint, addr: EndpointAddr) -> Result<()> {
    // One dial per accepted connection, with no connection kept between them.
    // What talks to this socket holds its own connection open across requests
    // (mp-collector keeps one HTTP/1.1 connection across flushes), so a dial is
    // rare enough that caching one would buy a reconnect state machine and
    // little else.
    let connection = match tokio::time::timeout(DIAL_TIMEOUT, endpoint.connect(addr, ALPN)).await {
        Ok(result) => result.anyerr()?,
        Err(_) => bail_any!("dial timed out after {:?}", DIAL_TIMEOUT),
    };
    let (mut s, r) = connection.open_bi().await.anyerr()?;
    // the connecting side must write first
    s.write_all(&HANDSHAKE).await.anyerr()?;
    let (read, write) = uds.into_split();
    forward_bidi(read, write, r, s).await
}
