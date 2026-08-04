//! The safety boundary for deferred certificate validation.
//!
//! A single-leg design could keep this guarantee locally: if the time arrived on the same TLS
//! session that presented the chain, pass 2 would run inside the function that read it and no
//! caller could obtain a time that had not been through it. That is not the shape here. There are
//! two TLS legs, the clock arrives in a UDP packet *after* the NTS-KE session has closed, and it
//! must be checked against the chains of both legs — the DoH resolver that produced the address
//! and the NTS server that produced the time.
//!
//! So the guarantee lives in the type. Chains accumulate in a `Deferred`, which has no way to
//! yield a timestamp; the only thing that produces one is `accept`, which consumes the whole
//! collection and re-verifies every chain at the claimed instant first. A caller cannot get a
//! believable time without pass 2 having run on everything, because there is no other
//! constructor.

use rustls::pki_types::{CertificateDer, ServerName};

use crate::verify::Verifier;

/// A chain that has passed pass 1 and is waiting for a time to be checked against.
struct Pending {
    /// Which leg this came from, so a failure names the server that caused it rather than
    /// leaving three very different faults looking alike.
    leg: String,
    chain: Vec<CertificateDer<'static>>,
    server_name: ServerName<'static>,
}

/// The chains gathered while obtaining one timestamp.
#[derive(Default)]
pub struct Deferred {
    pending: Vec<Pending>,
}

/// A timestamp that has been checked against every chain gathered on the way to it, plus the
/// span over which those chains are simultaneously valid.
///
/// The fields are private and the only constructor is `Deferred::accept`, so this type existing
/// is itself the evidence that pass 2 ran. The window rides along for the same reason the
/// timestamp does: it is derived from the very chains pass 2 just checked, so a caller cannot
/// obtain one that no verified chain vouches for.
#[derive(Debug)]
pub struct Verified {
    seconds: i64,
    window: Option<(i64, i64)>,
}

impl Verified {
    pub fn seconds(&self) -> i64 {
        self.seconds
    }

    /// When every chain behind this timestamp is valid at once.
    ///
    /// `None` if the chains have no common instant. `verify_at` would already have rejected such
    /// a set at the timestamp itself, so this should be unreachable; callers must nonetheless
    /// treat it as "no window is known" rather than "any time is fine".
    pub fn window(&self) -> Option<(i64, i64)> {
        self.window
    }
}

impl Deferred {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record(
        &mut self,
        leg: &str,
        chain: Vec<CertificateDer<'static>>,
        server_name: ServerName<'static>,
    ) {
        self.pending.push(Pending {
            leg: leg.to_string(),
            chain,
            server_name,
        });
    }

    /// Pass 2, for every leg at once. This is the only way to turn a claimed time into one the
    /// rest of the program will look at.
    pub fn accept(self, verifier: &Verifier, seconds: i64) -> Result<Verified, String> {
        if self.pending.is_empty() {
            // Not a formality: an empty collection would make `accept` a rubber stamp, and the
            // whole point is that it cannot be one.
            return Err("no certificate chains were recorded, so nothing vouches for this time".to_string());
        }

        // The window is collected in the same pass, from the same chains, so the two cannot
        // describe different sets of certificates.
        //
        // A single chain of unknown window makes the whole window unknown, rather than merely
        // dropping out of the intersection. That distinction is load-bearing: `intersect` over an
        // empty slice is `Some((i64::MIN, i64::MAX))`, so silently skipping unknowns would turn
        // "we could not tell" into "every instant is inside", which is the one wrong answer a
        // caller deciding whether the clock is already good enough must never be given.
        let mut windows: Vec<(i64, i64)> = Vec::with_capacity(self.pending.len());
        let mut window_known = true;
        for pending in &self.pending {
            verifier
                .verify_at(&pending.chain, &pending.server_name, seconds)
                .map_err(|e| format!("{}: {e}", pending.leg))?;

            // `verify_at` has just accepted this chain, so it has a leaf.
            let (leaf, intermediates) = pending
                .chain
                .split_first()
                .ok_or_else(|| format!("{}: an empty chain was recorded", pending.leg))?;
            match crate::verify::chain_window(leaf, intermediates)
                .map_err(|e| format!("{}: {e}", pending.leg))?
            {
                Some(window) => windows.push(window),
                None => window_known = false,
            }
        }

        Ok(Verified {
            seconds,
            window: if window_known {
                crate::verify::intersect(&windows)
            } else {
                None
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_collection_cannot_vouch_for_anything() {
        // Guards the degenerate case: if `accept` succeeded on nothing, a leg that silently
        // failed to record its chain would turn pass 2 into a no-op and nothing would notice.
        let verifier = crate::verify::Verifier::new(std::sync::Arc::new(
            rustls::crypto::ring::default_provider(),
        ));
        // The trust store may or may not be loadable in a test sandbox; either way the empty
        // check must fire before anything touches it.
        if let Ok(verifier) = verifier {
            let error = Deferred::new().accept(&verifier, 1_785_000_000).unwrap_err();
            assert!(error.contains("no certificate chains"), "{error}");
        }
    }
}
