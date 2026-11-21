//! Confinement, in three layers, so code from a compromised dependency of this program runs with
//! as little of the user's access as the work needs:
//!
//! 1. bwrap (outer): a fresh mount namespace holding only the store, /usr, /etc, the checkout
//!    (read-only), the cache and the output directory, plus private /proc, /dev and /tmp, a
//!    cleared environment and no further user namespaces. Home, other processes, /run and the
//!    session's sockets are not there at all.
//! 2. Landlock stage 1 (`stage_one`), applied in-process before any work: what Nix, Cargo and
//!    cargo-audit need. Execute only from the store and /usr; write only the cache and output directory;
//!    TCP out to 443 and 53 only; pathname unix sockets only the nix daemon's (and nscd's);
//!    no abstract unix sockets or signals outside the sandbox.
//! 3. Landlock stage 2 + seccomp (`stage_two`), stacked on stage 1 once Nix and Cargo are done
//!    and before the first HTTP request: nothing may be executed at all, writes go only to the
//!    HTTP cache and the output directory, and sockets other than IPv4/IPv6 cannot be created.
//!    The TLS/HTTP/JSON stack, the largest attack surface here, only ever runs in this stage.
//!
//! Landlock and seccomp attach to the calling thread and are inherited by threads and children
//! created later, so both are applied while the program is still single-threaded (no async
//! runtime; ureq is blocking). Landlock ABI 6 (Linux 6.12) is a hard requirement; the unix-socket
//! (ABI 9) and UDP (ABI 10) rules are applied when the kernel has them.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use landlock::{
    ABI, Access, AccessFs, AccessNet, BitFlags, CompatLevel, Compatible, NetPort, Ruleset, RulesetAttr,
    RulesetCreatedAttr, RulesetError, RulesetStatus, Scope, make_bitflags, path_beneath_rules,
};
use seccompiler::{BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter, SeccompRule, TargetArch};
use serde::{Deserialize, Serialize};

/// Every path the sandbox is built from, resolved once outside it and handed to the inside.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Layout {
    pub checkout: PathBuf,
    /// The checkout's git directories when they live outside it (linked worktrees).
    pub git_dirs: Vec<PathBuf>,
    pub output: PathBuf,
    pub cache: PathBuf,
    pub nix: PathBuf,
    pub cargo: PathBuf,
    pub rustc: PathBuf,
    pub cargo_audit: PathBuf,
    pub ca_file: Option<PathBuf>,
    /// Where /etc/resolv.conf really is (systemd-resolved points it into /run).
    pub resolv: Option<PathBuf>,
}

impl Layout {
    pub fn output_dir(&self) -> PathBuf {
        self.output.parent().map(Path::to_path_buf).unwrap_or_default()
    }
    pub fn http_cache(&self) -> PathBuf {
        self.cache.join("http")
    }
    pub fn cargo_cache(&self) -> PathBuf {
        self.cache.join("cargo")
    }
    pub fn cargo_home(&self) -> PathBuf {
        self.cache.join("cargo-home")
    }
    /// HOME for Nix and Cargo. Nix keeps its fetcher cache under it; sharing the user's real
    /// ~/.cache/nix read-write would let a compromised process poison what later, unsandboxed
    /// Nix runs resolve URLs to.
    pub fn home(&self) -> PathBuf {
        self.cache.join("home")
    }
    pub fn tmp(&self) -> PathBuf {
        self.cache.join("tmp")
    }
    /// Cargo's working directory: empty, so no `.cargo/config.toml` above it can name programs
    /// for Cargo to run.
    pub fn empty(&self) -> PathBuf {
        self.cache.join("empty")
    }
    pub fn subdirs(&self) -> [PathBuf; 6] {
        [self.http_cache(), self.cargo_cache(), self.cargo_home(), self.home(), self.tmp(), self.empty()]
    }
}

/// The environment Nix and Cargo run with; nothing of the caller's is inherited.
pub fn child_env(layout: &Layout) -> Vec<(String, String)> {
    let dirs: Vec<String> = [&layout.nix, &layout.cargo]
        .iter()
        .filter_map(|p| p.parent())
        .map(|d| d.display().to_string())
        .collect();
    let mut env = vec![
        ("HOME".to_string(), layout.home().display().to_string()),
        ("TMPDIR".to_string(), layout.tmp().display().to_string()),
        ("PATH".to_string(), dirs.join(":")),
        // Inside bwrap /nix/var/nix is an empty, writable tmpfs directory, which Nix's `auto`
        // store takes for a store it owns. The store is the daemon's; a single-user install
        // (no daemon) cannot work in here anyway, since /nix/store is read-only.
        ("NIX_REMOTE".to_string(), "daemon".to_string()),
    ];
    if let Some(ca) = &layout.ca_file {
        env.push(("SSL_CERT_FILE".to_string(), ca.display().to_string()));
        env.push(("NIX_SSL_CERT_FILE".to_string(), ca.display().to_string()));
    }
    env
}

