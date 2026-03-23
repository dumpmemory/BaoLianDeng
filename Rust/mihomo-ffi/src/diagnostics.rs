use std::io::{Read, Write};
use std::net::{TcpStream, UdpSocket};
use std::os::raw::c_char;
use std::time::{Duration, Instant};

use crate::{cstr_to_str, str_to_cstring_ptr};

/// # Safety
/// `host` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_test_direct_tcp(host: *const c_char, port: i32) -> *mut c_char {
    let host_str = cstr_to_str(host);
    let addr = format!("{}:{}", host_str, port);
    let start = Instant::now();
    match TcpStream::connect_timeout(
        &addr.parse().unwrap_or_else(|_| "0.0.0.0:0".parse().unwrap()),
        Duration::from_secs(5),
    ) {
        Ok(_) => {
            let elapsed = start.elapsed();
            str_to_cstring_ptr(&format!("OK: connected to {} in {:?}", addr, elapsed))
        }
        Err(e) => {
            let elapsed = start.elapsed();
            str_to_cstring_ptr(&format!("FAIL after {:?}: {}", elapsed, e))
        }
    }
}

/// # Safety
/// `url` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_test_proxy_http(url: *const c_char) -> *mut c_char {
    let target_url = cstr_to_str(url);
    let proxy_addr = "127.0.0.1:7890";
    let conn = match TcpStream::connect_timeout(
        &proxy_addr.parse().unwrap(),
        Duration::from_secs(5),
    ) {
        Ok(c) => c,
        Err(e) => return str_to_cstring_ptr(&format!("FAIL proxy connect: {}", e)),
    };
    let _ = conn.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = conn.set_write_timeout(Some(Duration::from_secs(10)));

    let req = format!(
        "GET {} HTTP/1.1\r\nHost: www.baidu.com\r\nConnection: close\r\n\r\n",
        target_url
    );
    let mut conn = conn;
    if let Err(e) = conn.write_all(req.as_bytes()) {
        return str_to_cstring_ptr(&format!("FAIL proxy write: {}", e));
    }

    let mut buf = vec![0u8; 512];
    match conn.read(&mut buf) {
        Ok(n) => {
            let resp = String::from_utf8_lossy(&buf[..n]);
            let first_line = resp.lines().next().unwrap_or("");
            str_to_cstring_ptr(&format!("OK: {}", first_line))
        }
        Err(e) => str_to_cstring_ptr(&format!("FAIL proxy read: {}", e)),
    }
}

/// # Safety
/// `dns_addr` must be a valid null-terminated UTF-8 string like "127.0.0.1:1053".
#[no_mangle]
pub unsafe extern "C" fn bridge_test_dns_resolver(dns_addr: *const c_char) -> *mut c_char {
    let addr_str = cstr_to_str(dns_addr);
    let sock = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(e) => {
            return str_to_cstring_ptr(&format!("DNS-TEST: FAIL bind: {}", e));
        }
    };
    let _ = sock.set_read_timeout(Some(Duration::from_secs(5)));

    if let Err(e) = sock.connect(addr_str) {
        return str_to_cstring_ptr(&format!("DNS-TEST: FAIL connect to {}: {}", addr_str, e));
    }

    // Build minimal DNS A query for www.baidu.com
    let query = build_dns_query("www.baidu.com");
    if let Err(e) = sock.send(&query) {
        return str_to_cstring_ptr(&format!("DNS-TEST: FAIL write: {}", e));
    }

    let mut buf = vec![0u8; 512];
    match sock.recv(&mut buf) {
        Ok(n) => {
            if let Some(ip) = parse_dns_response_a(&buf[..n]) {
                if ip.starts_with("198.18.") {
                    str_to_cstring_ptr(&format!(
                        "DNS-TEST: OK fake-ip {} for www.baidu.com",
                        ip
                    ))
                } else {
                    str_to_cstring_ptr(&format!(
                        "DNS-TEST: WARN got {} (not in 198.18.0.0/16) for www.baidu.com",
                        ip
                    ))
                }
            } else {
                str_to_cstring_ptr("DNS-TEST: FAIL could not parse A record from response")
            }
        }
        Err(e) => str_to_cstring_ptr(&format!("DNS-TEST: FAIL read: {}", e)),
    }
}

/// # Safety
/// `api_addr` must be a valid null-terminated UTF-8 string like "127.0.0.1:9090".
#[no_mangle]
pub unsafe extern "C" fn bridge_test_selected_proxy(api_addr: *const c_char) -> *mut c_char {
    let addr = cstr_to_str(api_addr);
    let rt = crate::get_runtime();
    let result = rt.block_on(async { test_selected_proxy_async(addr).await });
    str_to_cstring_ptr(&result)
}

