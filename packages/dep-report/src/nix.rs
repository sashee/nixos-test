//! The two Nix calls the walk makes: `nix flake archive --json` on the root checkout (store paths
//! of the root and every input at its locked commit) and `builtins.fetchTarball` for a commit pin
//! found in a scanned tree. Trees are only ever read from the store, so a repository is scanned
//! at the commit that is pinned, never at its HEAD, and nothing is cloned.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use crate::pins::{archive_url, valid_hash};
use crate::repo::{RepoId, is_full_sha};

#[derive(Debug, PartialEq, Eq)]
pub struct Archive {
    pub path: PathBuf,
    /// Direct inputs only: what the root's flake.lock rows point at.
    pub inputs: BTreeMap<String, PathBuf>,
}

fn store_path(v: Option<&Value>) -> Result<PathBuf, String> {
    let p = v.and_then(Value::as_str).ok_or("missing `path`")?;
    // Everything scanned must come out of the store: it is the only tree the sandbox can read.
    if !p.starts_with("/nix/store/") || p.contains("/../") {
        return Err(format!("not a store path: {p}"));
    }
    Ok(PathBuf::from(p))
}

pub fn parse_archive(json: &str) -> Result<Archive, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("nix flake archive output: {e}"))?;
    let inputs = v
        .get("inputs")
        .and_then(Value::as_object)
        .map(|inputs| {
            inputs.iter().map(|(name, i)| store_path(i.get("path")).map(|p| (name.clone(), p))).collect()
        })
        .transpose()?
        .unwrap_or_default();
    Ok(Archive { path: store_path(v.get("path"))?, inputs })
}

/// A `builtins.fetchTarball` expression for a GitHub commit. Every piece interpolated into it is
/// validated first: repository names by `RepoId`, the commit as 40 lowercase hex digits, the hash
/// by its encoding. The pins come from files in other repositories, so this is the line between
/// "a string read from a file" and "Nix code that runs".
pub fn fetch_tarball_expr(repo: &RepoId, rev: &str, sha256: Option<&str>) -> Result<String, String> {
    if !is_full_sha(rev) {
        return Err(format!("not a commit hash: {rev}"));
    }
    let url = archive_url(repo, rev);
    match sha256 {
        Some(hash) if !valid_hash(hash) => Err(format!("not a sha256: {hash}")),
        Some(hash) => Ok(format!("builtins.fetchTarball {{ url = \"{url}\"; sha256 = \"{hash}\"; }}")),
        None => Ok(format!("builtins.fetchTarball \"{url}\"")),
    }
}

pub struct Nix<'a> {
    pub bin: &'a Path,
    /// The whole environment: the caller's is never inherited.
    pub env: Vec<(String, String)>,
}

impl Nix<'_> {
    fn command(&self) -> Command {
        let mut cmd = Command::new(self.bin);
        cmd.env_clear().envs(self.env.iter().map(|(k, v)| (k, v)));
        cmd.args(["--extra-experimental-features", "nix-command flakes"]);
        cmd
    }

    pub fn archive(&self, flake: &Path) -> Result<Archive, String> {
        let mut cmd = self.command();
        cmd.args(["flake", "archive", "--json", "--no-warn-dirty"]).arg(flake);
        parse_archive(&run(cmd)?)
    }

    pub fn fetch_tarball(&self, expr: &str) -> Result<PathBuf, String> {
        let mut cmd = self.command();
        cmd.args(["eval", "--impure", "--raw", "--expr", expr]);
        store_path(Some(&Value::String(run(cmd)?.trim().to_string())))
    }
}

/// stdout of a successful run; otherwise the tail of stderr, which is where the reason is.
pub fn run(mut cmd: Command) -> Result<String, String> {
    let program = cmd.get_program().to_string_lossy().into_owned();
    let out = cmd.output().map_err(|e| format!("{program}: {e}"))?;
    if out.status.success() {
        return String::from_utf8(out.stdout).map_err(|e| format!("{program}: {e}"));
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    let tail: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
    Err(format!("{program} failed ({}): {}", out.status, tail[tail.len().saturating_sub(3)..].join(" | ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_json_shape() {
        let json = r#"{"inputs":{"dotfiles":{"inputs":{},"path":"/nix/store/vh4i-source"},
            "nixos-raspberrypi":{"inputs":{"nixpkgs":{"inputs":{},"path":"/nix/store/cjnd-source"}},
            "path":"/nix/store/s4s4-source"}},"path":"/nix/store/n9mz-source"}"#;
        let archive = parse_archive(json).unwrap();
        assert_eq!(archive.path, PathBuf::from("/nix/store/n9mz-source"));
        assert_eq!(archive.inputs.keys().collect::<Vec<_>>(), ["dotfiles", "nixos-raspberrypi"]);
        assert!(parse_archive(r#"{"path":"/home/x"}"#).is_err());
        assert!(parse_archive(r#"{"path":"/nix/store/../../etc"}"#).is_err());
    }

    #[test]
    fn expressions() {
        let repo = RepoId::new("sashee", "e2ee-store").unwrap();
        let rev = "09f0d147377d6f31b4a90e3420ecd500da6d85cd";
        let hash = "134kapvp02fdmvp80lsx20dg6nc3i7fzhm6v9kc75756v09sp8a4";
        assert_eq!(fetch_tarball_expr(&repo, rev, Some(hash)).unwrap(),
            format!("builtins.fetchTarball {{ url = \"https://github.com/sashee/e2ee-store/archive/{rev}.tar.gz\"; sha256 = \"{hash}\"; }}"));
        assert_eq!(fetch_tarball_expr(&repo, rev, None).unwrap(),
            format!("builtins.fetchTarball \"https://github.com/sashee/e2ee-store/archive/{rev}.tar.gz\""));
        assert!(fetch_tarball_expr(&repo, "HEAD", None).is_err());
        assert!(fetch_tarball_expr(&repo, rev, Some("\"; builtins.readFile /etc/passwd; \"")).is_err());
    }
}
