use crate::{
    build_exec_command, chunk_contains_ready, current_pid, encode_completion, force_kill,
    parse_exec_request, parse_stop_request, print_started, read_frame_file, remove_shell,
    send_frame_file, write_state, AppError, BrokerOptions, Completion, FrameKind, Result,
    ShellRecord, ShellStatus, StdoutParseState,
};
use std::fs::{File, OpenOptions};
use std::collections::VecDeque;
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const COMMAND_BEGIN_TIMEOUT: Duration = Duration::from_secs(1);
const COMPLETION_GRACE: Duration = Duration::from_millis(10);
const POLL: Duration = Duration::from_millis(20);

struct PendingRequest {
    reply_path: String,
    command: Option<String>,
    stop: bool,
}

struct ActiveRequest {
    reply_path: String,
    stop: bool,
    request_started: Instant,
    saw_begin: bool,
    saw_end: bool,
    completion_ready_at: Option<Instant>,
    exit_code: Option<i32>,
}

struct SharedState {
    queue: VecDeque<PendingRequest>,
    active: Option<ActiveRequest>,
    shutdown_requested: bool,
    shell_ready: bool,
    shell_exited: bool,
    stdout_state: StdoutParseState,
}

pub fn run_broker(options: BrokerOptions) -> Result<u8> {
    #[cfg(windows)]
    {
        return run_broker_windows(options);
    }
    #[cfg(not(windows))]
    {
    let root = PathBuf::from(&options.root);
    let shell_dir = crate::ensure_shell_dir(&root, &options.id)?;
    let ready_path = shell_dir.join("startup.fifo");
    let control_path = shell_dir.join("control.fifo");

    let control_listener = crate::ipc::create_fifo(&control_path)?;

    let command_line = options.command.join(" ");
    let mut record = ShellRecord {
        id: options.id.clone(),
        status: ShellStatus::Starting,
        pid: None,
        broker_pid: Some(current_pid()),
        broker_port: None,
        command_line: command_line.clone(),
    };
    write_state(&root, &record)?;

    let mut child = spawn_shell(&options)?;
    record.status = ShellStatus::Busy;
    record.pid = Some(child.id());
    write_state(&root, &record)?;

    let stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let shared = Arc::new((
        Mutex::new(SharedState {
            queue: VecDeque::new(),
            active: None,
            shutdown_requested: false,
            shell_ready: false,
            shell_exited: false,
            stdout_state: StdoutParseState {
                inside_prompt: false,
                pending: Vec::new(),
            },
        }),
        Condvar::new(),
    ));

    spawn_control_loop(shared.clone(), control_listener);
    spawn_stdout_loop(shared.clone(), stdout);
    spawn_stderr_loop(shared.clone(), stderr);

    wait_for_ready(&shared, &root, &options.id, &mut record, &ready_path)?;
    main_loop(shared, &root, &options.id, &mut child, stdin)?;
    remove_shell(&root, &options.id)?;
    Ok(0)
    }
}

fn spawn_shell(options: &BrokerOptions) -> Result<Child> {
    let mut command = Command::new(&options.command[0]);
    command.args(&options.command[1..]);
    command.current_dir(&options.cwd);
    command.stdin(Stdio::piped());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    Ok(command.spawn()?)
}

fn wait_for_ready(
    shared: &Arc<(Mutex<SharedState>, Condvar)>,
    root: &Path,
    id: &str,
    record: &mut ShellRecord,
    ready_path: &Path,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        {
            let guard = shared.0.lock().unwrap();
            if guard.shell_ready {
                break;
            }
            if guard.shell_exited {
                let _ = std::fs::remove_file(ready_path);
                return Err(AppError::Msg("shell start failed".to_string()));
            }
        }
        if Instant::now() >= deadline {
            let _ = std::fs::remove_file(ready_path);
            return Err(AppError::Msg("shell did not become ready before timeout".to_string()));
        }
        thread::sleep(POLL);
    }
    record.status = ShellStatus::Ready;
    write_state(root, record)?;
    if let Ok(mut ready_file) = crate::ipc::open_fifo_read_write(ready_path) {
        let _ = send_frame_file(&mut ready_file, FrameKind::Ready, &[]);
    }
    print_started(id);
    let _ = std::fs::remove_file(ready_path);
    Ok(())
}

