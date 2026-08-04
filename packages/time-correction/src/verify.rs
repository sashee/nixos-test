//! Certificate verification at an instant we choose, twice.
//!
//! The bootstrap problem: this program runs when the clock may be years wrong, so a normal
//! TLS handshake fails on `notBefore`/`notAfter` before it can get far enough to be told the
//! time. But simply not checking the dates would accept a chain from anyone holding any
//! once-valid certificate.
//!
//! So the check is deferred rather than dropped:
//!
//!   pass 1, during the handshake -- verify at the LEAF's own notBefore, falling back to the sent
//!     chain's intersected window. Time is neutralised by construction (the leaf is on every path
//!     webpki could build and a CA issues inside its own validity, so that instant satisfies the
//!     path that gets used), so the handshake can only fail on signatures,
//!     chain-to-a-trusted-root, or hostname. There is no fixed instant that would do: the build
//!     floor precedes a freshly issued certificate's notBefore, the epoch precedes every
//!     notBefore, and a far-future value follows every notAfter.
//!
//!   pass 2, after the response is read -- verify the same chain again, through the same
//!     verifier, at the time the exchange reported. This is the real check, and it is what
//!     makes an authenticated timestamp outside the chain's validity a hard failure.
//!
//! A peer sends whatever is in its chain file, and webpki date-checks only the certificates on
//! the path it ends up building -- so "the chain" and "what was verified" are not the same set,
//! and the difference is load-bearing in both passes. `spec/features/system/time-correction-details.md`
//! states the rule: only certificates that were checked in pass 2 may decide whether this host's
//! clock is already good enough. `verified_window` is where that is enforced, and pass 1's choice
//! of instant is what keeps a certificate nothing uses from aborting the handshake on its way
//! there.
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
/// `None` when the intersection is empty, which callers must treat as "no instant is known"
/// rather than as "any instant will do". Note what an empty intersection over a SENT chain does
/// not mean: not that the chain is unusable, only that the certificates in it do not all hold at
/// once -- which is the normal state of a chain file carrying a superseded cross-sign. Deciding
/// what to do about that is `verified_window`'s job and pass 1's; this function only does the
/// arithmetic.
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

