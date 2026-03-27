use crate::{Frame, FrameKind, Result};
use interprocess::local_socket::{
    prelude::*, ConnectOptions, GenericFilePath, ListenerNonblockingMode, ListenerOptions,
};
use std::io::{Read, Write};
use std::path::Path;

pub struct IpcListener {
    listener: interprocess::local_socket::Listener,
}

pub type IpcStream = interprocess::local_socket::Stream;

pub fn create_fifo(path: &Path) -> Result<IpcListener> {
    let name = socket_name(path).to_fs_name::<GenericFilePath>()?;
    let listener = ListenerOptions::new()
        .name(name)
        .try_overwrite(true)
        .create_sync()?;
    Ok(IpcListener { listener })
}

impl IpcListener {
    pub fn accept(&self) -> Result<IpcStream> {
        Ok(interprocess::local_socket::traits::Listener::accept(
            &self.listener,
        )?)
    }

    pub fn set_nonblocking_accept(&self, nonblocking: bool) -> Result<()> {
        let mode = if nonblocking {
            ListenerNonblockingMode::Accept
        } else {
            ListenerNonblockingMode::Neither
        };
        interprocess::local_socket::traits::Listener::set_nonblocking(&self.listener, mode)?;
        Ok(())
    }
}

pub fn open_fifo_read_write(path: &Path) -> Result<IpcStream> {
    use std::io::ErrorKind;
    use std::thread;
    use std::time::{Duration, Instant};

    let deadline = Instant::now() + Duration::from_secs(30);
    let name = socket_name(path);
    loop {
        match ConnectOptions::new()
            .name(name.clone().to_fs_name::<GenericFilePath>()?)
            .connect_sync()
        {
            Ok(stream) => return Ok(stream),
            Err(err) if err.kind() == ErrorKind::NotFound && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(err) => return Err(err.into()),
        }
    }
}

pub fn remove_fifo(_path: &Path) {}

pub fn send_frame_file(
    mut file: impl Write,
    kind: FrameKind,
    payload: &[u8],
) -> std::io::Result<()> {
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
        _ => {
            return Err(
                std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid frame kind").into(),
            )
        }
    };
    Ok(Some(Frame { kind, payload }))
}

fn socket_name(path: &Path) -> String {
    const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    let mut hash = FNV_OFFSET_BASIS;
    for byte in path.to_string_lossy().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    if cfg!(windows) {
        format!(r"\\.\pipe\shlice-{hash:016x}")
    } else {
        format!("/tmp/shlice-{hash:016x}.sock")
    }
}
