use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
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
    if cfg!(windows) {
        return run_via_files(cmd);
    }
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
    base.push(format!("shlice-test-{}-{stamp}-{seq}", std::process::id(),));
    fs::create_dir_all(&base).unwrap();
    base
}

#[cfg(not(windows))]
fn socket_path(path: &Path) -> PathBuf {
    const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    let mut hash = FNV_OFFSET_BASIS;
    for byte in path.to_string_lossy().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    PathBuf::from(format!("/tmp/shlice-{hash:016x}.sock"))
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn run_with_timeout(cmd: &mut Command, timeout: Duration, label: &str) -> Output {
    if cfg!(windows) {
        return run_with_timeout_via_files(cmd, timeout, label);
    }
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if wait_for_exit(&mut child, timeout).is_none() {
        let _ = child.kill();
        let output = child.wait_with_output().unwrap();
        let (stdout, stderr) = text(&output);
        panic!(
            "{label} timed out after {timeout:?}: status={:?} stdout={stdout:?} stderr={stderr:?}",
            output.status.code()
        );
    }
    child.wait_with_output().unwrap()
}

fn run_via_files(cmd: &mut Command) -> Output {
    let stdout_path = capture_path("stdout");
    let stderr_path = capture_path("stderr");
    let stdout = fs::File::create(&stdout_path).unwrap();
    let stderr = fs::File::create(&stderr_path).unwrap();
    let status = cmd
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .status()
        .unwrap();
    read_captured_output(status, &stdout_path, &stderr_path)
}

fn run_with_timeout_via_files(cmd: &mut Command, timeout: Duration, label: &str) -> Output {
    let stdout_path = capture_path("stdout");
    let stderr_path = capture_path("stderr");
    let stdout = fs::File::create(&stdout_path).unwrap();
    let stderr = fs::File::create(&stderr_path).unwrap();
    let mut child = cmd
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .spawn()
        .unwrap();
    if wait_for_exit(&mut child, timeout).is_none() {
        let _ = child.kill();
        let status = child.wait().unwrap();
        let output = read_captured_output(status, &stdout_path, &stderr_path);
        let (stdout, stderr) = text(&output);
        panic!(
            "{label} timed out after {timeout:?}: status={:?} stdout={stdout:?} stderr={stderr:?}",
            output.status.code()
        );
    }
    let status = child.wait().unwrap();
    read_captured_output(status, &stdout_path, &stderr_path)
}

fn capture_path(kind: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let seq = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
    path.push(format!(
        "shlice-capture-{kind}-{}-{stamp}-{seq}",
        std::process::id()
    ));
    path
}

fn read_captured_output(
    status: std::process::ExitStatus,
    stdout_path: &PathBuf,
    stderr_path: &PathBuf,
) -> Output {
    let stdout = fs::read(stdout_path).unwrap_or_default();
    let stderr = fs::read(stderr_path).unwrap_or_default();
    let _ = fs::remove_file(stdout_path);
    let _ = fs::remove_file(stderr_path);
    Output {
        status,
        stdout,
        stderr,
    }
}

#[test]
fn start_exec_stop() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(fake_shell));
    assert!(out.status.success());
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "started main\n");
    assert_eq!(stderr, "");

    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("(+ 1 2)"));
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
fn start_waits_for_ready() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");

    let started = Instant::now();
    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .env("FAKE_SHELL_STARTUP_DELAY_MS", "700")
        .arg("start")
        .arg("--")
        .arg(&fake_shell));
    let elapsed = started.elapsed();
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert!(elapsed >= Duration::from_millis(650), "elapsed={elapsed:?}");
    assert_eq!(stdout, "started main\n");
    assert_eq!(stderr, "");

    assert!(
        run(Command::new(&shlice).current_dir(&workspace).arg("stop"))
            .status
            .success()
    );
}

#[test]
fn start_handles_fragmented_ready_marker() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");

    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .env("FAKE_SHELL_FRAGMENT_READY", "1")
        .arg("start")
        .arg("--")
        .arg(&fake_shell));
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert_eq!(stdout, "started main\n");
    assert_eq!(stderr, "");

    assert!(
        run(Command::new(&shlice).current_dir(&workspace).arg("stop"))
            .status
            .success()
    );
}

