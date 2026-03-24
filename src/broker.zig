const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const fs_atomic = @import("fs_atomic.zig");
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const state_dir = @import("state_dir.zig");

const completion_grace_ms: i64 = 100;
const command_begin_timeout_ms: i64 = 1000;

const PendingRequest = struct {
    stream: std.net.Stream,
    command: []u8,
};

const SharedState = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
    command_line: []const u8,
    cwd: []const u8,
    ready_socket: []const u8,
    shell_pid: u32,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(PendingRequest),
    active_stream: ?std.net.Stream = null,
    stop_stream: ?std.net.Stream = null,
    shell_ready: bool = false,
    shell_exited: bool = false,
    shutdown_requested: bool = false,
    saw_begin: bool = false,
    saw_end: bool = false,
    completion_ready_at_ms: ?i64 = null,
    request_started_at_ms: ?i64 = null,
    active_exit_code: ?i32 = null,
};

pub fn run(allocator: std.mem.Allocator, options: cli.BrokerOptions) !u8 {
    if (builtin.os.tag == .windows) return runWindows(allocator, options);

    const shell_dir = try state_dir.ensureShellDir(allocator, options.root, options.id);
    defer allocator.free(shell_dir);

    const control_path = try state_dir.ipcSocketPath(allocator, options.root, options.id, "control");
    defer allocator.free(control_path);
    var control_server = try ipc.bindUnixServer(control_path);
    errdefer control_server.deinit();

    const command = try resolveCommand(allocator, options.command);
    defer freeCommand(allocator, command);

    const command_line = try std.mem.join(allocator, " ", command);
    defer allocator.free(command_line);

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = null,
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    var child = std.process.Child.init(command, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        try notifyStartupError(options.ready_socket, @errorName(err));
        control_server.deinit();
        try cleanup(allocator, options.root, options.id);
        return 1;
    };

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    var stdin_file = child.stdin.?;
    child.stdin = null;
    const stdout_file = child.stdout.?;
    child.stdout = null;
    const stderr_file = child.stderr.?;
    child.stderr = null;

    var state = SharedState{
        .allocator = allocator,
        .root = options.root,
        .id = options.id,
        .command_line = command_line,
        .cwd = options.cwd,
        .ready_socket = options.ready_socket,
        .shell_pid = process.pidFromChildId(child.id),
        .queue = std.ArrayList(PendingRequest).init(allocator),
    };
    defer {
        for (state.queue.items) |request| {
            allocator.free(request.command);
            request.stream.close();
        }
        state.queue.deinit();
    }

    var stdout_thread = try std.Thread.spawn(.{}, pumpStdout, .{ &state, stdout_file });
    var stderr_thread = try std.Thread.spawn(.{}, pumpStderr, .{ &state, stderr_file });
    var accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{ &state, &control_server });

    const startup_ok = try waitForStartupReady(&state);
    if (!startup_ok) {
        try notifyStartupError(options.ready_socket, "shell start failed");
        try shutdownChildAndDrain(allocator, &state, &child, &stdin_file, true);
        control_server.deinit();
        accept_thread.join();
        stdout_thread.join();
        stderr_thread.join();
        try cleanup(allocator, options.root, options.id);
        return 1;
    }

    try notifyStartupReady(options.ready_socket);
    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .ready,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    while (true) {
        state.mutex.lock();
        if (state.shutdown_requested) {
            state.mutex.unlock();
            break;
        }
        if (state.shell_exited) {
            state.mutex.unlock();
            break;
        }
        if (state.active_stream == null and state.queue.items.len != 0) {
            const request = state.queue.orderedRemove(0);
            state.active_stream = request.stream;
            state.request_started_at_ms = std.time.milliTimestamp();
            state.saw_begin = false;
            state.saw_end = false;
            state.completion_ready_at_ms = null;
            state.active_exit_code = null;
            state.cond.broadcast();
            state.mutex.unlock();

            const exec_command = try protocol.buildExecCommand(allocator, request.command);
            defer allocator.free(exec_command);
            stdin_file.writeAll(exec_command) catch {
                allocator.free(request.command);
                state.mutex.lock();
                state.shutdown_requested = true;
                state.mutex.unlock();
                continue;
            };
            allocator.free(request.command);
            continue;
        }

        if (state.active_stream != null) {
            const now_ms = std.time.milliTimestamp();
            const finish_reason = requestFinishReason(&state, now_ms);
            if (finish_reason) |reason| {
                const active_stream = state.active_stream.?;
                const exit_code: i32 = state.active_exit_code orelse switch (reason) {
                    .complete => 0,
                    .incomplete_command => 1,
                    .shutdown => 1,
                };
                state.active_stream = null;
                state.request_started_at_ms = null;
                state.saw_begin = false;
                state.saw_end = false;
                state.completion_ready_at_ms = null;
                state.active_exit_code = null;
                state.cond.broadcast();
                state.mutex.unlock();
                finishRequest(allocator, active_stream, reason, exit_code) catch {};
                continue;
            }

            const timeout_ns = activeWaitTimeout(&state, now_ms);
            if (timeout_ns == 0) {
                state.mutex.unlock();
                continue;
            }
            state.cond.timedWait(&state.mutex, timeout_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
            state.mutex.unlock();
            continue;
        }

        state.cond.wait(&state.mutex);
        state.mutex.unlock();
    }

    try shutdownChildAndDrain(allocator, &state, &child, &stdin_file, false);
    control_server.deinit();
    accept_thread.join();
    stdout_thread.join();
    stderr_thread.join();
    try cleanup(allocator, options.root, options.id);
    return 0;
}

