//! HTTP for the lookups: two hosts only, a 1-request-per-second pace for crates.io, the on-disk
//! cache, and GitHub's rate limit.
//!
//! There is no token: a run makes about 14 GitHub calls against the 60 per hour an IP gets
//! unauthenticated. When GitHub says the quota is gone, GitHub lookups stop for the rest of the
//! run and their rows say when it resets; the report is still written.

use std::time::Duration;

use crate::cache::Cache;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Service {
    GitHub,
    CratesIo,
}

/// The only URLs this program fetches. Anything else is refused before a socket is opened.
pub fn service_of(url: &str) -> Option<Service> {
    if url.starts_with("https://api.github.com/") {
        Some(Service::GitHub)
    } else if url.starts_with("https://crates.io/api/v1/") {
        Some(Service::CratesIo)
    } else {
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: String,
    pub ratelimit_remaining: Option<i64>,
    pub ratelimit_reset: Option<i64>,
    pub retry_after: Option<i64>,
}

pub trait Transport {
    fn get(&mut self, url: &str, service: Service) -> Result<Response, String>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Ok(String),
    NotFound,
    RateLimited { reset: Option<i64> },
    Failed(String),
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Stats {
    pub github_calls: u32,
    pub github_cached: u32,
    pub crates_calls: u32,
    pub crates_cached: u32,
    pub github_remaining: Option<i64>,
    pub github_reset: Option<i64>,
    /// Set once GitHub refused for quota: the reset time, if it said.
    pub github_blocked: Option<Option<i64>>,
}

pub struct Fetcher<'a> {
    pub transport: Box<dyn Transport + 'a>,
    pub cache: Cache,
    /// Called before every network request; the real one sleeps to keep crates.io at 1/s.
    pub pace: Box<dyn FnMut(Service) + 'a>,
    pub stats: Stats,
}

impl Fetcher<'_> {
    pub fn get(&mut self, url: &str) -> Outcome {
        let Some(service) = service_of(url) else {
            return Outcome::Failed(format!("refusing to fetch {url}"));
        };
        if let Some(hit) = self.cache.get(url) {
            match service {
                Service::GitHub => self.stats.github_cached += 1,
                Service::CratesIo => self.stats.crates_cached += 1,
            }
            return if hit.status == 404 { Outcome::NotFound } else { Outcome::Ok(hit.body) };
        }
        if let (Service::GitHub, Some(reset)) = (service, self.stats.github_blocked) {
            return Outcome::RateLimited { reset };
        }
        (self.pace)(service);
        match service {
            Service::GitHub => self.stats.github_calls += 1,
            Service::CratesIo => self.stats.crates_calls += 1,
        }
        let response = match self.transport.get(url, service) {
            Ok(r) => r,
            Err(e) => return Outcome::Failed(e),
        };
        if service == Service::GitHub {
            self.stats.github_remaining = response.ratelimit_remaining.or(self.stats.github_remaining);
            self.stats.github_reset = response.ratelimit_reset.or(self.stats.github_reset);
        }
        let quota_gone = response.ratelimit_remaining == Some(0) || response.retry_after.is_some();
        match response.status {
            200 => {
                self.cache.put(url, 200, &response.body);
                Outcome::Ok(response.body)
            }
            404 => {
                self.cache.put(url, 404, "");
                Outcome::NotFound
            }
            403 | 429 if quota_gone || response.status == 429 => {
                let reset = response.ratelimit_reset.or(response.retry_after.map(|s| self.cache.now + s));
                if service == Service::GitHub {
                    self.stats.github_blocked = Some(reset);
                }
                Outcome::RateLimited { reset }
            }
            status => Outcome::Failed(format!("HTTP {status}")),
        }
    }
}

/// ureq with rustls over the system trust store (`SSL_CERT_FILE`), as iroh-ssh and
/// time-correction verify TLS: baked-in webpki roots would ignore the store this host curates.
pub struct Ureq {
    agent: ureq::Agent,
}

impl Ureq {
    pub fn new(user_agent: &str) -> Ureq {
        let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
        let tls = ureq::tls::TlsConfig::builder()
            .provider(ureq::tls::TlsProvider::Rustls)
            .root_certs(ureq::tls::RootCerts::PlatformVerifier)
            .unversioned_rustls_crypto_provider(provider)
            .build();
        let config = ureq::Agent::config_builder()
            .tls_config(tls)
            .https_only(true)
            .http_status_as_error(false)
            // GitHub and crates.io answer API calls directly; a redirect would only lead to a
            // host service_of never approved.
            .max_redirects(0)
            .proxy(None)
            .timeout_global(Some(Duration::from_secs(60)))
            .user_agent(user_agent)
            .build();
        Ureq { agent: config.into() }
    }
}

fn header_i64(response: &ureq::http::Response<ureq::Body>, name: &str) -> Option<i64> {
    response.headers().get(name)?.to_str().ok()?.trim().parse().ok()
}

