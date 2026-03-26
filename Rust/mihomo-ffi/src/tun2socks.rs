//! smoltcp-based tun2socks: reads raw IP packets from the macOS utun fd.
//! TCP packets are processed by smoltcp for reassembly, then forwarded via
//! SOCKS5 to the local mihomo mixed listener. UDP packets (DNS) are parsed
//! directly from the IP header and forwarded via DoH.

use crate::dns_table;
use crate::doh_client;
use crate::logging;
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::os::raw::c_void;
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, info};

use smoltcp::iface::{Config, Interface, Route, SocketHandle, SocketSet};
use smoltcp::phy::{self, Device, DeviceCapabilities, Medium};
use smoltcp::socket::tcp as smol_tcp;
use smoltcp::time::Instant as SmolInstant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, IpListenEndpoint};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

static TUN2SOCKS_RUNNING: AtomicBool = AtomicBool::new(false);

pub fn start(fd: i32, socks_port: u16, _dns_port: u16) -> Result<(), String> {
    if TUN2SOCKS_RUNNING.swap(true, Ordering::SeqCst) {
        return Err("tun2socks already running".into());
    }

    let socks_addr = SocketAddrV4::new(Ipv4Addr::LOCALHOST, socks_port);

    info!("tun2socks starting: fd={}, socks={}", fd, socks_addr);

    // Initialize DoH client (reads config, creates reqwest client with SOCKS5 proxy)
    doh_client::init_doh_client(socks_port);

    let rt = crate::get_runtime();

    // Channels between packet thread and tokio
    let (tun_tx, tun_rx) = mpsc::unbounded_channel::<TunEvent>();
    let (socks_tx, socks_rx) = mpsc::unbounded_channel::<SocksEvent>();

    // Spawn the tokio side (handles SOCKS5 connections and DoH DNS resolution)
    let socks_addr2 = SocketAddr::V4(socks_addr);
    rt.spawn(async move {
        tokio_handler(tun_rx, socks_tx, socks_addr2).await;
    });

    // Spawn the packet processing thread (reads/writes fd, drives smoltcp)
    std::thread::Builder::new()
        .name("smoltcp-tun2socks".into())
        .spawn(move || {
            packet_thread(fd, tun_tx, socks_rx);
            TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
            info!("tun2socks packet thread exited");
        })
        .map_err(|e| format!("spawn packet thread: {}", e))?;

    Ok(())
}

pub fn stop() {
    TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
}

#[allow(dead_code)]
pub fn is_running() -> bool {
    TUN2SOCKS_RUNNING.load(Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Events between packet thread and tokio
// ---------------------------------------------------------------------------

enum TunEvent {
    TcpAccepted {
        conn_id: u64,
        dst_ip: u32,
        dst_port: u16,
    },
    TcpData {
        conn_id: u64,
        data: Vec<u8>,
    },
    TcpClosed {
        conn_id: u64,
    },
    UdpPacket {
        src_ip: u32,
        src_port: u16,
        dst_ip: u32,
        dst_port: u16,
        data: Vec<u8>,
    },
}

enum SocksEvent {
    TcpData { conn_id: u64, data: Vec<u8> },
    TcpClose { conn_id: u64 },
    UdpReply {
        dst_ip: u32,
        dst_port: u16,
        src_ip: u32,
        src_port: u16,
        data: Vec<u8>,
    },
}

// ---------------------------------------------------------------------------
// smoltcp TUN Device
// ---------------------------------------------------------------------------

use std::collections::VecDeque;

struct TunDevice {
    rx_queue: VecDeque<Vec<u8>>,
    tx_queue: VecDeque<Vec<u8>>,
    mtu: usize,
}

impl TunDevice {
    fn new(mtu: usize) -> Self {
        Self {
            rx_queue: VecDeque::new(),
            tx_queue: VecDeque::new(),
            mtu,
        }
    }
}

impl Device for TunDevice {
    type RxToken<'a> = TunRxToken;
    type TxToken<'a> = TunTxToken<'a>;

    fn receive(&mut self, _timestamp: SmolInstant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        if let Some(pkt) = self.rx_queue.pop_front() {
            Some((
                TunRxToken(pkt),
                TunTxToken(&mut self.tx_queue),
            ))
        } else {
            None
        }
    }

    fn transmit(&mut self, _timestamp: SmolInstant) -> Option<Self::TxToken<'_>> {
        Some(TunTxToken(&mut self.tx_queue))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = self.mtu;
        // Generate checksums on TX (kernel checks them), skip verify on RX
        // (utun inbound packets have zero/dummy checksums from hardware offload)
        caps.checksum = smoltcp::phy::ChecksumCapabilities::default();
        caps.checksum.ipv4 = smoltcp::phy::Checksum::Tx;
        caps.checksum.tcp = smoltcp::phy::Checksum::Tx;
        caps.checksum.udp = smoltcp::phy::Checksum::Tx;
        caps
    }
}

struct TunRxToken(Vec<u8>);

impl phy::RxToken for TunRxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.0)
    }
}

