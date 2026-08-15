//! Listen on an iroh endpoint and forward each incoming bidi stream to a new
//! connection to a local unix socket. The receiving half of a UDS-over-iroh
//! tunnel; the ssh listener next door is the same thing over TCP.
//!
//! Usage: iroh-uds-listen <socket-path>
//! The secret key is read from $CREDENTIALS_DIRECTORY/iroh-secret (set by
//! systemd via LoadCredentialEncrypted) or the IROH_SECRET env var.
//!
//! This authenticates nobody: anyone holding the endpoint id can open the pipe,
//! exactly as with the ssh listener. What sits behind the socket does the
//! authenticating -- sshd there, the monitoring platform's API key here.
use std::path::PathBuf;

use iroh::endpoint::Accepting;
use iroh_ssh::{
    create_endpoint, forward_bidi, load_secret, short_ticket, ALPN, HANDSHAKE, ONLINE_TIMEOUT,
};
use iroh_tickets::endpoint::EndpointTicket;
use n0_error::{bail_any, ensure_any, Result, StdResultExt};
use tokio::{select, time::timeout};

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
    let endpoint = create_endpoint(secret_key, vec![ALPN.to_vec()]).await?;
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

    loop {
        let incoming = select! {
            incoming = endpoint.accept() => incoming,
            _ = tokio::signal::ctrl_c() => {
                eprintln!("got ctrl-c, exiting");
                break;
            }
        };
        let Some(incoming) = incoming else {
            break;
        };
        let Ok(accepting) = incoming.accept() else {
            break;
        };
        let socket_path = socket_path.clone();
        tokio::spawn(async move {
            if let Err(cause) = handle_accept(accepting, socket_path).await {
                eprintln!("error handling connection: {cause}");
            }
        });
    }
    Ok(())
}

async fn handle_accept(accepting: Accepting, socket_path: PathBuf) -> Result<()> {
    let connection = accepting.await.std_context("error accepting connection")?;
    let (s, mut r) = connection
        .accept_bi()
        .await
        .std_context("error accepting stream")?;
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
    forward_bidi(read, write, r, s).await
}