#[test]
fn exec_streams_stderr_before_completion() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());

    let stdout_path = workspace.join("exec.stdout");
    let stderr_path = workspace.join("exec.stderr");
    let mut child = Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("(do (println \"warn\") (Thread/sleep 2000) :done)")
        .stdout(Stdio::from(fs::File::create(&stdout_path).unwrap()))
        .stderr(Stdio::from(fs::File::create(&stderr_path).unwrap()))
        .spawn()
        .unwrap();
    let stop_shell = || {
        let _ = run(Command::new(&shlice).current_dir(&workspace).arg("stop"));
    };

    let deadline = Instant::now() + Duration::from_millis(1000);
    let first_stderr = loop {
        let stderr = fs::read_to_string(&stderr_path)
            .unwrap_or_default()
            .replace("\r\n", "\n");
        if !stderr.is_empty() {
            break stderr;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = wait_for_exit(&mut child, Duration::from_secs(1));
            stop_shell();
            panic!("timed out waiting for streamed stderr");
        }
        if let Some(status) = child.try_wait().unwrap() {
            let stdout = fs::read_to_string(&stdout_path)
                .unwrap_or_default()
                .replace("\r\n", "\n");
            stop_shell();
            panic!("exec exited early: status={status:?} stdout={stdout:?} stderr={stderr:?}");
        }
        thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(first_stderr, "warn\n");
    assert!(child.try_wait().unwrap().is_none());

    let status = match wait_for_exit(&mut child, Duration::from_secs(5)) {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = wait_for_exit(&mut child, Duration::from_secs(1));
            stop_shell();
            panic!("exec child did not exit");
        }
    };
    let stdout = fs::read_to_string(&stdout_path)
        .unwrap_or_default()
        .replace("\r\n", "\n");
    let stderr = fs::read_to_string(&stderr_path)
        .unwrap_or_default()
        .replace("\r\n", "\n");
    assert!(status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert_eq!(stdout, ":done\n");
    assert_eq!(stderr, "warn\n");

    assert!(
        run(Command::new(&shlice).current_dir(&workspace).arg("stop"))
            .status
            .success()
    );
}

#[test]
fn restart_after_stop() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());
    assert!(
        run(Command::new(&shlice).current_dir(&workspace).arg("stop"))
            .status
            .success()
    );
    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell));
    assert!(out.status.success());
}

#[test]
fn stop_accepts_positional_shell_id() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--id")
        .arg("custom")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());

    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("stop")
        .arg("custom"));
    let (stdout, stderr) = text(&out);
    assert!(out.status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert_eq!(stdout, "stopped custom\n");
    assert_eq!(stderr, "");
}

#[test]
fn incomplete_command_recovers() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run_with_timeout(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("start")
            .arg("--")
            .arg(&fake_shell),
        Duration::from_secs(10),
        "start for incomplete_command_recovers",
    )
    .status
    .success());
    let out = run_with_timeout(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("exec")
            .arg("(+ 1"),
        Duration::from_secs(10),
        "first exec for incomplete_command_recovers",
    );
    assert!(!out.status.success());
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "");
    assert!(stderr.contains("incomplete") || stderr.contains("timed out"));
    let out = run_with_timeout(
        Command::new(&shlice)
            .current_dir(&workspace)
            .arg("exec")
            .arg("2)"),
        Duration::from_secs(10),
        "second exec for incomplete_command_recovers",
    );
    assert!(out.status.success());
    let (stdout, _) = text(&out);
    assert_eq!(stdout, "3\n");
}

#[test]
fn timed_out_exec_does_not_break_next_exec() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());

    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("--timeout")
        .arg("0")
        .arg("(do :first (Thread/sleep 1000))"));
    assert_eq!(out.status.code(), Some(124));
    let (stdout, stderr) = text(&out);
    assert_eq!(stdout, "");
    assert_eq!(stderr, "error: exec timed out\n");

    // Let the shell finish the timed-out form so the broker has to finalize it.
    thread::sleep(Duration::from_millis(1200));

    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("(* 6 7)"));
    let (stdout, stderr) = text(&out);
    assert!(
        out.status.success(),
        "next exec failed: stdout={stdout:?} stderr={stderr:?}"
    );
    assert_eq!(stdout, "42\n");
    assert_eq!(stderr, "");

    assert!(
        run(Command::new(&shlice).current_dir(&workspace).arg("stop"))
            .status
            .success()
    );
}

