//! Which GitHub repository the root checkout is, read from its git config.
//!
//! The walk must know the root's identity before it fetches anything: pw-mgr and media-store pin
//! older commits of the root for a dev tool, and those pins are reported but never fetched or
//! scanned. Reading `.git/config` directly instead of running `git` keeps git out of the sandbox.

use std::fs;
use std::path::{Path, PathBuf};

/// The checkout's git directory and the common directory its config lives in. They differ for a
/// linked worktree, where `.git` is a file pointing into the main checkout's `.git/worktrees/`.
#[derive(Debug, PartialEq, Eq)]
pub struct GitDirs {
    pub git_dir: PathBuf,
    pub common_dir: PathBuf,
}

pub fn locate(checkout: &Path) -> Option<GitDirs> {
    let dot_git = checkout.join(".git");
    let git_dir = if dot_git.is_dir() {
        dot_git
    } else {
        let pointer = fs::read_to_string(&dot_git).ok()?;
        let target = PathBuf::from(pointer.trim().strip_prefix("gitdir:")?.trim());
        checkout.join(target)
    };
    let common_dir = match fs::read_to_string(git_dir.join("commondir")) {
        Ok(rel) => git_dir.join(rel.trim()),
        Err(_) => git_dir.clone(),
    };
    Some(GitDirs { git_dir: git_dir.canonicalize().ok()?, common_dir: common_dir.canonicalize().ok()? })
}

/// `remote.origin.url` from git config text. Section names are case-insensitive, subsection
/// names are not; values may be quoted.
pub fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for raw in config.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(header) = line.strip_prefix('[') {
            let header = header.split(']').next().unwrap_or("").trim();
            let (section, sub) = header.split_once(char::is_whitespace).unwrap_or((header, ""));
            in_origin = section.eq_ignore_ascii_case("remote") && sub.trim() == "\"origin\"";
            continue;
        }
        if !in_origin {
            continue;
        }
        if let Some((key, value)) = line.split_once('=')
            && key.trim().eq_ignore_ascii_case("url")
        {
            let value = value.trim();
            let value = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
            return Some(value.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_origin_url() {
        let config = "[core]\n\trepositoryformatversion = 0\n[remote \"upstream\"]\n\turl = https://example.com/x\n\
            [Remote \"origin\"]\n\turl = git@github.com:sashee/nixos-test.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n";
        assert_eq!(origin_url(config).as_deref(), Some("git@github.com:sashee/nixos-test.git"));
        assert_eq!(origin_url("[remote \"origin\"]\n  url = \"https://github.com/a/b\"\n").as_deref(),
            Some("https://github.com/a/b"));
        assert_eq!(origin_url("[remote \"Origin\"]\nurl = x\n"), None);
    }

    #[test]
    fn locates_linked_worktrees() {
        let base = std::env::temp_dir().join(format!("dep-report-gitconfig-{}", std::process::id()));
        let main_git = base.join("main/.git");
        let wt_git = main_git.join("worktrees/wt");
        fs::create_dir_all(&wt_git).unwrap();
        fs::create_dir_all(base.join("wt")).unwrap();
        fs::write(wt_git.join("commondir"), "../..\n").unwrap();
        fs::write(base.join("wt/.git"), format!("gitdir: {}\n", wt_git.display())).unwrap();
        let dirs = locate(&base.join("wt")).unwrap();
        assert_eq!(dirs.git_dir, wt_git.canonicalize().unwrap());
        assert_eq!(dirs.common_dir, main_git.canonicalize().unwrap());
        assert_eq!(locate(&base.join("main")).unwrap().common_dir, main_git.canonicalize().unwrap());
        fs::remove_dir_all(&base).unwrap();
    }
}