async fn test_selected_proxy_async(api_addr: &str) -> String {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
    {
        Ok(c) => c,
        Err(e) => return format!("PROXY-TEST: FAIL build client: {}", e),
    };

    // List proxies
    let url = format!("http://{}/proxies", api_addr);
    let resp = match client.get(&url).send().await {
        Ok(r) => r,
        Err(e) => return format!("PROXY-TEST: FAIL list proxies: {}", e),
    };
    let body: serde_json::Value = match resp.json::<serde_json::Value>().await {
        Ok(v) => v,
        Err(e) => return format!("PROXY-TEST: FAIL parse proxies: {}", e),
    };

    let proxies = match body.get("proxies").and_then(serde_json::Value::as_object) {
        Some(p) => p,
        None => return "PROXY-TEST: FAIL no proxies object".to_string(),
    };

    let builtin = ["DIRECT", "REJECT", "GLOBAL", "default"];

    // Find first Selector group with a real proxy node
    let mut selected_name = None;
    let mut selected_now = None;
    for (name, info) in proxies {
        if builtin.contains(&name.as_str()) {
            continue;
        }
        if info.get("type").and_then(serde_json::Value::as_str) == Some("Selector") {
            if let Some(now) = info.get("now").and_then(serde_json::Value::as_str) {
                if now != "DIRECT" && now != "REJECT" && !now.is_empty() {
                    selected_name = Some(name.clone());
                    selected_now = Some(now.to_string());
                    break;
                }
            }
        }
    }

    let (group, now) = match (selected_name, selected_now) {
        (Some(g), Some(n)) => (g, n),
        _ => {
            let names: Vec<&String> = proxies.keys().collect();
            return format!("PROXY-TEST: FAIL no Selector group with proxy node found (groups: {:?})", names);
        }
    };

    // Get proxy type
    let proxy_url = format!("http://{}/proxies/{}", api_addr, now);
    let proxy_type = match client.get(&proxy_url).send().await {
        Ok(r) => {
            let info: serde_json::Value = r.json::<serde_json::Value>().await.unwrap_or_default();
            info.get("type")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown")
                .to_string()
        }
        Err(_) => "unknown".to_string(),
    };

    let mut result = format!("PROXY-TEST: group={} selected={} type={}", group, now, proxy_type);

    // Test latency
    let delay_url = format!(
        "http://{}/proxies/{}/delay?url=http://www.gstatic.com/generate_204&timeout=5000",
        api_addr, now
    );
    match client.get(&delay_url).send().await {
        Ok(r) => {
            let info: serde_json::Value = r.json::<serde_json::Value>().await.unwrap_or_default();
            if let Some(delay) = info.get("delay").and_then(serde_json::Value::as_i64) {
                if delay > 0 {
                    result += &format!(" delay={}ms", delay);
                } else if let Some(msg) = info.get("message").and_then(serde_json::Value::as_str) {
                    result += &format!(" delay=FAIL({})", msg);
                }
            }
        }
        Err(e) => {
            result += &format!(" delay=FAIL({})", e);
        }
    }

    result
}

// DNS helpers (ported from Go bridge)

fn build_dns_query(domain: &str) -> Vec<u8> {
    let mut buf = Vec::with_capacity(64);
    // Header: ID=0x1234, flags=0x0100, QDCOUNT=1
    buf.extend_from_slice(&[0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for label in domain.split('.') {
        buf.push(label.len() as u8);
        buf.extend_from_slice(label.as_bytes());
    }
    buf.push(0x00); // root label
    buf.extend_from_slice(&[0x00, 0x01]); // QTYPE = A
    buf.extend_from_slice(&[0x00, 0x01]); // QCLASS = IN
    buf
}

fn parse_dns_response_a(msg: &[u8]) -> Option<String> {
    if msg.len() < 12 {
        return None;
    }
    let mut pos = 12;
    let qdcount = (msg[4] as usize) << 8 | msg[5] as usize;
    for _ in 0..qdcount {
        while pos < msg.len() {
            let l = msg[pos] as usize;
            pos += 1;
            if l == 0 { break; }
            if l >= 0xC0 { pos += 1; break; }
            pos += l;
        }
        pos += 4; // QTYPE + QCLASS
    }
    let ancount = (msg[6] as usize) << 8 | msg[7] as usize;
    for _ in 0..ancount {
        if pos < msg.len() && msg[pos] >= 0xC0 {
            pos += 2;
        } else {
            while pos < msg.len() {
                let l = msg[pos] as usize;
                pos += 1;
                if l == 0 { break; }
                pos += l;
            }
        }
        if pos + 10 > msg.len() { break; }
        let rtype = (msg[pos] as usize) << 8 | msg[pos + 1] as usize;
        let rdlen = (msg[pos + 8] as usize) << 8 | msg[pos + 9] as usize;
        pos += 10;
        if rtype == 1 && rdlen == 4 && pos + 4 <= msg.len() {
            return Some(format!("{}.{}.{}.{}", msg[pos], msg[pos + 1], msg[pos + 2], msg[pos + 3]));
        }
        pos += rdlen;
    }
    None
}
