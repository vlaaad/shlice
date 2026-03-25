use crate::{Frame, FrameKind, Result};
use std::io::{Read, Write};
use std::path::Path;

#[cfg(unix)]
pub struct IpcListener {
    listener: std::os::unix::net::UnixListener,
}

#[cfg(windows)]
pub struct IpcListener {
    name: Vec<u16>,
}

#[cfg(unix)]
pub type IpcStream = std::os::unix::net::UnixStream;

#[cfg(windows)]
use std::fs::File;

#[cfg(windows)]
pub type IpcStream = File;

#[cfg(unix)]
pub fn create_fifo(path: &Path) -> Result<IpcListener> {
    let path = unix_socket_path(path);
    let _ = std::fs::remove_file(&path);
    let listener = std::os::unix::net::UnixListener::bind(&path)?;
    Ok(IpcListener {
        listener,
    })
}

#[cfg(windows)]
pub fn create_fifo(path: &Path) -> Result<IpcListener> {
    let name = windows_pipe_name(path);
    Ok(IpcListener { name })
}

#[cfg(unix)]
impl IpcListener {
    pub fn accept(&self) -> Result<IpcStream> {
        Ok(self.listener.accept()?.0)
    }
}

#[cfg(windows)]
impl IpcListener {
    pub fn accept(&self) -> Result<IpcStream> {
        windows_accept(&self.name)
    }
}

#[cfg(unix)]
pub fn open_fifo_read_write(path: &Path) -> Result<IpcStream> {
    use std::io::ErrorKind;
    use std::thread;
    use std::time::{Duration, Instant};

    let deadline = Instant::now() + Duration::from_secs(30);
    let path = unix_socket_path(path);
    loop {
        match std::os::unix::net::UnixStream::connect(&path) {
            Ok(stream) => return Ok(stream),
            Err(err) if err.kind() == ErrorKind::NotFound && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(err) => return Err(err.into()),
        }
    }
}

#[cfg(windows)]
pub fn open_fifo_read_write(path: &Path) -> Result<IpcStream> {
    windows_connect(&windows_pipe_name(path))
}

#[cfg(not(windows))]
pub fn remove_fifo(path: &Path) {
    let _ = std::fs::remove_file(unix_socket_path(path));
}

#[cfg(windows)]
pub fn remove_fifo(_path: &Path) {}

pub fn send_frame_file(mut file: impl Write, kind: FrameKind, payload: &[u8]) -> std::io::Result<()> {
    let kind_byte = match kind {
        FrameKind::Exec => b'E',
        FrameKind::Stop => b'S',
        FrameKind::Ready => b'R',
        FrameKind::Stdout => b'O',
        FrameKind::Stderr => b'e',
        FrameKind::Complete => b'C',
        FrameKind::Stopped => b'T',
        FrameKind::Err => b'X',
    };
    file.write_all(&[kind_byte])?;
    file.write_all(&(payload.len() as u32).to_le_bytes())?;
    file.write_all(payload)
}

pub fn read_frame_file(file: &mut impl Read, max_payload: usize) -> Result<Option<Frame>> {
    let mut kind = [0u8; 1];
    match file.read_exact(&mut kind) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err.into()),
    }
    let mut len = [0u8; 4];
    file.read_exact(&mut len)?;
    let len = u32::from_le_bytes(len) as usize;
    if len > max_payload {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large").into());
    }
    let mut payload = vec![0u8; len];
    file.read_exact(&mut payload)?;
    let kind = match kind[0] {
        b'E' => FrameKind::Exec,
        b'S' => FrameKind::Stop,
        b'R' => FrameKind::Ready,
        b'O' => FrameKind::Stdout,
        b'e' => FrameKind::Stderr,
        b'C' => FrameKind::Complete,
        b'T' => FrameKind::Stopped,
        b'X' => FrameKind::Err,
        _ => return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid frame kind").into()),
    };
    Ok(Some(Frame { kind, payload }))
}

#[cfg(windows)]
fn windows_pipe_name(path: &Path) -> Vec<u16> {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut hasher = DefaultHasher::new();
    path.hash(&mut hasher);
    format!(r"\\.\pipe\shlice-{:016x}", hasher.finish())
        .encode_utf16()
        .collect()
}