#[test]
fn status_reports_busy_during_exec() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());

    let exec = Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("--timeout")
        .arg("10")
        .arg("(do :first (Thread/sleep 1000))")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    thread::sleep(Duration::from_millis(200));

    let status = run(Command::new(&shlice).current_dir(&workspace).arg("status"));
    let (stdout, stderr) = text(&status);
    assert!(status.status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert!(stdout.contains("main\tbusy\t"), "stdout={stdout:?}");
    assert_eq!(stderr, "");

    let exec_out = exec.wait_with_output().unwrap();
    let (stdout, stderr) = text(&exec_out);
    assert!(exec_out.status.success(), "stdout={stdout:?} stderr={stderr:?}");

    assert!(
        run(Command::new(&shlice).current_dir(&workspace).arg("stop"))
            .status
            .success()
    );
}

#[test]
fn stop_does_not_claim_success_while_exec_lock_is_busy() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());

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
    let stop = run_with_timeout(
        Command::new(&shlice).current_dir(&workspace).arg("stop"),
        Duration::from_secs(20),
        "stop while exec is busy",
    );
    let elapsed = started.elapsed();
    let (stdout, stderr) = text(&stop);
    assert!(
        stop.status.success(),
        "stop failed: code={:?} elapsed={elapsed:?} stdout={stdout:?} stderr={stderr:?}",
        stop.status.code()
    );
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

    let out = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .arg("(* 6 7)"));
    let (stdout, stderr) = text(&out);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(stdout, "");
    assert_eq!(stderr, "error: shell not found\n");
}

#[test]
fn stop_does_not_force_kill_exec_client_waiting_for_stdin() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    assert!(run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell))
    .status
    .success());

    let mut exec = Command::new(&shlice)
        .current_dir(&workspace)
        .arg("exec")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    thread::sleep(Duration::from_millis(200));

    let started = Instant::now();
    let stop = run_with_timeout(
        Command::new(&shlice).current_dir(&workspace).arg("stop"),
        Duration::from_secs(5),
        "stop while exec waits for stdin",
    );
    let elapsed = started.elapsed();
    let (stdout, stderr) = text(&stop);
    assert!(
        stop.status.success(),
        "stdout={stdout:?} stderr={stderr:?} elapsed={elapsed:?}",
    );
    assert!(elapsed < Duration::from_secs(3), "elapsed={elapsed:?}");
    assert_eq!(stdout, "stopped main\n");
    assert_eq!(stderr, "");

    let status = run(Command::new(&shlice).current_dir(&workspace).arg("status"));
    let (stdout, stderr) = text(&status);
    assert!(status.status.success());
    assert_eq!(stdout, "no shells\n");
    assert_eq!(stderr, "");

    drop(exec.stdin.take());
    let exec_out = exec.wait_with_output().unwrap();
    let (stdout, stderr) = text(&exec_out);
    assert_eq!(exec_out.status.code(), Some(1));
    assert_eq!(stdout, "");
    assert_eq!(stderr, "error: missing command\n");

    let restart = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell));
    let (stdout, stderr) = text(&restart);
    assert!(
        restart.status.success(),
        "stdout={stdout:?} stderr={stderr:?}"
    );
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
        assert!(run(Command::new(&shlice)
            .current_dir(&workspace)
            .arg("start")
            .arg("--")
            .arg(&fake_shell))
        .status
        .success());
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

#[cfg(not(windows))]
#[test]
fn unix_socket_paths_are_removed_after_stop() {
    let workspace = workspace();
    let shlice = exe("shlice");
    let fake_shell = exe("fake_shell");
    let root = workspace.join(".shlice").join("shells").join("main");
    let startup_socket = socket_path(&root.join("startup.fifo"));
    let control_socket = socket_path(&root.join("control.fifo"));

    let start = run(Command::new(&shlice)
        .current_dir(&workspace)
        .arg("start")
        .arg("--")
        .arg(&fake_shell));
    let (stdout, stderr) = text(&start);
    assert!(start.status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert!(!startup_socket.exists(), "startup socket still exists: {startup_socket:?}");

    let stop = run(Command::new(&shlice).current_dir(&workspace).arg("stop"));
    let (stdout, stderr) = text(&stop);
    assert!(stop.status.success(), "stdout={stdout:?} stderr={stderr:?}");
    assert!(
        !control_socket.exists(),
        "control socket still exists: {control_socket:?}"
    );
}
