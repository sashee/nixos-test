//! Establish a rough system clock at boot, so that everything downstream which needs TLS can
//! work at all.
//!
//! The hosts in this repo resolve names over DoH and synchronise time over NTS. Both are TLS,
//! so a clock outside certificate validity blocks name resolution and time synchronisation at
//! once, and neither can recover the other. A Raspberry Pi with no RTC battery starts in
//! exactly that state on every cold boot, and chrony cannot break the deadlock itself: whatever
//! its certificate policy, it still has to *resolve* the NTS hostnames, and that is DoH.
//!
//! So this program does the whole chain with certificate time checks deferred:
//!
//!   1. ask a DoH resolver, dialled by pinned address, to resolve an NTS server's hostname;
//!   2. do NTS key establishment with that server;
//!   3. get an authenticated timestamp over NTPv4;
//!   4. re-verify both certificate chains at the time that was reported.
//!
//! Step 4 is the whole security argument, and `deferred::Deferred` is what makes it structural
//! rather than a step someone can forget: there is no way to obtain a believable time except by
//! consuming the recorded chains.
//!
//! Two independent pairs must agree, so moving this clock means compromising two operators at
//! once -- and even then only within a certificate's validity window, with the build-time floor
//! bounding how far back it can go. That is the same bound the previous Date-header design had:
//! the deferred check is what is being traded on, and NTS does not change it. What NTS buys is
//! that every configured server can answer, rather than the two of four that emitted a `Date`.
//!
//! Runs as a systemd oneshot that restarts until it succeeds (see `modules/time-sync.nix`).
//! A failed run exits non-zero and is retried, which keeps the failure visible in
//! `systemctl status` rather than hidden in an internal retry loop.

mod deferred;
mod dns;
mod doh;
mod ntp;
mod nts;
mod quorum;
mod timeserver;
mod verify;

use std::io::Read;
use std::net::IpAddr;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use quorum::Answer;

/// A DoH resolver: pinned addresses, dialled directly, hostname used for SNI and verification.
#[derive(Debug, Clone)]
struct Resolver {
    name: String,
    hostname: String,
    addresses: Vec<IpAddr>,
}

/// An NTS server. Hostnames only -- `time.cloudflare.com` is anycast, `nts.netnod.se` is a
/// round-robin across sites that redirects during key establishment anyway, and only the PTB
/// pair is pinnable at all. `operator` is the voting identity: two hostnames belonging to one
/// organisation are one source, and nothing in the names says so.
#[derive(Debug, Clone)]
struct TimeServer {
    name: String,
    hostname: String,
    operator: String,
}

#[derive(Debug)]
struct Options {
    resolvers: Vec<Resolver>,
    servers: Vec<TimeServer>,
    sample: usize,
    tolerance: i64,
    floor: i64,
    only: Option<Vec<String>>,
    timeout: Duration,
    force: bool,
    dry_run: bool,
}

const USAGE: &str = "\
usage: rough-time [options]

  --doh NAME=HOSTNAME@ADDR[,ADDR]  a DoH resolver, dialled at the given addresses with the
                                   hostname used for SNI and certificate verification.
                                   Repeatable. Nothing else in this program resolves a name,
                                   which is what lets it run before DNS works
  --nts NAME=HOSTNAME@OPERATOR     an NTS server and the organisation that runs it. Repeatable.
                                   The operator is the unit of agreement: two servers run by
                                   the same organisation count as one source
  --sample N                       how many operators to ask (default: 2). All must answer and
                                   agree, so this is also how many would have to be
                                   compromised at once to move the clock
  --tolerance SECONDS              how far apart two answers may be (default: 60)
  --floor EPOCH                    refuse any time earlier than this (default: 0)
  --only NAME[,NAME]               ask exactly these NTS servers instead of sampling; for
                                   tests, which need the choice to be deterministic
  --timeout SECONDS                per-connection connect and read timeout (default: 10)
  --force                          ask even if the clock is already synchronised. With
                                   --dry-run, this is how to check that the configured servers
                                   still answer on a host whose clock is fine
  --dry-run                        report the decision without touching the clock
  --check-synced                   exit 0 if the kernel reports the clock synchronised and 1 if
                                   not, contacting nothing. Exists so that whatever waits for
                                   synchronisation uses the same definition of it this program
                                   does, instead of a second one written in shell
  --help                           this text
";

