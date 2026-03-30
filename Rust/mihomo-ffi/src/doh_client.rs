//! DNS-over-HTTPS client that connects directly to DoH servers (bypassing the proxy).
//! Reads DoH server URLs from the Mihomo config; falls back to Cloudflare.

use crate::logging;
use std::sync::OnceLock;
use tracing::{info, warn};

const DOH_TIMEOUT_SECS: u64 = 5;

/// IP-based DoH servers that don't require DNS resolution.
/// These are always appended as fallbacks to avoid circular DNS dependency
/// when hostname-based DoH servers (e.g. dns.alidns.com) become unreachable
/// after the system DNS cache expires under the TUN.
const IP_BASED_DOH_URLS: &[&str] = &[
    "https://1.1.1.1/dns-query",
    "https://8.8.8.8/dns-query",
];

struct DohClient {
    http_client: reqwest::Client,
    doh_urls: Vec<String>,
}

static DOH_CLIENT: OnceLock<DohClient> = OnceLock::new();

/// Initialize the DoH client. Call once at tun2socks startup.
/// Reads DoH URLs from `{HOME_DIR}/config.yaml`, falls back to Cloudflare.
/// Connects directly to DoH servers (no proxy).
pub fn init_doh_client() {
    DOH_CLIENT.get_or_init(|| {
        let doh_urls = read_doh_urls_from_config();

        info!("DoH client: urls={:?}, direct (no proxy)", doh_urls);

        let http_client = reqwest::Client::builder()
            .no_proxy()
            .timeout(std::time::Duration::from_secs(DOH_TIMEOUT_SECS))
            .danger_accept_invalid_certs(true)
            .build()
            .expect("failed to build reqwest client");

        DohClient { http_client, doh_urls }
    });
}

/// Send a raw DNS query via DoH. Returns the raw DNS response bytes, or None on failure.
pub async fn resolve_via_doh(query: &[u8]) -> Option<Vec<u8>> {
    let client = DOH_CLIENT.get()?;

    for url in &client.doh_urls {
        match client
            .http_client
            .post(url)
            .header("Content-Type", "application/dns-message")
            .header("Accept", "application/dns-message")
            .body(query.to_vec())
            .send()
            .await
        {
            Ok(resp) => {
                if resp.status().is_success() {
                    match resp.bytes().await {
                        Ok(bytes) => return Some(bytes.to_vec()),
                        Err(e) => {
                            warn!("DoH response body error from {}: {}", url, e);
                            continue;
                        }
                    }
                } else {
                    warn!("DoH HTTP {} from {}", resp.status(), url);
                    continue;
                }
            }
            Err(e) => {
                warn!("DoH request failed to {}: {}", url, e);
                continue;
            }
        }
    }

    logging::bridge_log("DoH: all servers failed");
    None
}

// ---------------------------------------------------------------------------
// Config reading
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct MinimalConfig {
    dns: Option<MinimalDns>,
}

#[derive(serde::Deserialize)]
struct MinimalDns {
    nameserver: Option<Vec<serde_yaml::Value>>,
    fallback: Option<Vec<serde_yaml::Value>>,
}

/// Extract DoH URLs (starting with "https://") from Mihomo config.
/// Falls back to Cloudflare if none found.
fn read_doh_urls_from_config() -> Vec<String> {
    let home_dir = crate::HOME_DIR.lock();
    let config_path = match home_dir.as_ref() {
        Some(dir) => format!("{}/config.yaml", dir),
        None => {
            info!("DoH: no HOME_DIR, using default URL");
            return IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect();
        }
    };
    drop(home_dir); // release lock before I/O

    let config_str = match std::fs::read_to_string(&config_path) {
        Ok(s) => s,
        Err(e) => {
            warn!("DoH: cannot read {}: {}", config_path, e);
            return IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect();
        }
    };

    let config: MinimalConfig = match serde_yaml::from_str(&config_str) {
        Ok(c) => c,
        Err(e) => {
            warn!("DoH: cannot parse config: {}", e);
            return IP_BASED_DOH_URLS.iter().map(|s| s.to_string()).collect();
        }
    };

    let mut urls = Vec::new();
    if let Some(dns) = config.dns {
        for list in [dns.nameserver, dns.fallback].into_iter().flatten() {
            for entry in list {
                if let serde_yaml::Value::String(s) = entry {
                    if s.starts_with("https://") {
                        // Ensure URL has a path (append /dns-query if it's just a host)
                        if !urls.contains(&s) {
                            urls.push(s);
                        }
                    }
                }
            }
        }
    }

    // Always append IP-based DoH servers as fallbacks.
    // Hostname-based servers (dns.alidns.com, doh.pub) stop working once the
    // system DNS cache expires because resolving them requires DoH, which
    // requires resolving them — a circular dependency under the TUN.
    for fallback in IP_BASED_DOH_URLS {
        let s = fallback.to_string();
        if !urls.contains(&s) {
            urls.push(s);
        }
    }

    urls
}
