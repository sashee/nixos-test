//! dep-report: how stale every dependency is, across this repository and, recursively, every
//! repository it pins whose owner is on the allowlist.
//!
//! A run is three steps, each in a tighter sandbox than the last (see sandbox.rs):
//! 1. outside: resolve paths, then re-execute inside bwrap;
//! 2. walk (Landlock stage 1): `nix flake archive` and `fetchTarball` for the trees, scanning,
//!    `cargo update --dry-run` and `cargo audit` per lockfile;
//! 3. look up and report (Landlock stage 2 + seccomp): GitHub and crates.io, then the text file.

mod actions;
mod args;
mod audit;
mod cache;
mod cargo;
mod date;
mod discover;
mod flake_lock;
mod gitconfig;
mod http;
mod lookups;
mod nix;
mod pins;
mod probe;
mod repo;
mod report;
mod sandbox;
mod scan;

use std::env;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use args::{Options, Parsed};
use cache::Cache;
use discover::{CargoRunner, Walk};
use http::{Fetcher, Service, Stats};
use repo::RepoId;
use sandbox::Layout;

/// Store paths baked in by package.nix, so the binary runs exactly the bwrap and Cargo it was
/// built against. A plain `cargo build` falls back to `PATH`.
const BWRAP: Option<&str> = option_env!("DEP_REPORT_BWRAP");
const CARGO: Option<&str> = option_env!("DEP_REPORT_CARGO");
const RUSTC: Option<&str> = option_env!("DEP_REPORT_RUSTC");
const CARGO_AUDIT: Option<&str> = option_env!("DEP_REPORT_CARGO_AUDIT");

const CACHE_TTL: i64 = 6 * 3600;

