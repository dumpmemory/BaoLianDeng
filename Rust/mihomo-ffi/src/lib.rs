mod diagnostics;
mod logging;
mod tun_fd;

use mihomo_api::ApiServer;
use mihomo_listener::{MixedListener, TunListenerConfig};
use mihomo_tunnel::Tunnel;
use parking_lot::Mutex;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

// ---------------------------------------------------------------------------
// Thread-local error message
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: std::cell::RefCell<String> = std::cell::RefCell::new(String::new());
    static LAST_ERROR_CSTR: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

fn set_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg);
}

/// # Safety
/// Returns pointer to thread-local static. Do NOT free.
#[no_mangle]
pub unsafe extern "C" fn bridge_get_last_error() -> *const c_char {
    let msg = LAST_ERROR.with(|e| e.borrow().clone());
    LAST_ERROR_CSTR.with(|cs| {
        *cs.borrow_mut() = CString::new(msg).unwrap_or_else(|_| CString::new("unknown error").unwrap());
        cs.borrow().as_ptr()
    })
}

// ---------------------------------------------------------------------------
// String utilities
// ---------------------------------------------------------------------------

unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    CStr::from_ptr(ptr).to_str().unwrap_or("")
}

fn str_to_cstring_ptr(s: &str) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// # Safety
/// Free a string previously returned by a bridge_* function.
#[no_mangle]
pub unsafe extern "C" fn bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn get_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

struct EngineState {
    tunnel: Tunnel,
    // Keep handles alive so spawned tasks don't get cancelled
    _handles: Vec<tokio::task::JoinHandle<()>>,
}

static ENGINE: Mutex<Option<EngineState>> = Mutex::new(None);
static HOME_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
static TUN_FD: Mutex<Option<i32>> = Mutex::new(None);

// ---------------------------------------------------------------------------
// Version constant
// ---------------------------------------------------------------------------

static VERSION_CSTR: OnceLock<CString> = OnceLock::new();

/// # Safety
/// Returns pointer to static string. Do NOT free.
#[no_mangle]
pub unsafe extern "C" fn bridge_version() -> *const c_char {
    VERSION_CSTR
        .get_or_init(|| CString::new("mihomo-rust 0.2.0").unwrap())
        .as_ptr()
}

/// No-op. Kept for Swift compatibility (Swift calls ForceGC every 10s).
#[no_mangle]
pub extern "C" fn bridge_force_gc() {}

/// # Safety
/// `path` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_home_dir(path: *const c_char) {
    let p = cstr_to_str(path);
    *HOME_DIR.lock() = Some(PathBuf::from(p));
}

/// # Safety
/// `yaml` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_config(yaml: *const c_char) -> i32 {
    let yaml_str = cstr_to_str(yaml);
    let home = HOME_DIR.lock();
    let Some(home) = home.as_ref() else {
        set_error("home directory not set".to_string());
        return -1;
    };
    let config_path = home.join("config.yaml");
    match std::fs::write(&config_path, yaml_str) {
        Ok(()) => 0,
        Err(e) => {
            set_error(format!("write config: {}", e));
            -1
        }
    }
}

/// # Safety
/// `fd` must be a valid TUN file descriptor from iOS NEPacketTunnelProvider.
#[no_mangle]
pub extern "C" fn bridge_set_tun_fd(fd: i32) -> i32 {
    if fd < 0 {
        set_error(format!("invalid file descriptor: {}", fd));
        return -1;
    }
    *TUN_FD.lock() = Some(fd);
    0
}

#[no_mangle]
pub extern "C" fn bridge_is_running() -> bool {
    ENGINE.lock().is_some()
}