fn main_loop(
    shared: Arc<(Mutex<SharedState>, Condvar)>,
    root: &Path,
    id: &str,
    child: &mut Child,
    mut stdin: ChildStdin,
) -> Result<()> {
    loop {
        if let Some(status) = child.try_wait()? {
            let mut guard = shared.0.lock().unwrap();
            guard.shell_exited = true;
            if let Some(active) = guard.active.as_mut() {
                active.exit_code = Some(status.code().unwrap_or(1));
            }
            shared.1.notify_all();
        }

        let mut guard = shared.0.lock().unwrap();
        if guard.active.is_none() {
            if let Some(request) = guard.queue.pop_front() {
                if request.stop {
                    guard.shutdown_requested = true;
                    guard.active = Some(ActiveRequest {
                        reply_path: request.reply_path,
                        stop: true,
                        request_started: Instant::now(),
                        saw_begin: true,
                        saw_end: true,
                        completion_ready_at: Some(Instant::now()),
                        exit_code: Some(0),
                    });
                    drop(guard);
                    let _ = force_kill(child.id());
                    continue;
                }
                let command = request.command.unwrap_or_default();
                guard.active = Some(ActiveRequest {
                    reply_path: request.reply_path,
                    stop: false,
                    request_started: Instant::now(),
                    saw_begin: false,
                    saw_end: false,
                    completion_ready_at: None,
                    exit_code: None,
                });
                drop(guard);
                stdin.write_all(build_exec_command(&command).as_bytes())?;
                stdin.flush()?;
                continue;
            }
        }

        if let Some(reason) = finish_reason(&guard) {
            let active = guard.active.take().unwrap();
            let exit_code = active.exit_code.unwrap_or(1);
            let shutdown = guard.shutdown_requested || matches!(reason, FinishReason::Shutdown);
            drop(guard);
            finish_request(&active, reason, exit_code)?;
            if shutdown {
                break;
            }
            continue;
        }

        if guard.shutdown_requested && guard.active.is_none() && guard.queue.is_empty() {
            break;
        }

        let (next_guard, _) = shared.1.wait_timeout(guard, POLL).unwrap();
        drop(next_guard);
    }
    remove_shell(root, id)?;
    Ok(())
}

enum FinishReason {
    Complete,
    Incomplete,
    Shutdown,
    Stopped,
}

fn finish_reason(state: &SharedState) -> Option<FinishReason> {
    let active = state.active.as_ref()?;
    if active.stop && (state.shutdown_requested || state.shell_exited) {
        return Some(FinishReason::Stopped);
    }
    if state.shutdown_requested || state.shell_exited {
        return Some(FinishReason::Shutdown);
    }
    if active.saw_end
        && active
            .completion_ready_at
            .map_or(false, |t| t.elapsed() >= COMPLETION_GRACE)
    {
        return Some(FinishReason::Complete);
    }
    if !active.saw_begin && active.request_started.elapsed() >= COMMAND_BEGIN_TIMEOUT {
        return Some(FinishReason::Incomplete);
    }
    None
}

fn finish_request(active: &ActiveRequest, reason: FinishReason, exit_code: i32) -> Result<()> {
    match reason {
        FinishReason::Complete => {
            let payload = encode_completion(&Completion {
                exit_code,
                timed_out: false,
            });
            let mut reply = crate::ipc::open_fifo_read_write(Path::new(&active.reply_path))?;
            send_frame_file(&mut reply, FrameKind::Complete, &payload)?;
        }
        FinishReason::Incomplete => {
            let mut reply = crate::ipc::open_fifo_read_write(Path::new(&active.reply_path))?;
            send_frame_file(&mut reply, FrameKind::Stderr, b"error: incomplete command\n")?;
            let payload = encode_completion(&Completion {
                exit_code: 1,
                timed_out: false,
            });
            send_frame_file(&mut reply, FrameKind::Complete, &payload)?;
        }
        FinishReason::Shutdown => {
            let mut reply = crate::ipc::open_fifo_read_write(Path::new(&active.reply_path))?;
            send_frame_file(&mut reply, FrameKind::Err, b"shell stopped")?;
        }
        FinishReason::Stopped => {
            let mut reply = crate::ipc::open_fifo_read_write(Path::new(&active.reply_path))?;
            send_frame_file(&mut reply, FrameKind::Stopped, b"")?;
        }
    }
    let _ = std::fs::remove_file(&active.reply_path);
    Ok(())
}