struct TunTxToken<'a>(&'a mut VecDeque<Vec<u8>>);

impl<'a> phy::TxToken for TunTxToken<'a> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut buf = vec![0u8; len];
        let result = f(&mut buf);
        self.0.push_back(buf);
        result
    }
}

// ---------------------------------------------------------------------------
// Connection tracking
// ---------------------------------------------------------------------------

const MAX_SOCKETS: usize = 512;
const SOCKET_RX_BUF: usize = 65535;
const SOCKET_TX_BUF: usize = 65535;

#[derive(Clone, Copy, PartialEq, Debug)]
enum ConnState {
    Free,
    Listening,
    Established,
}

struct ConnInfo {
    handle: SocketHandle,
    conn_id: u64,
    dst_ip: u32,
    dst_port: u16,
    state: ConnState,
}

// ---------------------------------------------------------------------------
// Packet thread (replaces lwip_thread)
// ---------------------------------------------------------------------------

fn packet_thread(
    fd: RawFd,
    tun_tx: mpsc::UnboundedSender<TunEvent>,
    mut socks_rx: mpsc::UnboundedReceiver<SocksEvent>,
) {
    logging::bridge_log("packet_thread: starting (smoltcp)");

    // Create smoltcp device and interface
    let mut device = TunDevice::new(1500);
    let config = Config::new(HardwareAddress::Ip);
    let mut iface = Interface::new(config, &mut device, SmolInstant::from_millis(0));

    // Set interface IP and enable any_ip so smoltcp accepts packets
    // to ALL destination IPs (required for transparent proxy / tun2socks)
    iface.update_ip_addrs(|addrs| {
        addrs.push(IpCidr::new(IpAddress::v4(10, 0, 0, 1), 0)).unwrap();
    });
    iface.set_any_ip(true);
    // Add default route via our own IP — required for any_ip to accept packets
    iface.routes_mut().add_default_ipv4_route(smoltcp::wire::Ipv4Address::new(10, 0, 0, 1)).unwrap();

    // Pre-allocate socket pool
    let mut sockets = SocketSet::new(vec![]);
    let mut conns: Vec<ConnInfo> = Vec::with_capacity(MAX_SOCKETS);
    let mut next_conn_id: u64 = 1;

    for _ in 0..MAX_SOCKETS {
        let rx_buf = smol_tcp::SocketBuffer::new(vec![0u8; SOCKET_RX_BUF]);
        let tx_buf = smol_tcp::SocketBuffer::new(vec![0u8; SOCKET_TX_BUF]);
        let socket = smol_tcp::Socket::new(rx_buf, tx_buf);
        let handle = sockets.add(socket);
        conns.push(ConnInfo {
            handle,
            conn_id: 0,
            dst_ip: 0,
            dst_port: 0,
            state: ConnState::Free,
        });
    }

    logging::bridge_log(&format!("packet_thread: {} sockets allocated", MAX_SOCKETS));

    // Set fd to non-blocking
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    logging::bridge_log("packet_thread: entering main loop");

    let mut read_buf = vec![0u8; 65535];
    let mut pkt_total: u64 = 0;
    let mut pkt_udp: u64 = 0;
    let mut pkt_tcp: u64 = 0;
    let mut pkt_other: u64 = 0;
    let mut read_errors: u64 = 0;
    let mut active_conns: u64;
    let mut tx_pkt_count: u64 = 0;
    let mut tx_byte_count: u64 = 0;
    let mut socks_data_recv: u64 = 0;
    let mut socks_data_sent: u64 = 0;
    let mut socks_data_dropped: u64 = 0;
    let mut last_stats = Instant::now();
    let start_time = Instant::now();

    // Main loop
    while TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
        let now_millis = start_time.elapsed().as_millis() as i64;
        let smol_now = SmolInstant::from_millis(now_millis);

        // 1. Read packets from fd
        loop {
            let n = unsafe {
                libc::read(fd, read_buf.as_mut_ptr() as *mut c_void, read_buf.len())
            };
            if n < 0 {
                let errno = unsafe { *libc::__error() };
                if errno != libc::EAGAIN && errno != libc::EWOULDBLOCK {
                    read_errors += 1;
                    if read_errors <= 5 {
                        logging::bridge_log(&format!(
                            "packet_thread: read error: errno={}", errno
                        ));
                    }
                }
                break;
            }
            if n == 0 {
                break;
            }
            let n = n as usize;
            pkt_total += 1;
            // Strip 4-byte utun header
            if n <= 4 {
                continue;
            }
            let ip_data = &read_buf[4..n];

            // Log first few packets
            if pkt_total <= 5 {
                let version = if !ip_data.is_empty() { ip_data[0] >> 4 } else { 0 };
                let proto = if ip_data.len() > 9 { ip_data[9] } else { 0 };
                logging::bridge_log(&format!(
                    "packet_thread: pkt #{}: {}B, ip_ver={}, proto={}",
                    pkt_total, n, version, proto
                ));
            }

            // Intercept UDP before smoltcp
            if let Some((src_ip, src_port, dst_ip, dst_port, payload)) =
                parse_udp_packet(ip_data)
            {
                pkt_udp += 1;
                if pkt_udp <= 3 {
                    let dst = Ipv4Addr::from(dst_ip.to_ne_bytes());
                    logging::bridge_log(&format!(
                        "packet_thread: UDP -> {}:{} ({}B)",
                        dst, dst_port, payload.len()
                    ));
                }
                let _ = tun_tx.send(TunEvent::UdpPacket {
                    src_ip,
                    src_port,
                    dst_ip,
                    dst_port,
                    data: payload.to_vec(),
                });
            } else {
                // Check if TCP for stats
                if ip_data.len() > 9 && ip_data[9] == 6 {
                    pkt_tcp += 1;
                } else {
                    pkt_other += 1;
                }
                // Queue for smoltcp
                device.rx_queue.push_back(ip_data.to_vec());
            }
        }

        // 2. Pre-inspect SYN packets and set up listening sockets
        let mut syns_found = 0u64;
        let mut listens_set = 0u64;
        for pkt in &device.rx_queue {
            if let Some((dst_ip, dst_port)) = parse_tcp_syn(pkt) {
                syns_found += 1;
                if syns_found <= 3 {
                    let dst = Ipv4Addr::from(dst_ip.to_ne_bytes());
                    logging::bridge_log(&format!(
                        "SYN detected: {}:{}", dst, dst_port
                    ));
                }
                // Skip if we already have a Listening/Established socket for this exact SYN
                // (SYN retransmit — let smoltcp handle it with the existing socket)
                let already_handled = conns.iter().any(|c| {
                    c.dst_ip == dst_ip && c.dst_port == dst_port
                        && (c.state == ConnState::Listening || c.state == ConnState::Established)
                });
                if already_handled {
                    continue;
                }
                // Find a free socket and listen on dst_port
                if let Some(ci) = conns.iter_mut().find(|c| c.state == ConnState::Free) {
                    let socket = sockets.get_mut::<smol_tcp::Socket>(ci.handle);
                    // Listen on any IP, specific port
                    match socket.listen(IpListenEndpoint {
                        addr: None,
                        port: dst_port,
                    }) {
                        Ok(()) => {
                            ci.conn_id = next_conn_id;
                            next_conn_id += 1;
                            ci.dst_ip = dst_ip;
                            ci.dst_port = dst_port;
                            ci.state = ConnState::Listening;
                            listens_set += 1;
                            if listens_set <= 3 {
                                logging::bridge_log(&format!(
                                    "Socket listening on port {} (conn_id={})",
                                    dst_port, ci.conn_id
                                ));
                            }
                        }
                        Err(e) => {
                            if syns_found <= 3 {
                                logging::bridge_log(&format!(
                                    "listen failed for port {}: {:?}", dst_port, e
                                ));
                            }
                        }
                    }
                } else if syns_found <= 3 {
                    logging::bridge_log("No free sockets for SYN");
                }
            }
        }

        // 3. Poll smoltcp (may need multiple polls for SYN→SYN-ACK)
        iface.poll(smol_now, &mut device, &mut sockets);
        if syns_found > 0 && syns_found <= 3 {
            // Log socket states for recently set-up listeners
            for ci in conns.iter().filter(|c| c.state == ConnState::Listening) {
                let socket = sockets.get::<smol_tcp::Socket>(ci.handle);
                logging::bridge_log(&format!(
                    "conn_id={} after poll: state={:?}, is_active={}, is_open={}, is_listening={}, tx_queue={}",
                    ci.conn_id, socket.state(), socket.is_active(), socket.is_open(), socket.is_listening(),
                    device.tx_queue.len()
                ));
            }
        }

        // 4. Process socket events
        active_conns = 0;
        for ci in conns.iter_mut() {
            let socket = sockets.get_mut::<smol_tcp::Socket>(ci.handle);

            match ci.state {
                ConnState::Free => {}
                ConnState::Listening => {
                    match socket.state() {
                        smol_tcp::State::Established => {
                            // 3-way handshake complete
                            ci.state = ConnState::Established;
                            active_conns += 1;
                            let dst = Ipv4Addr::from(ci.dst_ip.to_ne_bytes());
                            logging::bridge_log(&format!(
                                "TCP Established: conn_id={} dst={}:{}",
                                ci.conn_id, dst, ci.dst_port
                            ));
                            let _ = tun_tx.send(TunEvent::TcpAccepted {
                                conn_id: ci.conn_id,
                                dst_ip: ci.dst_ip,
                                dst_port: ci.dst_port,
                            });
                        }
                        smol_tcp::State::SynReceived => {
                            // Handshake in progress — keep waiting
                            active_conns += 1;
                        }
                        smol_tcp::State::Listen => {
                            // Still listening, no SYN matched yet
                        }
                        _ => {
                            // Closed, TimeWait, or other terminal state — recycle
                            socket.abort();
                            ci.state = ConnState::Free;
                            ci.conn_id = 0;
                        }
                    }
                }
                ConnState::Established => {
                    if !socket.is_open() {
                        // Connection closed
                        let _ = tun_tx.send(TunEvent::TcpClosed {
                            conn_id: ci.conn_id,
                        });
                        socket.abort();
                        ci.state = ConnState::Free;
                        ci.conn_id = 0;
                        continue;
                    }
                    active_conns += 1;

                    // Read data from socket
                    if socket.may_recv() {
                        let mut buf = vec![0u8; 32768];
                        match socket.recv_slice(&mut buf) {
                            Ok(n) if n > 0 => {
                                buf.truncate(n);
                                logging::bridge_log(&format!(
                                    "TCP recv: conn_id={} {}B dst={}:{}",
                                    ci.conn_id, n,
                                    Ipv4Addr::from(ci.dst_ip.to_ne_bytes()), ci.dst_port
                                ));
                                let _ = tun_tx.send(TunEvent::TcpData {
                                    conn_id: ci.conn_id,
                                    data: buf,
                                });
                            }
                            _ => {}
                        }
                    }
                }
            }
        }

        // 5. Process events from tokio (SOCKS5 responses)
        while let Ok(event) = socks_rx.try_recv() {
            match event {
                SocksEvent::TcpData { conn_id, data } => {
                    socks_data_recv += data.len() as u64;
                    if let Some(ci) = conns.iter().find(|c| c.conn_id == conn_id && c.state == ConnState::Established) {
                        let socket = sockets.get_mut::<smol_tcp::Socket>(ci.handle);
                        if socket.can_send() {
                            match socket.send_slice(&data) {
                                Ok(n) => {
                                    socks_data_sent += n as u64;
                                    if n < data.len() {
                                        socks_data_dropped += (data.len() - n) as u64;
                                    }
                                }
                                Err(e) => {
                                    socks_data_dropped += data.len() as u64;
                                    logging::bridge_log(&format!(
                                        "send_slice ERR: conn_id={} err={:?} state={:?}",
                                        conn_id, e, socket.state()
                                    ));
                                }
                            }
                        } else {
                            socks_data_dropped += data.len() as u64;
                            logging::bridge_log(&format!(
                                "can_send=false: conn_id={} state={:?} send_queue={}",
                                conn_id, socket.state(), socket.send_queue()
                            ));
                        }
                    } else {
                        // Connection not found or not Established
                        let found = conns.iter().find(|c| c.conn_id == conn_id);
                        if let Some(ci) = found {
                            logging::bridge_log(&format!(
                                "SocksData MISS: conn_id={} len={} our_state={:?} sock_state={:?}",
                                conn_id, data.len(), ci.state,
                                sockets.get::<smol_tcp::Socket>(ci.handle).state()
                            ));
                        } else {
                            logging::bridge_log(&format!(
                                "SocksData ORPHAN: conn_id={} len={} (no conn)",
                                conn_id, data.len()
                            ));
                        }
                    }
                }
                SocksEvent::TcpClose { conn_id } => {
                    if let Some(ci) = conns.iter_mut().find(|c| c.conn_id == conn_id) {
                        let socket = sockets.get_mut::<smol_tcp::Socket>(ci.handle);
                        socket.close();
                    }
                }
                SocksEvent::UdpReply {
                    dst_ip,
                    dst_port,
                    src_ip,
                    src_port,
                    data,
                } => {
                    let raw = build_udp_packet(src_ip, src_port, dst_ip, dst_port, &data);
                    let mut pkt = Vec::with_capacity(4 + raw.len());
                    pkt.extend_from_slice(&2u32.to_be_bytes());
                    pkt.extend_from_slice(&raw);
                    unsafe {
                        libc::write(fd, pkt.as_ptr() as *const c_void, pkt.len());
                    }
                }
            }
        }

        // 6. Poll again to flush data written to sockets in step 5
        iface.poll(smol_now, &mut device, &mut sockets);

        // 7. Drain TX queue — write smoltcp output packets to utun fd
        static TX_LOG_COUNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        while let Some(pkt) = device.tx_queue.pop_front() {
            if pkt.is_empty() {
                continue;
            }
            let count = TX_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
            if pkt.len() >= 20 && (pkt[0] >> 4) == 4 && pkt[9] == 6 {
                let ihl = (pkt[0] & 0x0F) as usize * 4;
                let tcp_flags = if pkt.len() > ihl + 13 { pkt[ihl + 13] } else { 0 };
                let data_len = pkt.len() as i64 - ihl as i64 - 20; // approximate
                // Log PSH+ACK (data) packets
                if (tcp_flags & 0x08) != 0 && count < 200 {
                    let src = format!("{}.{}.{}.{}", pkt[12], pkt[13], pkt[14], pkt[15]);
                    let dst = format!("{}.{}.{}.{}", pkt[16], pkt[17], pkt[18], pkt[19]);
                    let src_port = u16::from_be_bytes([pkt[ihl], pkt[ihl+1]]);
                    let dst_port = u16::from_be_bytes([pkt[ihl+2], pkt[ihl+3]]);
                    logging::bridge_log(&format!(
                        "TX DATA: {}B {}:{} -> {}:{} flags=0x{:02x} payload={}B",
                        pkt.len(), src, src_port, dst, dst_port, tcp_flags, data_len
                    ));
                }
                // Log first few of any type
                if count < 10 {
                    let src = format!("{}.{}.{}.{}", pkt[12], pkt[13], pkt[14], pkt[15]);
                    let dst = format!("{}.{}.{}.{}", pkt[16], pkt[17], pkt[18], pkt[19]);
                    logging::bridge_log(&format!(
                        "TX pkt#{}: {}B {} -> {} flags=0x{:02x}",
                        count, pkt.len(), src, dst, tcp_flags
                    ));
                }
            }
            // Determine AF from IP version
            let af: u32 = if (pkt[0] >> 4) == 6 { 30 } else { 2 };
            let mut out = Vec::with_capacity(4 + pkt.len());
            out.extend_from_slice(&af.to_be_bytes());
            out.extend_from_slice(&pkt);
            tx_pkt_count += 1;
            tx_byte_count += out.len() as u64;
            let written = unsafe {
                libc::write(fd, out.as_ptr() as *const c_void, out.len())
            };
            if written < 0 && tx_pkt_count <= 5 {
                let errno = unsafe { *libc::__error() };
                logging::bridge_log(&format!("TX write error: errno={}, pkt_len={}", errno, out.len()));
            }
        }

        // 7. Wait for fd readable via select (wakes immediately on new packets)
        unsafe {
            let mut fds = libc::fd_set { fds_bits: [0; 32] };
            libc::FD_SET(fd, &mut fds);
            let mut timeout = libc::timeval { tv_sec: 0, tv_usec: 1000 }; // 1ms max
            libc::select(fd + 1, &mut fds, std::ptr::null_mut(), std::ptr::null_mut(), &mut timeout);
        }

        // 8. Periodic stats
        if last_stats.elapsed() >= std::time::Duration::from_secs(5) {
            logging::bridge_log(&format!(
                "STATS: rx={} udp={} tcp={} conns={} tx_pkts={} tx_bytes={} socks_recv={} socks_sent={} socks_drop={}",
                pkt_total, pkt_udp, pkt_tcp, active_conns, tx_pkt_count, tx_byte_count,
                socks_data_recv, socks_data_sent, socks_data_dropped
            ));
            last_stats = Instant::now();
        }
    }

    logging::bridge_log("packet_thread: exiting main loop");
}

