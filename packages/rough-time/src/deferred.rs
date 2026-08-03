//! The safety boundary for deferred certificate validation, now that there is more than one
//! TLS leg and the timestamp no longer arrives on the connection that presented the chain.
//!
//! The old single-leg design could keep its guarantee locally: the `Date` header came back on
//! the same TLS session, so pass 2 ran inside the function that read it and no caller could
//! obtain a time that had not been through it. That is impossible here. The clock comes from a
//! UDP packet, after the NTS-KE session has closed, and it must be checked against the chains
//! of *both* legs — the DoH resolver that produced the address and the NTS server that produced
//! the time.
//!
//! So the guarantee moves into the type. Chains accumulate in a `Deferred`, which has no way to
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

/// A timestamp that has been checked against every chain gathered on the way to it.
///
/// The field is private and the only constructor is `Deferred::accept`, so this type existing
/// is itself the evidence that pass 2 ran.
#[derive(Debug)]
pub struct Verified(i64);

impl Verified {
    pub fn seconds(&self) -> i64 {
        self.0
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

        for pending in &self.pending {
            verifier
                .verify_at(&pending.chain, &pending.server_name, seconds)
                .map_err(|e| format!("{}: {e}", pending.leg))?;
        }

        Ok(Verified(seconds))
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
