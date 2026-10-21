//! Listen on a local unix socket and forward each accepted connection, as a
//! stream of its own, over one iroh connection to the endpoint named by a
//! ticket. The dialing half of a UDS-over-iroh tunnel: whatever connects here
//! reaches the socket `iroh-uds-listen` fronts on the far side, and needs to
//! know nothing about iroh.
//!
//! One QUIC connection per process, and the process is the reconnect loop: it
//! dials once, binds the local socket only once that dial has succeeded, and
//! exits the moment the connection closes, for whatever reason. Restarting it
//! is the service manager's job, which hands every attempt a fresh endpoint --
//! nothing that went wrong inside the last one can outlive it. Dialing per local
//! connection instead had this hold one iroh endpoint for days while cycling a
//! connection a minute through it, and on 2026-10-11 that endpoint wedged: every
//! dial from 04:50 on timed out without sending a packet, while a fresh process
//! dialing the same ticket got straight through.
//!
//! Under systemd (`Type=notify`) the unit is active exactly while the connection
//! is up and the socket is bound, and the socket's existence says the same thing
//! to its clients: with the far side unreachable they are refused at once rather
//! than left waiting on a dial.
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

use iroh::endpoint::Connection;
use iroh_ssh::{
    closed_normally, create_dialer_endpoint, forward_bidi, load_ticket, notify, shutdown_signal,
    ALPN, HANDSHAKE, ONLINE_TIMEOUT,
};
use n0_error::{bail_any, Result, StdResultExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::{pin, select, time::timeout};

/// How long the one dial may take before this process gives up and exits.
///
/// Bounds how long the unit sits in `activating` against a far side that is not
/// answering. Giving up is cheap -- the service manager starts a fresh attempt
/// after its restart delay -- so this only needs to be comfortably longer than a
/// dial that is merely slow: discovery plus a relayed handshake.
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
    let remote = addr.id;

    let endpoint = create_dialer_endpoint().await?;
    // As dumbpipe does before it dials: until the home relay is known, a far side
    // reachable only through a relay has nowhere for the handshake to go. Bounded,
    // because a direct path may well work without one.
    if timeout(ONLINE_TIMEOUT, endpoint.online()).await.is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }
    let connection = match timeout(DIAL_TIMEOUT, endpoint.connect(addr, ALPN)).await {
        Ok(Ok(connection)) => connection,
        Ok(Err(cause)) => bail_any!("error connecting to {remote}: {cause}"),
        Err(_) => bail_any!("dial to {remote} timed out after {DIAL_TIMEOUT:?}"),
    };

    let listener = bind(&socket_path).await?;
    eprintln!(
        "Connected to {remote}; forwarding connections on '{}'.",
        socket_path.display()
    );
    // READY: the connection is up and the socket bound, which is what `active`
    // promises. RESTART_RESET: this attempt worked, so the restart backoff starts
    // over -- the next outage begins at RestartSec rather than wherever the last
    // one left the delay. Not fatal if it fails: the tunnel works either way.
    if let Err(cause) = notify("READY=1\nRESTART_RESET=1") {
        eprintln!("Warning: failed to notify the service manager: {cause}");
    }

    let closed = connection.closed();
    pin!(closed);
    let shutdown = shutdown_signal();
    pin!(shutdown);
    loop {
        let accepted = select! {
            accepted = listener.accept() => accepted,
            // Fatal by design: see the module comment. The reason goes in the
            // message because it is what tells a far side that went away
            // ("closed by peer") from a path that died ("timed out").
            reason = &mut closed => bail_any!("connection to {remote} closed: {reason}"),
            _ = &mut shutdown => break,
        };
        // Deliberately fatal rather than logged-and-retried: a listener that has
        // stopped accepting does not recover by being asked again, and spinning
        // on the error would burn a core to hide it. Exiting hands the problem
        // to the service manager, which restarts on a delay.
        let (uds, _) = accepted.std_context("error accepting a local connection")?;

        // Cheap: Connection is a handle, so every stream rides the one
        // connection rather than dialing its own.
        let connection = connection.clone();
        tokio::spawn(async move {
            // The local connection is dropped with this task, which is what tells
            // the client to stop waiting -- a socket held open after a failed
            // stream reads as a healthy peer that has simply gone quiet.
            if let Err(cause) = handle_accept(uds, connection.clone()).await {
                // Not when the connection ended normally under it: the accept loop
                // reports that once, rather than once per client it cut off.
                if !connection.close_reason().is_some_and(|reason| closed_normally(&reason)) {
                    eprintln!("error handling connection: {cause}");
                }
            }
        });
    }
    // Stopped on purpose, so say so: without the CONNECTION_CLOSE this sends, the
    // listener would only find out at its idle timeout, and would log that as an
    // error.
    endpoint.close().await;
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

async fn handle_accept(uds: UnixStream, connection: Connection) -> Result<()> {
    // Fails only once the connection itself has, which the accept loop is about
    // to act on too; this just releases the local client promptly.
    let (mut s, r) = connection.open_bi().await.anyerr()?;
    // the connecting side must write first
    s.write_all(&HANDSHAKE).await.anyerr()?;
    let (read, write) = uds.into_split();
    forward_bidi(read, write, r, s).await
}