/// Parse a TCP SYN packet, returning (dst_ip_ne, dst_port) if it's a SYN.
fn parse_tcp_syn(ip_data: &[u8]) -> Option<(u32, u16)> {
    if ip_data.len() < 40 {
        return None; // minimum: 20-byte IP + 20-byte TCP
    }
    if (ip_data[0] >> 4) != 4 {
        return None; // not IPv4
    }
    if ip_data[9] != 6 {
        return None; // not TCP
    }
    let ihl = (ip_data[0] & 0x0F) as usize * 4;
    if ip_data.len() < ihl + 20 {
        return None;
    }
    let tcp_flags = ip_data[ihl + 13];
    // SYN flag set, ACK not set (initial SYN only)
    if (tcp_flags & 0x02) == 0 || (tcp_flags & 0x10) != 0 {
        return None;
    }
    let dst_ip = u32::from_ne_bytes([ip_data[16], ip_data[17], ip_data[18], ip_data[19]]);
    let dst_port = u16::from_be_bytes([ip_data[ihl + 2], ip_data[ihl + 3]]);
    Some((dst_ip, dst_port))
}

/// Parse an IPv4+UDP packet, returning (src_ip, src_port, dst_ip, dst_port, payload).
fn parse_udp_packet(ip_data: &[u8]) -> Option<(u32, u16, u32, u16, &[u8])> {
    if ip_data.len() < 28 {
        return None;
    }
    let version_ihl = ip_data[0];
    if (version_ihl >> 4) != 4 {
        return None;
    }
    if ip_data[9] != 17 {
        return None;
    }
    let ihl = (version_ihl & 0x0F) as usize * 4;
    if ip_data.len() < ihl + 8 {
        return None;
    }
    let src_ip = u32::from_ne_bytes([ip_data[12], ip_data[13], ip_data[14], ip_data[15]]);
    let dst_ip = u32::from_ne_bytes([ip_data[16], ip_data[17], ip_data[18], ip_data[19]]);
    let src_port = u16::from_be_bytes([ip_data[ihl], ip_data[ihl + 1]]);
    let dst_port = u16::from_be_bytes([ip_data[ihl + 2], ip_data[ihl + 3]]);
    let udp_data_len = u16::from_be_bytes([ip_data[ihl + 4], ip_data[ihl + 5]]) as usize;
    let payload_start = ihl + 8;
    let payload_end = (ihl + udp_data_len).min(ip_data.len());
    if payload_start > payload_end {
        return None;
    }
    Some((src_ip, src_port, dst_ip, dst_port, &ip_data[payload_start..payload_end]))
}