const RequestFinishReason = enum {
    complete,
    incomplete_command,
    shutdown,
};

fn waitForStartupReady(state: *SharedState) !bool {
    state.mutex.lock();
    defer state.mutex.unlock();
    while (!state.shell_ready and !state.shell_exited and !state.shutdown_requested) {
        state.cond.wait(&state.mutex);
    }
    return state.shell_ready;
}

fn notifyStartupReady(path: []const u8) !void {
    var stream = try ipc.connectUnixStream(path);
    defer stream.close();
    try ipc.sendFrame(&stream, .ready, &.{});
}

fn notifyStartupError(path: []const u8, message: []const u8) !void {
    var stream = ipc.connectUnixStream(path) catch return;
    defer stream.close();
        try ipc.sendFrame(&stream, .err, message);
}

fn acceptLoop(state: *SharedState, server: *std.net.Server) void {
    while (true) {
        const connection = server.accept() catch return;
        var stream = connection.stream;
        const frame = ipc.readFrame(state.allocator, &stream, 1024 * 1024) catch |err| switch (err) {
            error.EndOfStream => {
                stream.close();
                continue;
            },
            else => {
                stream.close();
                continue;
            },
        } orelse {
            stream.close();
            continue;
        };

        switch (frame.kind) {
            .exec => {
                if (frame.payload.len == 0) {
                    allocatorFreeFrame(state.allocator, frame);
                    stream.close();
                    continue;
                }
                state.mutex.lock();
                if (state.shutdown_requested) {
                    state.mutex.unlock();
                    allocatorFreeFrame(state.allocator, frame);
                    stream.close();
                    continue;
                }
                const command = state.allocator.dupe(u8, frame.payload) catch {
                    state.mutex.unlock();
                    allocatorFreeFrame(state.allocator, frame);
                    stream.close();
                    continue;
                };
                state.queue.append(.{ .stream = stream, .command = command }) catch {
                    state.allocator.free(command);
                    state.mutex.unlock();
                    allocatorFreeFrame(state.allocator, frame);
                    stream.close();
                    continue;
                };
                state.cond.broadcast();
                state.mutex.unlock();
            },
            .stop => {
                state.mutex.lock();
                state.shutdown_requested = true;
                if (state.stop_stream) |old| old.close();
                state.stop_stream = stream;
                state.cond.broadcast();
                state.mutex.unlock();
            },
            else => {
                stream.close();
            },
        }
        allocatorFreeFrame(state.allocator, frame);
    }
}

