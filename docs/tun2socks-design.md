> **Note:** This design document describes the legacy TUN-based architecture (NEPacketTunnelProvider + smoltcp tun2socks). As of v4.0, BaoLianDeng uses NETransparentProxyProvider for socket-level flow interception — see `TransparentProxy/TransparentProxyProvider.swift`.

# tun2socks Design Document (Legacy)

## Overview

tun2socks is the core packet processing layer in BaoLianDeng's VPN tunnel. It sits between the macOS utun device (TUN) and mihomo's SOCKS5 proxy, transparently converting IP-level traffic into proxied connections.

```
Apps
 |  (DNS queries to 198.18.0.1:53, TCP to any IP)
 v
macOS utun device (fd)
 |
 v
tun2socks (Rust, in PacketTunnel system extension)
 |                          |
 | TCP (via smoltcp)        | UDP/DNS (parsed directly)
 v                          v
SOCKS5 proxy            DoH client
(127.0.0.1:7890)        (via SOCKS5)
 |                          |
 v                          v
mihomo proxy engine     DNS response
 |                      written back
 v                      to utun fd
Internet
```

## Threading Model

tun2socks uses two threads communicating via channels:

### Packet Thread (dedicated OS thread)

Runs a synchronous loop that:

1. **Reads** raw IP packets from the utun fd using `select()` for responsive wakeup
2. **Intercepts** UDP packets before smoltcp (only DNS on port 53 is handled; other UDP is dropped)
3. **Pre-inspects** TCP SYN packets to set up smoltcp listening sockets just-in-time
4. **Polls** smoltcp to process TCP state machines (handshake, data transfer, close)
5. **Reads** data from established smoltcp sockets and forwards to tokio via `TunEvent::TcpData`
6. **Writes** SOCKS5 response data into smoltcp sockets (received from tokio via `SocksEvent::TcpData`)
7. **Drains** smoltcp's TX queue, writing output packets to the utun fd with 4-byte AF header

The loop calls `iface.poll()` twice per iteration: once after reading packets from the fd (ingress), and once after writing SOCKS5 data to sockets (egress flush).

### Tokio Thread (async runtime)

Runs `tokio_handler` which processes events from the packet thread:

- **TcpAccepted**: spawns `handle_tcp_conn` which connects to SOCKS5 and relays data bidirectionally
- **TcpData**: forwards app data to the SOCKS5 write task via per-connection mpsc channel
- **TcpClosed**: removes connection from tracking map
- **UdpPacket** (port 53): spawns `handle_dns_query` which resolves via DoH through SOCKS5

## TCP Connection Lifecycle

### 1. SYN Detection and Socket Setup

smoltcp has no `accept()` backlog — sockets must be pre-allocated and listening before a SYN arrives. The packet thread solves this by pre-inspecting the RX queue:

```
for each packet in rx_queue:
    if is TCP SYN (flags & 0x02 != 0, flags & 0x10 == 0):
        extract (dst_ip, dst_port)
        skip if already handled (dedup SYN retransmits)
        find free socket from pool
        socket.listen(port)
        record ConnInfo { dst_ip, dst_port, state: Listening }
```

This runs BEFORE `iface.poll()`, so smoltcp finds a listening socket when it processes the SYN.

### 2. Handshake

```
Client -> SYN -> utun fd -> rx_queue -> smoltcp
smoltcp: Listen -> SynReceived, generates SYN-ACK -> tx_queue -> utun fd -> Client
Client -> ACK -> utun fd -> rx_queue -> smoltcp
smoltcp: SynReceived -> Established
```

The packet thread detects `socket.state() == Established` (not `is_active()`, which is true for SynReceived too) and sends `TunEvent::TcpAccepted`.

### 3. Data Relay

