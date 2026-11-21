//! On-disk cache under `$XDG_CACHE_HOME/dep-report`: one JSON file per key (a URL, or a
//! `cargo update` invocation) holding the answer and when it was fetched. A second run inside
//! the TTL makes no network calls, which also keeps it well inside GitHub's 60 unauthenticated
//! requests an hour.

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub key: String,
    pub fetched_at: i64,
    pub status: u16,
    pub body: String,
}

#[derive(Debug, Clone)]
pub struct Cache {
    pub dir: PathBuf,
    pub now: i64,
    pub ttl: i64,
    /// `--no-cache`: never answer from the cache, but still refresh it.
    pub read: bool,
}

/// FNV-1a: a stable file name per key. The key is stored in the entry and compared on read, so
/// a collision is a miss, not a wrong answer.
pub fn fnv1a64(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3))
}

/// Whether an entry fetched at `fetched_at` still answers at `now`. An entry from the future
/// (clock moved back) is treated as stale.
pub fn fresh(fetched_at: i64, now: i64, ttl: i64) -> bool {
    fetched_at <= now && now - fetched_at < ttl
}

impl Cache {
    fn path(&self, key: &str) -> PathBuf {
        self.dir.join(format!("{:016x}.json", fnv1a64(key)))
    }

    pub fn get(&self, key: &str) -> Option<Entry> {
        if !self.read {
            return None;
        }
        let entry: Entry = serde_json::from_str(&fs::read_to_string(self.path(key)).ok()?).ok()?;
        (entry.key == key && fresh(entry.fetched_at, self.now, self.ttl)).then_some(entry)
    }

    /// Best effort: a cache that cannot be written only costs the next run some requests.
    pub fn put(&self, key: &str, status: u16, body: &str) {
        let entry = Entry { key: key.to_string(), fetched_at: self.now, status, body: body.to_string() };
        let Ok(json) = serde_json::to_string(&entry) else { return };
        let path = self.path(key);
        let tmp = path.with_extension("tmp");
        if fs::create_dir_all(&self.dir).is_ok() && fs::write(&tmp, json).is_ok() {
            let _ = fs::rename(&tmp, &path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn freshness() {
        assert!(fresh(100, 100, 10));
        assert!(fresh(100, 109, 10));
        assert!(!fresh(100, 110, 10));
        assert!(!fresh(101, 100, 10));
    }

    #[test]
    fn round_trip_and_ttl() {
        let dir = std::env::temp_dir().join(format!("dep-report-cache-{}", std::process::id()));
        let cache = Cache { dir: dir.clone(), now: 1000, ttl: 60, read: true };
        cache.put("https://crates.io/api/v1/crates/tokio/versions", 200, "{}");
        assert_eq!(cache.get("https://crates.io/api/v1/crates/tokio/versions").unwrap().body, "{}");
        assert!(cache.get("https://crates.io/api/v1/crates/serde/versions").is_none());
        assert!(Cache { now: 1060, ..cache.clone() }.get("https://crates.io/api/v1/crates/tokio/versions").is_none());
        assert!(Cache { read: false, ..cache.clone() }.get("https://crates.io/api/v1/crates/tokio/versions").is_none());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn hash_is_stable() {
        assert_eq!(fnv1a64(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64("a"), 0xaf63_dc4c_8601_ec8c);
    }
}