fn spawn_control_loop(
    shared: Arc<(Mutex<SharedState>, Condvar)>,
    control_listener: crate::ipc::IpcListener,
) {
    thread::spawn(move || {
        loop {
            let mut control = match control_listener.accept() {
                Ok(file) => file,
                Err(_) => return,
            };
            let frame = match read_frame_file(&mut control, 1024 * 1024) {
                Ok(Some(frame)) => frame,
                _ => continue,
            };
            let mut guard = shared.0.lock().unwrap();
            match frame.kind {
                FrameKind::Exec => {
                    if let Ok(request) = parse_exec_request(&frame.payload) {
                        guard.queue.push_back(PendingRequest {
                            reply_path: request.reply_path,
                            command: Some(request.command),
                            stop: false,
                        });
                    }
                }
                FrameKind::Stop => {
                    if let Ok(request) = parse_stop_request(&frame.payload) {
                        guard.queue.push_back(PendingRequest {
                            reply_path: request.reply_path,
                            command: None,
                            stop: true,
                        });
                    }
                }
                _ => {}
            }
            shared.1.notify_all();
        }
    });
}

fn spawn_stdout_loop(shared: Arc<(Mutex<SharedState>, Condvar)>, mut stdout: ChildStdout) {
    thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let mut ready_seen = false;
        loop {
            let n = match stdout.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            let mut guard = shared.0.lock().unwrap();
            if !ready_seen {
                if chunk_contains_ready(&buf[..n]) {
                    guard.shell_ready = true;
                    ready_seen = true;
                    shared.1.notify_all();
                }
                continue;
            }
            let mut sink = Vec::new();
            let parsed = crate::parse_stdout_chunk(&mut sink, &buf[..n], &mut guard.stdout_state);
            if let Ok(parsed) = parsed {
                if let Some(active) = guard.active.as_mut() {
                    if parsed.began_request {
                        active.saw_begin = true;
                    }
                    if parsed.ended_request {
                        active.saw_end = true;
                        active.exit_code = parsed.exit_code;
                    }
                    if parsed.finished_prompt && active.saw_begin && active.saw_end {
                        active.completion_ready_at = Some(Instant::now());
                    }
                    if !sink.is_empty() {
                        if let Ok(mut reply) = crate::ipc::open_fifo_read_write(Path::new(&active.reply_path)) {
                            let _ = send_frame_file(&mut reply, FrameKind::Stdout, &sink);
                        }
                    }
                }
            }
            shared.1.notify_all();
        }
        let mut guard = shared.0.lock().unwrap();
        guard.shell_exited = true;
        shared.1.notify_all();
    });
}

fn spawn_stderr_loop(shared: Arc<(Mutex<SharedState>, Condvar)>, mut stderr: ChildStderr) {
    thread::spawn(move || {
        let mut buf = [0u8; 2048];
        loop {
            let n = match stderr.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            let guard = shared.0.lock().unwrap();
            if let Some(active) = guard.active.as_ref() {
                if let Ok(mut reply) = crate::ipc::open_fifo_read_write(Path::new(&active.reply_path)) {
                    let _ = send_frame_file(&mut reply, FrameKind::Stderr, &buf[..n]);
                }
            }
        }
    });
}