fn split_spec(spec: &str, kind: &str) -> Result<(String, String, String), String> {
    let (name, rest) = spec
        .split_once('=')
        .ok_or_else(|| format!("{kind} {spec:?} is not NAME=HOSTNAME@..."))?;
    let (hostname, tail) = rest
        .split_once('@')
        .ok_or_else(|| format!("{kind} {spec:?} has nothing after @"))?;
    if name.is_empty() {
        return Err(format!("{kind} {spec:?} has an empty name"));
    }
    if hostname.is_empty() {
        return Err(format!("{kind} {spec:?} has an empty hostname"));
    }
    if tail.is_empty() {
        return Err(format!("{kind} {spec:?} has nothing after @"));
    }
    Ok((name.to_string(), hostname.to_string(), tail.to_string()))
}

fn parse_resolver(spec: &str) -> Result<Resolver, String> {
    let (name, hostname, tail) = split_spec(spec, "resolver")?;
    let addresses: Vec<IpAddr> = tail
        .split(',')
        .filter(|a| !a.is_empty())
        .map(|a| {
            a.parse::<IpAddr>()
                .map_err(|_| format!("resolver {name}: {a:?} is not an IP address"))
        })
        .collect::<Result<_, _>>()?;
    if addresses.is_empty() {
        return Err(format!("resolver {name} has no addresses"));
    }
    Ok(Resolver {
        name,
        hostname,
        addresses,
    })
}

fn parse_server(spec: &str) -> Result<TimeServer, String> {
    let (name, hostname, operator) = split_spec(spec, "server")?;
    Ok(TimeServer {
        name,
        hostname,
        operator,
    })
}

