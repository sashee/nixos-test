//! Listen on an iroh endpoint and forward each incoming bidi stream to a new
//! TCP connection to the target (default 127.0.0.1:22, i.e. the local sshd).
//!
//! Usage: iroh-ssh-listen [host:port]
//! The secret key is read from $CREDENTIALS_DIRECTORY/iroh-secret (set by
//! systemd via LoadCredentialEncrypted) or the IROH_SECRET env var.
use std::net::{SocketAddr, ToSocketAddrs};

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
    let host = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:22".into());
    let addrs = match host.to_socket_addrs() {
        Ok(addrs) => addrs.collect::<Vec<_>>(),
        Err(e) => bail_any!("invalid host string {}: {}", host, e),
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
    eprintln!("Forwarding incoming requests to '{host}'.");
    eprintln!("To connect, use e.g.:");
    eprintln!("iroh-ssh-connect {ticket}");
    eprintln!("or:\niroh-ssh-connect {short}");

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
        let addrs = addrs.clone();
        tokio::spawn(async move {
            if let Err(cause) = handle_accept(accepting, addrs).await {
                eprintln!("error handling connection: {cause}");
            }
        });
    }
    Ok(())
}

async fn handle_accept(accepting: Accepting, addrs: Vec<SocketAddr>) -> Result<()> {
    let connection = accepting.await.std_context("error accepting connection")?;
    let (s, mut r) = connection
        .accept_bi()
        .await
        .std_context("error accepting stream")?;
    let mut buf = [0u8; HANDSHAKE.len()];
    r.read_exact(&mut buf).await.anyerr()?;
    ensure_any!(buf == HANDSHAKE, "invalid handshake");
    let tcp = tokio::net::TcpStream::connect(addrs.as_slice())
        .await
        .std_context(format!("error connecting to {addrs:?}"))?;
    let (read, write) = tcp.into_split();
    forward_bidi(read, write, r, s).await
}
