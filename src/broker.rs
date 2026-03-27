use crate::{
    build_exec_command, chunk_contains_ready, current_pid, encode_completion, force_kill,
    parse_exec_request, parse_stop_request, print_started, read_frame_file, remove_shell,
    send_frame_file, write_state, AppError, BrokerOptions, Completion, FrameKind, Result,
    ShellRecord, ShellStatus, StdoutParseState,
};
use std::collections::VecDeque;
use std::io::{Read, Write};
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
    timeout_ms: u64,
    command: Option<String>,
    stop: bool,
}

struct ActiveRequest {
    reply_path: String,
    reply: Option<Arc<Mutex<crate::ipc::IpcStream>>>,
    timeout_ms: u64,
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
            return Err(AppError::Msg(
                "shell did not become ready before timeout".to_string(),
            ));
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
        if let Some(active) = guard.active.as_mut() {
            if active.timeout_ms > 0
                && active.request_started.elapsed() >= Duration::from_millis(active.timeout_ms)
            {
                active.reply = None;
            }
        }
        if guard.active.is_none() {
            if let Some(request) = guard.queue.pop_front() {
                if request.stop {
                    guard.shutdown_requested = true;
                    let reply = Arc::new(Mutex::new(crate::ipc::open_fifo_read_write(Path::new(
                        &request.reply_path,
                    ))?));
                    guard.active = Some(ActiveRequest {
                        reply_path: request.reply_path,
                        reply: Some(reply),
                        timeout_ms: request.timeout_ms,
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
                let reply = if request.timeout_ms <= 1 {
                    None
                } else {
                    Some(Arc::new(Mutex::new(crate::ipc::open_fifo_read_write(
                        Path::new(&request.reply_path),
                    )?)))
                };
                guard.active = Some(ActiveRequest {
                    reply_path: request.reply_path,
                    reply,
                    timeout_ms: request.timeout_ms,
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
            finish_request(&active, reason, exit_code);
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
    TimedOut,
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
            .is_some_and(|t| t.elapsed() >= COMPLETION_GRACE)
    {
        return Some(FinishReason::Complete);
    }
    if !active.saw_begin
        && active.timeout_ms > 0
        && active.request_started.elapsed() >= Duration::from_millis(active.timeout_ms)
    {
        return Some(FinishReason::TimedOut);
    }
    if !active.saw_begin && active.request_started.elapsed() >= COMMAND_BEGIN_TIMEOUT {
        return Some(FinishReason::Incomplete);
    }
    None
}

fn finish_request(active: &ActiveRequest, reason: FinishReason, exit_code: i32) {
    match reason {
        FinishReason::Complete => {
            let payload = encode_completion(&Completion {
                exit_code,
                timed_out: false,
            });
            if let Some(reply) = &active.reply {
                if let Ok(mut reply) = reply.lock() {
                    let _ = send_frame_file(&mut *reply, FrameKind::Complete, &payload);
                }
            }
        }
        FinishReason::Incomplete => {
            if let Some(reply) = &active.reply {
                if let Ok(mut reply) = reply.lock() {
                    let _ = send_frame_file(
                        &mut *reply,
                        FrameKind::Stderr,
                        b"error: incomplete command\n",
                    );
                    let payload = encode_completion(&Completion {
                        exit_code: 1,
                        timed_out: false,
                    });
                    let _ = send_frame_file(&mut *reply, FrameKind::Complete, &payload);
                }
            }
        }
        FinishReason::TimedOut => {
            if let Some(reply) = &active.reply {
                if let Ok(mut reply) = reply.lock() {
                    let payload = encode_completion(&Completion {
                        exit_code: 1,
                        timed_out: true,
                    });
                    let _ = send_frame_file(&mut *reply, FrameKind::Complete, &payload);
                }
            }
        }
        FinishReason::Shutdown => {
            if let Some(reply) = &active.reply {
                if let Ok(mut reply) = reply.lock() {
                    let _ = send_frame_file(&mut *reply, FrameKind::Err, b"shell stopped");
                }
            }
        }
        FinishReason::Stopped => {
            if let Some(reply) = &active.reply {
                if let Ok(mut reply) = reply.lock() {
                    let _ = send_frame_file(&mut *reply, FrameKind::Stopped, b"");
                }
            }
        }
    }
    let _ = std::fs::remove_file(&active.reply_path);
}

fn spawn_control_loop(
    shared: Arc<(Mutex<SharedState>, Condvar)>,
    control_listener: crate::ipc::IpcListener,
) {
    thread::spawn(move || loop {
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
                        timeout_ms: request.timeout_ms,
                        command: Some(request.command),
                        stop: false,
                    });
                }
            }
            FrameKind::Stop => {
                if let Ok(request) = parse_stop_request(&frame.payload) {
                    guard.queue.push_back(PendingRequest {
                        reply_path: request.reply_path,
                        timeout_ms: 0,
                        command: None,
                        stop: true,
                    });
                }
            }
            _ => {}
        }
        shared.1.notify_all();
    });
}

fn spawn_stdout_loop(shared: Arc<(Mutex<SharedState>, Condvar)>, mut stdout: ChildStdout) {
    thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let mut ready_seen = false;
        let mut ready_pending = Vec::new();
        loop {
            let n = match stdout.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            let mut guard = shared.0.lock().unwrap();
            let mut reply = None;
            if !ready_seen {
                ready_pending.extend_from_slice(&buf[..n]);
                if chunk_contains_ready(&ready_pending) {
                    guard.shell_ready = true;
                    ready_seen = true;
                    ready_pending.clear();
                    shared.1.notify_all();
                } else {
                    let keep = crate::READY_MARKER.len().saturating_sub(1);
                    if ready_pending.len() > keep {
                        ready_pending.drain(..ready_pending.len() - keep);
                    }
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
                        reply = active.reply.clone();
                    }
                }
            }
            shared.1.notify_all();
            drop(guard);
            if let Some(reply) = reply {
                if let Ok(mut reply) = reply.lock() {
                    let _ = send_frame_file(&mut *reply, FrameKind::Stdout, &sink);
                }
            }
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
            let reply = guard
                .active
                .as_ref()
                .and_then(|active| active.reply.clone());
            drop(guard);
            if let Some(reply) = reply {
                if let Ok(mut reply) = reply.lock() {
                    let _ = send_frame_file(&mut *reply, FrameKind::Stderr, &buf[..n]);
                }
            }
        }
    });
}
