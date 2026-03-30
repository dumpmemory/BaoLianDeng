#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/netif.h"
#include "lwip/ip.h"
#include "lwip/stats.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <mach/mach_time.h>

// sys_now: required by lwIP timers (NO_SYS=1 mode).
// Returns monotonic milliseconds.
u32_t sys_now(void) {
    static mach_timebase_info_data_t info = {0};
    if (info.denom == 0) mach_timebase_info(&info);
    uint64_t ns = mach_absolute_time() * info.numer / info.denom;
    return (u32_t)(ns / 1000000);
}

// Helper functions to access lwIP struct fields from Rust without
// duplicating the complex C struct layouts.

uint32_t lwip_helper_tcp_remote_ip(const struct tcp_pcb *pcb) {
    if (!pcb) return 0;
    return ip_addr_get_ip4_u32(&pcb->remote_ip);
}

uint16_t lwip_helper_tcp_remote_port(const struct tcp_pcb *pcb) {
    if (!pcb) return 0;
    return pcb->remote_port;
}

uint16_t lwip_helper_tcp_local_port(const struct tcp_pcb *pcb) {
    if (!pcb) return 0;
    return pcb->local_port;
}

// Allocate a netif struct (Rust can't know the size)
struct netif *lwip_helper_netif_alloc(void) {
    struct netif *n = (struct netif *)calloc(1, sizeof(struct netif));
    return n;
}

void lwip_helper_netif_free(struct netif *n) {
    if (n) free(n);
}

// Set netif output function (Rust can't access netif fields directly)
typedef err_t (*netif_output_fn_t)(struct netif *, struct pbuf *, const ip4_addr_t *);

void lwip_helper_set_netif_output(struct netif *netif, netif_output_fn_t output) {
    if (netif) {
        netif->output = output;
        netif->mtu = 1500;
        netif->flags = NETIF_FLAG_UP | NETIF_FLAG_LINK_UP;
    }
}

// Force a listen PCB's local port to 0 so it acts as a catch-all
// (our patched tcp_in.c matches lpcb->local_port == 0 for any dest port)
void lwip_helper_set_listen_catchall(struct tcp_pcb *pcb) {
    if (pcb) {
        pcb->local_port = 0;
    }
}

// Diagnostic: call from Rust to check lwIP's view of the netif
void lwip_helper_diag_netif(struct netif *n) {
    if (!n) { fprintf(stderr, "[lwip_diag] netif=NULL\n"); return; }
    fprintf(stderr, "[lwip_diag] netif: ip=%08x mask=%08x gw=%08x flags=%02x up=%d link=%d default=%d\n",
        ip4_addr_get_u32(netif_ip4_addr(n)),
        ip4_addr_get_u32(netif_ip4_netmask(n)),
        ip4_addr_get_u32(netif_ip4_gw(n)),
        n->flags,
        netif_is_up(n),
        netif_is_link_up(n),
        (n == netif_default) ? 1 : 0);
}

// Diagnostic: check ip4_input_accept result for a given netif
int lwip_helper_diag_accept(struct netif *n, uint32_t dest_ip) {
    if (!n) return -1;
    // Simulate what ip4_input_accept checks
    int up = netif_is_up(n);
    int link = netif_is_link_up(n);
    int not_any = !ip4_addr_isany_val(*netif_ip4_addr(n));
    int is_default = (n == netif_default) ? 1 : 0;

    ip4_addr_t dest;
    dest.addr = dest_ip;
    int net_eq = ip4_addr_net_eq(&dest, netif_ip4_addr(n), netif_ip4_netmask(n));

    fprintf(stderr, "[lwip_diag] accept: up=%d link=%d not_any=%d is_default=%d net_eq=%d dest=%08x\n",
        up, link, not_any, is_default, net_eq, dest_ip);
    return (up && link && not_any && (net_eq || is_default)) ? 1 : 0;
}