```
Client -> data -> utun fd -> smoltcp -> recv_slice() -> TunEvent::TcpData -> tokio
tokio -> data_rx channel -> write_task -> SOCKS5 stream -> mihomo -> Internet

Internet -> mihomo -> SOCKS5 stream -> read_task -> SocksEvent::TcpData -> packet thread
packet thread -> send_slice() -> smoltcp -> poll() -> tx_queue -> utun fd -> Client
```

### 4. Connection Close

Detected when `!socket.is_open()` in the Established state handler. Sends `TunEvent::TcpClosed`, aborts the smoltcp socket, marks it free for reuse.

## DNS Resolution

DNS queries are intercepted BEFORE smoltcp at the IP/UDP level:

1. `parse_udp_packet()` extracts UDP packets from raw IP data
2. Packets to port 53 are sent as `TunEvent::UdpPacket` to tokio
3. `handle_dns_query()` sends the raw DNS query via DoH (DNS-over-HTTPS) through the SOCKS5 proxy
4. The DoH client (`doh_client.rs`) reads DoH server URLs from mihomo's config (falls back to Cloudflare 1.1.1.1)
5. DNS responses are parsed to populate the IP-to-hostname table (`dns_table.rs`)
6. The raw DNS response is sent back as a `SocksEvent::UdpReply`
7. The packet thread builds a raw IPv4+UDP packet and writes it directly to the utun fd

The DNS table is used later for domain-based SOCKS5 CONNECT: when a TCP connection is established to an IP that was previously resolved, the hostname is used in the SOCKS5 CONNECT request. This allows mihomo to apply domain-based routing rules correctly.

## smoltcp Configuration

### Interface Setup

```rust
let config = Config::new(HardwareAddress::Ip);  // Raw IP, no Ethernet
let mut iface = Interface::new(config, &mut device, timestamp);
iface.update_ip_addrs(|addrs| {
    addrs.push(IpCidr::new(IpAddress::v4(10, 0, 0, 1), 0)).unwrap();
});
iface.set_any_ip(true);
iface.routes_mut().add_default_ipv4_route(Ipv4Address::new(10, 0, 0, 1)).unwrap();
```

- **`Medium::Ip`**: raw IP packets, no Ethernet framing (utun is a Layer 3 device)
- **`any_ip=true`**: accept packets addressed to ANY destination IP, not just our interface IP (required for transparent proxy)
- **Default route via self**: smoltcp's `any_ip` requires a route to the destination; a default route via our own IP satisfies this for all destinations
- **IP `10.0.0.1/0`**: a real IP (not 0.0.0.0, which smoltcp treats as unconfigured) with /0 mask

### Checksum Handling

```rust
caps.checksum.ipv4 = smoltcp::phy::Checksum::Tx;
caps.checksum.tcp = smoltcp::phy::Checksum::Tx;
caps.checksum.udp = smoltcp::phy::Checksum::Tx;
```

- **TX (generate)**: smoltcp computes checksums on outbound packets. The macOS kernel verifies them.
- **RX (skip)**: inbound packets from the utun have zero/dummy checksums because macOS expects hardware to compute them. smoltcp must not reject these.

### TUN Device Implementation

The `TunDevice` struct implements smoltcp's `Device` trait using packet queues:

```rust
struct TunDevice {
    rx_queue: VecDeque<Vec<u8>>,  // packets from utun fd, waiting for smoltcp
    tx_queue: VecDeque<Vec<u8>>,  // packets from smoltcp, waiting for utun fd
}
```

- `receive()` pops from rx_queue, returns (RxToken, TxToken)
- `transmit()` returns TxToken that pushes to tx_queue
- The packet thread fills rx_queue from `read(fd)` and drains tx_queue to `write(fd)`
- Packets are NOT read/written to the fd inside the Device trait — this allows pre-inspection of SYN packets before smoltcp processes them

### Socket Pool

```
512 pre-allocated TCP sockets
64KB rx buffer + 64KB tx buffer each
```

