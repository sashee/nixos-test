//! Certificate verification at an instant we choose, twice.
//!
//! The bootstrap problem: this program runs when the clock may be years wrong, so a normal
//! TLS handshake fails on `notBefore`/`notAfter` before it can get far enough to be told the
//! time. But simply not checking the dates would accept a chain from anyone holding any
//! once-valid certificate.
//!
//! So the check is deferred rather than dropped:
//!
//!   pass 1, during the handshake -- verify at an instant taken from the chain's own
//!     intersected validity window. Time is neutralised by construction (an instant inside
//!     every certificate's window cannot fail a date check), so the handshake can only fail
//!     on signatures, chain-to-a-trusted-root, or hostname. There is no fixed instant that
//!     would do: the build floor precedes a freshly issued certificate's notBefore, the epoch
//!     precedes every notBefore, and a far-future value follows every notAfter.
//!
//!   pass 2, after the response is read -- verify the same chain again, through the same
//!     verifier, at the time the exchange reported. This is the real check, and it is what
//!     makes an authenticated timestamp outside the chain's validity a hard failure.
//!
//! Both passes run the identical `WebPkiServerVerifier`, so pass 2 cannot accidentally be
//! weaker than pass 1 -- and hostname and chain validation stay inside the library rather than
//! being reimplemented here, which is the failure mode a hand-rolled "ignore the dates"
//! verifier invites.
//!
//! Pass 1 also records the chain it saw. The HTTP client owns the connection and does not hand
//! the peer certificates back, so capturing them in the verifier is the only place they are
//! available -- and it is the right place regardless, because it is the chain that was actually
//! used rather than one re-fetched afterwards.
//!
//! Revocation is deliberately not checked. CRL and OCSP freshness are themselves
//! time-dependent, and fetching either needs another TLS connection with the same bad clock.
//! What bounds the resulting exposure is the build-time floor, applied in `main::ask_pair` to
//! each provider's own reported timestamp BEFORE that timestamp re-verifies any chain here --
//! so a revoked-but-once-valid certificate can only be replayed within its own validity and
//! above the floor. Not in `quorum::decide`: the agreed time is checked nowhere, because every
//! input to the agreement was already checked (see the note there).

use std::sync::{Arc, Mutex};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::WebPkiServerVerifier;
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, Error, RootCertStore, SignatureScheme};
use std::time::Duration;
use x509_parser::prelude::FromDer;
use x509_parser::certificate::X509Certificate;

/// The validity window of a single DER certificate, as Unix seconds.
fn window_of(der: &CertificateDer<'_>) -> Result<(i64, i64), String> {
    let (_, cert) = X509Certificate::from_der(der.as_ref())
        .map_err(|e| format!("unparseable certificate: {e}"))?;
    Ok((
        cert.validity().not_before.timestamp(),
        cert.validity().not_after.timestamp(),
    ))
}

/// The instants at which every window is simultaneously open.
///
/// `None` when the intersection is empty. That is not an edge case to paper over: a chain
/// whose leaf begins after an intermediate has expired is internally inconsistent, no instant
/// satisfies it, and verifying it at any time we invent would be verifying a lie.
pub fn intersect(windows: &[(i64, i64)]) -> Option<(i64, i64)> {
    let mut start = i64::MIN;
    let mut end = i64::MAX;

    for (not_before, not_after) in windows {
        start = start.max(*not_before);
        end = end.min(*not_after);
    }

    if start <= end {
        Some((start, end))
    } else {
        None
    }
}

/// `intersect` over the validity windows of an actual chain.
pub fn chain_window(
    end_entity: &CertificateDer<'_>,
    intermediates: &[CertificateDer<'_>],
) -> Result<Option<(i64, i64)>, String> {
    let windows: Vec<(i64, i64)> = std::iter::once(end_entity)
        .chain(intermediates.iter())
        .map(window_of)
        .collect::<Result<_, _>>()?;

    Ok(intersect(&windows))
}

fn unix_time(seconds: i64) -> Result<UnixTime, String> {
    let seconds = u64::try_from(seconds)
        .map_err(|_| format!("timestamp {seconds} predates the Unix epoch"))?;
    Ok(UnixTime::since_unix_epoch(Duration::from_secs(seconds)))
}

/// A `WebPkiServerVerifier` plus the ability to run it at an arbitrary instant.
#[derive(Debug)]
pub struct Verifier {
    inner: Arc<WebPkiServerVerifier>,
    crypto: Arc<CryptoProvider>,
}

impl Verifier {
    pub fn new(provider: Arc<CryptoProvider>) -> Result<Arc<Self>, String> {
        let mut roots = RootCertStore::empty();
        let loaded = rustls_native_certs::load_native_certs();
        for cert in loaded.certs {
            // A trust store usually carries a few certificates rustls declines (expired
            // roots, unsupported algorithms). Skipping them individually is what
            // rustls-native-certs expects; failing the whole load would make one bad entry in
            // the OS bundle indistinguishable from an empty one.
            let _ = roots.add(cert);
        }
        if roots.is_empty() {
            let detail = loaded
                .errors
                .iter()
                .map(|e| e.to_string())
                .collect::<Vec<_>>()
                .join("; ");
            return Err(format!(
                "no usable certificates in the system trust store: {detail}"
            ));
        }

        let inner = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone())
            .build()
            .map_err(|e| format!("cannot build the certificate verifier: {e}"))?;
        Ok(Arc::new(Self {
            inner,
            crypto: provider,
        }))
    }

    /// The provider both the verifier and every per-connection `ClientConfig` are built from,
    /// so a connection cannot end up using different cryptography than its verifier.
    pub fn crypto(&self) -> Arc<CryptoProvider> {
        self.crypto.clone()
    }

    /// Pass 2. Re-verify a chain captured from a completed handshake, at the time the server
    /// claimed it was.
    pub fn verify_at(
        &self,
        chain: &[CertificateDer<'static>],
        server_name: &ServerName<'static>,
        seconds: i64,
    ) -> Result<(), String> {
        let (end_entity, intermediates) = chain
            .split_first()
            .ok_or_else(|| "the peer presented no certificates".to_string())?;

        self.inner
            .verify_server_cert(
                end_entity,
                intermediates,
                server_name,
                &[],
                unix_time(seconds)?,
            )
            .map(|_| ())
            .map_err(|e| {
                format!("the chain is not valid at the time the server reported ({seconds}): {e}")
            })
    }
}

/// Pass 1. Delegates everything to `Verifier`, overriding only the instant, and records the
/// chain so pass 2 can re-run against exactly what this connection presented.
#[derive(Debug)]
pub struct TimeAgnosticVerifier {
    verifier: Arc<Verifier>,
    seen: Mutex<Option<Vec<CertificateDer<'static>>>>,
}

impl TimeAgnosticVerifier {
    pub fn new(verifier: Arc<Verifier>) -> Arc<Self> {
        Arc::new(Self {
            verifier,
            seen: Mutex::new(None),
        })
    }

    /// The chain pass 1 verified, or `None` if no handshake completed. One verifier is built
    /// per connection, so there is no ambiguity about which chain this is.
    pub fn chain(&self) -> Option<Vec<CertificateDer<'static>>> {
        self.seen.lock().ok()?.clone()
    }
}

