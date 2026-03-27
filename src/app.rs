use crate::{
    acquire_lock, default_state_root, encode_exec_request, encode_stop_request, force_kill,
    is_alive, list_states, parse, print_error, print_no_shells, print_started, print_status_header,
    print_status_line, print_stopped, print_usage, prune_dead, read_frame_file, read_state,
    remove_shell, run_broker, shell_id, AppError, Command, ExecOptions, FrameKind, LockGuard,
    Result, ShellStatus, StartOptions, StopOptions,
};
use std::io::{self, Read, Write};
use std::process::{Command as PCommand, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc,
};
use std::thread;
use std::time::{Duration, Instant};

pub fn run_main() -> u8 {
    match run() {
        Ok(code) => code,
        Err(AppError::Exit(code)) => code,
        Err(err) => {
            print_error(&err.to_string());
            1
        }
    }
}

fn run() -> Result<u8> {
    let argv: Vec<String> = std::env::args().collect();
    let cli = parse(&argv)?;
    match cli.command {
        Command::Help => {
            print_usage(io::stdout())?;
            Ok(0)
        }
        Command::List => run_list(),
        Command::Status(opts) => run_status(opts.id),
        Command::Start(opts) => run_start(opts),
        Command::Exec(opts) => run_exec(opts),
        Command::Stop(opts) => run_stop(opts),
        Command::Broker(opts) => run_broker(opts),
    }
}

fn run_list() -> Result<u8> {
    let root = default_state_root()?;
    if !root.exists() {
        print_no_shells(io::stdout())?;
        return Ok(0);
    }
    prune_dead(&root)?;
    let records = list_states(&root)?;
    if records.is_empty() {
        print_no_shells(io::stdout())?;
        return Ok(0);
    }
    print_status_header(io::stdout())?;
    for record in records {
        print_status_line(
            io::stdout(),
            &record.id,
            status_name(&record.status),
            record.pid,
            record.broker_pid,
            &record.command_line,
        )?;
    }
    Ok(0)
}

fn run_status(id: Option<String>) -> Result<u8> {
    let root = default_state_root()?;
    if !root.exists() {
        if id.is_some() {
            print_error("shell not found");
            return Ok(1);
        }
        print_no_shells(io::stdout())?;
        return Ok(0);
    }
    prune_dead(&root)?;
    if let Some(id) = id {
        match read_state(&root, &id)? {
            Some(record) => {
                print_status_header(io::stdout())?;
                print_status_line(
                    io::stdout(),
                    &record.id,
                    status_name(&record.status),
                    record.pid,
                    record.broker_pid,
                    &record.command_line,
                )?;
                Ok(0)
            }
            None => {
                print_error("shell not found");
                Ok(1)
            }
        }
    } else {
        run_list()
    }
}

