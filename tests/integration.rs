use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_DIR: AtomicU64 = AtomicU64::new(1);

fn exe(name: &str) -> PathBuf {
    if let Ok(path) = std::env::var(format!("CARGO_BIN_EXE_{name}")) {
        return PathBuf::from(path);
    }
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("target");
    path.push("debug");
    if cfg!(windows) {
        path.push(format!("{name}.exe"));
    } else {
        path.push(name);
    }
    path
}

fn run(cmd: &mut Command) -> Output {
    cmd.output().unwrap()
}

fn text(output: &Output) -> (String, String) {
    (
        String::from_utf8_lossy(&output.stdout).replace("\r\n", "\n"),
        String::from_utf8_lossy(&output.stderr).replace("\r\n", "\n"),
    )
}

fn workspace() -> PathBuf {
    let mut base = std::env::temp_dir();
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let seq = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
    base.push(format!(
        "shlice-test-{}-{stamp}-{seq}",
        std::process::id(),
    ));
    fs::create_dir_all(&base).unwrap();
    base
}

#[test]
fn start_exec_stop() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    let out = run(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("start")
            .arg("--")
            .arg(fake_shell),
    );
    assert!(out.status.success());
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "started main\n");
    assert_eq!(stderr, "");

    let out = run(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("exec")
            .arg("(+ 1 2)"),
    );
    assert!(out.status.success());
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "3\n");
    assert_eq!(stderr, "");

    let out = run(Command::new(&shlice).current_dir(&workspace).arg("stop"));
    assert!(out.status.success());
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "stopped main\n");
    assert_eq!(stderr, "");
}

#[test]
fn restart_after_stop() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice).current_dir(&workspace).arg("start").arg("--").arg(&fake_shell)).status.success());
    assert!(run(Command::new(&shlice).current_dir(&workspace).arg("stop")).status.success());
    let out = run(Command::new(&shlice).current_dir(&workspace).arg("start").arg("--").arg(&fake_shell));
    assert!(out.status.success());
}

#[test]
fn incomplete_command_recovers() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice).current_dir(&workspace).arg("start").arg("--").arg(&fake_shell)).status.success());
    let out = run(Command::new(&shlice).current_dir(&workspace).arg("exec").arg("(+ 1"));
    assert!(!out.status.success());
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "");
    assert!(stderr.contains("incomplete") || stderr.contains("timed out"));
    let out = run(Command::new(&shlice).current_dir(&workspace).arg("exec").arg("2)"));
    assert!(out.status.success());
    let (stdout, _) = text(&out);
    assert_eq!(stdout, "3\n");
}

#[test]
fn state_stays_in_shlice() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice).current_dir(&workspace).arg("start").arg("--").arg(&fake_shell)).status.success());
    assert!(workspace.join(".shlice").exists());
    assert!(!workspace.join("state.json").exists());
}