impl ServerCertVerifier for TimeAgnosticVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        let window = chain_window(end_entity, intermediates)
            .map_err(Error::General)?
            .ok_or_else(|| {
                Error::General(
                    "the certificate chain has no instant at which all of it is valid".to_string(),
                )
            })?;

        // The start of the window. webpki's date check is inclusive at both ends, so the
        // earliest valid instant is itself valid, and using it keeps the choice independent
        // of how wide the window happens to be.
        let at = unix_time(window.0).map_err(Error::General)?;

        let verified = self.verifier.inner.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            at,
        )?;

        // Recorded only on success, so a chain that failed pass 1 can never reach pass 2.
        let mut chain = vec![end_entity.clone().into_owned()];
        chain.extend(intermediates.iter().map(|c| c.clone().into_owned()));
        if let Ok(mut seen) = self.seen.lock() {
            *seen = Some(chain);
        }

        Ok(verified)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.verifier
            .inner
            .verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.verifier
            .inner
            .verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.verifier.inner.supported_verify_schemes()
    }
}

#[cfg(test)]
mod tests {
    //! The window arithmetic is what decides whether pass 1 can run at all, so it is tested
    //! directly. Building real chains would need a certificate generator; the end-to-end
    //! behaviour is covered by tests/time-correction.nix, which gives a provider a genuinely
    //! expired certificate while its clock stays correct -- so the answer it returns is right and
    //! pass 2 must still reject it -- and asserts the clock is left alone.

    use super::intersect;

    #[test]
    fn a_single_certificate_is_its_own_window() {
        assert_eq!(intersect(&[(100, 200)]), Some((100, 200)));
    }

    #[test]
    fn a_narrow_leaf_inside_a_wide_root() {
        assert_eq!(intersect(&[(150, 160), (100, 200)]), Some((150, 160)));
    }

    #[test]
    fn a_narrow_root_inside_a_wide_leaf() {
        assert_eq!(intersect(&[(100, 200), (150, 160)]), Some((150, 160)));
    }

    #[test]
    fn partially_overlapping_windows_intersect() {
        assert_eq!(intersect(&[(100, 180), (150, 250)]), Some((150, 180)));
    }

    #[test]
    fn a_leaf_issued_after_its_issuer_expired_has_no_window() {
        // Internally inconsistent: there is no instant at which both are valid, and inventing
        // one would be verifying a lie.
        assert_eq!(intersect(&[(300, 400), (100, 200)]), None);
    }

    #[test]
    fn touching_windows_still_intersect_at_the_instant_they_share() {
        assert_eq!(intersect(&[(100, 200), (200, 300)]), Some((200, 200)));
    }

    #[test]
    fn an_expired_root_narrows_the_window_rather_than_being_ignored() {
        assert_eq!(intersect(&[(100, 500), (100, 150), (100, 120)]), Some((100, 120)));
    }

    #[test]
    fn the_chosen_instant_is_valid_for_every_certificate_in_the_chain() {
        // `TimeAgnosticVerifier` hands webpki the start of the intersection. Whatever the
        // chain looks like, that instant has to satisfy every certificate's own window --
        // otherwise pass 1 fails on a date check, which is the one thing it must never do.
        for windows in [
            vec![(100, 200)],
            vec![(150, 160), (100, 200)],
            vec![(100, 200), (150, 160)],
            vec![(100, 180), (150, 250)],
            vec![(100, 200), (200, 300)],
            vec![(100, 500), (100, 150), (100, 120)],
        ] {
            let (chosen, _) = intersect(&windows).unwrap();
            for (not_before, not_after) in &windows {
                assert!(
                    chosen >= *not_before && chosen <= *not_after,
                    "{chosen} outside [{not_before}, {not_after}] for {windows:?}"
                );
            }
        }
    }
}
