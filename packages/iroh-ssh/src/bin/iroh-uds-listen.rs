//! Listen on an iroh endpoint and forward each incoming bidi stream to a new
//! connection to a local unix socket. The receiving half of a UDS-over-iroh
//! tunnel; the ssh listener next door is the same thing over TCP.
//!
//! Every stream a connection carries is served, not just its first: the dialing
//! half keeps one connection up and opens a stream per local client. A dialer
//! that opens a connection per stream instead -- stock dumbpipe, or
//! iroh-ssh-connect -- is the one-stream case of the same thing.
//!
//! Usage: iroh-uds-listen <socket-path>
//! The secret key is read from $CREDENTIALS_DIRECTORY/iroh-secret (set by
//! systemd via LoadCredentialEncrypted) or the IROH_SECRET env var.
//!
//! This authenticates nobody: anyone holding the endpoint id can open the pipe,
//! exactly as with the ssh listener. What sits behind the socket does the
//! authenticating -- sshd there, the monitoring platform's API key here.
use std::path::PathBuf;

use iroh::endpoint::{Accepting, RecvStream, SendStream};
use iroh_ssh::{
    closed_normally, create_listener_endpoint, forward_bidi, load_secret, short_ticket,
    shutdown_signal, ALPN, HANDSHAKE, ONLINE_TIMEOUT,
};
use iroh_tickets::endpoint::EndpointTicket;
use n0_error::{bail_any, ensure_any, Result, StdResultExt};
use tokio::{pin, select, time::timeout};

fn main() -> ! {
    iroh_ssh::run(listen())
}

async fn listen() -> Result<()> {
    // No default: unlike sshd's port 22 there is no conventional path for the
    // far side, so guessing one would only turn a misconfiguration into a
    // tunnel that silently forwards nowhere.
    let Some(socket_path) = std::env::args().nth(1).map(PathBuf::from) else {
        bail_any!("usage: iroh-uds-listen <socket-path>");
    };

    let secret_key = load_secret(None)?;
    let endpoint = create_listener_endpoint(secret_key, vec![ALPN.to_vec()]).await?;
    // wait for the endpoint to figure out its addresses before making a ticket
    if (timeout(ONLINE_TIMEOUT, endpoint.online()).await).is_err() {
        eprintln!("Warning: Failed to connect to the home relay");
    }
    let addr = endpoint.addr();
    let short = short_ticket(&addr);
    let ticket = EndpointTicket::new(addr);

    // tickets go to stderr so they don't interfere with any data on stdout
    eprintln!("Forwarding incoming requests to '{}'.", socket_path.display());
    eprintln!("To connect, use e.g.:");
    eprintln!("iroh-uds-connect <local-socket> {ticket}");
    eprintln!("or:\niroh-uds-connect <local-socket> {short}");

    let shutdown = shutdown_signal();
    pin!(shutdown);
    loop {
        let incoming = select! {
            incoming = endpoint.accept() => incoming,
            _ = &mut shutdown => break,
        };
        let Some(incoming) = incoming else {
            break;
        };
        let Ok(accepting) = incoming.accept() else {
            break;
        };
        let socket_path = socket_path.clone();
        tokio::spawn(async move {
            if let Err(cause) = handle_connection(accepting, socket_path).await {
                eprintln!("{cause}");
            }
        });
    }
    // Close every connection with a CONNECTION_CLOSE on the way out. A dialer
    // exits when its connection does, so this is what turns a restart here into
    // an immediate reconnect there rather than one an idle timeout later.
    endpoint.close().await;
    Ok(())
}

/// Serve every stream one connection carries, until it closes.
async fn handle_connection(accepting: Accepting, socket_path: PathBuf) -> Result<()> {
    let connection = accepting.await.std_context("error accepting connection")?;
    let remote = connection.remote_id();
    // Once per connection, which with a dialer that keeps one up is once per
    // dialer start: rare enough to log, and what shows a dialer reconnecting.
    eprintln!("Accepted connection from {remote}.");
    loop {
        let (s, r) = match connection.accept_bi().await {
            Ok(streams) => streams,
            // How a connection is meant to end: the dialer closed it, stopping or
            // restarting, or this side is shutting down. Nothing to report.
            Err(reason) if closed_normally(&reason) => return Ok(()),
            // Anything else ended it without a goodbye -- typically the idle
            // timeout after the dialer vanished.
            Err(cause) => bail_any!("connection from {remote} lost: {cause}"),
        };
        let socket_path = socket_path.clone();
        let connection = connection.clone();
        tokio::spawn(async move {
            if let Err(cause) = handle_stream(s, r, socket_path).await {
                // A stream cut short by its connection ending normally -- the
                // collector's kept HTTP connection, whenever its dialer restarts --
                // is that ending, which the loop above already deals with, and not
                // a failure of the stream.
                if !connection.close_reason().is_some_and(|reason| closed_normally(&reason)) {
                    eprintln!("error handling connection: {cause}");
                }
            }
        });
    }
}

/// Forward one stream to a fresh connection to the local socket.
async fn handle_stream(s: SendStream, mut r: RecvStream, socket_path: PathBuf) -> Result<()> {
    let mut buf = [0u8; HANDSHAKE.len()];
    r.read_exact(&mut buf).await.anyerr()?;
    ensure_any!(buf == HANDSHAKE, "invalid handshake");
    // Connected per stream rather than once at startup, so the far side may come
    // and go underneath us: nothing here is ordered against the service behind
    // the socket, and a restart of it costs the streams in flight, not the tunnel.
    let uds = tokio::net::UnixStream::connect(&socket_path)
        .await
        .std_context(format!("error connecting to {}", socket_path.display()))?;
    let (read, write) = uds.into_split();
    // Returning does not close anything beyond this stream: the connection stays
    // up for the next one, so our end of the stream is delivered after we drop
    // it. (Closing the connection per request instead is what used to lose that
    // end, failing the dialer's last read with "connection lost".)
    forward_bidi(read, write, r, s).await
}
