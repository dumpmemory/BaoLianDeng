//! Minimal FFI bindings for lwIP (NO_SYS=1 raw API).
//! Uses opaque pointers for tcp_pcb, netif, pbuf to avoid duplicating C struct layouts.

#![allow(non_camel_case_types, dead_code)]

use std::os::raw::c_void;

// Opaque types
pub type tcp_pcb = c_void;
pub type netif = c_void;
pub type pbuf = c_void;
pub type ip4_addr_t = u32;

// Error type
pub type err_t = i8;
pub const ERR_OK: err_t = 0;
pub const ERR_MEM: err_t = -1;

// pbuf constants
pub const PBUF_RAW: u16 = 0;
// PBUF_RAM = PBUF_ALLOC_FLAG_DATA_CONTIGUOUS | PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS | PBUF_TYPE_ALLOC_SRC_MASK_STD_HEAP
pub const PBUF_RAM: u16 = 0x200 | 0x80 | 0x02;

// TCP write flags
pub const TCP_WRITE_FLAG_COPY: u8 = 0x01;

// Callback function pointer types
pub type tcp_accept_fn = Option<unsafe extern "C" fn(arg: *mut c_void, newpcb: *mut tcp_pcb, err: err_t) -> err_t>;
pub type tcp_recv_fn = Option<unsafe extern "C" fn(arg: *mut c_void, tpcb: *mut tcp_pcb, p: *mut pbuf, err: err_t) -> err_t>;
pub type tcp_sent_fn = Option<unsafe extern "C" fn(arg: *mut c_void, tpcb: *mut tcp_pcb, len: u16) -> err_t>;
pub type tcp_err_fn = Option<unsafe extern "C" fn(arg: *mut c_void, err: err_t)>;
pub type netif_output_fn = Option<unsafe extern "C" fn(netif: *mut netif, p: *mut pbuf, ipaddr: *const ip4_addr_t) -> err_t>;

extern "C" {
    // Init
    pub fn lwip_init();

    // Timers
    pub fn sys_check_timeouts();

    // Netif
    pub fn netif_add(
        netif: *mut netif, ipaddr: *const ip4_addr_t, netmask: *const ip4_addr_t,
        gw: *const ip4_addr_t, state: *mut c_void,
        init: Option<unsafe extern "C" fn(*mut netif) -> err_t>,
        input: Option<unsafe extern "C" fn(*mut pbuf, *mut netif) -> err_t>,
    ) -> *mut netif;
    pub fn netif_set_default(netif: *mut netif);
    pub fn netif_set_up(netif: *mut netif);
    pub fn netif_set_link_up(netif: *mut netif);

    // IP input (ip_input is a macro → ip4_input when LWIP_IPV6=0)
    #[link_name = "ip4_input"]
    pub fn ip_input(p: *mut pbuf, inp: *mut netif) -> err_t;

    // TCP
    pub fn tcp_new() -> *mut tcp_pcb;
    pub fn tcp_bind(pcb: *mut tcp_pcb, ipaddr: *const ip4_addr_t, port: u16) -> err_t;
    pub fn tcp_listen_with_backlog(pcb: *mut tcp_pcb, backlog: u8) -> *mut tcp_pcb;
    pub fn tcp_accept(pcb: *mut tcp_pcb, accept: tcp_accept_fn);
    pub fn tcp_arg(pcb: *mut tcp_pcb, arg: *mut c_void);
    pub fn tcp_recv(pcb: *mut tcp_pcb, recv: tcp_recv_fn);
    pub fn tcp_sent(pcb: *mut tcp_pcb, sent: tcp_sent_fn);
    pub fn tcp_err(pcb: *mut tcp_pcb, err: tcp_err_fn);
    pub fn tcp_recved(pcb: *mut tcp_pcb, len: u16);
    pub fn tcp_write(pcb: *mut tcp_pcb, dataptr: *const c_void, len: u16, apiflags: u8) -> err_t;
    pub fn tcp_output(pcb: *mut tcp_pcb) -> err_t;
    pub fn tcp_close(pcb: *mut tcp_pcb) -> err_t;
    pub fn tcp_abort(pcb: *mut tcp_pcb);

    // Pbuf
    pub fn pbuf_alloc(layer: u16, length: u16, type_: u16) -> *mut pbuf;
    pub fn pbuf_free(p: *mut pbuf) -> u8;

    // Custom helpers from lwip_helpers.c
    pub fn lwip_helper_tcp_remote_ip(pcb: *const tcp_pcb) -> u32;
    pub fn lwip_helper_tcp_remote_port(pcb: *const tcp_pcb) -> u16;
    pub fn lwip_helper_tcp_local_port(pcb: *const tcp_pcb) -> u16;
    pub fn lwip_helper_netif_alloc() -> *mut netif;
    pub fn lwip_helper_netif_free(n: *mut netif);
    pub fn lwip_helper_set_netif_output(netif: *mut netif, output: netif_output_fn);
    pub fn lwip_helper_set_listen_catchall(pcb: *mut tcp_pcb);
}

/// Read payload pointer from a pbuf.
/// pbuf layout on 64-bit: { next: *mut pbuf (8), payload: *mut c_void (8), tot_len: u16, len: u16, ... }
pub unsafe fn pbuf_payload(p: *const pbuf) -> *const u8 {
    let ptr = p as *const u8;
    *(ptr.add(8) as *const *const u8)
}

pub unsafe fn pbuf_len(p: *const pbuf) -> u16 {
    let ptr = p as *const u8;
    *(ptr.add(18) as *const u16)
}

pub unsafe fn pbuf_tot_len(p: *const pbuf) -> u16 {
    let ptr = p as *const u8;
    *(ptr.add(16) as *const u16)
}
