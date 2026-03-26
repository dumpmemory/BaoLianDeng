//! IP-to-hostname mapping table populated from DNS responses,
//! plus minimal DNS wire format parsing for queries and A/AAAA answers.

use parking_lot::Mutex as ParkMutex;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::LazyLock;
use std::time::Instant;

// ---------------------------------------------------------------------------
// IP -> hostname table
// ---------------------------------------------------------------------------

struct DnsEntry {
    hostname: String,
    expires_at: Instant,
}

static DNS_TABLE: LazyLock<ParkMutex<HashMap<IpAddr, DnsEntry>>> =
    LazyLock::new(|| ParkMutex::new(HashMap::new()));

const MIN_TTL_SECS: u32 = 60;
const MAX_TTL_SECS: u32 = 3600;
const EVICTION_THRESHOLD: usize = 4096;

/// Insert an IP -> hostname mapping with clamped TTL.
pub fn dns_table_insert(ip: IpAddr, hostname: String, ttl_secs: u32) {
    let ttl = ttl_secs.clamp(MIN_TTL_SECS, MAX_TTL_SECS);
    let expires_at = Instant::now() + std::time::Duration::from_secs(ttl as u64);
    let mut table = DNS_TABLE.lock();
    table.insert(ip, DnsEntry { hostname, expires_at });
    // Bulk eviction when table grows too large
    if table.len() > EVICTION_THRESHOLD {
        let now = Instant::now();
        table.retain(|_, e| e.expires_at > now);
    }
}

/// Look up hostname for an IP. Returns None if absent or expired.
pub fn dns_table_lookup(ip: IpAddr) -> Option<String> {
    let mut table = DNS_TABLE.lock();
    if let Some(entry) = table.get(&ip) {
        if entry.expires_at > Instant::now() {
            return Some(entry.hostname.clone());
        }
        // Expired — remove lazily
        table.remove(&ip);
    }
    None
}

// ---------------------------------------------------------------------------
// DNS wire format parsing
// ---------------------------------------------------------------------------

/// Parse the queried domain name from a DNS query's question section.
/// Returns None if the packet is too short or malformed.
pub fn parse_dns_query_name(data: &[u8]) -> Option<String> {
    if data.len() < 12 {
        return None;
    }
    let (name, _) = read_dns_name(data, 12)?;
    Some(name)
}

/// Parse a DNS response and extract (resolved_ip, queried_hostname, ttl) tuples
/// for all A and AAAA answer records.
///
/// Uses the hostname from the *question section* (not the answer RR name)
/// so CNAME chains are handled correctly.
pub fn parse_dns_response_records(data: &[u8]) -> Vec<(IpAddr, String, u32)> {
    let mut results = Vec::new();
    if data.len() < 12 {
        return results;
    }

    let qdcount = u16::from_be_bytes([data[4], data[5]]) as usize;
    let ancount = u16::from_be_bytes([data[6], data[7]]) as usize;

    // Parse question section to get the queried hostname
    let (hostname, mut offset) = match read_dns_name(data, 12) {
        Some(v) => v,
        None => return results,
    };
    // Skip QTYPE (2) + QCLASS (2) for first question
    offset += 4;
    // Skip remaining questions (if any)
    for _ in 1..qdcount {
        let (_, new_offset) = match read_dns_name(data, offset) {
            Some(v) => v,
            None => return results,
        };
        offset = new_offset + 4; // QTYPE + QCLASS
    }

    // Parse answer section
    for _ in 0..ancount {
        if offset >= data.len() {
            break;
        }
        // Skip answer name (may be compressed)
        let (_, new_offset) = match read_dns_name(data, offset) {
            Some(v) => v,
            None => break,
        };
        offset = new_offset;

        if offset + 10 > data.len() {
            break;
        }
        let rtype = u16::from_be_bytes([data[offset], data[offset + 1]]);
        // rclass at offset+2..offset+4 (skip)
        let ttl = u32::from_be_bytes([
            data[offset + 4],
            data[offset + 5],
            data[offset + 6],
            data[offset + 7],
        ]);
        let rdlength = u16::from_be_bytes([data[offset + 8], data[offset + 9]]) as usize;
        offset += 10;

        if offset + rdlength > data.len() {
            break;
        }

        match rtype {
            1 if rdlength == 4 => {
                // A record
                let ip = Ipv4Addr::new(
                    data[offset],
                    data[offset + 1],
                    data[offset + 2],
                    data[offset + 3],
                );
                results.push((IpAddr::V4(ip), hostname.clone(), ttl));
            }
            28 if rdlength == 16 => {
                // AAAA record
                let mut octets = [0u8; 16];
                octets.copy_from_slice(&data[offset..offset + 16]);
                let ip = Ipv6Addr::from(octets);
                results.push((IpAddr::V6(ip), hostname.clone(), ttl));
            }
            _ => {} // skip CNAME, NS, etc.
        }

        offset += rdlength;
    }

    results
}

/// Read a DNS name at `offset`, handling label sequences and compression pointers.
/// Returns (decoded_name, byte_position_after_name_in_original_stream).
fn read_dns_name(data: &[u8], offset: usize) -> Option<(String, usize)> {
    let mut labels: Vec<String> = Vec::new();
    let mut pos = offset;
    let mut jumped = false;
    let mut end_pos = 0usize; // position after the name in the original stream
    let mut jumps = 0;

    loop {
        if pos >= data.len() {
            return None;
        }
        let len_byte = data[pos];

        if len_byte == 0 {
            // End of name
            if !jumped {
                end_pos = pos + 1;
            }
            break;
        }

        if len_byte & 0xC0 == 0xC0 {
            // Compression pointer
            if pos + 1 >= data.len() {
                return None;
            }
            if !jumped {
                end_pos = pos + 2;
            }
            let ptr = ((len_byte as usize & 0x3F) << 8) | data[pos + 1] as usize;
            pos = ptr;
            jumped = true;
            jumps += 1;
            if jumps > 32 {
                return None; // prevent infinite loops
            }
            continue;
        }

        // Regular label
        let label_len = len_byte as usize;
        if pos + 1 + label_len > data.len() {
            return None;
        }
        let label = std::str::from_utf8(&data[pos + 1..pos + 1 + label_len]).ok()?;
        labels.push(label.to_string());
        pos += 1 + label_len;
    }

    if !jumped {
        // end_pos was set in the loop
    }

    let name = labels.join(".");
    Some((name, end_pos))
}
