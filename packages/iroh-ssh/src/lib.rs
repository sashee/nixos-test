//! Shared machinery for the iroh-ssh binaries: a minimal SSH-over-iroh pipe.
//!
//! Wire-compatible with dumbpipe (same ALPN and handshake), so a stock
//! `dumbpipe connect <ticket>` also works against the listener. Adapted from
//! dumbpipe 0.39 (MIT OR Apache-2.0, n0-computer/dumbpipe), reduced to this
//! use case with two changes: the key is read from a file (a systemd
//! credential) rather than only the environment, and relay TLS is verified
//! against the operating system trust store instead of dumbpipe's compiled-in
//! Mozilla roots. The latter lets the hermetic VM test impersonate the n0 relay
//! hostnames with its own CA (and lets hosts trust self-hosted relays).
use std::{io, path::PathBuf, str::FromStr, time::Duration};

use iroh::{endpoint::presets, tls::CaTlsConfig, Endpoint, EndpointAddr, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use n0_error::{bail_any, Result, StdResultExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_util::sync::CancellationToken;

/// The dumbpipe ALPN, for wire compatibility with stock dumbpipe clients.
pub const ALPN: &[u8] = b"DUMBPIPEV0";

/// The handshake the connecting side sends after open_bi, consumed by the
/// accepting side (same convention as dumbpipe).
pub const HANDSHAKE: [u8; 5] = *b"hello";

/// How long to wait for the home relay before printing the ticket anyway.
pub const ONLINE_TIMEOUT: Duration = Duration::from_secs(5);

/// The credential filename the listener reads under `$CREDENTIALS_DIRECTORY`.
const SECRET_FILE: &str = "iroh-secret";

fn parse_secret(hex: &str) -> Result<SecretKey> {
    SecretKey::from_str(hex.trim()).std_context("invalid secret key")
}

/// Load the iroh secret key, trying in order: an explicit file path, the
/// systemd-exported `$CREDENTIALS_DIRECTORY/iroh-secret` (how the service gets
/// it), then the `IROH_SECRET` environment variable (manual runs).
pub fn load_secret(explicit: Option<PathBuf>) -> Result<SecretKey> {
    if let Some(path) = explicit {
        let hex = std::fs::read_to_string(&path)
            .with_std_context(|_| format!("failed to read secret file {}", path.display()))?;
        return parse_secret(&hex);
    }
    if let Ok(dir) = std::env::var("CREDENTIALS_DIRECTORY") {
        let path = PathBuf::from(dir).join(SECRET_FILE);
        let hex = std::fs::read_to_string(&path)
            .with_std_context(|_| format!("failed to read credential {}", path.display()))?;
        return parse_secret(&hex);
    }
    match std::env::var("IROH_SECRET") {
        Ok(hex) => parse_secret(&hex),
        Err(_) => bail_any!("no secret key: set $CREDENTIALS_DIRECTORY, pass a key file, or set IROH_SECRET"),
    }
}

/// Create an iroh endpoint that verifies relay TLS against the OS trust store
/// (`rustls-platform-verifier`) rather than compiled-in Mozilla roots, so
/// `security.pki`-installed CAs are honored.
pub async fn create_endpoint(secret_key: SecretKey, alpns: Vec<Vec<u8>>) -> Result<Endpoint> {
    Endpoint::builder(presets::N0)
        .ca_tls_config(CaTlsConfig::system())
        .secret_key(secret_key)
        .alpns(alpns)
        .bind()
        .await
        .anyerr()
}

/// A ticket that only includes the endpoint id and relay urls, which stays
/// valid across network changes.
pub fn short_ticket(addr: &EndpointAddr) -> EndpointTicket {
    let mut short = EndpointAddr::new(addr.id);
    for relay_url in addr.relay_urls() {
        short = short.with_relay_url(relay_url.clone());
    }
    short.into()
}

/// Copy from a reader to a noq send stream, resetting it on cancellation.
async fn copy_to_stream(
    mut from: impl AsyncRead + Unpin,
    mut send: noq::SendStream,
    token: CancellationToken,
) -> io::Result<u64> {
    tokio::select! {
        res = tokio::io::copy(&mut from, &mut send) => {
            let size = res?;
            send.finish()?;
            Ok(size)
        }
        _ = token.cancelled() => {
            send.reset(0u8.into()).ok();
            Err(io::Error::other("cancelled"))
        }
    }
}

/// Copy from a noq recv stream to a writer, stopping it on cancellation.
async fn copy_from_stream(
    mut recv: noq::RecvStream,
    mut to: impl AsyncWrite + Unpin,
    token: CancellationToken,
) -> io::Result<u64> {
    tokio::select! {
        res = tokio::io::copy(&mut recv, &mut to) => Ok(res?),
        _ = token.cancelled() => {
            recv.stop(0u8.into()).ok();
            Err(io::Error::other("cancelled"))
        }
    }
}

fn cancel_token<T>(token: CancellationToken) -> impl Fn(T) -> T {
    move |x| {
        token.cancel();
        x
    }
}

/// Forward bidirectionally between a reader/writer pair and a bidi stream,
/// aborting both directions when either finishes or on ctrl-c.
pub async fn forward_bidi(
    from1: impl AsyncRead + Send + Sync + Unpin + 'static,
    to1: impl AsyncWrite + Send + Sync + Unpin + 'static,
    from2: noq::RecvStream,
    to2: noq::SendStream,
) -> Result<()> {
    let token1 = CancellationToken::new();
    let token2 = token1.clone();
    let token3 = token1.clone();
    let forward_out = tokio::spawn(async move {
        copy_to_stream(from1, to2, token1.clone())
            .await
            .map_err(cancel_token(token1))
    });
    let forward_in = tokio::spawn(async move {
        copy_from_stream(from2, to1, token2.clone())
            .await
            .map_err(cancel_token(token2))
    });
    let _control_c = tokio::spawn(async move {
        tokio::signal::ctrl_c().await?;
        token3.cancel();
        io::Result::Ok(())
    });
    forward_in.await.anyerr()?.anyerr()?;
    forward_out.await.anyerr()?.anyerr()?;
    Ok(())
}

/// Run `f`, printing its error to stderr and exiting non-zero on failure.
/// Shared entry point for the binaries so each `main` stays tiny.
pub fn run(f: impl std::future::Future<Output = Result<()>>) -> ! {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    match rt.block_on(f) {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1)
        }
    }
}
