use crate::{is_alive, validate, AppError, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShellStatus {
    Starting,
    Busy,
    Ready,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShellRecord {
    pub id: String,
    pub status: ShellStatus,
    pub pid: Option<u32>,
    pub broker_pid: Option<u32>,
    pub broker_port: Option<u16>,
    pub command_line: String,
}

pub fn default_state_root() -> Result<PathBuf> {
    if let Some(value) = std::env::var_os("SHLICE_STATE_DIR") {
        return Ok(PathBuf::from(value));
    }
    Ok(std::env::current_dir()?.join(".shlice"))
}

pub fn ensure_layout() -> Result<PathBuf> {
    let root = default_state_root()?;
    fs::create_dir_all(shells_root(&root))?;
    Ok(root)
}

pub fn shells_root(root: &Path) -> PathBuf {
    root.join("shells")
}

pub fn shell_dir(root: &Path, id: &str) -> PathBuf {
    shells_root(root).join(id)
}

pub fn state_path(root: &Path, id: &str) -> PathBuf {
    shell_dir(root, id).join("state.json")
}

pub fn ensure_shell_dir(root: &Path, id: &str) -> Result<PathBuf> {
    let dir = shell_dir(root, id);
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

pub fn write_state(root: &Path, record: &ShellRecord) -> Result<()> {
    validate(&record.id).map_err(|m| AppError::Msg(m.to_string()))?;
    let dir = ensure_shell_dir(root, &record.id)?;
    let path = dir.join("state.json");
    atomic_write_json(&path, record)?;
    Ok(())
}

pub fn read_state(root: &Path, id: &str) -> Result<Option<ShellRecord>> {
    let path = state_path(root, id);
    if !path.exists() {
        return Ok(None);
    }
    let file = File::open(path)?;
    Ok(Some(serde_json::from_reader(file)?))
}

pub fn list_states(root: &Path) -> Result<Vec<ShellRecord>> {
    let shells = shells_root(root);
    if !shells.exists() {
        return Ok(Vec::new());
    }
    let mut records: Vec<ShellRecord> = Vec::new();
    for entry in fs::read_dir(shells)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let path = entry.path().join("state.json");
        if !path.exists() {
            continue;
        }
        match File::open(&path).and_then(|file| {
            serde_json::from_reader(file).map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err))
        }) {
            Ok(record) => records.push(record),
            Err(_) => continue,
        }
    }
    records.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(records)
}

pub fn prune_dead(root: &Path) -> Result<()> {
    for record in list_states(root)? {
        let broker_alive = record.broker_pid.map_or(false, is_alive);
        let shell_alive = record.pid.map_or(true, is_alive);
        if !broker_alive || !shell_alive {
            remove_shell(root, &record.id)?;
        }
    }
    Ok(())
}

pub fn remove_shell(root: &Path, id: &str) -> Result<()> {
    let dir = shell_dir(root, id);
    if dir.exists() {
        fs::remove_dir_all(dir)?;
    }
    Ok(())
}

pub fn acquire_lock(root: &Path, id: &str, kind: &str) -> Result<LockGuard> {
    let dir = ensure_shell_dir(root, id)?;
    let path = dir.join(format!("{kind}.lock"));
    let file = OpenOptions::new().read(true).write(true).create(true).open(&path)?;
    if let Err(err) = file.try_lock_exclusive() {
        if err.kind() == std::io::ErrorKind::WouldBlock {
            return Err(AppError::Msg("busy".to_string()));
        }
        return Err(err.into());
    }
    Ok(LockGuard { file, path })
}

pub struct LockGuard {
    file: File,
    path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = self.file.unlock();
        let _ = self.file.sync_all();
        let _ = &self.path;
    }
}

fn atomic_write_json(path: &Path, value: &ShellRecord) -> Result<()> {
    let parent = path.parent().ok_or_else(|| AppError::Msg("invalid path".to_string()))?;
    fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|s| s.to_str()).unwrap_or("state"),
        std::process::id()
    ));
    {
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        serde_json::to_writer_pretty(&file, value)?;
        file.sync_all()?;
    }
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}