// ---------------------------------------------------------------------------
// Tokio handler (runs on the tokio runtime)
// ---------------------------------------------------------------------------

async fn tokio_handler(
    mut tun_rx: mpsc::UnboundedReceiver<TunEvent>,
    socks_tx: mpsc::UnboundedSender<SocksEvent>,
    socks_addr: SocketAddr,
) {
    while let Some(event) = tun_rx.recv().await {
        match event {
            TunEvent::TcpAccepted {
                conn_id,
                dst_ip,
                dst_port,
            } => {
                let socks_tx2 = socks_tx.clone();
                let dst = SocketAddrV4::new(
                    Ipv4Addr::from(dst_ip.to_ne_bytes()),
                    dst_port,
                );
                debug!("tun2socks: TCP {} -> {}", conn_id, dst);
                // Insert channel BEFORE spawning so TcpData events don't race
                let (data_tx, data_rx) = mpsc::channel::<Vec<u8>>(64);
                TCP_CONN_MAP.lock().insert(conn_id, data_tx);
                tokio::spawn(async move {
                    handle_tcp_conn(conn_id, dst, socks_addr, socks_tx2, data_rx).await;
                });
            }
            TunEvent::TcpData { conn_id, data } => {
                let tx = TCP_CONN_MAP.lock().get(&conn_id).cloned();
                if let Some(tx) = tx {
                    let _ = tx.send(data).await;
                }
            }
            TunEvent::TcpClosed { conn_id } => {
                TCP_CONN_MAP.lock().remove(&conn_id);
            }
            TunEvent::UdpPacket {
                src_ip,
                src_port,
                dst_ip,
                dst_port,
                data,
            } => {
                if dst_port == 53 {
                    let socks_tx2 = socks_tx.clone();
                    tokio::spawn(async move {
                        handle_dns_query(src_ip, src_port, dst_ip, dst_port, data, socks_tx2).await;
                    });
                } else {
                    debug!(
                        "tun2socks: dropping non-DNS UDP to {}:{}",
                        Ipv4Addr::from(dst_ip.to_ne_bytes()),
                        dst_port
                    );
                }
            }
        }
    }
}