#[cfg(unix)]
fn unix_socket_path(path: &Path) -> std::path::PathBuf {
    use std::os::unix::ffi::OsStrExt;

    const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    let mut hash = FNV_OFFSET_BASIS;
    for byte in path.as_os_str().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    std::path::PathBuf::from(format!("/tmp/shlice-{hash:016x}.sock"))
}

#[cfg(windows)]
fn windows_accept(name: &[u16]) -> Result<File> {
    let handle = unsafe { create_named_pipe(name)? };
    let connected = unsafe { connect_named_pipe(handle) };
    if !connected {
        let err = std::io::Error::last_os_error();
        const ERROR_PIPE_CONNECTED: i32 = 535;
        if err.raw_os_error() != Some(ERROR_PIPE_CONNECTED) {
            unsafe {
                close_handle(handle);
            }
            return Err(err.into());
        }
    }
    Ok(unsafe { File::from_raw_handle(handle) })
}

#[cfg(windows)]
fn windows_connect(name: &[u16]) -> Result<File> {
    use std::io::ErrorKind;
    use std::thread;
    use std::time::{Duration, Instant};

    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        match unsafe { open_named_pipe(name) } {
            Ok(handle) => return Ok(unsafe { File::from_raw_handle(handle) }),
            Err(err) if err.kind() == ErrorKind::NotFound && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(25));
            }
            Err(err) => return Err(err.into()),
        }
    }
}

#[cfg(windows)]
use std::os::windows::io::{FromRawHandle, RawHandle};

#[cfg(windows)]
const GENERIC_READ: u32 = 0x80000000;
#[cfg(windows)]
const GENERIC_WRITE: u32 = 0x40000000;
#[cfg(windows)]
const OPEN_EXISTING: u32 = 3;
#[cfg(windows)]
const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;
#[cfg(windows)]
const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
#[cfg(windows)]
const PIPE_TYPE_BYTE: u32 = 0x00000000;
#[cfg(windows)]
const PIPE_WAIT: u32 = 0x00000000;
#[cfg(windows)]
const PIPE_UNLIMITED_INSTANCES: u32 = 255;

#[cfg(windows)]
extern "system" {
    fn CreateNamedPipeW(
        lpName: *const u16,
        dwOpenMode: u32,
        dwPipeMode: u32,
        nMaxInstances: u32,
        nOutBufferSize: u32,
        nInBufferSize: u32,
        nDefaultTimeOut: u32,
        lpSecurityAttributes: *mut core::ffi::c_void,
    ) -> RawHandle;
    fn ConnectNamedPipe(hNamedPipe: RawHandle, lpOverlapped: *mut core::ffi::c_void) -> i32;
    fn CreateFileW(
        lpFileName: *const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: *mut core::ffi::c_void,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: RawHandle,
    ) -> RawHandle;
    fn CloseHandle(hObject: RawHandle) -> i32;
}

#[cfg(windows)]
unsafe fn create_named_pipe(name: &[u16]) -> std::io::Result<RawHandle> {
    let handle = CreateNamedPipeW(
        name.as_ptr(),
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        4096,
        4096,
        0,
        core::ptr::null_mut(),
    );
    if handle == invalid_handle() {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(handle)
    }
}

#[cfg(windows)]
unsafe fn connect_named_pipe(handle: RawHandle) -> bool {
    ConnectNamedPipe(handle, core::ptr::null_mut()) != 0
}

#[cfg(windows)]
unsafe fn open_named_pipe(name: &[u16]) -> std::io::Result<RawHandle> {
    let handle = CreateFileW(
        name.as_ptr(),
        GENERIC_READ | GENERIC_WRITE,
        0,
        core::ptr::null_mut(),
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        core::ptr::null_mut(),
    );
    if handle == invalid_handle() {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(handle)
    }
}

#[cfg(windows)]
unsafe fn close_handle(handle: RawHandle) {
    let _ = CloseHandle(handle);
}

#[cfg(windows)]
fn invalid_handle() -> RawHandle {
    (-1isize) as RawHandle
}