impl Transport for Ureq {
    fn get(&mut self, url: &str, service: Service) -> Result<Response, String> {
        let request = self.agent.get(url);
        let request = match service {
            Service::GitHub => {
                request.header("Accept", "application/vnd.github+json").header("X-GitHub-Api-Version", "2022-11-28")
            }
            Service::CratesIo => request.header("Accept", "application/json"),
        };
        let mut response = request.call().map_err(|e| e.to_string())?;
        let body = response
            .body_mut()
            .with_config()
            .limit(32 * 1024 * 1024)
            .read_to_string()
            .map_err(|e| e.to_string())?;
        Ok(Response {
            status: response.status().as_u16(),
            ratelimit_remaining: header_i64(&response, "x-ratelimit-remaining"),
            ratelimit_reset: header_i64(&response, "x-ratelimit-reset"),
            retry_after: header_i64(&response, "retry-after"),
            body,
        })
    }
}

#[cfg(test)]
pub mod fake {
    use super::*;
    use std::collections::BTreeMap;

    /// Answers from a map; anything not in it is a 404. Records every URL it was asked for.
    pub struct FakeTransport<'a> {
        pub responses: BTreeMap<String, Response>,
        pub requested: &'a std::cell::RefCell<Vec<String>>,
    }

    impl Transport for FakeTransport<'_> {
        fn get(&mut self, url: &str, _: Service) -> Result<Response, String> {
            self.requested.borrow_mut().push(url.to_string());
            Ok(self.responses.get(url).cloned().unwrap_or(Response {
                status: 404,
                body: String::new(),
                ratelimit_remaining: None,
                ratelimit_reset: None,
                retry_after: None,
            }))
        }
    }

    pub fn ok(body: &str) -> Response {
        Response { status: 200, body: body.into(), ratelimit_remaining: Some(50), ratelimit_reset: Some(1_800_000_000),
            retry_after: None }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::{FakeTransport, ok};
    use super::*;
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    fn cache(tag: &str) -> Cache {
        let dir = std::env::temp_dir().join(format!("dep-report-http-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Cache { dir, now: 1_000, ttl: 3600, read: true }
    }

    #[test]
    fn caches_and_counts() {
        let requested = RefCell::new(Vec::new());
        let url = "https://api.github.com/repos/a/b/releases/latest";
        let responses = BTreeMap::from([(url.to_string(), ok("{\"tag_name\":\"v1\"}"))]);
        let mut fetcher = Fetcher {
            transport: Box::new(FakeTransport { responses, requested: &requested }),
            cache: cache("count"),
            pace: Box::new(|_| {}),
            stats: Stats::default(),
        };
        assert!(matches!(fetcher.get(url), Outcome::Ok(_)));
        assert!(matches!(fetcher.get(url), Outcome::Ok(_)));
        assert_eq!(fetcher.get("https://api.github.com/repos/a/missing/releases/latest"), Outcome::NotFound);
        assert_eq!(requested.borrow().len(), 2, "the second call is answered from the cache");
        assert_eq!((fetcher.stats.github_calls, fetcher.stats.github_cached, fetcher.stats.github_remaining), (2, 1, Some(50)));
        assert!(matches!(fetcher.get("https://example.com/x"), Outcome::Failed(_)));
        assert_eq!(requested.borrow().len(), 2, "other hosts are never contacted");
        let _ = std::fs::remove_dir_all(&fetcher.cache.dir);
    }

    #[test]
    fn stops_github_lookups_when_the_quota_is_gone() {
        let requested = RefCell::new(Vec::new());
        let limited = Response { status: 403, body: "rate limited".into(), ratelimit_remaining: Some(0),
            ratelimit_reset: Some(1_800_000_000), retry_after: None };
        let responses = BTreeMap::from([
            ("https://api.github.com/repos/a/b/commits?per_page=1".to_string(), limited),
            ("https://crates.io/api/v1/crates/tokio/versions".to_string(), ok("{}")),
        ]);
        let mut fetcher = Fetcher {
            transport: Box::new(FakeTransport { responses, requested: &requested }),
            cache: cache("limit"),
            pace: Box::new(|_| {}),
            stats: Stats::default(),
        };
        let limited = Outcome::RateLimited { reset: Some(1_800_000_000) };
        assert_eq!(fetcher.get("https://api.github.com/repos/a/b/commits?per_page=1"), limited);
        assert_eq!(fetcher.get("https://api.github.com/repos/c/d/releases/latest"), limited);
        assert!(matches!(fetcher.get("https://crates.io/api/v1/crates/tokio/versions"), Outcome::Ok(_)));
        assert_eq!(requested.borrow().len(), 2, "no GitHub request after the refusal");
        assert_eq!(fetcher.stats.github_blocked, Some(Some(1_800_000_000)));
        let _ = std::fs::remove_dir_all(&fetcher.cache.dir);
    }

    #[test]
    fn plain_403_is_a_failure_not_a_rate_limit() {
        let requested = RefCell::new(Vec::new());
        let forbidden = Response { status: 403, body: String::new(), ratelimit_remaining: Some(40),
            ratelimit_reset: None, retry_after: None };
        let url = "https://api.github.com/repos/a/b/releases/latest";
        let mut fetcher = Fetcher {
            transport: Box::new(FakeTransport { responses: BTreeMap::from([(url.to_string(), forbidden)]), requested: &requested }),
            cache: cache("forbidden"),
            pace: Box::new(|_| {}),
            stats: Stats::default(),
        };
        assert_eq!(fetcher.get(url), Outcome::Failed("HTTP 403".into()));
        assert_eq!(fetcher.stats.github_blocked, None);
    }
}
