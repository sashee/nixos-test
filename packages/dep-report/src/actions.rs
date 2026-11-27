//! GitHub Actions in workflow and composite-action files: `uses: owner/repo[/path]@ref`, where ref
//! is either a commit SHA with the version in a trailing comment (`@de0fac2... # v6.0.2`) or a tag
//! (`@v6.0.2`, `@v31`). Local (`./...`) and `docker://` actions have no upstream release to check.

use crate::repo::{RepoId, is_full_sha};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActionUse {
    pub file: String,
    pub line: usize,
    /// `owner/repo` or `owner/repo/sub/path`, as written.
    pub action: String,
    pub repo: RepoId,
    pub reference: String,
    pub comment: Option<String>,
}

impl ActionUse {
    /// The version this use is on: the comment for a SHA pin, the ref itself for a tag.
    pub fn current_version(&self) -> Option<&str> {
        if is_full_sha(&self.reference) { self.comment.as_deref() } else { Some(&self.reference) }
    }
}

pub fn find(file: &str, text: &str) -> Vec<ActionUse> {
    text.lines()
        .enumerate()
        .filter_map(|(index, raw)| {
            let line = raw.trim_start();
            let line = line.strip_prefix("- ").map_or(line, str::trim_start);
            let rest = line.strip_prefix("uses:")?;
            let (value, comment) = rest.split_once('#').map_or((rest, None), |(v, c)| (v, Some(c)));
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
            if value.starts_with("./") || value.starts_with("docker://") {
                return None;
            }
            let (action, reference) = value.split_once('@')?;
            let mut segments = action.split('/');
            let repo = RepoId::new(segments.next()?, segments.next()?)?;
            let comment = comment
                .and_then(|c| c.split_whitespace().next())
                .filter(|c| c.trim_start_matches('v').starts_with(|ch: char| ch.is_ascii_digit()))
                .map(str::to_string);
            Some(ActionUse {
                file: file.to_string(),
                line: index + 1,
                action: action.to_string(),
                repo,
                reference: reference.to_string(),
                comment,
            })
        })
        .collect()
}

#[derive(Debug, PartialEq, Eq)]
pub enum TagRelation {
    Same,
    /// A moving major tag (`v31`) that the latest release (`v31.11.0`) falls under.
    Tracks,
    Older,
    Newer,
    Unknown,
}

fn numeric_parts(tag: &str) -> Option<Vec<u64>> {
    tag.trim_start_matches('v').split('.').map(|p| p.parse().ok()).collect()
}

pub fn compare_tags(current: &str, latest: &str) -> TagRelation {
    let (Some(cur), Some(new)) = (numeric_parts(current), numeric_parts(latest)) else {
        return if current == latest { TagRelation::Same } else { TagRelation::Unknown };
    };
    if cur.len() < new.len() && new.starts_with(&cur) {
        return TagRelation::Tracks;
    }
    let width = cur.len().max(new.len());
    let pad = |v: &[u64]| -> Vec<u64> { v.iter().copied().chain(std::iter::repeat(0)).take(width).collect() };
    match pad(&cur).cmp(&pad(&new)) {
        std::cmp::Ordering::Equal => TagRelation::Same,
        std::cmp::Ordering::Less => TagRelation::Older,
        std::cmp::Ordering::Greater => TagRelation::Newer,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha_pins_with_version_comments() {
        let uses = find(".github/workflows/ci.yml", include_str!("fixtures/ci.yml.txt"));
        assert!(uses.iter().all(|u| is_full_sha(&u.reference) && u.comment.is_some()), "{uses:#?}");
        let checkout = uses.iter().find(|u| u.action == "actions/checkout").unwrap();
        assert_eq!(checkout.current_version(), Some("v6.0.2"));
        assert_eq!(checkout.reference, "de0fac2e4500dabe0009e67214ff5f5447ce83dd");
        let mut actions: Vec<_> = uses.iter().map(|u| u.action.as_str()).collect();
        actions.sort();
        actions.dedup();
        // `./.github/actions/nix-runner` is local and skipped.
        assert_eq!(actions, ["actions/checkout", "actions/upload-artifact"]);
    }

    #[test]
    fn tag_refs() {
        let uses = find(".github/workflows/ci.yml", include_str!("fixtures/dotfiles-ci.yml.txt"));
        let refs: Vec<_> = uses.iter().map(|u| (u.action.as_str(), u.current_version().unwrap())).collect();
        assert_eq!(refs, [("actions/checkout", "v6.0.2"), ("cachix/install-nix-action", "v31"),
            ("actions/checkout", "v6.0.2"), ("cachix/install-nix-action", "v31")]);
    }

    #[test]
    fn odd_forms() {
        let text = "steps:\n  - uses: \"owner/repo/sub/dir@v1\"  # pinned\n  - uses: docker://alpine:3\n  - name: x\n    uses: a/b@0123456789012345678901234567890123456789\n";
        let uses = find("f.yml", text);
        assert_eq!(uses.len(), 2);
        assert_eq!((uses[0].action.as_str(), uses[0].repo.to_string().as_str(), uses[0].comment.as_deref()),
            ("owner/repo/sub/dir", "owner/repo", None));
        assert_eq!(uses[1].current_version(), None);
        assert_eq!(uses[1].line, 5);
    }

    #[test]
    fn tag_comparison() {
        assert_eq!(compare_tags("v6.0.2", "v6.0.2"), TagRelation::Same);
        assert_eq!(compare_tags("v31", "v31.11.0"), TagRelation::Tracks);
        assert_eq!(compare_tags("v31.10.7", "v31.11.0"), TagRelation::Older);
        assert_eq!(compare_tags("v30", "v31.0.0"), TagRelation::Older);
        assert_eq!(compare_tags("v7.1", "v7.0.9"), TagRelation::Newer);
        assert_eq!(compare_tags("v7", "v7.0"), TagRelation::Tracks);
        assert_eq!(compare_tags("main", "v1"), TagRelation::Unknown);
    }
}
