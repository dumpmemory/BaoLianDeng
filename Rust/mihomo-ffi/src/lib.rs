mod diagnostics;
mod logging;
use mihomo_api::ApiServer;
use mihomo_listener::MixedListener;
use mihomo_tunnel::Tunnel;
use parking_lot::Mutex;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
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

pub(crate) fn get_runtime() -> &'static tokio::runtime::Runtime {
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
pub(crate) static HOME_DIR: Mutex<Option<String>> = Mutex::new(None);

/// Set the config directory. If set, the engine reads `config.yaml` from this
/// directory on startup instead of using the minimal built-in config.
///
/// # Safety
/// `dir` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_home_dir(dir: *const c_char) {
    let dir_str = cstr_to_str(dir).to_string();
    logging::bridge_log(&format!("bridge_set_home_dir: {}", dir_str));
    *HOME_DIR.lock() = if dir_str.is_empty() { None } else { Some(dir_str) };
}

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

#[no_mangle]
pub extern "C" fn bridge_is_running() -> bool {
    ENGINE.lock().is_some()
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

/// Minimal config used at startup. The caller must push the real config via
/// PUT /configs?force=true on the external controller after the engine starts.
const MINIMAL_CONFIG: &str = "\
mixed-port: 7890\n\
mode: rule\n\
log-level: info\n\
allow-lan: false\n\
dns:\n\
  enable: true\n\
  enhanced-mode: redir-host\n\
  listen: 127.0.0.1:1053\n\
  nameserver:\n\
    - 114.114.114.114\n\
proxies: []\n\
proxy-groups: []\n\
rules:\n\
  - MATCH,DIRECT\n\
";

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
    logging::bridge_log("start_engine: acquiring ENGINE lock");
    let mut engine = ENGINE.lock();
    if engine.is_some() {
        set_error("proxy is already running".to_string());
        return -1;
    }
    logging::bridge_log("start_engine: ENGINE lock acquired");

    let rt = get_runtime();
    logging::bridge_log("start_engine: got runtime, calling block_on");

    match rt.block_on(async { start_engine_async(external_controller, secret).await }) {
        Ok(state) => {
            logging::bridge_log("start_engine: engine started successfully");
            *engine = Some(state);
            0
        }
        Err(e) => {
            logging::bridge_log(&format!("start_engine: ERROR: {}", e));
            set_error(format!("start proxy: {}", e));
            -1
        }
    }
}

async fn start_engine_async(
    external_controller: Option<String>,
    secret: Option<String>,
) -> Result<EngineState, anyhow::Error> {
    logging::bridge_log("start_engine_async: initializing rustls");
    let _ = rustls::crypto::ring::default_provider().install_default();

    // Load config from home dir if set, otherwise use minimal built-in config
    let config_str = if let Some(dir) = HOME_DIR.lock().as_ref() {
        let path = format!("{}/config.yaml", dir);
        logging::bridge_log(&format!("start_engine_async: loading config from {}", path));
        match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                logging::bridge_log(&format!("start_engine_async: failed to read {}: {}, using minimal", path, e));
                MINIMAL_CONFIG.to_string()
            }
        }
    } else {
        logging::bridge_log("start_engine_async: no home dir, using minimal config");
        MINIMAL_CONFIG.to_string()
    };
    let mut config = mihomo_config::load_config_from_str(&config_str)?;
    logging::bridge_log(&format!(
        "start_engine_async: config loaded, proxies={}, rules={}",
        config.proxies.len(),
        config.rules.len()
    ));

    // Override external controller if specified
    if let Some(addr) = external_controller {
        config.api.external_controller = addr.parse().ok();
    }
    if let Some(s) = secret {
        config.api.secret = if s.is_empty() { None } else { Some(s) };
    }

    let raw_config = Arc::new(parking_lot::RwLock::new(config.raw.clone()));
    logging::bridge_log("start_engine_async: creating tunnel");
    let tunnel = Tunnel::new(config.dns.resolver.clone());
    tunnel.set_mode(config.general.mode);
    tunnel.update_rules(config.rules);
    tunnel.update_proxies(config.proxies);
    logging::bridge_log("start_engine_async: tunnel created, spawning tasks");

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
            String::new(),
            raw_config.clone(),
        );
        handles.push(tokio::spawn(async move {
            if let Err(e) = api_server.run().await {
                tracing::error!("API server error: {}", e);
            }
        }));
    }

    // Start mixed listener (SOCKS5/HTTP proxy on port 7890)
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

    logging::bridge_log(&format!(
        "start_engine_async: all tasks spawned, handles={}",
        handles.len()
    ));
    Ok(EngineState {
        tunnel,
        _handles: handles,
    })
}

#[no_mangle]
pub extern "C" fn bridge_stop_proxy() {
    let mut engine = ENGINE.lock();
    if let Some(state) = engine.take() {
        for handle in state._handles {
            handle.abort();
        }
    }
}