#[cfg(windows)]
fn run_broker_windows(options: BrokerOptions) -> Result<u8> {
    let root = PathBuf::from(&options.root);
    let shell_dir = crate::ensure_shell_dir(&root, &options.id)?;

    let command_line = options.command.join(" ");
    let mut record = ShellRecord {
        id: options.id.clone(),
        status: ShellStatus::Starting,
        pid: None,
        broker_pid: Some(current_pid()),
        broker_port: None,
        command_line: command_line.clone(),
    };
    write_state(&root, &record)?;

    let mut child = spawn_shell(&options)?;
    record.status = ShellStatus::Busy;
    record.pid = Some(child.id());
    write_state(&root, &record)?;

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let shared = Arc::new((
        Mutex::new(WindowsSharedState {
            shutdown_requested: false,
            shell_ready: false,
            shell_exited: false,
            active_request_id: None,
            active_stdout: None,
            active_stderr: None,
            active_exit_code: None,
            request_started_at: None,
            saw_begin: false,
            saw_end: false,
            completion_ready_at: None,
            stdout_state: StdoutParseState {
                inside_prompt: false,
                pending: Vec::new(),
            },
        }),
        Condvar::new(),
    ));

    windows_spawn_stdout_loop(shared.clone(), stdout);
    windows_spawn_stderr_loop(shared.clone(), stderr);

    let startup_deadline = Instant::now() + Duration::from_secs(30);
    loop {
        {
            let guard = shared.0.lock().unwrap();
            if guard.shell_ready {
                break;
            }
            if guard.shell_exited {
                let _ = write_error_file(&root, &options.id, "shell start failed");
                let _ = remove_shell(&root, &options.id);
                return Err(AppError::Msg("shell start failed".to_string()));
            }
        }
        if Instant::now() >= startup_deadline {
            let _ = force_kill(child.id());
            let _ = write_error_file(&root, &options.id, "shell did not become ready before timeout");
            let _ = remove_shell(&root, &options.id);
            return Err(AppError::Msg("shell did not become ready before timeout".to_string()));
        }
        thread::sleep(Duration::from_millis(25));
    }

    record.status = ShellStatus::Ready;
    write_state(&root, &record)?;
    print_started(&options.id);

    let request_path = shell_dir.join("request.json");
    let stop_path = shell_dir.join("stop.request");
    let completion_path = shell_dir.join("completion.json");
    let stdout_path = shell_dir.join("stdout.log");
    let stderr_path = shell_dir.join("stderr.log");

    loop {
        if let Some(status) = child.try_wait()? {
            let mut guard = shared.0.lock().unwrap();
            guard.shell_exited = true;
            if let Some(active) = guard.active_request_id.as_ref() {
                let _ = active;
                guard.active_exit_code = Some(status.code().unwrap_or(1));
            }
            shared.1.notify_all();
        }

        {
            let mut guard = shared.0.lock().unwrap();
            if guard.active_request_id.is_none() && request_path.exists() {
                if let Ok(request_bytes) = std::fs::read(&request_path) {
                    if let Ok(request) = crate::parse_request(&request_bytes) {
                        if let Ok(exec_command) = std::fs::read_to_string(&request_path) {
                            let _ = exec_command;
                        }
                        let exec_command = crate::build_exec_command(&request.command);
                        std::fs::remove_file(&stdout_path).ok();
                        std::fs::remove_file(&stderr_path).ok();
                        std::fs::remove_file(&completion_path).ok();
                        let stdout_log = OpenOptions::new().create(true).truncate(true).write(true).open(&stdout_path)?;
                        let stderr_log = OpenOptions::new().create(true).truncate(true).write(true).open(&stderr_path)?;
                        stdin.write_all(exec_command.as_bytes())?;
                        stdin.flush()?;
                        guard.active_request_id = Some(request.id);
                        guard.active_stdout = Some(stdout_log);
                        guard.active_stderr = Some(stderr_log);
                        guard.active_exit_code = None;
                        guard.saw_begin = false;
                        guard.saw_end = false;
                        guard.completion_ready_at = None;
                        guard.request_started_at = Some(Instant::now());
                        shared.1.notify_all();
                        record.status = ShellStatus::Busy;
                        write_state(&root, &record)?;
                    }
                }
            }

            if guard.shutdown_requested && guard.active_request_id.is_none() {
                let _ = force_kill(child.id());
                drop(guard);
                break;
            }
        }

        if let Some((request_id, reason, exit_code, stdout_file, stderr_file)) = windows_take_finished_request(&shared) {
            if let Some(mut stderr_file) = stderr_file {
                if matches!(reason, WindowsRequestFinishReason::IncompleteCommand) {
                    let _ = stderr_file.write_all(b"error: incomplete command\n");
                } else if matches!(reason, WindowsRequestFinishReason::Shutdown) {
                    let _ = stderr_file.write_all(b"error: shell stopped\n");
                }
                let _ = stderr_file.flush();
            }
            if let Some(mut stdout_file) = stdout_file {
                let _ = stdout_file.flush();
            }
            let completion = crate::WindowsCompletion {
                id: request_id.clone(),
                exit_code,
                timed_out: false,
            };
            std::fs::write(&completion_path, crate::stringify_completion(&completion)?)?;
            let _ = std::fs::remove_file(&request_path);
            record.status = ShellStatus::Ready;
            write_state(&root, &record)?;
            continue;
        }

        let _ = windows_maybe_start_stop(&shared, &stop_path);

        if Instant::now() >= startup_deadline + Duration::from_secs(300) {
            break;
        }
        thread::sleep(Duration::from_millis(25));
    }

    let _ = remove_shell(&root, &options.id);
    Ok(0)
}

#[cfg(windows)]
enum WindowsRequestFinishReason {
    Complete,
    IncompleteCommand,
    Shutdown,
}