fn pumpStdout(state: *SharedState, file: std.fs.File) void {
    defer file.close();
    var pending = std.ArrayList(u8).init(state.allocator);
    defer pending.deinit();
    var parse_state = protocol.StdoutParseState{};
    var buffer: [2048]u8 = undefined;
    var ready_seen = false;

    while (true) {
        const bytes_read = file.read(&buffer) catch break;
        if (bytes_read == 0) break;

        if (!ready_seen) {
            pending.appendSlice(buffer[0..bytes_read]) catch break;
            if (protocol.chunkContainsReady(pending.items)) {
                state.mutex.lock();
                state.shell_ready = true;
                state.cond.broadcast();
                state.mutex.unlock();
                ready_seen = true;
                pending.clearRetainingCapacity();
            }
            continue;
        }

        const parsed = protocol.parseStdoutChunk(stdoutSink(state), buffer[0..bytes_read], &parse_state) catch break;
        applyParsedStdout(state, parsed);
    }

    state.mutex.lock();
    state.shell_exited = true;
    state.cond.broadcast();
    state.mutex.unlock();
}

fn pumpStderr(state: *SharedState, file: std.fs.File) void {
    defer file.close();
    var buffer: [2048]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buffer) catch break;
        if (bytes_read == 0) break;
        sendToActive(state, .stderr, buffer[0..bytes_read]);
    }
}

fn stdoutSink(state: *SharedState) StdoutSink {
    return .{ .state = state };
}

const StdoutSink = struct {
    state: *SharedState,

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        sendToActive(self.state, .stdout, bytes);
    }
};

fn sendToActive(state: *SharedState, kind: ipc.FrameKind, bytes: []const u8) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.active_stream) |stream| {
        var owned = stream;
        ipc.sendFrame(&owned, kind, bytes) catch {};
    }
}

fn applyParsedStdout(state: *SharedState, parsed: protocol.StdoutParse) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (parsed.began_request) {
        state.saw_begin = true;
        state.saw_end = false;
        state.completion_ready_at_ms = null;
        state.active_exit_code = null;
        state.cond.broadcast();
    }

    if (parsed.ended_request and state.saw_begin) {
        state.saw_end = true;
        state.active_exit_code = parsed.exit_code;
        state.cond.broadcast();
    }

    if (parsed.finished_prompt and state.saw_begin and state.saw_end) {
        state.completion_ready_at_ms = std.time.milliTimestamp();
        state.cond.broadcast();
    }
}

fn requestFinishReason(state: *SharedState, now_ms: i64) ?RequestFinishReason {
    if (state.shutdown_requested) return .shutdown;
    if (!state.saw_begin and state.request_started_at_ms != null and now_ms - state.request_started_at_ms.? >= command_begin_timeout_ms) {
        return .incomplete_command;
    }
    if (state.saw_end and state.completion_ready_at_ms != null and now_ms - state.completion_ready_at_ms.? >= completion_grace_ms) {
        return .complete;
    }
    if (state.shell_exited and state.active_stream != null) return .shutdown;
    return null;
}

fn activeWaitTimeout(state: *SharedState, now_ms: i64) u64 {
    if (!state.saw_begin and state.request_started_at_ms != null) {
        const remaining_ms = command_begin_timeout_ms - (now_ms - state.request_started_at_ms.?);
        if (remaining_ms > 0) return @intCast(remaining_ms * std.time.ns_per_ms);
        return 1;
    }
    if (state.saw_end and state.completion_ready_at_ms != null) {
        const remaining_ms = completion_grace_ms - (now_ms - state.completion_ready_at_ms.?);
        if (remaining_ms > 0) return @intCast(remaining_ms * std.time.ns_per_ms);
        return 1;
    }
    return 0;
}

fn finishRequest(allocator: std.mem.Allocator, stream: std.net.Stream, reason: RequestFinishReason, exit_code: i32) !void {
    var owned = stream;
    switch (reason) {
        .complete => {
            const completion_bytes = try ipc.encodeCompletion(allocator, .{ .exit_code = exit_code, .timed_out = false });
            defer allocator.free(completion_bytes);
            try ipc.sendFrame(&owned, .complete, completion_bytes);
        },
        .incomplete_command => {
            try ipc.sendFrame(&owned, .stderr, "error: incomplete command\n");
            const completion_bytes = try ipc.encodeCompletion(allocator, .{ .exit_code = 1, .timed_out = false });
            defer allocator.free(completion_bytes);
            try ipc.sendFrame(&owned, .complete, completion_bytes);
        },
        .shutdown => {
            try ipc.sendFrame(&owned, .stderr, "error: shell stopped\n");
            const completion_bytes = try ipc.encodeCompletion(allocator, .{ .exit_code = exit_code, .timed_out = false });
            defer allocator.free(completion_bytes);
            try ipc.sendFrame(&owned, .complete, completion_bytes);
        },
    }
    owned.close();
}

