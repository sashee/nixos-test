//! Connect to a listener and forward stdin/stdout to a bidi stream, for use as
//! an ssh ProxyCommand:
//!
//!   ssh -o ProxyCommand='iroh-ssh-connect <ticket>' user@host
use std::str::FromStr;

use iroh::SecretKey;
use iroh_ssh::{create_endpoint, forward_bidi, ALPN, HANDSHAKE};
use iroh_tickets::endpoint::EndpointTicket;
use n0_error::{bail_any, Result, StdResultExt};
use tokio::io::AsyncWriteExt;

fn main() -> ! {
    iroh_ssh::run(connect())
}

async fn connect() -> Result<()> {
    let ticket = match std::env::args().nth(1) {
        Some(t) => EndpointTicket::from_str(&t).std_context("invalid ticket")?,
        None => bail_any!("usage: iroh-ssh-connect <ticket>"),
    };

    // the connecting side needs no stable identity
    let endpoint = create_endpoint(SecretKey::generate(), vec![]).await?;
    let addr = ticket.endpoint_addr().clone();
    let connection = endpoint.connect(addr, ALPN).await.anyerr()?;
    let (mut s, r) = connection.open_bi().await.anyerr()?;
    // the connecting side must write first
    s.write_all(&HANDSHAKE).await.anyerr()?;
    forward_bidi(tokio::io::stdin(), tokio::io::stdout(), r, s).await?;
    tokio::io::stdout().flush().await.anyerr()?;
    // The listener now waits for this side to close, and `run` exits the process the moment we
    // return -- before the endpoint has sent the CONNECTION_CLOSE a dropped connection only
    // queues. Without this the listener's connection would sit until the idle timeout. Quick
    // normally; iroh bounds it at ~3s on a bad link.
    endpoint.close().await;
    Ok(())
}