/// What the command line asked for. Three genuinely different things, rather than one of them
/// with flags: `--help` and `--check-synced` need none of the resolver and server configuration
/// that `Run` cannot work without, so the validation below must not apply to them.
#[derive(Debug)]
enum Action {
    Help,
    CheckSynced,
    Run(Options),
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Action, String> {
    let mut options = Options {
        resolvers: Vec::new(),
        servers: Vec::new(),
        sample: 2,
        tolerance: 60,
        floor: 0,
        only: None,
        timeout: Duration::from_secs(10),
        force: false,
        dry_run: false,
    };

    let mut args = args;
    while let Some(arg) = args.next() {
        let mut value = |name: &str| -> Result<String, String> {
            args.next().ok_or_else(|| format!("{name} needs a value"))
        };
        match arg.as_str() {
            "--help" | "-h" => return Ok(Action::Help),
            "--check-synced" => return Ok(Action::CheckSynced),
            "--doh" => options.resolvers.push(parse_resolver(&value("--doh")?)?),
            "--nts" => options.servers.push(parse_server(&value("--nts")?)?),
            "--sample" => {
                options.sample = value("--sample")?
                    .parse()
                    .map_err(|_| "--sample needs a number".to_string())?
            }
            "--tolerance" => {
                options.tolerance = value("--tolerance")?
                    .parse()
                    .map_err(|_| "--tolerance needs a number".to_string())?
            }
            "--floor" => {
                options.floor = value("--floor")?
                    .parse()
                    .map_err(|_| "--floor needs a number".to_string())?
            }
            "--timeout" => {
                let seconds: u64 = value("--timeout")?
                    .parse()
                    .map_err(|_| "--timeout needs a number".to_string())?;
                options.timeout = Duration::from_secs(seconds);
            }
            "--only" => {
                options.only = Some(
                    value("--only")?
                        .split(',')
                        .filter(|s| !s.is_empty())
                        .map(str::to_string)
                        .collect(),
                )
            }
            "--force" => options.force = true,
            "--dry-run" => options.dry_run = true,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }

    if options.resolvers.is_empty() {
        return Err("no --doh resolver given".to_string());
    }
    if options.servers.is_empty() {
        return Err("no --nts server given".to_string());
    }
    if options.sample == 0 {
        return Err("--sample must be at least 1".to_string());
    }

    let operators = distinct_operators(&options.servers);
    if options.sample > operators.len() {
        return Err(format!(
            "--sample {} exceeds the {} distinct NTS operators configured; servers run by the same organisation cannot cross-check each other",
            options.sample,
            operators.len()
        ));
    }
    if options.sample > options.resolvers.len() {
        return Err(format!(
            "--sample {} exceeds the {} DoH resolvers configured; each pair uses a different one",
            options.sample,
            options.resolvers.len()
        ));
    }
    if let Some(only) = &options.only {
        if only.is_empty() {
            return Err("--only needs at least one name".to_string());
        }
        for name in only {
            if !options.servers.iter().any(|s| &s.name == name) {
                return Err(format!("--only names {name:?}, which is not configured"));
            }
        }
    }

    Ok(Action::Run(options))
}

fn distinct_operators(servers: &[TimeServer]) -> Vec<String> {
    let mut operators: Vec<String> = Vec::new();
    for server in servers {
        if !operators.contains(&server.operator) {
            operators.push(server.operator.clone());
        }
    }
    operators
}

/// True when the kernel reports the clock as disciplined, in which case an authenticated
/// source already owns it and this program must not overwrite it.
///
/// `STA_UNSYNC` is the kernel's own answer rather than a proxy for it: it is clear only because
/// something synchronised the clock and told the kernel so, which chrony does (via `rtcsync`;
/// see the comment in modules/time-sync.nix) and this program does not.
///
/// This can never be true because of a previous run: `ntp_clear()`, which the kernel calls from
/// `do_settimeofday64()`, re-sets `STA_UNSYNC` on every clock step. "Rough time set" and
/// "synchronised" therefore stay distinct states, which is what makes the check meaningful.
fn clock_is_disciplined() -> bool {
    // SAFETY: the one raw call in this crate. `adjtimex` reads the caller's `timex` and writes
    // its result back into it; `modes = 0` makes that a pure query, so no other field is
    // interpreted as a request. `timex` is a plain struct of integers, so an all-zero value is
    // valid, and `buf` is uniquely owned by this frame for the whole call, so the pointer is
    // valid and non-aliased. rustix 1.x does not bind adjtimex and the crates that do are
    // unvetted, so AGENTS.md's no-unsafe preference yields to interoperability here.
    let mut buf: libc::timex = unsafe { std::mem::zeroed() };
    let result = unsafe { libc::adjtimex(&mut buf) };

    // A negative return is a failed call, not evidence of a good clock. Otherwise read the bit
    // directly rather than comparing the return against TIME_ERROR: TIME_ERROR also covers
    // STA_CLOCKERR, and it is specifically "nothing has synchronised this clock" we care about.
    result >= 0 && (buf.status & libc::STA_UNSYNC) == 0
}

/// Whether the clock is far enough wrong to be worth stepping, given the span over which the
/// certificates behind the answer are simultaneously valid.
///
/// The only thing this program exists to fix is a clock so wrong that TLS cannot validate, which
/// is what blocks DoH and NTS and therefore everything downstream. If the current clock already
/// sits inside that span, TLS already works, chrony can already do its job, and stepping would
/// buy no correctness -- only a discontinuity, and a coarser one than chrony's own first
/// correction, which is accurate rather than accurate-to-the-second.
///
/// `None` means no window could be established, and then the clock is set: not knowing whether
/// the clock is good enough is not the same as knowing that it is.
///
/// Note what this deliberately does NOT consult: the floor. The floor bounds a timestamp an
/// attacker could have supplied, and standing down adopts no timestamp at all -- it leaves the
/// clock the host booted with. A clock that is stale but inside certificate validity is a clock
/// chrony will correct, because nixpkgs' chrony defaults to `makestep 0.1 3` and its first
/// updates step without a size limit.
fn needs_setting(now: i64, window: Option<(i64, i64)>) -> bool {
    match window {
        Some((not_before, not_after)) => now < not_before || now > not_after,
        None => true,
    }
}

/// The current wall clock, which is the thing under judgement rather than a source of truth.
fn wall_clock() -> Result<i64, String> {
    use std::time::{SystemTime, UNIX_EPOCH};

    // Signed, and `duration_since` is not enough on its own: a clock before 1970 is exactly the
    // state this program exists for, and it must produce a negative number rather than an error.
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(since) => i64::try_from(since.as_secs())
            .map_err(|_| "the clock is further ahead than a signed epoch can hold".to_string()),
        Err(before) => i64::try_from(before.duration().as_secs())
            .map(|seconds| -seconds)
            .map_err(|_| "the clock is further behind than a signed epoch can hold".to_string()),
    }
}

fn set_clock(seconds: i64) -> Result<(), String> {
    use rustix::time::{clock_settime, ClockId, Timespec};

    clock_settime(
        ClockId::Realtime,
        Timespec {
            tv_sec: seconds,
            tv_nsec: 0,
        },
    )
    .map_err(|e| format!("cannot set the clock: {e}"))
}

/// Random bytes for the sampling seed and for each exchange's unique identifier and nonce.
///
/// The identifier is not merely nice to randomise: it is what matches a response to its request
/// and therefore what makes a replayed packet detectable, so a predictable one would quietly
/// remove the replay guard.
fn random_bytes(buffer: &mut [u8]) -> Result<(), String> {
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(buffer))
        .map_err(|e| format!("cannot read /dev/urandom: {e}"))
}