fn shutdownChildAndDrain(allocator: std.mem.Allocator, state: *SharedState, child: *std.process.Child, stdin_file: *std.fs.File, force: bool) !void {
    _ = force;
    state.mutex.lock();
    state.shutdown_requested = true;
    const active_stream = state.active_stream;
    state.active_stream = null;
    const active_exit_code = state.active_exit_code orelse 1;
    const queued = state.queue.toOwnedSlice() catch {
        state.mutex.unlock();
        return;
    };
    state.queue = std.ArrayList(PendingRequest).init(state.allocator);
    const stop_stream = state.stop_stream;
    state.stop_stream = null;
    state.mutex.unlock();

    stdin_file.close();
    if (!state.shell_exited) {
        if (!process.terminate(process.pidFromChildId(child.id))) _ = process.forceKill(process.pidFromChildId(child.id));
        _ = child.wait() catch {};
    } else {
        _ = child.wait() catch {};
    }

    if (active_stream) |stream| {
        finishRequest(allocator, stream, .shutdown, active_exit_code) catch {};
    }
    for (queued) |request| {
        finishRequest(allocator, request.stream, .shutdown, 1) catch {};
        allocator.free(request.command);
    }
    if (stop_stream) |stream| {
        var owned = stream;
        ipc.sendFrame(&owned, .stopped, &.{}) catch {};
        owned.close();
    }
    allocator.free(queued);
}

fn allocatorFreeFrame(allocator: std.mem.Allocator, frame: ipc.Frame) void {
    allocator.free(frame.payload);
}

fn resolveCommand(allocator: std.mem.Allocator, provided: []const []const u8) ![]const []const u8 {
    if (provided.len != 0) {
        const owned = try allocator.alloc([]const u8, provided.len);
        errdefer allocator.free(owned);
        var initialized: usize = 0;
        errdefer freeCommandItems(allocator, owned[0..initialized]);
        owned[0] = try process.resolveExecutable(allocator, provided[0]);
        initialized = 1;
        for (provided, 0..) |arg, index| {
            if (index == 0) continue;
            owned[index] = try allocator.dupe(u8, arg);
            initialized = index + 1;
        }
        return owned;
    }

    if (@import("builtin").os.tag == .windows) {
        const owned = try allocator.alloc([]const u8, 5);
        errdefer allocator.free(owned);
        var initialized: usize = 0;
        errdefer freeCommandItems(allocator, owned[0..initialized]);
        owned[0] = try process.resolveExecutable(allocator, "powershell.exe");
        initialized = 1;
        owned[1] = try allocator.dupe(u8, "-NoLogo");
        initialized = 2;
        owned[2] = try allocator.dupe(u8, "-NoExit");
        initialized = 3;
        owned[3] = try allocator.dupe(u8, "-Command");
        initialized = 4;
        owned[4] = try allocator.dupe(u8, "-");
        initialized = 5;
        return owned;
    }

    const owned = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(owned);
    var initialized: usize = 0;
    errdefer freeCommandItems(allocator, owned[0..initialized]);
    owned[0] = try process.resolveExecutable(allocator, "sh");
    initialized = 1;
    return owned;
}

fn freeCommand(allocator: std.mem.Allocator, command: []const []const u8) void {
    freeCommandItems(allocator, command);
    allocator.free(command);
}

fn freeCommandItems(allocator: std.mem.Allocator, command: []const []const u8) void {
    for (command) |arg| allocator.free(arg);
}

fn cleanup(allocator: std.mem.Allocator, root: []const u8, id: []const u8) !void {
    try registry.remove(allocator, root, id);
    try state_dir.deleteShellDir(allocator, root, id);
}

const WindowsRequestProgress = struct {
    shutdown: bool,
    request_started_at_ms: ?i64,
    saw_begin: bool,
    saw_end: bool,
    completion_ready_at_ms: ?i64,
};

const WindowsSharedState = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
    command_line: []const u8,
    cwd: []const u8,
    shell_pid: u32,
    mutex: std.Thread.Mutex = .{},
    active_request_id: ?[]const u8 = null,
    active_stdout: ?std.fs.File = null,
    active_stderr: ?std.fs.File = null,
    active_exit_code: ?i32 = null,
    saw_begin: bool = false,
    saw_end: bool = false,
    completion_ready_at_ms: ?i64 = null,
    request_started_at_ms: ?i64 = null,
    shutdown: bool = false,
};

