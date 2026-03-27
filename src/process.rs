#[cfg(unix)]
mod unix {
    extern "C" {
        fn getpid() -> i32;
        fn kill(pid: i32, sig: i32) -> i32;
    }

    pub fn current_pid() -> u32 {
        unsafe { getpid() as u32 }
    }

    pub fn is_alive(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        unsafe { kill(pid as i32, 0) == 0 }
    }

    pub fn force_kill(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        unsafe { kill(pid as i32, 9) == 0 }
    }
}

#[cfg(windows)]
mod windows {
    type BOOL = i32;
    type DWORD = u32;
    type HANDLE = *mut core::ffi::c_void;

    extern "system" {
        fn GetCurrentProcessId() -> DWORD;
        fn OpenProcess(desired_access: DWORD, inherit: BOOL, pid: DWORD) -> HANDLE;
        fn CloseHandle(handle: HANDLE) -> BOOL;
        fn GetExitCodeProcess(process: HANDLE, exit_code: *mut DWORD) -> BOOL;
        fn TerminateProcess(process: HANDLE, code: DWORD) -> BOOL;
    }

    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
    const PROCESS_TERMINATE: DWORD = 0x0001;
    const SYNCHRONIZE: DWORD = 0x00100000;
    const STILL_ACTIVE: DWORD = 259;

    pub fn current_pid() -> u32 {
        unsafe { GetCurrentProcessId() }
    }

    pub fn is_alive(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        let handle =
            unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, 0, pid) };
        if handle.is_null() {
            return false;
        }
        let mut exit_code = 0;
        let ok = unsafe { GetExitCodeProcess(handle, &mut exit_code) != 0 };
        unsafe {
            CloseHandle(handle);
        }
        ok && exit_code == STILL_ACTIVE
    }

    pub fn force_kill(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        let handle = unsafe { OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, 0, pid) };
        if handle.is_null() {
            return false;
        }
        let ok = unsafe { TerminateProcess(handle, 1) != 0 };
        unsafe {
            CloseHandle(handle);
        }
        ok
    }
}

pub fn current_pid() -> u32 {
    #[cfg(unix)]
    {
        unix::current_pid()
    }
    #[cfg(windows)]
    {
        windows::current_pid()
    }
}

pub fn is_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unix::is_alive(pid)
    }
    #[cfg(windows)]
    {
        windows::is_alive(pid)
    }
}

pub fn force_kill(pid: u32) -> bool {
    #[cfg(unix)]
    {
        unix::force_kill(pid)
    }
    #[cfg(windows)]
    {
        windows::force_kill(pid)
    }
}