#[cfg(windows)]
struct WindowsSharedState {
    shutdown_requested: bool,
    shell_ready: bool,
    shell_exited: bool,
    active_request_id: Option<String>,
    active_stdout: Option<File>,
    active_stderr: Option<File>,
    active_exit_code: Option<i32>,
    request_started_at: Option<Instant>,
    saw_begin: bool,
    saw_end: bool,
    completion_ready_at: Option<Instant>,
    stdout_state: StdoutParseState,
}

#[cfg(windows)]
fn windows_spawn_stdout_loop(shared: Arc<(Mutex<WindowsSharedState>, Condvar)>, mut stdout: ChildStdout) {
    thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let mut ready_seen = false;
        loop {
            let n = match stdout.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            let mut guard = shared.0.lock().unwrap();
            if !ready_seen {
                if chunk_contains_ready(&buf[..n]) {
                    guard.shell_ready = true;
                    ready_seen = true;
                    shared.1.notify_all();
                }
                continue;
            }
            let mut sink = Vec::new();
            let parsed = crate::parse_stdout_chunk(&mut sink, &buf[..n], &mut guard.stdout_state);
            if let Ok(parsed) = parsed {
                if parsed.began_request {
                    guard.saw_begin = true;
                    guard.saw_end = false;
                    guard.completion_ready_at = None;
                    guard.active_exit_code = None;
                }
                if parsed.ended_request {
                    guard.saw_end = true;
                    guard.active_exit_code = parsed.exit_code;
                }
                if parsed.finished_prompt && guard.saw_begin && guard.saw_end {
                    guard.completion_ready_at = Some(Instant::now());
                }
                if !sink.is_empty() {
                    if let Some(active) = guard.active_stdout.as_mut() {
                        let _ = active.write_all(&sink);
                        let _ = active.flush();
                    }
                }
            }
            shared.1.notify_all();
        }
        let mut guard = shared.0.lock().unwrap();
        guard.shell_exited = true;
        shared.1.notify_all();
    });
}

#[cfg(windows)]
fn windows_spawn_stderr_loop(shared: Arc<(Mutex<WindowsSharedState>, Condvar)>, mut stderr: ChildStderr) {
    thread::spawn(move || {
        let mut buf = [0u8; 2048];
        loop {
            let n = match stderr.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            let mut guard = shared.0.lock().unwrap();
            if let Some(file) = guard.active_stderr.as_mut() {
                let _ = file.write_all(&buf[..n]);
                let _ = file.flush();
            }
        }
    });
}

#[cfg(windows)]
fn windows_take_finished_request(
    shared: &Arc<(Mutex<WindowsSharedState>, Condvar)>,
) -> Option<(String, WindowsRequestFinishReason, i32, Option<File>, Option<File>)> {
    let mut guard = shared.0.lock().unwrap();
    let active_id = guard.active_request_id.clone()?;
    let now = Instant::now();
    let reason = if guard.shutdown_requested || guard.shell_exited {
        WindowsRequestFinishReason::Shutdown
    } else if !guard.saw_begin {
        if guard.request_started_at.map_or(false, |started| now.duration_since(started) >= Duration::from_secs(1)) {
            WindowsRequestFinishReason::IncompleteCommand
        } else {
            return None;
        }
    } else if guard.saw_end && guard.completion_ready_at.map_or(false, |ready| now.duration_since(ready) >= Duration::from_millis(10)) {
        WindowsRequestFinishReason::Complete
    } else {
        return None;
    };

    let exit_code = guard.active_exit_code.unwrap_or(1);
    let stdout_file = guard.active_stdout.take();
    let stderr_file = guard.active_stderr.take();
    guard.active_request_id = None;
    guard.active_exit_code = None;
    guard.request_started_at = None;
    guard.saw_begin = false;
    guard.saw_end = false;
    guard.completion_ready_at = None;
    Some((active_id, reason, exit_code, stdout_file, stderr_file))
}

#[cfg(windows)]
fn windows_maybe_start_stop(shared: &Arc<(Mutex<WindowsSharedState>, Condvar)>, stop_path: &std::path::Path) -> Result<()> {
    if !stop_path.exists() {
        return Ok(());
    }
    let mut guard = shared.0.lock().unwrap();
    guard.shutdown_requested = true;
    shared.1.notify_all();
    Ok(())
}

#[cfg(windows)]
fn write_error_file(root: &Path, id: &str, message: &str) -> Result<()> {
    let path = root.join("shells").join(id).join("error.txt");
    std::fs::write(path, message.as_bytes())?;
    Ok(())
}