fn runWindows(allocator: std.mem.Allocator, options: cli.BrokerOptions) !u8 {
    const shell_dir = try state_dir.ensureShellDir(allocator, options.root, options.id);
    defer allocator.free(shell_dir);

    const command = try resolveCommand(allocator, options.command);
    defer freeCommand(allocator, command);

    const command_line = try std.mem.join(allocator, " ", command);
    defer allocator.free(command_line);

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = null,
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    var child = std.process.Child.init(command, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        try writeErrorFile(allocator, options.root, options.id, @errorName(err));
        try cleanup(allocator, options.root, options.id);
        return 1;
    };

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    var stdin_file = child.stdin.?;
    child.stdin = null;
    var stdout_file = child.stdout.?;
    child.stdout = null;
    const stderr_file = child.stderr.?;
    child.stderr = null;

    if (!try windowsWaitForReady(allocator, &stdout_file)) {
        _ = process.forceKill(process.pidFromChildId(child.id));
        _ = child.wait() catch {};
        stdin_file.close();
        stderr_file.close();
        try writeErrorFile(allocator, options.root, options.id, "shell did not become ready before timeout");
        try cleanup(allocator, options.root, options.id);
        return 1;
    }

    var state = WindowsSharedState{
        .allocator = allocator,
        .root = options.root,
        .id = options.id,
        .command_line = command_line,
        .cwd = options.cwd,
        .shell_pid = process.pidFromChildId(child.id),
    };
    defer {
        if (state.active_request_id) |request_id| state.allocator.free(request_id);
        if (state.active_stdout) |file| file.close();
        if (state.active_stderr) |file| file.close();
    }

    var stdout_thread = try std.Thread.spawn(.{}, windowsPumpStdout, .{ &state, stdout_file });
    var stderr_thread = try std.Thread.spawn(.{}, windowsPumpStderr, .{ &state, stderr_file });
    defer stdin_file.close();

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .ready,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    const stop_path = try state_dir.shellFilePath(allocator, options.root, options.id, "stop.request");
    defer allocator.free(stop_path);

    while (true) {
        if (fileExists(stop_path)) {
            state.mutex.lock();
            state.shutdown = true;
            state.mutex.unlock();
            _ = process.terminate(process.pidFromChildId(child.id));
            if (!process.waitUntilDead(process.pidFromChildId(child.id), 1500)) _ = process.forceKill(process.pidFromChildId(child.id));
            _ = child.wait() catch {};
            break;
        }

        if (!process.isAlive(process.pidFromChildId(child.id))) {
            state.mutex.lock();
            state.shutdown = true;
            state.mutex.unlock();
            _ = child.wait() catch {};
            break;
        }

        try windowsMaybeStartRequest(allocator, &state, &stdin_file);
        try windowsMaybeFinalizeRequest(allocator, &state);
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    try windowsMaybeFinalizeRequest(allocator, &state);
    stdout_thread.join();
    stderr_thread.join();
    try cleanup(allocator, options.root, options.id);
    return 0;
}

fn windowsWaitForReady(allocator: std.mem.Allocator, stdout_file: *std.fs.File) !bool {
    var state = WindowsReadyWaitState{ .allocator = allocator };
    var thread = try std.Thread.spawn(.{}, windowsWaitForReadyReader, .{ &state, stdout_file });
    defer thread.join();

    const deadline = std.time.milliTimestamp() + 30000;
    while (std.time.milliTimestamp() < deadline) {
        state.mutex.lock();
        const done = state.done;
        const ready = state.ready;
        state.mutex.unlock();
        if (done) {
            if (!ready) stdout_file.close();
            return ready;
        }
        std.time.sleep(25 * std.time.ns_per_ms);
    }
    stdout_file.close();
    return false;
}

const WindowsReadyWaitState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    ready: bool = false,
};

