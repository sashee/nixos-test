//! Commit-pinned GitHub tarballs in `.nix` files: `fetchTarball` of
//! `https://github.com/{owner}/{repo}/archive/{40 hex}.tar.gz`, optionally with a `sha256`.
//!
//! Branch tarballs (`.../tarball/nixos-26.05`) are skipped on purpose: they float, so there is
//! nothing to bump. The URL is rebuilt from validated parts, never copied out of the file,
//! because it is later spliced into a Nix expression (nix.rs).

use crate::repo::{RepoId, is_full_sha};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TarballPin {
    pub file: String,
    pub line: usize,
    pub repo: RepoId,
    pub rev: String,
    pub sha256: Option<String>,
}

pub fn archive_url(repo: &RepoId, rev: &str) -> String {
    format!("https://github.com/{}/{}/archive/{}.tar.gz", repo.owner, repo.repo, rev)
}

const PREFIX: &str = "https://github.com/";

pub fn find(file: &str, text: &str) -> Vec<TarballPin> {
    text.match_indices(PREFIX)
        .filter_map(|(start, _)| {
            let after = &text[start + PREFIX.len()..];
            let end = after.find(|c: char| matches!(c, '"' | '\'' | ';' | ')') || c.is_whitespace()).unwrap_or(after.len());
            let parts: Vec<&str> = after[..end].split('/').collect();
            let [owner, repo, "archive", file_name] = parts.as_slice() else { return None };
            let rev = file_name.strip_suffix(".tar.gz").filter(|rev| is_full_sha(rev))?;
            Some(TarballPin {
                file: file.to_string(),
                line: text[..start].matches('\n').count() + 1,
                repo: RepoId::new(owner, repo)?,
                rev: rev.to_string(),
                sha256: hash_in_same_attrset(text, start),
            })
        })
        .collect()
}

/// The `sha256 = "..."` of the attribute set the URL sits in, when that set holds exactly one
/// GitHub URL (otherwise which hash belongs to which URL is a guess).
fn hash_in_same_attrset(text: &str, url_start: usize) -> Option<String> {
    let open = text[..url_start].rfind('{')?;
    let close = url_start + text[url_start..].find('}')?;
    let scope = &text[open..close];
    if scope.matches(PREFIX).count() != 1 {
        return None;
    }
    let after = &scope[scope.find("sha256")? + "sha256".len()..];
    let quoted = after.trim_start().strip_prefix('=')?.trim_start().strip_prefix('"')?;
    let value = &quoted[..quoted.find('"')?];
    valid_hash(value).then(|| value.to_string())
}

/// A sha256 in one of the encodings Nix accepts: its base32 (52 chars), hex (64), or SRI.
pub fn valid_hash(v: &str) -> bool {
    const NIX32: &[u8] = b"0123456789abcdfghijklmnpqrsvwxyz";
    let nix32 = v.len() == 52 && v.bytes().all(|b| NIX32.contains(&b));
    let hex = v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit());
    let sri = v.strip_prefix("sha256-").is_some_and(|b64| {
        b64.len() == 44 && b64.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
    });
    nix32 || hex || sri
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_pin_with_hash() {
        let pins = find("nix/e2ee-store.nix", include_str!("fixtures/e2ee-store.nix.txt"));
        assert_eq!(pins, [TarballPin {
            file: "nix/e2ee-store.nix".into(),
            line: 7,
            repo: RepoId::new("sashee", "e2ee-store").unwrap(),
            rev: "09f0d147377d6f31b4a90e3420ecd500da6d85cd".into(),
            sha256: Some("134kapvp02fdmvp80lsx20dg6nc3i7fzhm6v9kc75756v09sp8a4".into()),
        }]);
        assert_eq!(archive_url(&pins[0].repo, &pins[0].rev),
            "https://github.com/sashee/e2ee-store/archive/09f0d147377d6f31b4a90e3420ecd500da6d85cd.tar.gz");
    }

    #[test]
    fn commit_pin_without_hash() {
        let pins = find("nix/iroh-ssh.nix", include_str!("fixtures/iroh-ssh.nix.txt"));
        assert_eq!(pins.len(), 1);
        assert_eq!(pins[0].repo.to_string(), "sashee/nixos-test");
        assert_eq!(pins[0].rev, "65892504d0ec05f258d4b6b578b0f3711dd778dc");
        // The file's only `{ }` is the function header, which holds no hash.
        assert_eq!(pins[0].sha256, None);
    }

    #[test]
    fn branch_tarballs_are_not_pins() {
        assert!(find("nix/pkgs.nix", include_str!("fixtures/pkgs.nix.txt")).is_empty());
        assert!(find("x.nix", "fetchTarball \"https://github.com/nix-community/nixGL/archive/main.tar.gz\"").is_empty());
    }

    #[test]
    fn hash_before_url_and_ambiguous_sets() {
        let sha = "0".repeat(52);
        let text = format!("fetchTarball {{ sha256 = \"{sha}\"; url = \"https://github.com/a/b/archive/{}.tar.gz\"; }}",
            "a".repeat(40));
        assert_eq!(find("x.nix", &text)[0].sha256.as_deref(), Some(sha.as_str()));
        let two = format!("{{ a = \"https://github.com/a/b/archive/{r}.tar.gz\"; b = \"https://github.com/a/c/archive/{r}.tar.gz\"; sha256 = \"{sha}\"; }}",
            r = "b".repeat(40));
        assert!(find("x.nix", &two).iter().all(|p| p.sha256.is_none()));
    }

    #[test]
    fn hostile_text_never_becomes_a_pin() {
        let r = "c".repeat(40);
        for text in [format!("\"https://github.com/a\\\"b/c/archive/{r}.tar.gz\""),
            format!("\"https://github.com/a/b/archive/{r}.tar.gz?x=1\""),
            format!("\"https://github.com/a/b/archive/{}.tar.gz\"", "C".repeat(40))]
        {
            assert!(find("x.nix", &text).is_empty(), "{text}");
        }
        let bad_hash = format!("{{ url = \"https://github.com/a/b/archive/{r}.tar.gz\"; sha256 = \"\\\"; builtins.x\"; }}");
        assert_eq!(find("x.nix", &bad_hash)[0].sha256, None);
    }

    #[test]
    fn hash_encodings() {
        assert!(valid_hash("134kapvp02fdmvp80lsx20dg6nc3i7fzhm6v9kc75756v09sp8a4"));
        assert!(valid_hash(&"f".repeat(64)));
        assert!(valid_hash("sha256-7NaFGuZprPP3M4ZmAYQMA66HlTD1X4UtEGx7R5McAPU="));
        assert!(!valid_hash("134kapvp02fdmvp80lsx20dg6nc3i7fzhm6v9kc75756v09sp8ae"));
        assert!(!valid_hash("sha512-x"));
    }
}
