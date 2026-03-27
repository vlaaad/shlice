use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

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
    if cfg!(windows) {
        return;
    }
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
    if cfg!(windows) {
        return;
    }
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
    if cfg!(windows) {
        return;
    }
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
fn timed_out_exec_does_not_break_next_exec() {
    if cfg!(windows) {
        return;
    }
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(
        run(
            Command::new(&shlice)
                .current_dir(&workspace)
                .arg("start")
                .arg("--")
                .arg(&fake_shell)
        )
        .status
        .success()
    );

    let out = run(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("exec")
            .arg("--timeout")
            .arg("0")
            .arg("(do :first (Thread/sleep 1000))"),
    );
    assert_eq!(out.status.code(), Some(124));
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "");
    assert_eq!(stderr, "error: exec timed out\n");

    // Let the shell finish the timed-out form so the broker has to finalize it.
    thread::sleep(Duration::from_millis(1200));

    let out = run(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("exec")
            .arg("(* 6 7)"),
    );
    let (stdout, stderr) = text(&out);
    assert!(
        out.status.success(),
        "next exec failed: stdout={stdout:?} stderr={stderr:?}"
    );
    assert_eq!(stdout, "42\n");
    assert_eq!(stderr, "");

    assert!(run(Command::new(&shlice).current_dir(&workspace).arg("stop")).status.success());
}

#[test]
fn stop_does_not_claim_success_while_exec_lock_is_busy() {
    if cfg!(windows) {
        return;
    }
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(
        run(
            Command::new(&shlice)
                .current_dir(&workspace)
                .arg("start")
                .arg("--")
                .arg(&fake_shell)
        )
        .status
        .success()
    );

    let exec = Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("--timeout")
        .arg("10")
        .arg("(do :first (Thread/sleep 6000))")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    thread::sleep(Duration::from_millis(200));

    let started = Instant::now();
    let stop = run(Command::new(&shlice).current_dir(&workspace).arg("stop"));
    let elapsed = started.elapsed();
    let (stdout, stderr) = text(&stop);
    assert!(stop.status.success());
    assert!(elapsed >= Duration::from_secs(5));
    assert_eq!(stdout, "stopped main\n");
    assert_eq!(stderr, "");

    let status = run(Command::new(&shlice).current_dir(&workspace).arg("status"));
    let (stdout, stderr) = text(&status);
    assert!(status.status.success());
    assert_eq!(stdout, "no shells\n");
    assert_eq!(stderr, "");

    let exec_out = exec.wait_with_output().unwrap();
    let (stdout, stderr) = text(&exec_out);
    assert_eq!(exec_out.status.code(), Some(1));
    assert_eq!(stdout, "");
    assert_eq!(stderr, "error: shell stopped\n");

    let out = run(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("exec")
            .arg("(* 6 7)"),
    );
    let (stdout, stderr) = text(&out);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(stdout, "");
    assert_eq!(stderr, "error: shell not found\n");
}

#[test]
fn state_stays_in_shlice() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");

    if cfg!(windows) {
        let status = Command::new(&shlice)
            .current_dir(&workspace)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .arg("start")
            .arg("--")
            .arg(&fake_shell)
            .status()
            .unwrap();
        assert!(status.success());
    } else {
        assert!(
            run(
                Command::new(&shlice)
                    .current_dir(&workspace)
                    .arg("start")
                    .arg("--")
                    .arg(&fake_shell)
            )
            .status
            .success()
        );
    }

    assert!(workspace.join(".shlice").exists());
    assert!(!workspace.join("state.json").exists());

    let stop = Command::new(&shlice)
        .current_dir(&workspace)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .arg("stop")
        .status()
        .unwrap();
    assert!(stop.success());
}
