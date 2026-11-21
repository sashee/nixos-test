//! GitHub repository identities: parsed out of git remotes, flake.lock nodes, tarball URLs and
//! workflow `uses:` lines, and the owner allowlist that decides which ones the walk enters.

use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RepoId {
    pub owner: String,
    pub repo: String,
}

impl RepoId {
    /// Only names GitHub itself allows: these strings end up in API URLs and Nix expressions, so
    /// anything else is refused rather than escaped.
    pub fn new(owner: &str, repo: &str) -> Option<RepoId> {
        (valid_segment(owner) && valid_segment(repo))
            .then(|| RepoId { owner: owner.to_string(), repo: repo.to_string() })
    }

    /// GitHub treats owner and repository names case-insensitively (`NixOS/nixpkgs` is
    /// `nixos/nixpkgs`), so identity comparisons do too.
    pub fn key(&self) -> String {
        format!("{}/{}", self.owner.to_ascii_lowercase(), self.repo.to_ascii_lowercase())
    }

    pub fn same(&self, other: &RepoId) -> bool {
        self.key() == other.key()
    }
}

impl fmt::Display for RepoId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}/{}", self.owner, self.repo)
    }
}

pub fn valid_segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s != "."
        && s != ".."
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// `owner/repo`.
pub fn parse_slug(s: &str) -> Option<RepoId> {
    let (owner, repo) = s.split_once('/')?;
    RepoId::new(owner, repo)
}

/// The GitHub repository a git remote URL points at, in any of the forms git accepts for it.
pub fn parse_remote_url(url: &str) -> Option<RepoId> {
    let url = url.trim();
    let rest = ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/",
        "git://github.com/", "ssh://github.com/"]
        .iter()
        .find_map(|prefix| url.strip_prefix(prefix))?;
    let rest = rest.trim_end_matches('/');
    parse_slug(rest.strip_suffix(".git").unwrap_or(rest))
}

pub fn owner_allowed(owners: &[String], repo: &RepoId) -> bool {
    owners.iter().any(|owner| owner.eq_ignore_ascii_case(&repo.owner))
}

/// First 7 characters of a commit hash, as git abbreviates it.
pub fn short(rev: &str) -> &str {
    rev.get(..7).unwrap_or(rev)
}

pub fn is_full_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_url_forms() {
        let expected = RepoId::new("sashee", "nixos-test");
        for url in ["git@github.com:sashee/nixos-test.git", "git@github.com:sashee/nixos-test",
            "https://github.com/sashee/nixos-test", "https://github.com/sashee/nixos-test.git/",
            "ssh://git@github.com/sashee/nixos-test.git"]
        {
            assert_eq!(parse_remote_url(url), expected, "{url}");
        }
        assert_eq!(parse_remote_url("git@gitlab.com:sashee/nixos-test.git"), None);
        assert_eq!(parse_remote_url("https://github.com/sashee/nixos-test/extra"), None);
    }

    #[test]
    fn refuses_names_github_would_not_allow() {
        assert_eq!(RepoId::new("sashee", "a b"), None);
        assert_eq!(RepoId::new("sashee", ".."), None);
        assert_eq!(RepoId::new("", "x"), None);
        assert_eq!(RepoId::new("o\"", "x"), None);
    }

    #[test]
    fn owners_compare_case_insensitively() {
        let nixpkgs = RepoId::new("NixOS", "nixpkgs").unwrap();
        assert!(owner_allowed(&["nixos".to_string()], &nixpkgs));
        assert!(!owner_allowed(&["sashee".to_string()], &nixpkgs));
        assert!(nixpkgs.same(&RepoId::new("nixos", "NIXPKGS").unwrap()));
    }
}