/// # Safety
/// Returns heap-allocated string. Caller must free via bridge_free_string.
/// Returns null on error (check bridge_get_last_error).
#[no_mangle]
pub unsafe extern "C" fn bridge_read_config() -> *mut c_char {
    let home = HOME_DIR.lock();
    let Some(home) = home.as_ref() else {
        set_error("home directory not set".to_string());
        return std::ptr::null_mut();
    };
    let config_path = home.join("config.yaml");
    match std::fs::read_to_string(&config_path) {
        Ok(content) => str_to_cstring_ptr(&content),
        Err(e) => {
            set_error(format!("read config: {}", e));
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `yaml` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_validate_config(yaml: *const c_char) -> i32 {
    let yaml_str = cstr_to_str(yaml);
    match mihomo_config::load_config_from_str(yaml_str) {
        Ok(_) => 0,
        Err(e) => {
            set_error(format!("validate config: {}", e));
            -1
        }
    }
}

/// # Safety
/// `level` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_update_log_level(level: *const c_char) {
    let _level = cstr_to_str(level);
    // TODO: update tracing subscriber level dynamically
}

#[no_mangle]
pub extern "C" fn bridge_get_upload_traffic() -> i64 {
    let engine = ENGINE.lock();
    match engine.as_ref() {
        Some(state) => state.tunnel.statistics().snapshot().0,
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn bridge_get_download_traffic() -> i64 {
    let engine = ENGINE.lock();
    match engine.as_ref() {
        Some(state) => state.tunnel.statistics().snapshot().1,
        None => 0,
    }
}

// ---------------------------------------------------------------------------
// Engine lifecycle
// ---------------------------------------------------------------------------

/// # Safety
/// Call bridge_set_home_dir and optionally bridge_set_tun_fd before this.
#[no_mangle]
pub extern "C" fn bridge_start_proxy() -> i32 {
    start_engine(None, None)
}

/// # Safety
/// `addr` and `secret` must be valid null-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn bridge_start_with_external_controller(
    addr: *const c_char,
    secret: *const c_char,
) -> i32 {
    let addr_str = cstr_to_str(addr).to_string();
    let secret_str = cstr_to_str(secret).to_string();
    start_engine(Some(addr_str), Some(secret_str))
}

fn start_engine(
    external_controller: Option<String>,
    secret: Option<String>,
) -> i32 {
    let mut engine = ENGINE.lock();
    if engine.is_some() {
        set_error("proxy is already running".to_string());
        return -1;
    }

    let home = HOME_DIR.lock().clone();
    let Some(home) = home else {
        set_error("home directory not set".to_string());
        return -1;
    };

    let config_path = home.join("config.yaml");
    let config_path_str = config_path.to_string_lossy().to_string();

    if !config_path.exists() {
        set_error(format!("config.yaml not found in {}", home.display()));
        return -1;
    }

    let tun_fd = TUN_FD.lock().take();

    let rt = get_runtime();

    match rt.block_on(async { start_engine_async(&config_path_str, tun_fd, external_controller, secret).await }) {
        Ok(state) => {
            *engine = Some(state);
            0
        }
        Err(e) => {
            set_error(format!("start proxy: {}", e));
            -1
        }
    }
}

async fn start_engine_async(
    config_path: &str,
    tun_fd: Option<i32>,
    external_controller: Option<String>,
    secret: Option<String>,
) -> Result<EngineState, anyhow::Error> {
    // Initialize rustls crypto provider
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut config = mihomo_config::load_config(config_path)?;

    // Override external controller if specified
    if let Some(addr) = external_controller {
        config.api.external_controller = addr.parse().ok();
    }
    if let Some(s) = secret {
        config.api.secret = if s.is_empty() { None } else { Some(s) };
    }

    let raw_config = Arc::new(parking_lot::RwLock::new(config.raw.clone()));
    let tunnel = Tunnel::new(config.dns.resolver.clone());
    tunnel.set_mode(config.general.mode);
    tunnel.update_rules(config.rules);
    tunnel.update_proxies(config.proxies);

    let mut handles: Vec<tokio::task::JoinHandle<()>> = Vec::new();

    // Start DNS server
    if let Some(listen_addr) = config.dns.listen_addr {
        let dns_server = mihomo_dns::DnsServer::new(config.dns.resolver.clone(), listen_addr);
        handles.push(tokio::spawn(async move {
            if let Err(e) = dns_server.run().await {
                tracing::error!("DNS server error: {}", e);
            }
        }));
    }

    // Start REST API
    if let Some(api_addr) = config.api.external_controller {
        let api_server = ApiServer::new(
            tunnel.clone(),
            api_addr,
            config.api.secret.clone(),
            config_path.to_string(),
            raw_config.clone(),
        );
        handles.push(tokio::spawn(async move {
            if let Err(e) = api_server.run().await {
                tracing::error!("API server error: {}", e);
            }
        }));
    }

    // Start mixed listener
    let bind_addr = &config.listeners.bind_address;
    if let Some(port) = config.listeners.mixed_port {
        let addr: std::net::SocketAddr = format!("{}:{}", bind_addr, port).parse()?;
        let listener = MixedListener::new(tunnel.clone(), addr);
        handles.push(tokio::spawn(async move {
            if let Err(e) = listener.run().await {
                tracing::error!("Mixed listener error: {}", e);
            }
        }));
    }

    // Start TUN listener
    if let Some(fd) = tun_fd {
        // iOS path: use fd-based TUN listener
        let tun_config = config.tun.as_ref();
        let mtu = tun_config.map(|t| t.mtu).unwrap_or(1500);
        let dns_hijack = tun_config
            .map(|t| t.dns_hijack.clone())
            .unwrap_or_default();
        let tun_listener = tun_fd::TunFdListener::new(
            tunnel.clone(),
            fd,
            mtu,
            dns_hijack,
            config.dns.resolver.clone(),
        );
        handles.push(tokio::spawn(async move {
            if let Err(e) = tun_listener.run().await {
                tracing::error!("TUN fd listener error: {}", e);
            }
        }));
    } else if let Some(ref tun_config) = config.tun {
        if tun_config.enable {
            // Desktop path: create TUN device
            let tun_listener_config = TunListenerConfig {
                device: tun_config.device.clone(),
                mtu: tun_config.mtu,
                inet4_address: tun_config.inet4_address.clone(),
                dns_hijack: tun_config.dns_hijack.clone(),
            };
            let tun = mihomo_listener::TunListener::new(
                tunnel.clone(),
                tun_listener_config,
                config.dns.resolver.clone(),
            );
            handles.push(tokio::spawn(async move {
                if let Err(e) = tun.run().await {
                    tracing::error!("TUN listener error: {}", e);
                }
            }));
        }
    }

    Ok(EngineState {
        tunnel,
        _handles: handles,
    })
}

#[no_mangle]
pub extern "C" fn bridge_stop_proxy() {
    let mut engine = ENGINE.lock();
    if let Some(state) = engine.take() {
        // Abort all spawned tasks
        for handle in state._handles {
            handle.abort();
        }
    }
    // Reset TUN fd
    *TUN_FD.lock() = None;
}

/// # Safety
/// `fd` must be a valid TUN fd. `dns_addr` must be a null-terminated string.
#[no_mangle]
pub unsafe extern "C" fn bridge_generate_tun_config(fd: i32, dns_addr: *const c_char) -> *mut c_char {
    let dns = cstr_to_str(dns_addr);
    let dns = if dns.is_empty() { "198.18.0.2" } else { dns };
    let yaml = format!(
        "tun:\n  enable: true\n  stack: gvisor\n  device: fd://{}\n  auto-route: false\n  auto-detect-interface: false\n  dns-hijack:\n    - \"{}:53\"\n",
        fd, dns
    );
    str_to_cstring_ptr(&yaml)
}