// Per-connection data channel map
use parking_lot::Mutex as ParkMutex;
use std::sync::LazyLock;

static TCP_CONN_MAP: LazyLock<ParkMutex<HashMap<u64, mpsc::Sender<Vec<u8>>>>> =
    LazyLock::new(|| ParkMutex::new(HashMap::new()));

async fn handle_tcp_conn(
    conn_id: u64,
    dst: SocketAddrV4,
    socks_addr: SocketAddr,
    socks_tx: mpsc::UnboundedSender<SocksEvent>,
    mut data_rx: mpsc::Receiver<Vec<u8>>,
) {

    // Use domain-based SOCKS5 when we have the hostname from DNS table.
    // This allows mihomo to apply domain-based rules correctly.
    // Fall back to IP-based when hostname is unknown.
    let target = match dns_table::dns_table_lookup(IpAddr::V4(*dst.ip())) {
        Some(hostname) => SocksTarget::Domain(hostname, dst.port()),
        None => SocksTarget::Ip(dst),
    };

    let target_desc = match &target {
        SocksTarget::Domain(h, p) => format!("domain={}:{}", h, p),
        SocksTarget::Ip(a) => format!("ip={}", a),
    };
    logging::bridge_log(&format!("SOCKS5 connecting: conn_id={} {}", conn_id, target_desc));
    let stream = match socks5_connect(socks_addr, target).await {
        Ok(s) => {
            logging::bridge_log(&format!("SOCKS5 connected: conn_id={}", conn_id));
            s
        }
        Err(e) => {
            logging::bridge_log(&format!("SOCKS5 FAIL: conn_id={} dst={} err={}", conn_id, dst, e));
            let _ = socks_tx.send(SocksEvent::TcpClose { conn_id });
            TCP_CONN_MAP.lock().remove(&conn_id);
            return;
        }
    };

    let (mut read_half, mut write_half) = stream.into_split();

    let socks_tx2 = socks_tx.clone();
    let conn_id2 = conn_id;
    let write_task = tokio::spawn(async move {
        while let Some(data) = data_rx.recv().await {
            logging::bridge_log(&format!(
                "SOCKS5 write: conn_id={} {}B", conn_id2, data.len()
            ));
            if write_half.write_all(&data).await.is_err() {
                logging::bridge_log(&format!(
                    "SOCKS5 write ERR: conn_id={}", conn_id2
                ));
                break;
            }
        }
        logging::bridge_log(&format!("SOCKS5 write done: conn_id={}", conn_id2));
        let _ = write_half.shutdown().await;
    });

    let read_task = tokio::spawn(async move {
        let mut buf = vec![0u8; 32768];
        loop {
            match read_half.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    let _ = socks_tx2.send(SocksEvent::TcpData {
                        conn_id,
                        data: buf[..n].to_vec(),
                    });
                }
                Err(_) => break,
            }
        }
        let _ = socks_tx2.send(SocksEvent::TcpClose { conn_id });
    });

    let _ = tokio::select! {
        r = write_task => r,
        r = read_task => r,
    };

    TCP_CONN_MAP.lock().remove(&conn_id);
}