fn run_start(opts: StartOptions) -> Result<u8> {
    let root = crate::ensure_layout()?;
    let id = opts.id.unwrap_or_else(|| "main".to_string());
    shell_id::validate(&id).map_err(|m| AppError::Msg(m.to_string()))?;
    let _guard = acquire_lock(&root, &id, "start")?;
    if read_state(&root, &id)?.is_some() {
        print_error("shell id already exists");
        return Ok(1);
    }
    let ready_path = root.join("shells").join(&id).join("startup.fifo");
    let ready_listener = crate::ipc::create_fifo(&ready_path)?;
    let cwd = std::env::current_dir()?;
    let self_exe = std::env::current_exe()?;
    let mut cmd = PCommand::new(self_exe);
    cmd.arg("broker");
    cmd.arg("--root");
    cmd.arg(root.as_os_str());
    cmd.arg("--id");
    cmd.arg(&id);
    cmd.arg("--cwd");
    cmd.arg(cwd.as_os_str());
    cmd.arg("--");
    cmd.args(&opts.command);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());
    let mut broker = cmd.spawn()?;

    let deadline = Instant::now() + Duration::from_secs(30);
    let (tx, rx) = mpsc::channel::<std::result::Result<FrameKind, String>>();
    thread::spawn(move || {
        let mut file = match ready_listener.accept() {
            Ok(file) => file,
            Err(err) => {
                let _ = tx.send(Err(err.to_string()));
                return;
            }
        };
        loop {
            match read_frame_file(&mut file, 1024 * 1024) {
                Ok(Some(frame)) => {
                    let _ = tx.send(Ok(frame.kind));
                    return;
                }
                Ok(None) => {
                    let _ = tx.send(Err("shell start failed".to_string()));
                    return;
                }
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    return;
                }
            }
        }
    });

    loop {
        if let Ok(result) = rx.try_recv() {
            match result {
                Ok(FrameKind::Ready) => {
                    print_started(&id);
                    crate::ipc::remove_fifo(&ready_path);
                    return Ok(0);
                }
                Ok(FrameKind::Err) => {
                    print_error("shell start failed");
                    let _ = broker.kill();
                    crate::ipc::remove_fifo(&ready_path);
                    remove_shell(&root, &id)?;
                    return Ok(1);
                }
                Err(message) => {
                    print_error(&message);
                    let _ = broker.kill();
                    crate::ipc::remove_fifo(&ready_path);
                    remove_shell(&root, &id)?;
                    return Ok(1);
                }
                _ => {}
            }
        }
        if let Some(_) = broker.try_wait()? {
            print_error("shell start failed");
            crate::ipc::remove_fifo(&ready_path);
            remove_shell(&root, &id)?;
            return Ok(1);
        }
        if Instant::now() >= deadline {
            let _ = broker.kill();
            print_error("shell did not become ready before timeout");
            crate::ipc::remove_fifo(&ready_path);
            remove_shell(&root, &id)?;
            return Ok(1);
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn run_exec(opts: ExecOptions) -> Result<u8> {
    let root = default_state_root()?;
    if !root.exists() {
        print_error("shell not found");
        return Ok(1);
    }
    let _record = match read_state(&root, &opts.id)? {
        Some(record) => record,
        None => {
            print_error("shell not found");
            return Ok(1);
        }
    };
    let _guard = wait_for_lock(&root, &opts.id, "exec", opts.timeout_seconds)?;
    let command = match opts.command {
        Some(command) => command,
        None => {
            let mut buf = String::new();
            io::stdin().read_to_string(&mut buf)?;
            buf
        }
    };
    if command.trim().is_empty() {
        print_error("missing command");
        return Ok(1);
    }
    let reply_path = root
        .join("shells")
        .join(&opts.id)
        .join(format!("reply-{}.fifo", shell_id::generate()));
    let reply_listener = crate::ipc::create_fifo(&reply_path)?;
    reply_listener.set_nonblocking_accept(true)?;
    let control_path = root.join("shells").join(&opts.id).join("control.fifo");
    let request = crate::ExecRequest {
        reply_path: reply_path.to_string_lossy().into_owned(),
        timeout_ms: (opts.timeout_seconds * 1000).max(1),
        command,
    };
    let mut control = crate::ipc::open_fifo_read_write(&control_path)?;
    crate::send_frame_file(
        &mut control,
        FrameKind::Exec,
        &encode_exec_request(&request),
    )?;

    let (tx, rx) = mpsc::channel::<std::result::Result<crate::Frame, String>>();
    let reply_reader_shutdown = Arc::new(AtomicBool::new(false));
    let reply_reader_shutdown_clone = reply_reader_shutdown.clone();
    let reply_reader = thread::spawn(move || loop {
        if reply_reader_shutdown_clone.load(Ordering::Relaxed) {
            return;
        }
        let mut file = match reply_listener.accept() {
            Ok(file) => file,
            Err(AppError::Io(err)) if err.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(err) => {
                let _ = tx.send(Err(err.to_string()));
                return;
            }
        };
        loop {
            match read_frame_file(&mut file, 1024 * 1024) {
                Ok(Some(frame)) => {
                    let terminal = matches!(
                        frame.kind,
                        FrameKind::Complete | FrameKind::Err | FrameKind::Stopped
                    );
                    if tx.send(Ok(frame)).is_err() {
                        return;
                    }
                    if terminal {
                        return;
                    }
                }
                Err(AppError::Io(err)) if err.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(None) => break,
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    return;
                }
            }
        }
    });

    let result = (|| -> Result<u8> {
        let deadline = Instant::now() + Duration::from_secs(opts.timeout_seconds);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match rx.recv_timeout(remaining.min(Duration::from_millis(200))) {
                Ok(Ok(frame)) => match frame.kind {
                    FrameKind::Stdout => {
                        io::stdout().write_all(&frame.payload)?;
                    }
                    FrameKind::Stderr => {
                        io::stderr().write_all(&frame.payload)?;
                    }
                    FrameKind::Complete => {
                        let completion = crate::decode_completion(&frame.payload)?;
                        if completion.timed_out {
                            print_error("exec timed out");
                            return Ok(124);
                        }
                        return Ok(completion.exit_code.clamp(0, 255) as u8);
                    }
                    FrameKind::Err => {
                        print_error(std::str::from_utf8(&frame.payload).unwrap_or("shell stopped"));
                        return Ok(1);
                    }
                    _ => {}
                },
                Ok(Err(message)) => {
                    print_error(&message);
                    return Ok(1);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if Instant::now() >= deadline {
                        print_error("exec timed out");
                        return Ok(124);
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    print_error("shell stopped");
                    return Ok(1);
                }
            }
        }
    })();

    reply_reader_shutdown.store(true, Ordering::Relaxed);
    let _ = reply_reader.join();
    crate::ipc::remove_fifo(&reply_path);
    result
}

fn run_stop(opts: StopOptions) -> Result<u8> {
    let root = default_state_root()?;
    if !root.exists() {
        print_error("shell not found");
        return Ok(1);
    }
    let _record = match read_state(&root, &opts.id)? {
        Some(record) => record,
        None => {
            print_error("shell not found");
            return Ok(1);
        }
    };
    let _guard = match wait_for_lock(&root, &opts.id, "exec", 5) {
        Ok(guard) => guard,
        Err(AppError::Msg(message)) if message == "busy" => {
            return force_stop_busy_shell(&_record, &root, &opts.id);
        }
        Err(err) => return Err(err),
    };
    let result = (|| -> Result<u8> {
        let reply_path = root
            .join("shells")
            .join(&opts.id)
            .join(format!("reply-{}.fifo", shell_id::generate()));
        let reply_listener = crate::ipc::create_fifo(&reply_path)?;
        let request = crate::StopRequest {
            reply_path: reply_path.to_string_lossy().into_owned(),
        };
        let control_path = root.join("shells").join(&opts.id).join("control.fifo");
        let mut control = crate::ipc::open_fifo_read_write(&control_path)?;
        crate::send_frame_file(
            &mut control,
            FrameKind::Stop,
            &encode_stop_request(&request),
        )?;

        let (tx, rx) = mpsc::channel::<std::result::Result<crate::Frame, String>>();
        thread::spawn(move || loop {
            let mut file = match reply_listener.accept() {
                Ok(file) => file,
                Err(err) => {
                    let _ = tx.send(Err(err.to_string()));
                    return;
                }
            };
            loop {
                match read_frame_file(&mut file, 1024 * 1024) {
                    Ok(Some(frame)) => {
                        let terminal = matches!(frame.kind, FrameKind::Err | FrameKind::Stopped);
                        if tx.send(Ok(frame)).is_err() {
                            return;
                        }
                        if terminal {
                            return;
                        }
                    }
                    Ok(None) => break,
                    Err(err) => {
                        let _ = tx.send(Err(err.to_string()));
                        return;
                    }
                }
            }
        });

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match rx.recv_timeout(remaining.min(Duration::from_millis(200))) {
                Ok(Ok(frame)) => match frame.kind {
                    FrameKind::Err => {
                        let message =
                            std::str::from_utf8(&frame.payload).unwrap_or("shell stopped");
                        crate::ipc::remove_fifo(&reply_path);
                        if message == "shell stopped" || message == "shell not found" {
                            return Ok(0);
                        }
                        print_error(message);
                        return Ok(1);
                    }
                    FrameKind::Stopped => {
                        crate::ipc::remove_fifo(&reply_path);
                        return Ok(0);
                    }
                    _ => {}
                },
                Ok(Err(message)) => {
                    crate::ipc::remove_fifo(&reply_path);
                    return Err(AppError::Msg(message));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if Instant::now() >= deadline {
                        print_error("stop timed out");
                        crate::ipc::remove_fifo(&reply_path);
                        return Ok(124);
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    crate::ipc::remove_fifo(&reply_path);
                    return Ok(0);
                }
            }
        }
    })();

    match result {
        Ok(0) => {
            let _ = remove_shell(&root, &opts.id);
            print_stopped(&opts.id);
            Ok(0)
        }
        Ok(code) => Ok(code),
        Err(err) => Err(err),
    }
}

fn force_stop_busy_shell(
    record: &crate::ShellRecord,
    root: &std::path::Path,
    id: &str,
) -> Result<u8> {
    let shell_pid = record.pid;
    let broker_pid = record.broker_pid;

    if let Some(pid) = shell_pid {
        if is_alive(pid) {
            let _ = force_kill(pid);
        }
    }

    let deadline = Instant::now() + Duration::from_millis(750);
    while Instant::now() < deadline {
        let broker_alive = broker_pid.map_or(false, is_alive);
        let shell_alive = shell_pid.map_or(false, is_alive);
        if !broker_alive && !shell_alive {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    if let Some(pid) = broker_pid {
        if is_alive(pid) {
            let _ = force_kill(pid);
        }
    }

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let broker_alive = broker_pid.map_or(false, is_alive);
        let shell_alive = shell_pid.map_or(false, is_alive);
        if !broker_alive && !shell_alive {
            let _ = remove_shell(root, id);
            print_stopped(id);
            return Ok(0);
        }
        if Instant::now() >= deadline {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    if broker_pid.map_or(false, is_alive) || shell_pid.map_or(false, is_alive) {
        print_error("failed to stop shell");
        return Ok(1);
    }

    let _ = remove_shell(root, id);
    print_stopped(id);
    Ok(0)
}

fn wait_for_lock(
    root: &std::path::Path,
    id: &str,
    kind: &str,
    timeout_seconds: u64,
) -> Result<LockGuard> {
    let deadline = Instant::now() + Duration::from_secs(timeout_seconds);
    loop {
        match acquire_lock(root, id, kind) {
            Ok(guard) => return Ok(guard),
            Err(AppError::Msg(_)) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(err) => return Err(err),
        }
    }
}

fn status_name(status: &ShellStatus) -> &str {
    match status {
        ShellStatus::Starting | ShellStatus::Busy => "busy",
        ShellStatus::Ready => "ready",
    }
}
