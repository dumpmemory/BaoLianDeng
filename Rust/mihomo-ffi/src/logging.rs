use std::os::raw::c_char;

use crate::{set_error, cstr_to_str};

#[cfg(debug_assertions)]
mod inner {
    use std::fs::{File, OpenOptions};
    use std::io::Write;

    use crate::set_error;

    static LOG_FILE: parking_lot::Mutex<Option<File>> = parking_lot::Mutex::new(None);

    pub fn open_log_file(path_str: &str) -> i32 {
        match OpenOptions::new().create(true).write(true).truncate(true).open(path_str) {
            Ok(file) => {
                {
                    let mut log = LOG_FILE.lock();
                    *log = Some(file);
                }
                // Call bridge_log AFTER releasing the lock to avoid deadlock
                bridge_log(&format!("Log file opened: {}", path_str));
                0
            }
            Err(e) => {
                set_error(format!("open log file: {}", e));
                -1
            }
        }
    }

    pub fn bridge_log(msg: &str) {
        let mut log = LOG_FILE.lock();
        if let Some(ref mut file) = *log {
            let _ = writeln!(file, "[Bridge] {}", msg);
        }
    }
}

/// # Safety
/// `path` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_log_file(path: *const c_char) -> i32 {
    #[cfg(debug_assertions)]
    {
        let path_str = cstr_to_str(path);
        inner::open_log_file(path_str)
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = path;
        0
    }
}

#[cfg(debug_assertions)]
pub fn bridge_log(msg: &str) {
    inner::bridge_log(msg);
}

#[cfg(not(debug_assertions))]
#[inline(always)]
pub fn bridge_log(_msg: &str) {}