fn windowsWaitForReadyReader(state: *WindowsReadyWaitState, stdout_file: *std.fs.File) void {
    var collected = std.ArrayList(u8).init(state.allocator);
    defer collected.deinit();

    var buffer: [512]u8 = undefined;
    while (true) {
        const bytes_read = stdout_file.read(&buffer) catch break;
        if (bytes_read == 0) break;
        collected.appendSlice(buffer[0..bytes_read]) catch break;
        if (protocol.chunkContainsReady(collected.items)) {
            state.mutex.lock();
            state.ready = true;
            state.done = true;
            state.mutex.unlock();
            return;
        }
    }

    state.mutex.lock();
    state.done = true;
    state.mutex.unlock();
}

fn windowsMaybeStartRequest(allocator: std.mem.Allocator, state: *WindowsSharedState, stdin_file: *std.fs.File) !void {
    state.mutex.lock();
    const busy = state.active_request_id != null;
    state.mutex.unlock();
    if (busy) return;

    const request_path = try state_dir.shellFilePath(allocator, state.root, state.id, "request.json");
    defer allocator.free(request_path);
    const request_bytes = readFileAllocAbsolute(allocator, request_path, 1024 * 256) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(request_bytes);
    const request = protocol.parseRequest(allocator, request_bytes) catch return;
    errdefer allocator.free(request.id);
    defer allocator.free(request.command);

    const exec_command = try protocol.buildExecCommand(allocator, request.command);
    defer allocator.free(exec_command);

    const stdout_path = try state_dir.shellFilePath(allocator, state.root, state.id, "stdout.log");
    defer allocator.free(stdout_path);
    const stderr_path = try state_dir.shellFilePath(allocator, state.root, state.id, "stderr.log");
    defer allocator.free(stderr_path);
    const completion_path = try state_dir.shellFilePath(allocator, state.root, state.id, "completion.json");
    defer allocator.free(completion_path);

    std.fs.deleteFileAbsolute(stdout_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    std.fs.deleteFileAbsolute(stderr_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    std.fs.deleteFileAbsolute(completion_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };

    const stdout_log = try std.fs.createFileAbsolute(stdout_path, .{ .truncate = true });
    errdefer stdout_log.close();
    const stderr_log = try std.fs.createFileAbsolute(stderr_path, .{ .truncate = true });
    errdefer stderr_log.close();

    try stdin_file.writeAll(exec_command);

    state.mutex.lock();
    defer state.mutex.unlock();
    state.active_request_id = @constCast(request.id);
    state.active_stdout = stdout_log;
    state.active_stderr = stderr_log;
    state.active_exit_code = null;
    state.saw_begin = false;
    state.saw_end = false;
    state.completion_ready_at_ms = null;
    state.request_started_at_ms = std.time.milliTimestamp();
    try registry.upsert(allocator, state.root, .{
        .id = state.id,
        .status = .busy,
        .pid = state.shell_pid,
        .broker_pid = process.currentPid(),
        .command_line = state.command_line,
        .cwd = state.cwd,
    });
}

fn windowsMaybeFinalizeRequest(allocator: std.mem.Allocator, state: *WindowsSharedState) !void {
    var request_id: ?[]const u8 = null;
    var stdout_log: ?std.fs.File = null;
    var stderr_log: ?std.fs.File = null;
    var exit_code: i32 = 1;
    var finish_reason: ?RequestFinishReason = null;

    state.mutex.lock();
    if (state.active_request_id) |active_id| {
        finish_reason = windowsRequestFinishReason(.{
            .shutdown = state.shutdown,
            .request_started_at_ms = state.request_started_at_ms,
            .saw_begin = state.saw_begin,
            .saw_end = state.saw_end,
            .completion_ready_at_ms = state.completion_ready_at_ms,
        }, std.time.milliTimestamp());
        if (finish_reason != null) {
            request_id = active_id;
            stdout_log = state.active_stdout;
            stderr_log = state.active_stderr;
            exit_code = state.active_exit_code orelse switch (finish_reason.?) {
                .shutdown => 1,
                .incomplete_command => 1,
                .complete => 1,
            };
            state.active_request_id = null;
            state.active_stdout = null;
            state.active_stderr = null;
            state.active_exit_code = null;
            state.saw_begin = false;
            state.saw_end = false;
            state.completion_ready_at_ms = null;
            state.request_started_at_ms = null;
        }
    }
    state.mutex.unlock();

    if (finish_reason == null) return;

    if (finish_reason.? == .incomplete_command) {
        if (stderr_log) |file| {
            try file.writer().writeAll("error: incomplete command\n");
        }
    } else if (finish_reason.? == .shutdown) {
        if (stderr_log) |file| {
            try file.writer().writeAll("error: shell stopped\n");
        }
    }
    if (stdout_log) |file| file.close();
    if (stderr_log) |file| file.close();

    const completion_path = try state_dir.shellFilePath(allocator, state.root, state.id, "completion.json");
    defer allocator.free(completion_path);
    const request_path = try state_dir.shellFilePath(allocator, state.root, state.id, "request.json");
    defer allocator.free(request_path);

    const completion = try protocol.stringifyCompletion(allocator, .{
        .id = request_id.?,
        .exit_code = exit_code,
        .timed_out = finish_reason.? == .shutdown and exit_code == 124,
    });
    defer allocator.free(completion);
    try fs_atomic.writeFileAbsolute(allocator, completion_path, completion);
    std.fs.deleteFileAbsolute(request_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    allocator.free(request_id.?);
    try registry.upsert(allocator, state.root, .{
        .id = state.id,
        .status = .ready,
        .pid = state.shell_pid,
        .broker_pid = process.currentPid(),
        .command_line = state.command_line,
        .cwd = state.cwd,
    });
}

fn windowsRequestFinishReason(progress: WindowsRequestProgress, now_ms: i64) ?RequestFinishReason {
    if (progress.shutdown) return .shutdown;
    if (!progress.saw_begin and progress.request_started_at_ms != null and now_ms - progress.request_started_at_ms.? >= command_begin_timeout_ms) {
        return .incomplete_command;
    }
    if (progress.saw_end and progress.completion_ready_at_ms != null and now_ms - progress.completion_ready_at_ms.? >= completion_grace_ms) {
        return .complete;
    }
    return null;
}

fn windowsPumpStdout(state: *WindowsSharedState, file: std.fs.File) void {
    defer file.close();
    var parse_state = protocol.StdoutParseState{};
    var buffer: [2048]u8 = undefined;

    while (true) {
        const bytes_read = file.read(&buffer) catch break;
        if (bytes_read == 0) break;

        const parsed = protocol.parseStdoutChunk(windowsStdoutSink(state), buffer[0..bytes_read], &parse_state) catch break;
        windowsApplyParsedStdout(state, parsed);
    }
}

fn windowsPumpStderr(state: *WindowsSharedState, file: std.fs.File) void {
    defer file.close();
    var buffer: [2048]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buffer) catch break;
        if (bytes_read == 0) break;
        windowsSendToActive(state, .stderr, buffer[0..bytes_read]);
    }
}

fn windowsStdoutSink(state: *WindowsSharedState) WindowsStdoutSink {
    return .{ .state = state };
}

const WindowsStdoutSink = struct {
    state: *WindowsSharedState,

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        windowsSendToActive(self.state, .stdout, bytes);
    }
};