fn seed() -> u64 {
    let mut bytes = [0u8; 8];
    match random_bytes(&mut bytes) {
        Ok(()) => u64::from_ne_bytes(bytes),
        // Not fatal for the draw itself -- a fixed seed still picks distinct operators, it only
        // makes which ones predictable, and an attacker who knows the pair still has to
        // compromise both.
        Err(e) => {
            eprintln!("warning: {e}; falling back to a fixed draw");
            0
        }
    }
}

/// One (resolver, server) pair, taken all the way from a hostname to a verified timestamp and the
/// window over which the certificates behind it are valid.
fn ask_pair(
    verifier: Arc<verify::Verifier>,
    resolver: &Resolver,
    server: &TimeServer,
    timeout: Duration,
) -> Result<(i64, Option<(i64, i64)>), String> {
    let mut deferred = deferred::Deferred::new();
    let mut id_bytes = [0u8; 2];
    random_bytes(&mut id_bytes)?;
    let mut query_id = u16::from_be_bytes(id_bytes);

    // Both families, and both are optional individually. A host with no IPv6 route gets
    // nothing usable from AAAA and vice versa, so a family that yields nothing is not a
    // failure as long as the other did -- only an empty union is. Asking for both is what
    // makes an IPv6-only host work at all: querying A alone resolves to an address it has no
    // way to reach.
    //
    // Every failure is collected rather than only the last kept, which is a diagnostics fix with
    // a real cost behind it. Keeping one meant reporting whichever attempt happened to come last
    // -- always AAAA over the resolver's IPv6 address -- so a host whose IPv4 path was the broken
    // one produced logs that named an IPv6 address and nothing else, and a CI failure caused
    // entirely by a missing IPv4 route read as an IPv6 problem. Only an empty union is a failure,
    // so this text appears only when EVERY attempt failed, and then each is worth naming.
    let resolve = |deferred: &mut deferred::Deferred, name: &str, id: u16| {
        let mut found: Vec<IpAddr> = Vec::new();
        let mut failures: Vec<String> = Vec::new();

        for (offset, qtype) in [(0u16, dns::TYPE_A), (1u16, dns::TYPE_AAAA)] {
            let kind = if qtype == dns::TYPE_A { "A" } else { "AAAA" };
            // Whichever address of the resolver answers first. Being unreachable over one
            // family is normal on these hosts; unreachable over both is the failure.
            for address in &resolver.addresses {
                match doh::resolve(
                    verifier.clone(),
                    deferred,
                    &resolver.hostname,
                    *address,
                    name,
                    qtype,
                    id.wrapping_add(offset),
                    timeout,
                ) {
                    Ok(addresses) => {
                        found.extend(addresses);
                        break;
                    }
                    Err(e) => failures.push(format!("{kind} via {address}: {e}")),
                }
            }
        }

        if found.is_empty() {
            Err(format!(
                "{} could not resolve {name}: {}",
                resolver.name,
                if failures.is_empty() {
                    "no address was even attempted".to_string()
                } else {
                    failures.join("; ")
                }
            ))
        } else {
            Ok(found)
        }
    };

    let addresses = resolve(&mut deferred, &server.hostname, query_id)?;

    // Each candidate in turn. On a single-stack host the other family's addresses fail
    // immediately with ENETUNREACH rather than costing a timeout, so trying them all is cheap
    // and avoids having to guess which family this host actually has.
    let mut key_address = None;
    let mut established = None;
    let mut last = format!("{} resolved to nothing", server.hostname);
    for address in &addresses {
        match timeserver::establish(
            verifier.clone(),
            &mut deferred,
            &server.hostname,
            *address,
            timeout,
        ) {
            Ok(session) => {
                key_address = Some(*address);
                established = Some(session);
                break;
            }
            Err(e) => last = e,
        }
    }
    let (key_address, established) = match (key_address, established) {
        (Some(a), Some(e)) => (a, e),
        _ => return Err(last),
    };

    let (redirect, mut address, port) = timeserver::ntp_target(&established, key_address);
    if let Some(name) = redirect {
        // Offset by two so the A/AAAA pair above cannot collide with this pair's ids.
        query_id = query_id.wrapping_add(2);
        let candidates = resolve(&mut deferred, &name, query_id)?;
        // Match the family that key establishment worked over: the redirect target is the same
        // operator's timestamping host, so if only one family was reachable for the first hop
        // it is the one to use for the second.
        address = *candidates
            .iter()
            .find(|a| a.is_ipv4() == key_address.is_ipv4())
            .or_else(|| candidates.first())
            .ok_or_else(|| format!("the redirect to {name} resolved to nothing"))?;
    }

    let mut unique_id = [0u8; ntp::UNIQUE_ID_LENGTH];
    let mut nonce = [0u8; ntp::NONCE_LENGTH];
    random_bytes(&mut unique_id)?;
    random_bytes(&mut nonce)?;

    let seconds = timeserver::ask_time(&established, address, port, unique_id, nonce, timeout)?;

    // Pass 2, on every chain gathered on the way here. There is no other way to get a number
    // out of this function.
    let verified = deferred.accept(&verifier, seconds)?;
    Ok((verified.seconds(), verified.window()))
}