fn log(msg: &str) {
    eprintln!("dep-report: {msg}");
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

fn find_in_path(name: &str) -> Option<PathBuf> {
    env::var_os("PATH").and_then(|path| env::split_paths(&path).map(|dir| dir.join(name)).find(|p| p.is_file()))
}

fn tool(baked: Option<&str>, name: &str) -> Result<PathBuf, String> {
    let path = baked.map(PathBuf::from).or_else(|| find_in_path(name)).ok_or(format!("`{name}` not found"))?;
    path.canonicalize().map_err(|e| format!("{}: {e}", path.display()))
}

fn ca_file() -> Option<PathBuf> {
    let from_env = ["SSL_CERT_FILE", "NIX_SSL_CERT_FILE"].iter().filter_map(env::var_os).map(PathBuf::from);
    let known = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"].map(PathBuf::from);
    from_env.chain(known).find_map(|p| p.canonicalize().ok())
}

fn cache_root() -> Result<PathBuf, String> {
    env::var_os("XDG_CACHE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .map(|base| base.join("dep-report"))
        .ok_or("neither XDG_CACHE_HOME nor HOME is set".to_string())
}

/// Resolves every path once, outside the sandbox, creating the directories it will write to.
fn layout(opts: &Options) -> Result<Layout, String> {
    let cwd = env::current_dir().map_err(|e| format!("current directory: {e}"))?;
    let checkout = opts.flake.clone().unwrap_or_else(|| cwd.clone());
    let checkout = checkout.canonicalize().map_err(|e| format!("{}: {e}", checkout.display()))?;
    if !checkout.join("flake.nix").is_file() {
        return Err(format!("{} has no flake.nix", checkout.display()));
    }
    let output = opts.output.as_ref().map_or_else(|| checkout.join("results/dep-report.txt"), |o| cwd.join(o));
    let (Some(dir), Some(file)) = (output.parent(), output.file_name()) else {
        return Err(format!("--output: not a file path: {}", output.display()));
    };
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let output = dir.canonicalize().map_err(|e| format!("{}: {e}", dir.display()))?.join(file);
    let cache = cache_root()?;
    fs::create_dir_all(&cache).map_err(|e| format!("{}: {e}", cache.display()))?;
    let git_dirs = gitconfig::locate(&checkout)
        .map(|g| [g.git_dir, g.common_dir].into_iter().filter(|d| !d.starts_with(&checkout)).collect())
        .unwrap_or_default();
    let layout = Layout {
        checkout,
        git_dirs,
        output,
        cache: cache.canonicalize().map_err(|e| format!("{}: {e}", cache.display()))?,
        nix: tool(None, "nix")?,
        cargo: tool(CARGO, "cargo")?,
        rustc: tool(RUSTC, "rustc")?,
        cargo_audit: tool(CARGO_AUDIT, "cargo-audit")?,
        ca_file: ca_file(),
        resolv: Path::new("/etc/resolv.conf").canonicalize().ok(),
    };
    for dir in layout.subdirs() {
        fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    Ok(layout)
}

/// Re-executes this binary inside bwrap; returns only if that fails.
fn enter_bwrap(layout: &Layout) -> String {
    let exe = match env::current_exe().and_then(|p| p.canonicalize()) {
        Ok(exe) => exe,
        Err(e) => return format!("own executable: {e}"),
    };
    let bwrap = match tool(BWRAP, "bwrap") {
        Ok(b) => b,
        Err(e) => return e,
    };
    let sockets: Vec<PathBuf> = [sandbox::DAEMON_SOCKET_DIR, sandbox::NSCD_DIR].iter().map(PathBuf::from).filter(|p| p.exists()).collect();
    let mut inner: Vec<String> = env::args().skip(1).collect();
    let json = match serde_json::to_string(layout) {
        Ok(json) => json,
        Err(e) => return e.to_string(),
    };
    inner.extend(["--layout".to_string(), json]);
    let err = Command::new(&bwrap).args(sandbox::bwrap_args(layout, &sandbox::host_root(), &sockets, &exe, &inner)).exec();
    format!("{}: {err}", bwrap.display())
}

fn root_repo(opts: &Options, layout: &Layout) -> Result<RepoId, String> {
    if let Some(repo) = &opts.root_repo {
        return Ok(repo.clone());
    }
    gitconfig::locate(&layout.checkout)
        .and_then(|dirs| fs::read_to_string(dirs.common_dir.join("config")).ok())
        .and_then(|config| gitconfig::origin_url(&config))
        .and_then(|url| repo::parse_remote_url(&url))
        .ok_or_else(|| format!("cannot tell which GitHub repository {} is; pass --root-repo OWNER/REPO", layout.checkout.display()))
}

fn write_report(path: &Path, text: &str) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, text).and_then(|()| fs::rename(&tmp, path)).map_err(|e| format!("{}: {e}", path.display()))
}

fn run(opts: &Options, layout: &Layout) -> Result<ExitCode, String> {
    if opts.probe_sandbox {
        return Ok(if probe::run(layout)? { ExitCode::SUCCESS } else { ExitCode::FAILURE });
    }
    let started = now();
    let one = sandbox::enforce(&sandbox::stage_one(layout))?;
    sandbox::seccomp_stage_one()?;
    if one != landlock::RulesetStatus::FullyEnforced {
        log(&format!("landlock {}", sandbox::describe(&one)));
    }
    let root = root_repo(opts, layout)?;
    let owners = if opts.owners.is_empty() { vec![root.owner.clone()] } else { opts.owners.clone() };
    let cache = |dir: PathBuf| Cache { dir, now: started, ttl: CACHE_TTL, read: !opts.no_cache };

    let nix = nix::Nix { bin: &layout.nix, env: sandbox::child_env(layout) };
    let cargo = CargoRunner {
        cargo: &layout.cargo,
        rustc: &layout.rustc,
        cargo_audit: &layout.cargo_audit,
        cargo_home: layout.cargo_home(),
        cwd: layout.empty(),
        env: sandbox::child_env(layout),
        cache: cache(layout.cargo_cache()),
    };
    log(&format!("nix flake archive {}", layout.checkout.display()));
    let archive = nix.archive(&layout.checkout)?;
    let walk = Walk {
        fetch_tarball: &|expr| nix.fetch_tarball(expr),
        dry_run: &|manifest| cargo.dry_run(manifest),
        audit: &|lockfile| cargo.audit(lockfile),
        root_repo: root.clone(),
        owners: owners.clone(),
        max_depth: opts.depth,
        log: &log,
    };
    let tree = walk.run(&archive);

    sandbox::enforce(&sandbox::stage_two(layout))?;
    sandbox::seccomp_stage_two()?;
    let mut last_crates_io: Option<Instant> = None;
    let mut fetcher = Fetcher {
        transport: Box::new(http::Ureq::new(&format!("dep-report (https://github.com/{root})"))),
        cache: cache(layout.http_cache()),
        // crates.io's crawler policy: at most one request a second.
        pace: Box::new(move |service| {
            if service == Service::CratesIo {
                if let Some(last) = last_crates_io {
                    std::thread::sleep(Duration::from_secs(1).saturating_sub(last.elapsed()));
                }
                last_crates_io = Some(Instant::now());
            }
        }),
        stats: Stats::default(),
    };
    let answers = lookups::fetch_all(&tree, opts.transitive, &mut fetcher, &log);
    let ctx = report::Context { answers: &answers, now: started, transitive: opts.transitive };
    let text = report::render(&ctx, &tree, &root, &owners, &fetcher.stats);
    write_report(&layout.output, &text)?;
    // The report on stdout, progress on stderr: `dep-report | less` shows just the report.
    print!("{text}");
    log(&format!("wrote {}", layout.output.display()));
    Ok(ExitCode::SUCCESS)
}

fn main() -> ExitCode {
    let opts = match args::parse(env::args().skip(1)) {
        Ok(Parsed::Help) => {
            print!("{}", args::USAGE);
            return ExitCode::SUCCESS;
        }
        Ok(Parsed::Run(opts)) => opts,
        Err(e) => {
            log(&e);
            return ExitCode::from(2);
        }
    };
    let result = match &opts.layout {
        Some(json) => serde_json::from_str::<Layout>(json).map_err(|e| format!("--layout: {e}")).and_then(|l| run(&opts, &l)),
        None => layout(&opts).and_then(|l| if opts.no_bwrap { run(&opts, &l) } else { Err(enter_bwrap(&l)) }),
    };
    result.unwrap_or_else(|e| {
        log(&e);
        ExitCode::FAILURE
    })
}
