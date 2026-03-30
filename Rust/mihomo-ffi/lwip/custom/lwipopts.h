#ifndef LWIPOPTS_H
#define LWIPOPTS_H

// NO_SYS mode: raw API only, no threads/semaphores
#define NO_SYS                      1
#define LWIP_SOCKET                 0
#define LWIP_NETCONN                0
#define SYS_LIGHTWEIGHT_PROT        0

// Use system malloc for all allocations
#define MEM_LIBC_MALLOC             1
#define MEMP_MEM_MALLOC             1
#define MEM_ALIGNMENT               8
#define MEM_SIZE                    (256 * 1024)

// TCP settings
#define LWIP_TCP                    1
#define TCP_MSS                     1460
#define TCP_WND                     (32 * TCP_MSS)
#define TCP_SND_BUF                 (64 * TCP_MSS)
#define TCP_SND_QUEUELEN            (4 * TCP_SND_BUF / TCP_MSS)
#define TCP_LISTEN_BACKLOG          1
#define MEMP_NUM_TCP_PCB            512
#define MEMP_NUM_TCP_PCB_LISTEN     1
#define MEMP_NUM_TCP_SEG            512
#define TCP_OVERSIZE                TCP_MSS

// UDP settings
#define LWIP_UDP                    1
#define MEMP_NUM_UDP_PCB            16

// IPv4
#define LWIP_IPV4                   1
#define LWIP_ICMP                   1
#define IP_FORWARD                  0
#define IP_REASSEMBLY               1
#define IP_FRAG                     1

// IPv6 disabled for v1
#define LWIP_IPV6                   0

// pbuf settings
#define MEMP_NUM_PBUF               256
#define PBUF_POOL_SIZE              128
#define PBUF_POOL_BUFSIZE           1600

// Disable features we don't need
#define LWIP_RAW                    0
#define LWIP_DHCP                   0
#define LWIP_AUTOIP                 0
#define LWIP_DNS                    0
#define LWIP_IGMP                   0
#define LWIP_ARP                    0
#define LWIP_ETHERNET               0
#define LWIP_ACD                    0
#define LWIP_STATS                  0
#define LWIP_STATS_DISPLAY          0
#define LWIP_DEBUG                  0

// Callback API (required for NO_SYS)
#define LWIP_CALLBACK_API           1
#define LWIP_TIMERS                 1

// Checksum: generate on outbound, skip verification on inbound.
// utun packets from macOS have zero/dummy checksums (hardware offload
// was expected to compute them), so lwIP must not verify them.
#define CHECKSUM_GEN_IP             1
#define CHECKSUM_GEN_TCP            1
#define CHECKSUM_GEN_UDP            1
#define CHECKSUM_GEN_ICMP           1
#define CHECKSUM_CHECK_IP           0
#define CHECKSUM_CHECK_TCP          0
#define CHECKSUM_CHECK_UDP          0

// Single pbuf for TX (simplifies output)
#define LWIP_NETIF_TX_SINGLE_PBUF   1

// Disable netif API and loopif
#define LWIP_NETIF_API              0
#define LWIP_HAVE_LOOPIF            0

// Disable unused protocols
#define LWIP_ALTCP                  0
#define LWIP_ALTCP_TLS              0

#endif /* LWIPOPTS_H */