/// The answers that came back, and the validity windows of the chains that vouched for them.
///
/// The windows are kept beside the answers rather than inside `Answer` so that `quorum` stays a
/// pure function of times and operators, which is the whole reason its rules are testable.
struct Collected {
    answers: Vec<Answer>,
    windows: Vec<Option<(i64, i64)>>,
}

fn collect_answers(options: &Options, pairs: &[(Resolver, TimeServer)]) -> Collected {
    let verifier = match verify::Verifier::new(Arc::new(rustls::crypto::ring::default_provider()))
    {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: {e}");
            return Collected {
                answers: Vec::new(),
                windows: Vec::new(),
            };
        }
    };

    // One thread per pair: a pair that cannot be reached costs its timeouts once rather than
    // delaying the others.
    std::thread::scope(|scope| {
        let handles: Vec<_> = pairs
            .iter()
            .map(|(resolver, server)| {
                let verifier = verifier.clone();
                let timeout = options.timeout;
                scope.spawn(move || {
                    let outcome = ask_pair(verifier, resolver, server, timeout);
                    (server.clone(), resolver.name.clone(), outcome)
                })
            })
            .collect();

        let mut collected = Collected {
            answers: Vec::new(),
            windows: Vec::new(),
        };
        for handle in handles {
            let Ok((server, resolver, outcome)) = handle.join() else {
                continue;
            };
            match outcome {
                Ok((seconds, window)) => {
                    eprintln!("{} via {resolver}: {seconds}", server.name);
                    collected.answers.push(Answer {
                        operator: server.operator,
                        endpoint: format!("{} via {resolver}", server.hostname),
                        seconds,
                    });
                    collected.windows.push(window);
                }
                Err(e) => {
                    // The message already names the leg -- resolution, key establishment and
                    // the NTP exchange are three different faults, and a summary that
                    // collapsed them would send whoever reads it to the wrong place.
                    eprintln!("{} via {resolver}: {e}", server.name);
                }
            }
        }
        collected
    })
}

/// The span over which every chain gathered this run is valid at once.
///
/// Every answer's window, not only the quorum's: an answer that lost the vote still presented a
/// chain that passed both passes, and including it can only narrow the result. Narrower means
/// stepping more often, which is the safe direction for a decision about whether the clock is
/// already good enough.
fn common_window(windows: &[Option<(i64, i64)>]) -> Option<(i64, i64)> {
    if windows.is_empty() || windows.iter().any(Option::is_none) {
        return None;
    }
    verify::intersect(&windows.iter().flatten().copied().collect::<Vec<_>>())
}

/// Choose which (resolver, server) pairs to ask.
///
/// Distinct operators, so two hostnames from one organisation cannot form a quorum with each
/// other, and a distinct resolver per pair, so one compromised resolver cannot sit in the path
/// of every answer.
fn choose(options: &Options, seed: u64) -> Result<Vec<(Resolver, TimeServer)>, String> {
    let chosen: Vec<TimeServer> = match &options.only {
        Some(only) => options
            .servers
            .iter()
            .filter(|s| only.contains(&s.name))
            .cloned()
            .collect(),
        None => {
            let operators = distinct_operators(&options.servers);
            quorum::sample(&operators, options.sample, seed)
                .into_iter()
                .enumerate()
                .filter_map(|(index, operator)| {
                    // Draw among that operator's servers rather than taking the first. Taking
                    // the first made a second server for an operator dead weight: ptbtime2 was
                    // configured, passed to the binary and never asked, so the redundancy it
                    // exists for -- ptbtime1 being down -- did not work. The seed is varied per
                    // position so two operators drawn in one run do not both take the same
                    // index into their own lists.
                    let theirs: Vec<&TimeServer> = options
                        .servers
                        .iter()
                        .filter(|s| s.operator == operator)
                        .collect();
                    let names: Vec<String> = theirs.iter().map(|s| s.name.clone()).collect();
                    let picked = quorum::sample(&names, 1, seed.wrapping_add(index as u64 + 2));
                    let name = picked.first()?;
                    theirs.iter().find(|s| &s.name == name).map(|s| (*s).clone())
                })
                .collect()
        }
    };

    let resolver_names: Vec<String> = options.resolvers.iter().map(|r| r.name.clone()).collect();
    let resolvers = quorum::sample(&resolver_names, chosen.len(), seed.wrapping_add(1));
    if resolvers.len() < chosen.len() {
        return Err("not enough DoH resolvers to give each server its own".to_string());
    }

    Ok(chosen
        .into_iter()
        .zip(resolvers)
        .map(|(server, resolver_name)| {
            let resolver = options
                .resolvers
                .iter()
                .find(|r| r.name == resolver_name)
                .cloned()
                .expect("sampled from the configured names");
            (resolver, server)
        })
        .collect())
}