// ---------------------------------------------------------------------------
// SOCKS5 client
// ---------------------------------------------------------------------------

enum SocksTarget {
    Ip(SocketAddrV4),
    Domain(String, u16),
}

async fn socks5_connect(proxy: SocketAddr, target: SocksTarget) -> io::Result<TcpStream> {
    let mut stream = TcpStream::connect(proxy).await?;

    // Auth negotiation: version=5, 1 method, no-auth
    stream.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut resp = [0u8; 2];
    stream.read_exact(&mut resp).await?;
    if resp[0] != 0x05 || resp[1] != 0x00 {
        return Err(io::Error::new(io::ErrorKind::Other, "SOCKS5 auth failed"));
    }

    // CONNECT request
    match &target {
        SocksTarget::Ip(dst) => {
            let ip = dst.ip().octets();
            let port = dst.port().to_be_bytes();
            let req = [0x05, 0x01, 0x00, 0x01, ip[0], ip[1], ip[2], ip[3], port[0], port[1]];
            stream.write_all(&req).await?;
        }
        SocksTarget::Domain(domain, port) => {
            let domain_bytes = domain.as_bytes();
            let len = domain_bytes.len() as u8;
            let port_bytes = port.to_be_bytes();
            let mut req = Vec::with_capacity(4 + 1 + domain_bytes.len() + 2);
            req.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, len]);
            req.extend_from_slice(domain_bytes);
            req.extend_from_slice(&port_bytes);
            stream.write_all(&req).await?;
        }
    }

    let mut reply_header = [0u8; 4];
    stream.read_exact(&mut reply_header).await?;
    if reply_header[0] != 0x05 || reply_header[1] != 0x00 {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("SOCKS5 CONNECT failed: rep={}", reply_header[1]),
        ));
    }

    match reply_header[3] {
        0x01 => {
            let mut buf = [0u8; 6];
            stream.read_exact(&mut buf).await?;
        }
        0x03 => {
            let mut len_buf = [0u8; 1];
            stream.read_exact(&mut len_buf).await?;
            let mut buf = vec![0u8; len_buf[0] as usize + 2];
            stream.read_exact(&mut buf).await?;
        }
        0x04 => {
            let mut buf = [0u8; 18];
            stream.read_exact(&mut buf).await?;
        }
        _ => {}
    }

    Ok(stream)
}

