use futures::{SinkExt, StreamExt};
use mihomo_common::{ConnType, Metadata, Network};
use mihomo_dns::{DnsServer, Resolver};
use mihomo_listener::tun_conn::TunTcpConn;
use mihomo_tunnel::Tunnel;
use netstack_smoltcp::StackBuilder;
use std::io;
use std::net::SocketAddr;
use std::os::unix::io::RawFd;
use std::sync::Arc;
use tokio::io::unix::AsyncFd;
use tracing::{debug, error, info};

/// TUN listener that reads/writes raw IP packets from an iOS-provided
/// file descriptor (from NEPacketTunnelProvider) and processes them
/// through the tunnel's proxy routing engine via netstack-smoltcp.
pub struct TunFdListener {
    tunnel: Tunnel,
    fd: i32,
    mtu: u16,
    dns_hijack: Vec<SocketAddr>,
    resolver: Arc<Resolver>,
}

/// Wrapper around a raw fd for async I/O via tokio's AsyncFd.
struct RawTunDevice {
    fd: std::os::fd::OwnedFd,
}

impl RawTunDevice {
    /// # Safety
    /// `fd` must be a valid, open file descriptor. Ownership is transferred.
    unsafe fn from_raw_fd(fd: RawFd) -> Self {
        use std::os::fd::FromRawFd;
        Self {
            fd: std::os::fd::OwnedFd::from_raw_fd(fd),
        }
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        use std::os::fd::AsRawFd;
        let n = unsafe {
            libc::read(
                self.fd.as_raw_fd(),
                buf.as_mut_ptr() as *mut libc::c_void,
                buf.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }

    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        use std::os::fd::AsRawFd;
        let n = unsafe {
            libc::write(
                self.fd.as_raw_fd(),
                buf.as_ptr() as *const libc::c_void,
                buf.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }
}

impl std::os::fd::AsRawFd for RawTunDevice {
    fn as_raw_fd(&self) -> RawFd {
        std::os::fd::AsRawFd::as_raw_fd(&self.fd)
    }
}

impl TunFdListener {
    pub fn new(
        tunnel: Tunnel,
        fd: i32,
        mtu: u16,
        dns_hijack: Vec<SocketAddr>,
        resolver: Arc<Resolver>,
    ) -> Self {
        Self {
            tunnel,
            fd,
            mtu,
            dns_hijack,
            resolver,
        }
    }

    pub async fn run(self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let device = unsafe { RawTunDevice::from_raw_fd(self.fd as RawFd) };

        // Set fd to non-blocking for tokio AsyncFd
        unsafe {
            let flags = libc::fcntl(self.fd, libc::F_GETFL);
            libc::fcntl(self.fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        let async_device = Arc::new(AsyncFd::new(device)?);

        info!("TUN fd listener started: fd={}, mtu={}", self.fd, self.mtu);

        // Build the netstack-smoltcp stack
        let (stack, tcp_runner, udp_socket, tcp_listener) = StackBuilder::default()
            .enable_tcp(true)
            .enable_udp(true)
            .build()?;

        let tcp_runner = tcp_runner.ok_or("TCP runner not created")?;
        let udp_socket = udp_socket.ok_or("UDP socket not created")?;
        let tcp_listener = tcp_listener.ok_or("TCP listener not created")?;

        // Spawn TCP runner
        tokio::spawn(async move {
            if let Err(e) = tcp_runner.await {
                error!("TCP runner error: {}", e);
            }
        });

        // Bidirectional packet relay: fd <-> netstack
        let relay_device = async_device.clone();
        tokio::spawn(async move {
            relay_packets(relay_device, stack).await;
        });

        // TCP acceptor
        let tunnel_tcp = self.tunnel.clone();
        let mut tcp_listener = tcp_listener;
        tokio::spawn(async move {
            while let Some((stream, _local_addr, remote_addr)) = tcp_listener.next().await {
                let src_addr = *stream.local_addr();
                let metadata = Metadata {
                    network: Network::Tcp,
                    conn_type: ConnType::Tun,
                    src_ip: Some(src_addr.ip()),
                    dst_ip: Some(remote_addr.ip()),
                    src_port: src_addr.port(),
                    dst_port: remote_addr.port(),
                    ..Default::default()
                };
                let conn = Box::new(TunTcpConn::new(stream, remote_addr));
                let tunnel = tunnel_tcp.clone();
                tokio::spawn(async move {
                    mihomo_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata).await;
                });
            }
        });

        // UDP handler with DNS hijack
        let tunnel_udp = self.tunnel.clone();
        let dns_hijack_addrs = self.dns_hijack.clone();
        let resolver = self.resolver.clone();
        let (mut udp_read, mut udp_write) = udp_socket.split();

        tokio::spawn(async move {
            while let Some((payload, src_addr, dst_addr)) = udp_read.next().await {
                if dns_hijack_addrs.contains(&dst_addr) {
                    match DnsServer::handle_query(&payload, &resolver).await {
                        Ok(response) => {
                            let reply: netstack_smoltcp::udp::UdpMsg =
                                (response, dst_addr, src_addr);
                            if let Err(e) = udp_write.send(reply).await {
                                debug!("DNS hijack reply error: {}", e);
                            }
                        }
                        Err(e) => {
                            debug!("DNS hijack query error: {}", e);
                        }
                    }
                    continue;
                }

                let metadata = Metadata {
                    network: Network::Udp,
                    conn_type: ConnType::Tun,
                    src_ip: Some(src_addr.ip()),
                    dst_ip: Some(dst_addr.ip()),
                    src_port: src_addr.port(),
                    dst_port: dst_addr.port(),
                    ..Default::default()
                };
                let tunnel = tunnel_udp.clone();
                tokio::spawn(async move {
                    mihomo_tunnel::udp::handle_udp(tunnel.inner(), &payload, src_addr, metadata)
                        .await;
                });
            }
        });

        info!("TUN fd listener running");
        std::future::pending::<()>().await;
        Ok(())
    }
}

/// Bidirectional packet relay between raw fd and netstack-smoltcp stack.
async fn relay_packets(device: Arc<AsyncFd<RawTunDevice>>, mut stack: netstack_smoltcp::Stack) {
    let mut tun_buf = vec![0u8; 65535];

    loop {
        tokio::select! {
            // fd -> stack: read raw IP packet, feed to netstack
            result = device.readable() => {
                match result {
                    Ok(mut guard) => {
                        match guard.get_inner().read(&mut tun_buf) {
                            Ok(n) if n > 0 => {
                                let pkt = tun_buf[..n].to_vec();
                                guard.clear_ready();
                                if let Err(e) = stack.send(pkt).await {
                                    debug!("fd->stack error: {}", e);
                                    break;
                                }
                            }
                            Ok(_) => { guard.clear_ready(); }
                            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                                guard.clear_ready();
                            }
                            Err(e) => {
                                error!("TUN fd recv error: {}", e);
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        error!("TUN fd readable error: {}", e);
                        break;
                    }
                }
            }
            // stack -> fd: read outgoing packet from netstack, write to fd
            Some(result) = stack.next() => {
                match result {
                    Ok(pkt) => {
                        match device.writable().await {
                            Ok(mut guard) => {
                                match guard.get_inner().write(&pkt) {
                                    Ok(_) => { guard.clear_ready(); }
                                    Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                                        guard.clear_ready();
                                    }
                                    Err(e) => {
                                        debug!("stack->fd error: {}", e);
                                        break;
                                    }
                                }
                            }
                            Err(e) => {
                                error!("TUN fd writable error: {}", e);
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        error!("stack stream error: {}", e);
                        break;
                    }
                }
            }
        }
    }
}
