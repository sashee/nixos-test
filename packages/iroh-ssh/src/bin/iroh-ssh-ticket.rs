//! Print the endpoint's canonical connect ticket, derived from the secret key.
//!
//! Usage: iroh-ssh-ticket
//!
//! The ticket carries only the endpoint id -- no relay urls, no direct addresses
//! -- which makes it a pure function of the secret: no endpoint is bound, no
//! network is touched. That is the form operators distribute, because it stays
//! valid across relay changes, where a ticket with a relay url baked in stops
//! working once that relay goes away. The connecting side resolves the id
//! through discovery.
//!
//! The secret is read exactly as the listener reads it (see `load_secret`): an
//! explicit path, the systemd credential, or `$IROH_SECRET`.
use iroh_ssh::{id_ticket, load_secret};
use iroh_tickets::endpoint::EndpointTicket;
use n0_error::Result;

/// Derive the id-only ticket. Pure: same secret in, same ticket out, offline.
fn ticket() -> Result<EndpointTicket> {
    Ok(id_ticket(&load_secret(None)?))
}

fn main() -> ! {
    // No tokio runtime here on purpose: the derivation is synchronous, so this
    // binary stays usable in contexts that have no reactor (and no network).
    match ticket() {
        Ok(ticket) => {
            println!("{ticket}");
            std::process::exit(0)
        }
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1)
        }
    }
}