// ---------------------------------------------------------------------------
// Raw IP+UDP packet construction (for DNS responses via TUN fd)
// ---------------------------------------------------------------------------

fn build_udp_packet(src_ip: u32, src_port: u16, dst_ip: u32, dst_port: u16, payload: &[u8]) -> Vec<u8> {
    let udp_len = 8 + payload.len();
    let total_len = 20 + udp_len;
    let mut pkt = vec![0u8; total_len];

    pkt[0] = 0x45;
    pkt[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
    pkt[6] = 0x40; // Don't Fragment
    pkt[8] = 64;   // TTL
    pkt[9] = 17;   // protocol = UDP
    pkt[12..16].copy_from_slice(&src_ip.to_ne_bytes());
    pkt[16..20].copy_from_slice(&dst_ip.to_ne_bytes());

    let cksum = ip_checksum(&pkt[..20]);
    pkt[10..12].copy_from_slice(&cksum.to_be_bytes());

    pkt[20..22].copy_from_slice(&src_port.to_be_bytes());
    pkt[22..24].copy_from_slice(&dst_port.to_be_bytes());
    pkt[24..26].copy_from_slice(&(udp_len as u16).to_be_bytes());
    pkt[28..].copy_from_slice(payload);

    pkt
}

fn ip_checksum(header: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    for i in (0..header.len()).step_by(2) {
        let word = if i + 1 < header.len() {
            (header[i] as u32) << 8 | header[i + 1] as u32
        } else {
            (header[i] as u32) << 8
        };
        sum += word;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !sum as u16
}

// ---------------------------------------------------------------------------
// DNS resolution via DoH
// ---------------------------------------------------------------------------

async fn handle_dns_query(
    src_ip: u32,
    src_port: u16,
    dst_ip: u32,
    dst_port: u16,
    query: Vec<u8>,
    socks_tx: mpsc::UnboundedSender<SocksEvent>,
) {
    let query_name = dns_table::parse_dns_query_name(&query)
        .unwrap_or_else(|| "<unparseable>".to_string());
    logging::bridge_log(&format!(
        "DoH query: {} from {:?}:{}",
        query_name,
        Ipv4Addr::from(src_ip.to_ne_bytes()),
        src_port
    ));

    let response = match doh_client::resolve_via_doh(&query).await {
        Some(r) => r,
        None => {
            logging::bridge_log(&format!("DoH failed for {}", query_name));
            return;
        }
    };

    let records = dns_table::parse_dns_response_records(&response);
    for (ip, hostname, ttl) in &records {
        dns_table::dns_table_insert(*ip, hostname.clone(), *ttl);
    }
    if !records.is_empty() {
        logging::bridge_log(&format!(
            "DoH response: {} -> {} record(s)",
            query_name,
            records.len()
        ));
    }

    let _ = socks_tx.send(SocksEvent::UdpReply {
        dst_ip: src_ip,
        dst_port: src_port,
        src_ip: dst_ip,
        src_port: dst_port,
        data: response,
    });
}