/// What the host's root holds at `/bin`, `/lib`, ...: a merged-/usr symlink or a real directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RootEntry {
    Link { path: String, target: String },
    Dir(String),
}

pub fn host_root() -> Vec<RootEntry> {
    ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/lib32"]
        .iter()
        .filter_map(|path| match std::fs::read_link(path) {
            Ok(target) => Some(RootEntry::Link { path: path.to_string(), target: target.display().to_string() }),
            Err(_) if Path::new(path).is_dir() => Some(RootEntry::Dir(path.to_string())),
            Err(_) => None,
        })
        .collect()
}

/// Sockets Nix needs that may or may not exist on this host.
pub const DAEMON_SOCKET_DIR: &str = "/nix/var/nix/daemon-socket";
pub const NSCD_DIR: &str = "/run/nscd";

fn covered(path: &Path) -> bool {
    ["/etc", "/nix/store", "/usr"].iter().any(|base| path.starts_with(base))
}

pub fn bwrap_args(layout: &Layout, root: &[RootEntry], existing_sockets: &[PathBuf], exe: &Path, inner: &[String]) -> Vec<String> {
    let s = |v: &str| v.to_string();
    let p = |v: &Path| v.display().to_string();
    let mut args: Vec<String> = [
        "--unshare-all", "--share-net", "--unshare-user", "--disable-userns", "--die-with-parent", "--new-session",
        "--cap-drop", "ALL", "--clearenv", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
        "--ro-bind", "/nix/store", "/nix/store", "--ro-bind", "/etc", "/etc",
    ]
    .map(s)
    .to_vec();
    for entry in root {
        match entry {
            RootEntry::Link { path, target } => args.extend([s("--symlink"), target.clone(), path.clone()]),
            RootEntry::Dir(path) => args.extend([s("--ro-bind"), path.clone(), path.clone()]),
        }
    }
    let read_only = existing_sockets
        .iter()
        .chain(layout.resolv.iter().filter(|r| !covered(r)))
        .chain(layout.ca_file.iter().filter(|c| !covered(c)))
        .chain([&layout.checkout])
        .chain(layout.git_dirs.iter());
    for path in read_only {
        args.extend([s("--ro-bind"), p(path), p(path)]);
    }
    // After the checkout, so an output directory inside it is writable.
    for path in [layout.cache.clone(), layout.output_dir()] {
        args.extend([s("--bind"), p(&path), p(&path)]);
    }
    for (key, value) in child_env(layout) {
        args.extend([s("--setenv"), key, value]);
    }
    args.extend([s("--chdir"), p(&layout.checkout), s("--"), p(exe)]);
    args.extend(inner.iter().cloned());
    args
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Stage {
    pub read_exec: Vec<PathBuf>,
    pub read: Vec<PathBuf>,
    pub read_write: Vec<PathBuf>,
    /// Pathname unix sockets that may be connected to, beneath these.
    pub unix: Vec<PathBuf>,
    pub tcp: Vec<u16>,
    pub udp: Vec<u16>,
}

fn system_libs() -> Vec<PathBuf> {
    ["/nix/store", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/lib32"].map(PathBuf::from).to_vec()
}

/// What Nix and Cargo need: the walk.
pub fn stage_one(layout: &Layout) -> Stage {
    let mut read_exec = system_libs();
    read_exec.extend(layout.nix.parent().map(Path::to_path_buf));
    // /proc: Nix's garbage collector (Boehm) finds the main thread's stack through
    // /proc/self/maps and warns, then scans less, without it. A rule cannot name "the calling
    // process's own entry" (it is resolved once, to this pid, not Nix's), so it is /proc whole:
    // inside bwrap that holds only the sandbox's own processes; under --no-bwrap it is the
    // host's, for this stage only.
    let fixed = ["/etc", "/proc"].map(PathBuf::from);
    Stage {
        read_exec,
        read: [vec![layout.checkout.clone()], fixed.to_vec(), layout.git_dirs.clone(), layout.resolv.iter().cloned().collect(),
            layout.ca_file.iter().cloned().collect()]
            .concat(),
        read_write: vec![layout.cache.clone(), layout.output_dir(), PathBuf::from("/dev/null")],
        unix: vec![PathBuf::from(DAEMON_SOCKET_DIR), PathBuf::from(NSCD_DIR)],
        tcp: vec![443, 53],
        udp: vec![53],
    }
}

/// What the lookups and the report need, stacked on stage one.
pub fn stage_two(layout: &Layout) -> Stage {
    let etc = ["/etc/hosts", "/etc/nsswitch.conf", "/etc/host.conf", "/etc/gai.conf"].map(PathBuf::from);
    Stage {
        read_exec: Vec::new(),
        read: [system_libs(), etc.to_vec(), layout.resolv.iter().cloned().collect(), layout.ca_file.iter().cloned().collect()].concat(),
        read_write: vec![layout.http_cache(), layout.output_dir(), PathBuf::from("/dev/null")],
        unix: Vec::new(),
        tcp: vec![443, 53],
        udp: vec![53],
    }
}

fn read_access() -> BitFlags<AccessFs> {
    make_bitflags!(AccessFs::{ReadFile | ReadDir})
}

fn ruleset_error(e: RulesetError) -> String {
    format!("landlock: {e}")
}

/// Applies a stage's Landlock ruleset to this thread and everything it starts from now on.
pub fn enforce(stage: &Stage) -> Result<RulesetStatus, String> {
    let fs_all = AccessFs::from_all(ABI::V6);
    let write = fs_all & !BitFlags::from(AccessFs::Execute);
    let udp = make_bitflags!(AccessNet::{BindUdp | ConnectSendUdp});
    let ruleset = Ruleset::default()
        .set_compatibility(CompatLevel::HardRequirement)
        .handle_access(fs_all)
        .and_then(|r| r.handle_access(AccessNet::from_all(ABI::V6)))
        .and_then(|r| r.scope(Scope::from_all(ABI::V6)))
        .map(|r| r.set_compatibility(CompatLevel::BestEffort))
        .and_then(|r| r.handle_access(AccessFs::ResolveUnix))
        .and_then(|r| r.handle_access(udp))
        .and_then(Ruleset::create)
        .map_err(ruleset_error)?;
    let tcp = stage.tcp.iter().map(|port| Ok::<_, RulesetError>(NetPort::new(*port, AccessNet::ConnectTcp)));
    let udp_rules = stage.udp.iter().map(|port| Ok::<_, RulesetError>(NetPort::new(*port, AccessNet::ConnectSendUdp)));
    // Port 0: the ephemeral port the kernel binds an unbound UDP socket to on its first send.
    let udp_bind = (!stage.udp.is_empty()).then(|| Ok::<_, RulesetError>(NetPort::new(0, AccessNet::BindUdp)));
    let status = ruleset
        .add_rules(path_beneath_rules(&stage.read_exec, read_access() | AccessFs::Execute))
        .and_then(|r| r.add_rules(path_beneath_rules(&stage.read, read_access())))
        .and_then(|r| r.add_rules(path_beneath_rules(&stage.read_write, write)))
        .and_then(|r| r.add_rules(path_beneath_rules(&stage.unix, AccessFs::ResolveUnix)))
        .and_then(|r| r.add_rules(tcp))
        .and_then(|r| r.add_rules(udp_rules))
        .and_then(|r| r.add_rules(udp_bind))
        .and_then(|r| r.restrict_self())
        .map_err(ruleset_error)?;
    if !status.no_new_privs {
        return Err("landlock: no_new_privs was not set".into());
    }
    Ok(status.ruleset)
}

/// Syscalls neither Nix, Cargo nor this program has any use for, and that a compromised one
/// would: debugging other processes, kernel-level sandbox escapes, new namespaces, and io_uring,
/// whose operations seccomp cannot see.
fn denied_always() -> Vec<i64> {
    vec![
        libc::SYS_ptrace, libc::SYS_process_vm_readv, libc::SYS_process_vm_writev, libc::SYS_bpf,
        libc::SYS_perf_event_open, libc::SYS_userfaultfd, libc::SYS_keyctl, libc::SYS_add_key, libc::SYS_request_key,
        libc::SYS_mount, libc::SYS_umount2, libc::SYS_pivot_root, libc::SYS_unshare, libc::SYS_setns,
        libc::SYS_io_uring_setup, libc::SYS_io_uring_enter, libc::SYS_io_uring_register, libc::SYS_open_by_handle_at,
        libc::SYS_name_to_handle_at, libc::SYS_kexec_load, libc::SYS_init_module, libc::SYS_finit_module,
    ]
}

fn apply_seccomp(rules: BTreeMap<i64, Vec<SeccompRule>>) -> Result<(), String> {
    let arch = TargetArch::try_from(std::env::consts::ARCH).map_err(|e| format!("seccomp: {e}"))?;
    let filter = SeccompFilter::new(rules, SeccompAction::Allow, SeccompAction::Errno(libc::EPERM as u32), arch)
        .map_err(|e| format!("seccomp: {e}"))?;
    let program: BpfProgram = filter.try_into().map_err(|e| format!("seccomp: {e:?}"))?;
    seccompiler::apply_filter(&program).map_err(|e| format!("seccomp: {e}"))
}

pub fn seccomp_stage_one() -> Result<(), String> {
    apply_seccomp(denied_always().into_iter().map(|nr| (nr, Vec::new())).collect())
}

/// Stacked on stage one's filter: no exec at all, and only IPv4/IPv6 sockets (so no unix socket
/// to the nix daemon, D-Bus or nscd, whatever the Landlock ABI).
pub fn seccomp_stage_two() -> Result<(), String> {
    let not_family = |family: i32| {
        SeccompCondition::new(0, SeccompCmpArgLen::Dword, SeccompCmpOp::Ne, family as u64).map_err(|e| format!("seccomp: {e}"))
    };
    let other_family = SeccompRule::new(vec![not_family(libc::AF_INET)?, not_family(libc::AF_INET6)?])
        .map_err(|e| format!("seccomp: {e}"))?;
    let rules = BTreeMap::from([
        (libc::SYS_execve, Vec::new()),
        (libc::SYS_execveat, Vec::new()),
        (libc::SYS_socket, vec![other_family]),
    ]);
    apply_seccomp(rules)
}

pub fn describe(status: &RulesetStatus) -> &'static str {
    match status {
        RulesetStatus::FullyEnforced => "fully enforced",
        RulesetStatus::PartiallyEnforced => {
            "enforced without the unix-socket (ABI 9) or UDP (ABI 10) rules: this kernel's Landlock predates them"
        }
        RulesetStatus::NotEnforced => "NOT enforced",
    }
}

pub fn errno_name(e: &io::Error) -> String {
    match e.raw_os_error() {
        Some(libc::EACCES) => "EACCES".into(),
        Some(libc::EPERM) => "EPERM".into(),
        Some(libc::EROFS) => "EROFS".into(),
        Some(libc::ENOENT) => "ENOENT".into(),
        Some(libc::ECONNREFUSED) => "ECONNREFUSED".into(),
        _ => e.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout() -> Layout {
        Layout {
            checkout: "/home/u/nixos-test".into(),
            git_dirs: vec![],
            output: "/home/u/nixos-test/results/dep-report.txt".into(),
            cache: "/home/u/.cache/dep-report".into(),
            nix: "/usr/bin/nix".into(),
            cargo: "/nix/store/c-cargo/bin/cargo".into(),
            rustc: "/nix/store/r-rustc/bin/rustc".into(),
            cargo_audit: "/nix/store/a-cargo-audit/bin/cargo-audit".into(),
            ca_file: Some("/etc/ca-certificates/extracted/tls-ca-bundle.pem".into()),
            resolv: Some("/run/systemd/resolve/stub-resolv.conf".into()),
        }
    }

    #[test]
    fn bwrap_binds_only_what_the_run_needs() {
        let root = vec![RootEntry::Dir("/usr".into()), RootEntry::Link { path: "/lib64".into(), target: "usr/lib".into() }];
        let args = bwrap_args(&layout(), &root, &[PathBuf::from(DAEMON_SOCKET_DIR)], Path::new("/nix/store/d-dep-report/bin/dep-report"),
            &["--layout".into(), "{}".into()]);
        let joined = args.join(" ");
        for expected in ["--unshare-all --share-net --unshare-user --disable-userns", "--clearenv", "--symlink usr/lib /lib64",
            "--ro-bind /usr /usr", "--ro-bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket",
            "--ro-bind /run/systemd/resolve/stub-resolv.conf /run/systemd/resolve/stub-resolv.conf",
            "--ro-bind /home/u/nixos-test /home/u/nixos-test --bind /home/u/.cache/dep-report /home/u/.cache/dep-report --bind /home/u/nixos-test/results /home/u/nixos-test/results",
            "--setenv HOME /home/u/.cache/dep-report/home", "--setenv PATH /usr/bin:/nix/store/c-cargo/bin",
            "-- /nix/store/d-dep-report/bin/dep-report --layout {}"]
        {
            assert!(joined.contains(expected), "missing `{expected}` in\n{joined}");
        }
        assert!(!joined.contains("--ro-bind /etc/ca-certificates"), "under /etc, which is bound whole");
        assert!(!joined.contains("/home/u "), "home itself is never bound");
    }

    #[test]
    fn stage_two_narrows_stage_one() {
        let (one, two) = (stage_one(&layout()), stage_two(&layout()));
        assert!(two.read_exec.is_empty(), "nothing is executable in stage two");
        assert!(two.unix.is_empty());
        assert!(!two.read.contains(&layout().checkout), "the checkout was scanned in stage one");
        assert!(two.read_write.iter().all(|p| one.read_write.iter().any(|q| p.starts_with(q))),
            "stage two can only narrow: its writable paths must be inside stage one's");
        assert_eq!(two.tcp, [443, 53]);
    }
}