Each socket has associated `ConnInfo`:
- `handle`: smoltcp SocketHandle
- `conn_id`: unique connection ID (monotonically increasing)
- `dst_ip`, `dst_port`: original destination from the SYN packet
- `state`: Free / Listening / Established

SYN deduplication prevents the same (dst_ip, dst_port) from consuming multiple sockets on retransmit.

## Channel Protocol

### TunEvent (packet thread -> tokio)

| Variant | Fields | When |
|---------|--------|------|
| `TcpAccepted` | conn_id, dst_ip, dst_port | Socket reaches Established state |
| `TcpData` | conn_id, data | Data read from smoltcp socket |
| `TcpClosed` | conn_id | Socket no longer open |
| `UdpPacket` | src/dst ip+port, data | UDP packet intercepted (DNS) |

### SocksEvent (tokio -> packet thread)

| Variant | Fields | When |
|---------|--------|------|
| `TcpData` | conn_id, data | Data received from SOCKS5 server |
| `TcpClose` | conn_id | SOCKS5 connection closed |
| `UdpReply` | src/dst ip+port, data | DNS response to write to utun |

## SOCKS5 Client

`socks5_connect()` implements the SOCKS5 handshake:

1. TCP connect to `127.0.0.1:7890` (mihomo's mixed listener)
2. Auth negotiation: no-auth method
3. CONNECT request: domain-based (0x03) when hostname known, IPv4 (0x01) as fallback
4. Read reply, drain address bytes

Domain-based SOCKS5 is preferred because mihomo applies routing rules based on domain names. Without the domain, mihomo may route traffic through an unreachable external proxy instead of DIRECT.

## Race Condition Prevention

The per-connection data channel is inserted into `TCP_CONN_MAP` BEFORE spawning the SOCKS5 task:

```rust
// In tokio_handler, on TcpAccepted:
let (data_tx, data_rx) = mpsc::channel(64);
TCP_CONN_MAP.lock().insert(conn_id, data_tx);  // insert FIRST
tokio::spawn(handle_tcp_conn(conn_id, ..., data_rx));  // spawn SECOND
```

This ensures that if `TcpData` arrives before `handle_tcp_conn` starts executing, the data is buffered in the channel rather than dropped.

## Polling Strategy

The packet thread uses `select()` on the utun fd to wake immediately when packets arrive:

```rust
let mut fds = libc::fd_set { ... };
libc::FD_SET(fd, &mut fds);
let mut timeout = libc::timeval { tv_sec: 0, tv_usec: 1000 }; // 1ms max
libc::select(fd + 1, &mut fds, ...);
```

This wakes up immediately when new packets arrive on the utun fd, rather than waiting for a fixed sleep interval. This is critical for TCP performance — delayed ACKs cause retransmission timeouts and connection failures.

## Network Constraints

The system extension process has limited network access:

- **Localhost only**: TCP connections to `127.0.0.1` work (SOCKS5 proxy, REST API)
- **No direct outbound**: TCP `connect()` to external IPs fails with EADDRNOTAVAIL (error 49) because the extension's traffic would loop through its own TUN
- **Consequence**: all external traffic MUST go through the SOCKS5 proxy. This includes DNS (via DoH through SOCKS5) and all TCP connections.

## File Map

| File | Purpose |
|------|---------|
| `src/tun2socks.rs` | Main tun2socks implementation (smoltcp device, socket pool, packet thread, tokio handler, SOCKS5 client) |
| `src/dns_table.rs` | IP-to-hostname mapping table populated from DNS responses |
| `src/doh_client.rs` | DNS-over-HTTPS client that sends queries through SOCKS5 proxy |
| `src/logging.rs` | Bridge logging to file (truncated on each tunnel start) |
| `src/lib.rs` | FFI boundary, engine lifecycle, tun2socks entry point |
| `src/diagnostics.rs` | Connectivity diagnostic tests (TCP, DNS, proxy) |
