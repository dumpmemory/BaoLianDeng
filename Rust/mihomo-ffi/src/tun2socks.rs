//! lwIP-based tun2socks: reads raw IP packets from the macOS utun fd.
//! TCP packets are processed by lwIP for reassembly, then forwarded via
//! SOCKS5 to the local mihomo mixed listener. UDP packets (DNS) are parsed
//! directly from the IP header and forwarded via DoH.

use crate::dns_table;
use crate::doh_client;
use crate::logging;
use crate::lwip_ffi;
use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::os::raw::c_void;
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{debug, info};

// ---------------------------------------------------------------------------
// Wake pipe for signaling the packet loop from tokio tasks
// ---------------------------------------------------------------------------

static WAKE_PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);

fn wake_packet_loop() {
    let fd = WAKE_PIPE_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        unsafe {
            libc::write(fd, b"w".as_ptr() as *const c_void, 1);
        }
    }
}

/// Sender wrapper that wakes the packet loop after each send.
#[derive(Clone)]
struct WakingSender {
    inner: mpsc::UnboundedSender<SocksEvent>,
}

impl WakingSender {
    fn send(&self, event: SocksEvent) -> Result<(), mpsc::error::SendError<SocksEvent>> {
        let result = self.inner.send(event);
        wake_packet_loop();
        result
    }
}

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

    // Initialize DoH client (reads config, connects directly to DoH servers)
    doh_client::init_doh_client();

    let rt = crate::get_runtime();

    // Create wake pipe for signaling the packet loop from tokio tasks
    let mut pipe_fds = [0i32; 2];
    if unsafe { libc::pipe(pipe_fds.as_mut_ptr()) } != 0 {
        return Err("failed to create wake pipe".into());
    }
    let wake_read_fd = pipe_fds[0];
    let wake_write_fd = pipe_fds[1];

    // Set wake pipe read end to non-blocking
    unsafe {
        let flags = libc::fcntl(wake_read_fd, libc::F_GETFL);
        libc::fcntl(wake_read_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        let flags = libc::fcntl(wake_write_fd, libc::F_GETFL);
        libc::fcntl(wake_write_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
    WAKE_PIPE_WRITE.store(wake_write_fd, Ordering::Relaxed);

    // Channels between packet thread and tokio
    let (tun_tx, tun_rx) = mpsc::unbounded_channel::<TunEvent>();
    let (socks_tx, socks_rx) = mpsc::unbounded_channel::<SocksEvent>();

    // Wrap socks_tx in WakingSender so tokio tasks wake the packet loop
    let waking_socks_tx = WakingSender { inner: socks_tx };

    // Spawn the tokio side (handles SOCKS5 connections and DoH DNS resolution)
    let socks_addr2 = SocketAddr::V4(socks_addr);
    rt.spawn(async move {
        tokio_handler(tun_rx, waking_socks_tx, socks_addr2).await;
    });

    // Spawn the packet processing loop on a dedicated OS thread (uses select())
    std::thread::spawn(move || {
        if let Err(e) = packet_loop(fd, tun_tx, socks_rx, wake_read_fd) {
            logging::bridge_log(&format!("packet_loop error: {}", e));
        }
        TUN2SOCKS_RUNNING.store(false, Ordering::SeqCst);
        WAKE_PIPE_WRITE.store(-1, Ordering::Relaxed);
        unsafe {
            libc::close(wake_read_fd);
            libc::close(wake_write_fd);
        }
        info!("tun2socks packet loop exited");
    });

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
// lwIP callback state (single-threaded, accessed only from packet_loop)
// ---------------------------------------------------------------------------

/// Per-connection state tracked by the packet loop.
struct LwipConnState {
    pcb: *mut lwip_ffi::tcp_pcb,
}

/// Global state passed to lwIP callbacks via static mutable pointer.
/// SAFETY: only accessed from the dedicated packet_loop thread (never concurrent).
struct LwipState {
    tun_tx: mpsc::UnboundedSender<TunEvent>,
    next_conn_id: u64,
    conns: HashMap<u64, LwipConnState>,
    tx_queue: VecDeque<Vec<u8>>,
}

/// Static pointer to the LwipState. Set before entering the main loop,
/// cleared on exit. SAFETY: only one packet_loop runs at a time.
static mut LWIP_STATE: *mut LwipState = std::ptr::null_mut();

// ---------------------------------------------------------------------------
// lwIP callbacks (unsafe extern "C")
// ---------------------------------------------------------------------------

/// Called by lwIP when it has an IP packet to send out the netif (e.g. SYN-ACK, data ACK).
unsafe extern "C" fn netif_output_cb(
    _netif: *mut lwip_ffi::netif,
    p: *mut lwip_ffi::pbuf,
    _ipaddr: *const lwip_ffi::ip4_addr_t,
) -> lwip_ffi::err_t {
    if p.is_null() {
        return lwip_ffi::ERR_OK;
    }
    let state = &mut *LWIP_STATE;
    // Copy pbuf chain payload into a Vec
    let tot_len = lwip_ffi::pbuf_tot_len(p) as usize;
    let mut data = Vec::with_capacity(tot_len);
    let mut cur = p;
    while !cur.is_null() {
        let payload = lwip_ffi::pbuf_payload(cur);
        let len = lwip_ffi::pbuf_len(cur) as usize;
        data.extend_from_slice(std::slice::from_raw_parts(payload, len));
        // next pointer is at offset 0 of pbuf
        cur = *(cur as *const *mut lwip_ffi::pbuf);
    }
    state.tx_queue.push_back(data);
    lwip_ffi::ERR_OK
}

/// Called by lwIP when a new TCP connection is accepted by the catch-all listener.
unsafe extern "C" fn tcp_accept_cb(
    _arg: *mut c_void,
    newpcb: *mut lwip_ffi::tcp_pcb,
    _err: lwip_ffi::err_t,
) -> lwip_ffi::err_t {
    if newpcb.is_null() {
        return lwip_ffi::ERR_MEM;
    }
    let state = &mut *LWIP_STATE;

    let conn_id = state.next_conn_id;
    state.next_conn_id += 1;

    let dst_ip = lwip_ffi::lwip_helper_tcp_remote_ip(newpcb);
    let dst_port = lwip_ffi::lwip_helper_tcp_remote_port(newpcb);

    // Store conn_id in the PCB's arg
    lwip_ffi::tcp_arg(newpcb, conn_id as *mut c_void);
    lwip_ffi::tcp_recv(newpcb, Some(tcp_recv_cb));
    lwip_ffi::tcp_sent(newpcb, Some(tcp_sent_cb));
    lwip_ffi::tcp_err(newpcb, Some(tcp_err_cb));

    state.conns.insert(conn_id, LwipConnState { pcb: newpcb });

    let dst = Ipv4Addr::from(dst_ip.to_ne_bytes());
    logging::bridge_log(&format!(
        "TCP Accepted: conn_id={} dst={}:{}", conn_id, dst, dst_port
    ));

    let _ = state.tun_tx.send(TunEvent::TcpAccepted {
        conn_id,
        dst_ip,
        dst_port,
    });

    lwip_ffi::ERR_OK
}

/// Called by lwIP when data is received on a TCP connection.
unsafe extern "C" fn tcp_recv_cb(
    arg: *mut c_void,
    tpcb: *mut lwip_ffi::tcp_pcb,
    p: *mut lwip_ffi::pbuf,
    _err: lwip_ffi::err_t,
) -> lwip_ffi::err_t {
    let conn_id = arg as u64;
    let state = &mut *LWIP_STATE;

    if p.is_null() {
        // Remote closed the connection
        logging::bridge_log(&format!("TCP remote closed: conn_id={}", conn_id));
        let _ = state.tun_tx.send(TunEvent::TcpClosed { conn_id });
        state.conns.remove(&conn_id);
        lwip_ffi::tcp_close(tpcb);
        return lwip_ffi::ERR_OK;
    }

    // Copy data from pbuf chain
    let tot_len = lwip_ffi::pbuf_tot_len(p) as usize;
    let mut data = Vec::with_capacity(tot_len);
    let mut cur = p;
    while !cur.is_null() {
        let payload = lwip_ffi::pbuf_payload(cur);
        let len = lwip_ffi::pbuf_len(cur) as usize;
        data.extend_from_slice(std::slice::from_raw_parts(payload, len));
        cur = *(cur as *const *mut lwip_ffi::pbuf);
    }

    // Acknowledge received data to lwIP
    lwip_ffi::tcp_recved(tpcb, tot_len as u16);

    logging::bridge_log(&format!(
        "TCP recv: conn_id={} {}B", conn_id, data.len()
    ));

    let _ = state.tun_tx.send(TunEvent::TcpData { conn_id, data });

    // Free the pbuf
    lwip_ffi::pbuf_free(p);

    lwip_ffi::ERR_OK
}

/// Called by lwIP when previously written data has been acknowledged.
unsafe extern "C" fn tcp_sent_cb(
    _arg: *mut c_void,
    _tpcb: *mut lwip_ffi::tcp_pcb,
    _len: u16,
) -> lwip_ffi::err_t {
    lwip_ffi::ERR_OK
}

/// Called by lwIP when a TCP connection encounters an error.
/// IMPORTANT: lwIP has already freed the PCB by the time this is called.
unsafe extern "C" fn tcp_err_cb(arg: *mut c_void, _err: lwip_ffi::err_t) {
    let conn_id = arg as u64;
    let state = &mut *LWIP_STATE;

    logging::bridge_log(&format!("TCP error: conn_id={}", conn_id));
    state.conns.remove(&conn_id);
    let _ = state.tun_tx.send(TunEvent::TcpClosed { conn_id });
}

// ---------------------------------------------------------------------------
// Packet loop (lwIP + select())
// ---------------------------------------------------------------------------

fn packet_loop(
    fd: RawFd,
    tun_tx: mpsc::UnboundedSender<TunEvent>,
    mut socks_rx: mpsc::UnboundedReceiver<SocksEvent>,
    wake_read_fd: RawFd,
) -> io::Result<()> {
    logging::bridge_log("packet_loop: starting (lwIP + select())");

    // Initialize lwIP
    unsafe { lwip_ffi::lwip_init(); }

    // Allocate and configure netif
    let netif = unsafe { lwip_ffi::lwip_helper_netif_alloc() };
    if netif.is_null() {
        return Err(io::Error::new(io::ErrorKind::Other, "failed to allocate netif"));
    }

    // IP 10.0.0.1, netmask 0.0.0.0 (accept everything)
    let ip: lwip_ffi::ip4_addr_t = u32::from(Ipv4Addr::new(10, 0, 0, 1)).to_be();
    let netmask: lwip_ffi::ip4_addr_t = 0;
    let gw: lwip_ffi::ip4_addr_t = 0;

    unsafe {
        // netif_add with ip_input as the input function
        let result = lwip_ffi::netif_add(
            netif,
            &ip as *const u32,
            &netmask as *const u32,
            &gw as *const u32,
            std::ptr::null_mut(),
            None, // init callback not needed — we use the helper
            Some(lwip_ffi::ip_input),
        );
        if result.is_null() {
            lwip_ffi::lwip_helper_netif_free(netif);
            return Err(io::Error::new(io::ErrorKind::Other, "netif_add failed"));
        }

        lwip_ffi::netif_set_default(netif);
        lwip_ffi::netif_set_up(netif);
        lwip_ffi::netif_set_link_up(netif);
        lwip_ffi::lwip_helper_set_netif_output(netif, Some(netif_output_cb));
    }

    logging::bridge_log("packet_loop: netif configured");

    // Create catch-all TCP listener
    unsafe {
        let listen_pcb = lwip_ffi::tcp_new();
        if listen_pcb.is_null() {
            lwip_ffi::lwip_helper_netif_free(netif);
            return Err(io::Error::new(io::ErrorKind::Other, "tcp_new failed"));
        }
        let any_ip: lwip_ffi::ip4_addr_t = 0; // IP_ADDR_ANY
        let err = lwip_ffi::tcp_bind(listen_pcb, &any_ip, 0);
        if err != lwip_ffi::ERR_OK {
            lwip_ffi::lwip_helper_netif_free(netif);
            return Err(io::Error::new(io::ErrorKind::Other, format!("tcp_bind failed: {}", err)));
        }
        let listen_pcb = lwip_ffi::tcp_listen_with_backlog(listen_pcb, 255);
        if listen_pcb.is_null() {
            lwip_ffi::lwip_helper_netif_free(netif);
            return Err(io::Error::new(io::ErrorKind::Other, "tcp_listen failed"));
        }
        lwip_ffi::lwip_helper_set_listen_catchall(listen_pcb);
        lwip_ffi::tcp_accept(listen_pcb, Some(tcp_accept_cb));
    }

    logging::bridge_log("packet_loop: catch-all TCP listener created");

    // Initialize global state for callbacks
    let mut lwip_state = LwipState {
        tun_tx: tun_tx.clone(),
        next_conn_id: 1,
        conns: HashMap::new(),
        tx_queue: VecDeque::new(),
    };
    unsafe {
        LWIP_STATE = &mut lwip_state as *mut LwipState;
    }

    // Set TUN fd to non-blocking
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    logging::bridge_log("packet_loop: entering main loop");

    let mut read_buf = vec![0u8; 65535];
    let mut pkt_total: u64 = 0;
    let mut pkt_udp: u64 = 0;
    let mut pkt_tcp: u64 = 0;
    let mut _pkt_other: u64 = 0;
    let mut read_errors: u64 = 0;
    let mut tx_pkt_count: u64 = 0;
    let mut tx_byte_count: u64 = 0;
    let mut socks_data_recv: u64 = 0;
    let mut socks_data_sent: u64 = 0;
    let mut socks_data_dropped: u64 = 0;
    let mut last_stats = Instant::now();
    // Track recycled conn_ids so we silently skip stale SocksEvent data
    let mut dead_conns: HashSet<u64> = HashSet::new();

    // Main loop — wait for fd readable or wake pipe via select()
    loop {
        if !TUN2SOCKS_RUNNING.load(Ordering::SeqCst) {
            break;
        }

        // Build fd_set for select()
        unsafe {
            let mut read_fds: libc::fd_set = std::mem::zeroed();
            libc::FD_ZERO(&mut read_fds);
            libc::FD_SET(fd, &mut read_fds);
            libc::FD_SET(wake_read_fd, &mut read_fds);
            let nfds = std::cmp::max(fd, wake_read_fd) + 1;

            // 50ms timeout for lwIP timers
            let mut timeout = libc::timeval { tv_sec: 0, tv_usec: 50_000 };

            let ret = libc::select(
                nfds,
                &mut read_fds,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut timeout,
            );

            if ret > 0 {
                // Read all available packets from TUN fd
                if libc::FD_ISSET(fd, &read_fds) {
                    loop {
                        let n = libc::read(
                            fd,
                            read_buf.as_mut_ptr() as *mut c_void,
                            read_buf.len(),
                        );
                        if n <= 0 {
                            if n < 0 {
                                let errno = *libc::__error();
                                if errno != libc::EAGAIN {
                                    read_errors += 1;
                                    if read_errors <= 5 {
                                        logging::bridge_log(&format!(
                                            "packet_loop: read error: errno={}", errno
                                        ));
                                    }
                                }
                            }
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
                                "packet_loop: pkt #{}: {}B, ip_ver={}, proto={}",
                                pkt_total, n, version, proto
                            ));
                        }

                        // Intercept UDP before lwIP
                        if let Some((src_ip, src_port, dst_ip, dst_port, payload)) =
                            parse_udp_packet(ip_data)
                        {
                            pkt_udp += 1;
                            if pkt_udp <= 3 {
                                let dst = Ipv4Addr::from(dst_ip.to_ne_bytes());
                                logging::bridge_log(&format!(
                                    "packet_loop: UDP -> {}:{} ({}B)",
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
                                _pkt_other += 1;
                            }
                            // Feed to lwIP via pbuf
                            let pkt_len = ip_data.len();
                            if pkt_len <= u16::MAX as usize {
                                let p = lwip_ffi::pbuf_alloc(
                                    lwip_ffi::PBUF_RAW,
                                    pkt_len as u16,
                                    lwip_ffi::PBUF_RAM,
                                );
                                if !p.is_null() {
                                    let payload_ptr = lwip_ffi::pbuf_payload(p) as *mut u8;
                                    std::ptr::copy_nonoverlapping(
                                        ip_data.as_ptr(),
                                        payload_ptr,
                                        pkt_len,
                                    );
                                    // ip_input takes ownership of the pbuf — do NOT free
                                    lwip_ffi::ip_input(p, netif);
                                }
                            }
                        }
                    }
                }

                // Drain wake pipe
                if libc::FD_ISSET(wake_read_fd, &read_fds) {
                    let mut drain_buf = [0u8; 256];
                    while libc::read(
                        wake_read_fd,
                        drain_buf.as_mut_ptr() as *mut c_void,
                        drain_buf.len(),
                    ) > 0 {}
                }
            }
        }

        // Process events from tokio (SOCKS5 responses) — non-blocking
        while let Ok(event) = socks_rx.try_recv() {
            process_socks_event(
                event, fd, &mut lwip_state,
                &mut socks_data_recv, &mut socks_data_sent, &mut socks_data_dropped,
                &dead_conns,
            );
        }

        // Run lwIP timers
        unsafe { lwip_ffi::sys_check_timeouts(); }

        // Drain TX queue — write lwIP output packets to utun fd
        static TX_LOG_COUNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        while let Some(pkt) = lwip_state.tx_queue.pop_front() {
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
            // Retry writes that fail with EAGAIN (utun buffer full during burst)
            let mut retries = 0u32;
            loop {
                let written = unsafe {
                    libc::write(fd, out.as_ptr() as *const c_void, out.len())
                };
                if written >= 0 {
                    break;
                }
                let errno = unsafe { *libc::__error() };
                if errno == libc::EAGAIN && retries < 5 {
                    retries += 1;
                    std::thread::sleep(std::time::Duration::from_micros(100));
                    continue;
                }
                if tx_pkt_count <= 5 || retries > 0 {
                    logging::bridge_log(&format!(
                        "TX write error: errno={}, pkt_len={}, retries={}", errno, out.len(), retries
                    ));
                }
                break;
            }
        }

        // Periodic cleanup and stats
        if last_stats.elapsed() >= std::time::Duration::from_secs(5) {
            // Purge dead_conns
            dead_conns.clear();
            let active_conns = lwip_state.conns.len();
            logging::bridge_log(&format!(
                "STATS: rx={} udp={} tcp={} conns={} tx_pkts={} tx_bytes={} socks_recv={} socks_sent={} socks_drop={}",
                pkt_total, pkt_udp, pkt_tcp, active_conns,
                tx_pkt_count, tx_byte_count,
                socks_data_recv, socks_data_sent, socks_data_dropped
            ));
            last_stats = Instant::now();
        }
    }

    // Cleanup
    unsafe {
        LWIP_STATE = std::ptr::null_mut();
    }

    logging::bridge_log("packet_loop: exiting main loop");
    Ok(())
}

/// Process a single SocksEvent.
fn process_socks_event(
    event: SocksEvent,
    fd: RawFd,
    lwip_state: &mut LwipState,
    socks_data_recv: &mut u64,
    socks_data_sent: &mut u64,
    socks_data_dropped: &mut u64,
    dead_conns: &HashSet<u64>,
) {
    match event {
        SocksEvent::TcpData { conn_id, data } => {
            if dead_conns.contains(&conn_id) {
                return;
            }
            *socks_data_recv += data.len() as u64;
            if let Some(conn) = lwip_state.conns.get(&conn_id) {
                let pcb = conn.pcb;
                // tcp_write takes u16 len — split into chunks if needed
                let mut offset = 0;
                while offset < data.len() {
                    let chunk_len = std::cmp::min(data.len() - offset, u16::MAX as usize);
                    let err = unsafe {
                        lwip_ffi::tcp_write(
                            pcb,
                            data[offset..].as_ptr() as *const c_void,
                            chunk_len as u16,
                            lwip_ffi::TCP_WRITE_FLAG_COPY,
                        )
                    };
                    if err != lwip_ffi::ERR_OK {
                        logging::bridge_log(&format!(
                            "tcp_write ERR: conn_id={} err={} len={}",
                            conn_id, err, chunk_len
                        ));
                        *socks_data_dropped += (data.len() - offset) as u64;
                        break;
                    }
                    *socks_data_sent += chunk_len as u64;
                    offset += chunk_len;
                }
                unsafe { lwip_ffi::tcp_output(pcb); }
            } else {
                *socks_data_dropped += data.len() as u64;
                logging::bridge_log(&format!(
                    "SocksData ORPHAN: conn_id={} len={} (no conn)",
                    conn_id, data.len()
                ));
            }
        }
        SocksEvent::TcpClose { conn_id } => {
            if let Some(conn) = lwip_state.conns.remove(&conn_id) {
                unsafe {
                    let err = lwip_ffi::tcp_close(conn.pcb);
                    if err != lwip_ffi::ERR_OK {
                        // tcp_close failed (e.g. out of memory) — force abort
                        lwip_ffi::tcp_abort(conn.pcb);
                    }
                }
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
    socks_tx: WakingSender,
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
                let handle = tokio::spawn(async move {
                    handle_tcp_conn(conn_id, dst, socks_addr, socks_tx2, data_rx).await;
                });
                TCP_TASK_MAP.lock().insert(conn_id, handle);
            }
            TunEvent::TcpData { conn_id, data } => {
                let tx = TCP_CONN_MAP.lock().get(&conn_id).cloned();
                if let Some(tx) = tx {
                    let _ = tx.send(data).await;
                }
            }
            TunEvent::TcpClosed { conn_id } => {
                TCP_CONN_MAP.lock().remove(&conn_id);
                if let Some(handle) = TCP_TASK_MAP.lock().remove(&conn_id) {
                    handle.abort();
                }
            }
            TunEvent::UdpPacket {
                src_ip,
                src_port,
                dst_ip,
                dst_port,
                data,
            } => {
                if dst_port == 53 {
                    let socks_tx_dns = socks_tx.clone();
                    tokio::spawn(async move {
                        handle_dns_query(src_ip, src_port, dst_ip, dst_port, data, socks_tx_dns).await;
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

/// Tracks spawned SOCKS5 task handles so they can be aborted when lwIP recycles the connection.
static TCP_TASK_MAP: LazyLock<ParkMutex<HashMap<u64, tokio::task::JoinHandle<()>>>> =
    LazyLock::new(|| ParkMutex::new(HashMap::new()));

async fn handle_tcp_conn(
    conn_id: u64,
    dst: SocketAddrV4,
    socks_addr: SocketAddr,
    socks_tx: WakingSender,
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
    TCP_TASK_MAP.lock().remove(&conn_id);
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
    socks_tx: WakingSender,
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