fn windowsSendToActive(state: *WindowsSharedState, kind: ipc.FrameKind, bytes: []const u8) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    switch (kind) {
        .stdout => if (state.active_stdout) |stdout_file| {
            _ = stdout_file.writer().writeAll(bytes) catch {};
        },
        .stderr => if (state.active_stderr) |stderr_file| {
            _ = stderr_file.writer().writeAll(bytes) catch {};
        },
        else => {},
    }
}

fn windowsApplyParsedStdout(state: *WindowsSharedState, parsed: protocol.StdoutParse) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (parsed.began_request) {
        state.saw_begin = true;
        state.saw_end = false;
        state.completion_ready_at_ms = null;
        state.active_exit_code = null;
    }

    if (parsed.ended_request and state.saw_begin) {
        state.saw_end = true;
        state.active_exit_code = parsed.exit_code;
    }

    if (parsed.finished_prompt and state.saw_begin and state.saw_end) {
        state.completion_ready_at_ms = std.time.milliTimestamp();
    }
}

fn writeErrorFile(allocator: std.mem.Allocator, root: []const u8, id: []const u8, message: []const u8) !void {
    const path = try state_dir.shellFilePath(allocator, root, id, "error.txt");
    defer allocator.free(path);
    try fs_atomic.writeFileAbsolute(allocator, path, message);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

test "ready marker is prompt marker" {
    try std.testing.expect(protocol.chunkContainsReady(protocol.ready_marker));
}