/// `intersect` over the validity windows of an actual chain, as sent.
///
/// Private, and that is the point: "when is everything the peer sent valid at once" is not a
/// question anything outside this file should be asking. It survives only as pass 1's fallback
/// candidate, where no verification has happened yet and there is nothing better to go on.
/// Callers deciding anything about the clock want `verified_window`.
fn chain_window(
    end_entity: &CertificateDer<'_>,
    intermediates: &[CertificateDer<'_>],
) -> Result<Option<(i64, i64)>, String> {
    let windows: Vec<(i64, i64)> = std::iter::once(end_entity)
        .chain(intermediates.iter())
        .map(window_of)
        .collect::<Result<_, _>>()?;

    Ok(intersect(&windows))
}

/// The validity window of every certificate a peer sent, in the order it sent them, `None` where
/// one could not be parsed.
///
/// Deliberately not an intersection: which of these certificates matter is not knowable until
/// something has verified the chain, so they are kept apart until `verified_window` can be handed
/// an instant at which that has happened.
pub fn chain_windows(
    end_entity: &CertificateDer<'_>,
    intermediates: &[CertificateDer<'_>],
) -> Vec<Option<(i64, i64)>> {
    std::iter::once(end_entity)
        .chain(intermediates.iter())
        .map(|der| window_of(der).ok())
        .collect()
}

/// The span over which the path that was verified at `seconds` is valid.
///
/// `windows` is `chain_windows` for the chain a peer sent, and `seconds` an instant at which
/// verification has ALREADY succeeded. That precondition is what makes the filter sound: webpki
/// date-checks every certificate on the path it built against the instant it was given, so a
/// certificate whose own window excludes `seconds` provably was not on that path. It is something
/// the peer sent and nothing used -- a superseded cross-sign left in a chain file is exactly that
/// -- and giving it a vote on whether this clock is good enough would step a CORRECT clock on
/// every run, since `now` and `seconds` are the same instant on a healthy host.
///
/// Certificates that are off the path but happen to be valid at `seconds` cannot be told apart
/// from on-path ones, so they stay in and narrow the result. That is the safe direction and worth
/// being explicit about: too narrow steps a clock that did not need it, and the step lands on a
/// verified, quorum-agreed time; too wide stands down on a clock TLS cannot actually use, and then
/// nothing recovers the host at all.
///
/// `None` -- "no window is known", which makes the caller step -- when any window could not be
/// read, for that same reason: an unparseable certificate might be on the path, and dropping it
/// silently would widen the answer.
pub fn verified_window(windows: &[Option<(i64, i64)>], seconds: i64) -> Option<(i64, i64)> {
    if windows.is_empty() || windows.iter().any(Option::is_none) {
        return None;
    }

    let used: Vec<(i64, i64)> = windows
        .iter()
        .flatten()
        .copied()
        .filter(|(not_before, not_after)| *not_before <= seconds && seconds <= *not_after)
        .collect();

    // Cannot happen after a successful verification -- the leaf is on every path, so it is valid
    // at `seconds` -- but checked rather than assumed, because `intersect` over an empty slice is
    // `Some((i64::MIN, i64::MAX))`. That is the one wrong answer here: it says "every instant is
    // inside" at the moment nothing at all is known.
    if used.is_empty() {
        return None;
    }

    intersect(&used)
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
        // The leaf's own notBefore first, and the intersection over the whole sent chain only as
        // a fallback. webpki's date check is inclusive at both ends, so the earliest valid instant
        // is itself valid.
        //
        // The leaf rather than the intersection, because the leaf is the only certificate that is
        // on every path webpki could build, and a CA issues inside its own validity -- so the
        // leaf's notBefore satisfies the path that will actually be used, whatever else the peer
        // sent. The intersection does not have that property: a superseded cross-sign or any other
        // certificate the peer sends and nothing uses gets a vote, and one whose window does not
        // overlap the leaf's makes the intersection EMPTY -- which used to abort the handshake and
        // fail the whole run over a certificate that plays no part in it. Deferring the date check
        // is pointless if an irrelevant date can still refuse the connection.
        //
        // The intersection is kept as a second candidate for the converse shape: a chain whose
        // leaf predates an intermediate's notBefore, i.e. mis-issued or cross-signed later, where
        // the leaf's own notBefore is not an instant the path satisfies. Trying both means this is
        // never worse than the old rule, only better where the old one gave up.
        //
        // Neither instant is any more real than the other -- both are invented, and pass 2 against
        // the reported time is the check that decides anything.
        let leaf = window_of(end_entity).ok().map(|(not_before, _)| not_before);
        let intersected = chain_window(end_entity, intermediates)
            .ok()
            .flatten()
            .map(|(not_before, _)| not_before)
            // The two coincide on any chain without an off-path certificate, which is most of
            // them; filtering here rather than verifying twice for the same answer.
            .filter(|at| Some(*at) != leaf);
        let candidates: Vec<i64> = [leaf, intersected].into_iter().flatten().collect();

        let mut last = Error::General(
            "no certificate in the chain has a readable validity window".to_string(),
        );
        for at in candidates {
            let at = match unix_time(at) {
                Ok(at) => at,
                Err(e) => {
                    last = Error::General(e);
                    continue;
                }
            };
            match self.verifier.inner.verify_server_cert(
                end_entity,
                intermediates,
                server_name,
                ocsp_response,
                at,
            ) {
                Ok(verified) => {
                    // Recorded only on success, so a chain that failed pass 1 can never reach
                    // pass 2 -- and only once, from the attempt that succeeded.
                    let mut chain = vec![end_entity.clone().into_owned()];
                    chain.extend(intermediates.iter().map(|c| c.clone().into_owned()));
                    if let Ok(mut seen) = self.seen.lock() {
                        *seen = Some(chain);
                    }
                    return Ok(verified);
                }
                Err(e) => last = e,
            }
        }

        // rustls' own error rather than a synthetic one: it names whether the failure was the
        // signature, the chain, or the hostname, which is the only part worth acting on.
        Err(last)
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
    //! The window arithmetic decides both whether pass 1 can run at all and whether the clock is
    //! stepped, so it is tested directly. Building real chains would need a certificate generator;
    //! the end-to-end behaviour is covered by tests/time-correction.nix, which gives a provider a
    //! genuinely expired certificate while its clock stays correct -- so the answer it returns is
    //! right and pass 2 must still reject it -- and asserts the clock is left alone. That test also
    //! has the interceptors SEND a certificate nothing on the path uses, which is the shape
    //! `verified_window` exists for and the one no arithmetic fixture can prove is really ignored
    //! by webpki rather than merely by this file.

    use super::{intersect, verified_window};

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
    fn a_certificate_the_path_cannot_have_used_is_not_part_of_the_window() {
        // The defect this function exists for. A peer sends its leaf plus a superseded cross-sign
        // that expired at 200; webpki builds a path that does not include it and verifies fine at
        // 500. Counting it would answer "TLS works only up to 200", and a host whose clock reads
        // 500 -- the correct time -- would be stepped on every run.
        assert_eq!(
            verified_window(&[Some((100, 900)), Some((50, 200))], 500),
            Some((100, 900))
        );
        // Same shape in the other direction: a certificate that is not valid YET.
        assert_eq!(
            verified_window(&[Some((100, 900)), Some((700, 1000))], 500),
            Some((100, 900))
        );
        // And the shape that used to abort the handshake outright: no instant satisfies leaf and
        // extra together, and the extra is still simply not part of the answer.
        assert_eq!(
            verified_window(&[Some((300, 900)), Some((50, 200))], 500),
            Some((300, 900))
        );
    }

    #[test]
    fn a_certificate_that_could_have_been_used_still_narrows() {
        // The other half of the rule, and the reason this is a filter rather than "just use the
        // leaf": a certificate valid at `seconds` is indistinguishable from one on the path, so it
        // stays in. Narrow is the safe direction -- it steps a clock that did not need it, onto a
        // verified time, rather than standing down on a clock TLS cannot use.
        assert_eq!(
            verified_window(&[Some((100, 900)), Some((200, 600))], 500),
            Some((200, 600))
        );
    }

    #[test]
    fn the_reported_time_is_always_inside_the_window() {
        // The invariant the stand-down rule rests on: `seconds` came back from a chain that
        // verified AT `seconds`, so the window derived from that chain has to contain it. Without
        // this, `now` can sit outside a window on a host whose clock is right.
        for windows in [
            vec![Some((100, 900))],
            vec![Some((100, 900)), Some((50, 200))],
            vec![Some((100, 900)), Some((200, 600))],
            vec![Some((100, 900)), Some((700, 1000)), Some((400, 800))],
        ] {
            let (not_before, not_after) =
                verified_window(&windows, 500).expect("the leaf is valid at 500");
            assert!(
                (not_before..=not_after).contains(&500),
                "500 outside [{not_before}, {not_after}] for {windows:?}"
            );
        }
    }

    #[test]
    fn an_unreadable_window_poisons_the_result() {
        // Fail-closed, and note WHICH way closed is: `None` makes the caller step. An unparseable
        // certificate might be on the path, so dropping it would widen the window -- the direction
        // that leaves a host standing down on a clock TLS cannot use.
        assert_eq!(verified_window(&[Some((100, 900)), None], 500), None);
        assert_eq!(verified_window(&[], 500), None);
    }

    #[test]
    fn a_chain_valid_nowhere_near_the_reported_time_yields_nothing() {
        // Unreachable after a successful verification, since the leaf is on every path. Pinned
        // because the alternative is `intersect` over an empty slice, which is
        // `Some((i64::MIN, i64::MAX))` -- "every instant is inside" at the moment nothing is
        // known, which would silently disable the step.
        assert_eq!(verified_window(&[Some((100, 200))], 500), None);
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