fn run(options: Options) -> Result<(), String> {
    if !options.force && clock_is_disciplined() {
        println!("the clock is already synchronised; leaving it alone");
        return Ok(());
    }

    let pairs = choose(&options, seed())?;
    let sampled: Vec<String> = pairs.iter().map(|(_, s)| s.operator.clone()).collect();
    eprintln!(
        "asking {}",
        pairs
            .iter()
            .map(|(r, s)| format!("{} via {}", s.name, r.name))
            .collect::<Vec<_>>()
            .join(", ")
    );

    let collected = collect_answers(&options, &pairs);
    let seconds = quorum::decide(&sampled, &collected.answers, options.tolerance, options.floor)?;
    let window = common_window(&collected.windows);

    if options.dry_run {
        match reason_to_stand_down(&options, window)? {
            Some(reason) => println!("would leave the clock alone: {reason}"),
            None => println!("would set the clock to {seconds}"),
        }
        return Ok(());
    }

    if let Some(reason) = reason_to_stand_down(&options, window)? {
        println!("leaving the clock alone: {reason}");
        return Ok(());
    }

    set_clock(seconds)?;
    println!("clock set to {seconds}");
    Ok(())
}

/// Why the clock should be left as it is, or `None` if it should be stepped.
///
/// Both tests belong here rather than at the top of `run`, because both are about the state the
/// clock is in *now*, after the exchange, and the exchange takes seconds during which that state
/// can change.
fn reason_to_stand_down(
    options: &Options,
    window: Option<(i64, i64)>,
) -> Result<Option<String>, String> {
    if options.force {
        return Ok(None);
    }

    // Asked again, having also been asked before the exchange. That earlier check is only an
    // optimization -- it saves the exchange on a host whose clock is already fine -- and it
    // cannot cover the common case on its own: STA_UNSYNC is always set at boot, so on a warm
    // reboot the early check never fires, while chronyd starts alongside this program -- nothing
    // orders the two, see modules/time-sync.nix -- and with cached NTS cookies can synchronise in
    // well under a second. Without this, the exchange finishes moments later and overwrites an
    // accurate clock with a whole-second approximation of it.
    if clock_is_disciplined() {
        return Ok(Some(
            "something synchronised the clock while we were asking".to_string(),
        ));
    }

    let now = wall_clock()?;
    if !needs_setting(now, window) {
        let (not_before, not_after) = window.expect("needs_setting is true when there is no window");
        return Ok(Some(format!(
            "{now} is already inside the certificates' validity ({not_before}..{not_after}), so TLS works and chrony can correct the rest"
        )));
    }

    Ok(None)
}

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1)) {
        Ok(Action::Help) => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Ok(Action::CheckSynced) => {
            if clock_is_disciplined() {
                println!("the clock is synchronised");
                ExitCode::SUCCESS
            } else {
                println!("the clock is not synchronised");
                ExitCode::FAILURE
            }
        }
        Ok(Action::Run(options)) => match run(options) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            eprintln!("error: {e}\n\n{USAGE}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(items: &[&str]) -> Result<Action, String> {
        parse_args(items.iter().map(|s| s.to_string()))
    }

    const CF: &str = "cloudflare=cloudflare-dns.com@1.1.1.1,2606:4700:4700::1111";
    const Q9: &str = "quad9=dns10.quad9.net@9.9.9.10";
    const NTS_CF: &str = "cloudflare=time.cloudflare.com@cloudflare";
    const NTS_PTB1: &str = "ptb1=ptbtime1.ptb.de@ptb";
    const NTS_PTB2: &str = "ptb2=ptbtime2.ptb.de@ptb";

    fn full(extra: &[&str]) -> Vec<String> {
        let mut v = vec!["--doh", CF, "--doh", Q9, "--nts", NTS_CF, "--nts", NTS_PTB1];
        v.extend_from_slice(extra);
        v.into_iter().map(str::to_string).collect()
    }

    /// A parse that is expected to be runnable, from an exact argument list.
    fn run_options(items: &[&str]) -> Options {
        match parse(items).unwrap() {
            Action::Run(options) => options,
            other => panic!("expected a runnable action, got {other:?}"),
        }
    }

    /// The same, on top of the standard two-resolver two-operator configuration.
    fn options(extra: &[&str]) -> Options {
        run_options(
            &full(extra)
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn parses_both_populations() {
        let options = options(&[]);
        assert_eq!(options.resolvers.len(), 2);
        assert_eq!(options.resolvers[0].addresses.len(), 2);
        assert_eq!(options.servers.len(), 2);
        assert_eq!(options.servers[0].operator, "cloudflare");
    }

    #[test]
    fn defaults_match_the_documented_ones() {
        let options = options(&[]);
        assert_eq!(options.sample, 2);
        assert_eq!(options.tolerance, 60);
        assert_eq!(options.floor, 0);
        assert_eq!(options.timeout, Duration::from_secs(10));
        assert!(!options.force && !options.dry_run && options.only.is_none());
    }

    #[test]
    fn rejects_malformed_specs() {
        for spec in [
            "cloudflare",
            "cloudflare=cloudflare-dns.com",
            "=cloudflare-dns.com@1.1.1.1",
            "cloudflare=@1.1.1.1",
            "cloudflare=cloudflare-dns.com@",
            "cloudflare=cloudflare-dns.com@nope",
        ] {
            assert!(parse(&["--doh", spec]).is_err(), "{spec:?} should be rejected");
        }
        for spec in ["ptb1", "ptb1=ptbtime1.ptb.de", "=h@o", "ptb1=@o", "ptb1=h@"] {
            assert!(parse(&["--nts", spec]).is_err(), "{spec:?} should be rejected");
        }
    }

    #[test]
    fn requires_both_populations() {
        assert!(parse(&["--doh", CF]).is_err(), "no NTS server");
        assert!(parse(&["--nts", NTS_CF]).is_err(), "no DoH resolver");
    }

    #[test]
    fn a_sample_cannot_exceed_the_distinct_operators() {
        // The property the operator field exists for: ptb1 and ptb2 are two servers but one
        // source, so a sample of two cannot be satisfied by them alone.
        let two_ptb = vec!["--doh", CF, "--doh", Q9, "--nts", NTS_PTB1, "--nts", NTS_PTB2];
        let error = parse(&two_ptb).unwrap_err();
        assert!(error.contains("distinct NTS operators"), "{error}");

        // Adding a genuinely independent operator makes the same sample legal.
        let mixed = vec![
            "--doh", CF, "--doh", Q9, "--nts", NTS_PTB1, "--nts", NTS_PTB2, "--nts", NTS_CF,
        ];
        assert!(parse(&mixed).is_ok());
    }

    #[test]
    fn a_sample_cannot_exceed_the_resolvers() {
        let one_resolver = vec!["--doh", CF, "--nts", NTS_CF, "--nts", NTS_PTB1];
        let error = parse(&one_resolver).unwrap_err();
        assert!(error.contains("DoH resolvers"), "{error}");
    }

    #[test]
    fn rejects_only_naming_an_unconfigured_server() {
        assert!(parse_args(full(&["--only", "netnod"]).into_iter()).is_err());
        assert!(parse_args(full(&["--only", ""]).into_iter()).is_err());
        assert!(parse_args(full(&["--only", "ptb1"]).into_iter()).is_ok());
    }

    #[test]
    fn rejects_unknown_arguments_and_missing_values() {
        assert!(parse_args(full(&["--nope"]).into_iter()).is_err());
        assert!(parse_args(full(&["--tolerance"]).into_iter()).is_err());
        assert!(parse_args(full(&["--tolerance", "soon"]).into_iter()).is_err());
    }

    #[test]
    fn force_is_off_by_default() {
        // A default-on --force would overwrite a chrony-disciplined clock on every boot, which
        // is the one thing the adjtimex check exists to prevent.
        assert!(!options(&[]).force);
        assert!(options(&["--force"]).force);
    }

    #[test]
    fn help_and_check_synced_short_circuit_before_validation() {
        // Both are reachable with no --doh or --nts at all, which is the point: the unwedge unit
        // asks --check-synced about the kernel, not about any server.
        assert!(matches!(parse(&["--help"]), Ok(Action::Help)));
        assert!(matches!(
            parse(&["--check-synced"]),
            Ok(Action::CheckSynced)
        ));
    }

    #[test]
    fn a_clock_inside_the_certificates_validity_is_left_alone() {
        // The whole point of the rule: TLS already works at `now`, so there is nothing for this
        // program to fix and chrony can do the accurate correction itself.
        assert!(!needs_setting(150, Some((100, 200))));
        // The boundaries are inside. A certificate valid *at* an instant is valid, and treating
        // the edges as outside would step the clock for no reason on the one day per validity
        // period when it matters.
        assert!(!needs_setting(100, Some((100, 200))));
        assert!(!needs_setting(200, Some((100, 200))));
    }

    #[test]
    fn a_clock_outside_the_certificates_validity_is_set() {
        assert!(needs_setting(99, Some((100, 200))));
        assert!(needs_setting(201, Some((100, 200))));
        // The case this program exists for: an RTC-less host booting at the epoch.
        assert!(needs_setting(0, Some((1_785_000_000, 1_800_000_000))));
    }

    #[test]
    fn an_unknown_window_sets_the_clock() {
        // Not knowing whether the clock is good enough is not knowing that it is. The opposite
        // default would make any failure to read a validity window silently disable the step.
        assert!(needs_setting(150, None));
    }

    #[test]
    fn the_common_window_is_the_intersection_and_fails_closed() {
        assert_eq!(
            common_window(&[Some((100, 300)), Some((200, 400))]),
            Some((200, 300))
        );
        // One unknown poisons the result rather than dropping out of the intersection: an empty
        // intersection is `Some((i64::MIN, i64::MAX))`, so dropping unknowns would answer "every
        // instant is inside" precisely when least is known.
        assert_eq!(common_window(&[Some((100, 300)), None]), None);
        assert_eq!(common_window(&[]), None);
        // Disjoint windows have no common instant, so no clock can be inside them.
        assert_eq!(common_window(&[Some((100, 200)), Some((300, 400))]), None);
        assert!(needs_setting(
            150,
            common_window(&[Some((100, 200)), Some((300, 400))])
        ));
    }

    #[test]
    fn choosing_pairs_distinct_operators_with_distinct_resolvers() {
        let options = options(&[]);
        for seed in 0..200u64 {
            let pairs = choose(&options, seed).unwrap();
            assert_eq!(pairs.len(), 2);
            assert_ne!(
                pairs[0].1.operator, pairs[1].1.operator,
                "seed {seed} drew one operator twice"
            );
            assert_ne!(
                pairs[0].0.name, pairs[1].0.name,
                "seed {seed} routed both pairs through one resolver"
            );
        }
    }

    #[test]
    fn both_servers_of_an_operator_get_used() {
        // ptb1 and ptb2 are one operator, so they never appear together -- but each must be
        // reachable, or the second is dead weight and the redundancy it exists for (the first
        // being down) does not work. Regression: `.find()` used to return the first match
        // always, so ptb2 was configured, passed to the binary and never asked.
        let options = run_options(&[
            "--doh", CF, "--doh", Q9, "--nts", NTS_CF, "--nts", NTS_PTB1, "--nts", NTS_PTB2,
        ]);

        let mut seen: Vec<String> = Vec::new();
        for seed in 0..500u64 {
            for (_, server) in choose(&options, seed).unwrap() {
                if !seen.contains(&server.name) {
                    seen.push(server.name);
                }
            }
        }
        seen.sort();
        assert_eq!(
            seen,
            vec!["cloudflare".to_string(), "ptb1".to_string(), "ptb2".to_string()],
            "every configured server should be reachable by some draw"
        );
    }

    #[test]
    fn one_operator_never_appears_twice_in_a_draw() {
        // The other half, kept separate so neither property can be traded for the other: now
        // that a draw picks among an operator's servers, it must still never pick two servers
        // belonging to the same operator.
        let options = run_options(&[
            "--doh", CF, "--doh", Q9, "--nts", NTS_CF, "--nts", NTS_PTB1, "--nts", NTS_PTB2,
        ]);
        for seed in 0..500u64 {
            let pairs = choose(&options, seed).unwrap();
            assert_eq!(pairs.len(), 2);
            assert_ne!(
                pairs[0].1.operator, pairs[1].1.operator,
                "seed {seed} drew one operator twice"
            );
        }
    }

    #[test]
    fn only_bypasses_sampling() {
        let options = options(&["--only", "ptb1"]);
        let pairs = choose(&options, 7).unwrap();
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].1.name, "ptb1");
    }

    #[test]
    fn one_operator_with_two_servers_yields_one_choice() {
        // Sampling draws operators, so a pool of ptb1+ptb2 can only ever produce one pair --
        // which is what makes the --sample check above a real constraint rather than advice.
        let options = run_options(&[
            "--doh", CF, "--doh", Q9, "--nts", NTS_PTB1, "--nts", NTS_PTB2, "--sample", "1",
        ]);
        let pairs = choose(&options, 3).unwrap();
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].1.operator, "ptb");
    }
}
