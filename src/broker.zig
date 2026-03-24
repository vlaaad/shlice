const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const fs_atomic = @import("fs_atomic.zig");
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const state_dir = @import("state_dir.zig");

const windows = std.os.windows;
const windows_create_no_window: windows.DWORD = 0x08000000;
const windows_detached_process: windows.DWORD = 0x00000008;
const windows_new_process_group: windows.DWORD = 0x00000200;
const windows_detached_creation_flags: windows.DWORD =
    windows.CREATE_UNICODE_ENVIRONMENT |
    windows_create_no_window |
    windows_detached_process |
    windows_new_process_group;

const completion_grace_ms: i64 = 10;
const command_begin_timeout_ms: i64 = 1000;

const PendingRequest = struct {
    reply_id: []u8,
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
    active_reply: ?std.fs.File = null,
    active_reply_id: ?[]u8 = null,
    stop_reply_id: ?[]u8 = null,
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

    const control_path = try state_dir.ipcSocketPath(allocator, options.root, options.id, "control.fifo");
    defer allocator.free(control_path);
    try ipc.createFifo(allocator, control_path);
    var control_file = try ipc.openFifoReadWrite(control_path);
    defer control_file.close();

    const command = resolveCommand(allocator, options.command) catch |err| {
        try notifyStartupError(options.ready_socket, @errorName(err));
        try cleanup(allocator, options.root, options.id);
        return 1;
    };
    defer freeCommand(allocator, command);

    const command_line = try std.mem.join(allocator, " ", command);
    defer allocator.free(command_line);

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = null,
        .broker_pid = process.currentPid(),
        .command_line = command_line,
    });

    var child = std.process.Child.init(command, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        try notifyStartupError(options.ready_socket, @errorName(err));
        try cleanup(allocator, options.root, options.id);
        return 1;
    };

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
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
            allocator.free(request.reply_id);
            allocator.free(request.command);
        }
        state.queue.deinit();
    }

    var stdout_thread = try std.Thread.spawn(.{}, pumpStdout, .{ &state, stdout_file });
    var stderr_thread = try std.Thread.spawn(.{}, pumpStderr, .{ &state, stderr_file });
    var control_thread = try std.Thread.spawn(.{}, controlLoop, .{ &state, &control_file });

    const startup_ok = try waitForStartupReady(&state);
    if (!startup_ok) {
        try notifyStartupError(options.ready_socket, "shell start failed");
        try shutdownChildAndDrain(allocator, &state, &child, &stdin_file, true);
        control_thread.join();
        stdout_thread.join();
        stderr_thread.join();
        try cleanup(allocator, options.root, options.id);
        return 1;
    }

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .ready,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
    });
    try notifyStartupReady(options.ready_socket);

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
        if (state.active_reply == null and state.queue.items.len != 0) {
            const request = state.queue.orderedRemove(0);
            const reply_path = requestReplyPath(allocator, state.root, state.id, request.reply_id) catch {
                allocator.free(request.reply_id);
                allocator.free(request.command);
                state.mutex.unlock();
                continue;
            };
            defer allocator.free(reply_path);
            state.active_reply = ipc.openFifoReadWrite(reply_path) catch {
                allocator.free(request.reply_id);
                allocator.free(request.command);
                state.mutex.unlock();
                continue;
            };
            state.active_reply_id = request.reply_id;
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
                state.mutex.lock();
                const reply = state.active_reply;
                state.active_reply = null;
                const reply_id = state.active_reply_id;
                state.active_reply_id = null;
                state.shutdown_requested = true;
                state.mutex.unlock();
                if (reply) |owned| owned.close();
                if (reply_id) |owned_id| allocator.free(owned_id);
                allocator.free(request.command);
                continue;
            };
            allocator.free(request.command);
            continue;
        }

        if (state.active_reply != null) {
            const now_ms = std.time.milliTimestamp();
            const finish_reason = requestFinishReason(&state, now_ms);
            if (finish_reason) |reason| {
                const active_reply = state.active_reply.?;
                const exit_code: i32 = state.active_exit_code orelse switch (reason) {
                    .complete => 0,
                    .incomplete_command => 1,
                    .shutdown => 1,
                };
                state.active_reply = null;
                const active_reply_id = state.active_reply_id;
                state.active_reply_id = null;
                state.request_started_at_ms = null;
                state.saw_begin = false;
                state.saw_end = false;
                state.completion_ready_at_ms = null;
                state.active_exit_code = null;
                state.cond.broadcast();
                state.mutex.unlock();
                if (active_reply_id) |reply_id| {
                    finishRequest(allocator, state.root, state.id, reply_id, active_reply, reason, exit_code) catch {};
                    allocator.free(reply_id);
                } else {
                    active_reply.close();
                }
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
    control_thread.join();
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
    var stream = try ipc.openFifoReadWrite(path);
    defer stream.close();
    try ipc.sendFrameFile(&stream, .ready, &.{});
}

fn notifyStartupError(path: []const u8, message: []const u8) !void {
    var stream = ipc.openFifoReadWrite(path) catch return;
    defer stream.close();
    try ipc.sendFrameFile(&stream, .err, message);
}

fn controlLoop(state: *SharedState, file: *std.fs.File) void {
    while (true) {
        const frame = ipc.readFrameFile(state.allocator, file, 1024 * 1024) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return,
        } orelse return;

        switch (frame.kind) {
            .exec => {
                if (frame.payload.len == 0) {
                    allocatorFreeFrame(state.allocator, frame);
                    continue;
                }
                const request = protocol.parseRequest(state.allocator, frame.payload) catch {
                    allocatorFreeFrame(state.allocator, frame);
                    continue;
                };
                errdefer state.allocator.free(request.id);
                defer state.allocator.free(request.command);
                state.mutex.lock();
                if (state.shutdown_requested) {
                    state.mutex.unlock();
                    state.allocator.free(request.id);
                    allocatorFreeFrame(state.allocator, frame);
                    continue;
                }
                const queued_command = state.allocator.dupe(u8, request.command) catch {
                    state.mutex.unlock();
                    state.allocator.free(request.id);
                    allocatorFreeFrame(state.allocator, frame);
                    continue;
                };
                state.queue.append(.{ .reply_id = request.id, .command = queued_command }) catch {
                    state.mutex.unlock();
                    state.allocator.free(request.id);
                    state.allocator.free(queued_command);
                    allocatorFreeFrame(state.allocator, frame);
                    continue;
                };
                state.cond.broadcast();
                state.mutex.unlock();
            },
            .stop => {
                const request = protocol.parseRequest(state.allocator, frame.payload) catch {
                    allocatorFreeFrame(state.allocator, frame);
                    continue;
                };
                state.mutex.lock();
                state.shutdown_requested = true;
                if (state.stop_reply_id) |old| state.allocator.free(old);
                state.stop_reply_id = request.id;
                state.cond.broadcast();
                state.mutex.unlock();
                state.allocator.free(request.command);
            },
            else => {},
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

    protocol.flushStdoutChunk(stdoutSink(state), &parse_state) catch {};

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
    if (state.active_reply) |reply| {
        var owned = reply;
        ipc.sendFrameFile(&owned, kind, bytes) catch {};
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
    if (state.shell_exited and state.active_reply != null) return .shutdown;
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

fn requestReplyPath(allocator: std.mem.Allocator, root: []const u8, id: []const u8, reply_id: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "reply-{s}.fifo", .{reply_id});
    defer allocator.free(filename);
    return state_dir.shellFilePath(allocator, root, id, filename);
}

fn finishRequestFrames(allocator: std.mem.Allocator, reply_file: *std.fs.File, reason: RequestFinishReason, exit_code: i32) !void {
    switch (reason) {
        .complete => {
            const completion_bytes = try ipc.encodeCompletion(allocator, .{ .exit_code = exit_code, .timed_out = false });
            defer allocator.free(completion_bytes);
            try ipc.sendFrameFile(reply_file, .complete, completion_bytes);
        },
        .incomplete_command => {
            try ipc.sendFrameFile(reply_file, .stderr, "error: incomplete command\n");
            const completion_bytes = try ipc.encodeCompletion(allocator, .{ .exit_code = 1, .timed_out = false });
            defer allocator.free(completion_bytes);
            try ipc.sendFrameFile(reply_file, .complete, completion_bytes);
        },
        .shutdown => {
            try ipc.sendFrameFile(reply_file, .stderr, "error: shell stopped\n");
            const completion_bytes = try ipc.encodeCompletion(allocator, .{ .exit_code = exit_code, .timed_out = false });
            defer allocator.free(completion_bytes);
            try ipc.sendFrameFile(reply_file, .complete, completion_bytes);
        },
    }
}

fn finishRequest(allocator: std.mem.Allocator, root: []const u8, id: []const u8, reply_id: []const u8, reply_file: std.fs.File, reason: RequestFinishReason, exit_code: i32) !void {
    var owned = reply_file;
    defer owned.close();
    const reply_path = try requestReplyPath(allocator, root, id, reply_id);
    defer allocator.free(reply_path);
    finishRequestFrames(allocator, &owned, reason, exit_code) catch {};
    std.fs.deleteFileAbsolute(reply_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn finishQueuedRequest(allocator: std.mem.Allocator, root: []const u8, id: []const u8, reply_id: []const u8, reason: RequestFinishReason, exit_code: i32) !void {
    const reply_path = requestReplyPath(allocator, root, id, reply_id) catch return;
    defer allocator.free(reply_path);

    var reply_file = ipc.openFifoReadWrite(reply_path) catch {
        std.fs.deleteFileAbsolute(reply_path) catch {};
        return;
    };
    defer reply_file.close();

    finishRequestFrames(allocator, &reply_file, reason, exit_code) catch {};
    std.fs.deleteFileAbsolute(reply_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn finishStoppedReply(allocator: std.mem.Allocator, root: []const u8, id: []const u8, reply_id: []const u8) !void {
    const reply_path = requestReplyPath(allocator, root, id, reply_id) catch return;
    defer allocator.free(reply_path);

    var reply_file = ipc.openFifoReadWrite(reply_path) catch {
        std.fs.deleteFileAbsolute(reply_path) catch {};
        return;
    };
    defer reply_file.close();

    ipc.sendFrameFile(&reply_file, .stopped, &.{}) catch {};
    std.fs.deleteFileAbsolute(reply_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn shutdownChildAndDrain(allocator: std.mem.Allocator, state: *SharedState, child: *std.process.Child, stdin_file: *std.fs.File, force: bool) !void {
    _ = force;
    state.mutex.lock();
    state.shutdown_requested = true;
    const active_reply = state.active_reply;
    state.active_reply = null;
    const active_reply_id = state.active_reply_id;
    state.active_reply_id = null;
    const active_exit_code = state.active_exit_code orelse 1;
    const queued = state.queue.toOwnedSlice() catch {
        state.mutex.unlock();
        return;
    };
    state.queue = std.ArrayList(PendingRequest).init(state.allocator);
    const stop_reply_id = state.stop_reply_id;
    state.stop_reply_id = null;
    state.mutex.unlock();

    stdin_file.close();
    if (!state.shell_exited) {
        if (!process.terminate(process.pidFromChildId(child.id))) _ = process.forceKill(process.pidFromChildId(child.id));
        _ = child.wait() catch {};
    } else {
        _ = child.wait() catch {};
    }

    if (active_reply) |reply| {
        if (active_reply_id) |reply_id| {
            finishRequest(allocator, state.root, state.id, reply_id, reply, .shutdown, active_exit_code) catch {};
            allocator.free(reply_id);
        } else {
            var owned = reply;
            owned.close();
        }
    }
    for (queued) |request| {
        finishQueuedRequest(allocator, state.root, state.id, request.reply_id, .shutdown, 1) catch {};
        allocator.free(request.reply_id);
        allocator.free(request.command);
    }
    if (stop_reply_id) |reply_id| {
        finishStoppedReply(allocator, state.root, state.id, reply_id) catch {};
        allocator.free(reply_id);
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
    active_request_id: ?[]u8 = null,
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

    const command = resolveCommand(allocator, options.command) catch |err| {
        try writeErrorFile(allocator, options.root, options.id, @errorName(err));
        try cleanup(allocator, options.root, options.id);
        return 1;
    };
    defer freeCommand(allocator, command);

    const command_line = try std.mem.join(allocator, " ", command);
    defer allocator.free(command_line);

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = null,
        .broker_pid = process.currentPid(),
        .command_line = command_line,
    });

    const spawn = spawnWindowsProcess(allocator, command, options.cwd, .pipe, windows_detached_creation_flags) catch |err| {
        try writeErrorFile(allocator, options.root, options.id, @errorName(err));
        try cleanup(allocator, options.root, options.id);
        return 1;
    };
    var stdin_file = spawn.stdin_file.?;
    var stdout_file = spawn.stdout_file.?;
    const stderr_file = spawn.stderr_file.?;

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .busy,
        .pid = spawn.pid,
        .broker_pid = process.currentPid(),
        .command_line = command_line,
    });

    if (!try windowsWaitForReady(allocator, &stdout_file)) {
        _ = process.forceKill(spawn.pid);
        stdin_file.close();
        stdout_file.close();
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
        .shell_pid = spawn.pid,
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
        .pid = spawn.pid,
        .broker_pid = process.currentPid(),
        .command_line = command_line,
    });

    const stop_path = try state_dir.shellFilePath(allocator, options.root, options.id, "stop.request");
    defer allocator.free(stop_path);

    while (true) {
        if (fileExists(stop_path)) {
            state.mutex.lock();
            state.shutdown = true;
            state.mutex.unlock();
            _ = process.terminate(spawn.pid);
            if (!process.waitUntilDead(spawn.pid, 1500)) _ = process.forceKill(spawn.pid);
            break;
        }

        if (!process.isAlive(spawn.pid)) {
            state.mutex.lock();
            state.shutdown = true;
            state.mutex.unlock();
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

const WindowsLaunchCommand = struct {
    application_name: [:0]u16,
    command_line: [:0]u16,
};

const WindowsSpawnMode = enum { ignore, pipe };

const WindowsSpawnResult = struct {
    pid: u32,
    stdin_file: ?std.fs.File = null,
    stdout_file: ?std.fs.File = null,
    stderr_file: ?std.fs.File = null,
};

fn spawnWindowsProcess(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, mode: WindowsSpawnMode, creation_flags: windows.DWORD) !WindowsSpawnResult {
    if (argv.len == 0) return error.InvalidArguments;

    var sa = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = windows.TRUE,
        .lpSecurityDescriptor = null,
    };

    var nul_handle: ?windows.HANDLE = null;
    if (mode == .ignore) {
        nul_handle = try openWindowsNullHandle(&sa);
    }
    defer if (nul_handle) |handle| std.posix.close(handle);

    var child_stdin: ?windows.HANDLE = null;
    var parent_stdin: ?windows.HANDLE = null;
    var child_stdout: ?windows.HANDLE = null;
    var parent_stdout: ?windows.HANDLE = null;
    var child_stderr: ?windows.HANDLE = null;
    var parent_stderr: ?windows.HANDLE = null;

    switch (mode) {
        .ignore => {
            child_stdin = nul_handle;
            child_stdout = nul_handle;
            child_stderr = nul_handle;
        },
        .pipe => {
            try windowsMakePipe(&child_stdin, &parent_stdin, &sa, true);
            try windowsMakePipe(&child_stdout, &parent_stdout, &sa, false);
            try windowsMakePipe(&child_stderr, &parent_stderr, &sa, false);
        },
    }
    errdefer {
        if (mode == .pipe) {
            if (child_stdin) |handle| std.posix.close(handle);
            if (parent_stdin) |handle| std.posix.close(handle);
            if (child_stdout) |handle| std.posix.close(handle);
            if (parent_stdout) |handle| std.posix.close(handle);
            if (child_stderr) |handle| std.posix.close(handle);
            if (parent_stderr) |handle| std.posix.close(handle);
        }
    }

    var startup = windows.STARTUPINFOW{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .hStdInput = child_stdin,
        .hStdOutput = child_stdout,
        .hStdError = child_stderr,
        .dwFlags = windows.STARTF_USESTDHANDLES,
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
    };
    var process_info: windows.PROCESS_INFORMATION = undefined;

    const launch = try buildWindowsLaunchCommand(allocator, argv);
    defer allocator.free(launch.application_name);
    defer allocator.free(launch.command_line);

    const cwd_w = if (cwd) |value| try std.unicode.wtf8ToWtf16LeAllocZ(allocator, value) else null;
    defer if (cwd_w) |value| allocator.free(value);

    try windows.CreateProcessW(
        launch.application_name.ptr,
        launch.command_line.ptr,
        null,
        null,
        windows.TRUE,
        creation_flags,
        null,
        if (cwd_w) |value| value.ptr else null,
        &startup,
        &process_info,
    );
    if (mode == .pipe) {
        if (child_stdin) |handle| std.posix.close(handle);
        if (child_stdout) |handle| std.posix.close(handle);
        if (child_stderr) |handle| std.posix.close(handle);
    }
    defer std.posix.close(process_info.hProcess);
    defer std.posix.close(process_info.hThread);

    return .{
        .pid = process.pidFromChildId(process_info.hProcess),
        .stdin_file = if (parent_stdin) |handle| .{ .handle = handle } else null,
        .stdout_file = if (parent_stdout) |handle| .{ .handle = handle } else null,
        .stderr_file = if (parent_stderr) |handle| .{ .handle = handle } else null,
    };
}

fn buildWindowsLaunchCommand(allocator: std.mem.Allocator, argv: []const []const u8) !WindowsLaunchCommand {
    const app_path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, argv[0]);
    errdefer allocator.free(app_path);

    const ext = std.fs.path.extension(argv[0]);
    if (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd")) {
        const application_name = try windowsCmdExePath(allocator);
        errdefer allocator.free(application_name);
        const command_line = try argvToScriptCommandLineWindows(allocator, app_path, argv[1..]);
        return .{ .application_name = application_name, .command_line = command_line };
    }

    const command_line = try argvToCommandLineWindows(allocator, argv);
    return .{ .application_name = app_path, .command_line = command_line };
}

fn openWindowsNullHandle(sa: *windows.SECURITY_ATTRIBUTES) !windows.HANDLE {
    const nul_path = &[_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' };
    return windows.OpenFile(nul_path, .{
        .access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE | windows.SYNCHRONIZE,
        .share_access = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        .sa = sa,
        .creation = windows.OPEN_EXISTING,
    }) catch |err| switch (err) {
        else => return err,
    };
}

fn windowsMakePipe(child_end: *?windows.HANDLE, parent_end: *?windows.HANDLE, sa: *const windows.SECURITY_ATTRIBUTES, child_gets_read_end: bool) !void {
    var read_handle: windows.HANDLE = undefined;
    var write_handle: windows.HANDLE = undefined;
    try windows.CreatePipe(&read_handle, &write_handle, sa);

    const child_handle = if (child_gets_read_end) read_handle else write_handle;
    const parent_handle = if (child_gets_read_end) write_handle else read_handle;
    try windows.SetHandleInformation(parent_handle, windows.HANDLE_FLAG_INHERIT, 0);
    child_end.* = child_handle;
    parent_end.* = parent_handle;
}

fn windowsCmdExePath(allocator: std.mem.Allocator) ![:0]u16 {
    var buf = try std.ArrayListUnmanaged(u16).initCapacity(allocator, 128);
    errdefer buf.deinit(allocator);
    while (true) {
        const unused_slice = buf.unusedCapacitySlice();
        const len = windows.kernel32.GetSystemDirectoryW(@ptrCast(unused_slice), @intCast(unused_slice.len));
        if (len == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (len > unused_slice.len) {
            try buf.ensureUnusedCapacity(allocator, len);
        } else {
            buf.items.len = len;
            break;
        }
    }
    switch (buf.items[buf.items.len - 1]) {
        '/', '\\' => {},
        else => try buf.append(allocator, std.fs.path.sep),
    }
    try buf.appendSlice(allocator, std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe"));
    return try buf.toOwnedSliceSentinel(allocator, 0);
}

fn argvToCommandLineWindows(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    if (argv.len != 0) {
        const arg0 = argv[0];
        var needs_quotes = arg0.len == 0;
        for (arg0) |c| {
            if (c <= ' ') needs_quotes = true;
            if (c == '"') return error.InvalidArguments;
        }
        if (needs_quotes) {
            try buf.append('"');
            try buf.appendSlice(arg0);
            try buf.append('"');
        } else {
            try buf.appendSlice(arg0);
        }

        for (argv[1..]) |arg| {
            try buf.append(' ');
            needs_quotes = for (arg) |c| {
                if (c <= ' ' or c == '"') break true;
            } else arg.len == 0;
            if (!needs_quotes) {
                try buf.appendSlice(arg);
                continue;
            }
            try buf.append('"');
            var backslash_count: usize = 0;
            for (arg) |byte| {
                switch (byte) {
                    '\\' => backslash_count += 1,
                    '"' => {
                        try buf.appendNTimes('\\', backslash_count * 2 + 1);
                        try buf.append('"');
                        backslash_count = 0;
                    },
                    else => {
                        try buf.appendNTimes('\\', backslash_count);
                        try buf.append(byte);
                        backslash_count = 0;
                    },
                }
            }
            try buf.appendNTimes('\\', backslash_count * 2);
            try buf.append('"');
        }
    }

    return try std.unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}

fn argvToScriptCommandLineWindows(allocator: std.mem.Allocator, script_path: []const u16, script_args: []const []const u8) ![:0]u16 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer buf.deinit();

    buf.appendSliceAssumeCapacity("cmd.exe /d /e:ON /v:OFF /c \"");
    buf.appendAssumeCapacity('"');
    if (std.mem.indexOfAny(u16, script_path, &[_]u16{ '\\', '/' }) == null) {
        try buf.appendSlice(".\\");
    }
    try std.unicode.wtf16LeToWtf8ArrayList(&buf, script_path);
    buf.appendAssumeCapacity('"');

    for (script_args) |arg| {
        if (std.mem.indexOfAny(u8, arg, "\x00\r\n") != null) return error.InvalidArguments;
        try buf.append(' ');
        var needs_quotes = arg.len == 0 or arg[arg.len - 1] == '\\';
        if (!needs_quotes) {
            for (arg) |c| {
                switch (c) {
                    'A'...'Z', 'a'...'z', '0'...'9', '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_' => {},
                    else => {
                        needs_quotes = true;
                        break;
                    },
                }
            }
        }
        if (needs_quotes) try buf.append('"');
        var backslashes: usize = 0;
        for (arg) |c| {
            switch (c) {
                '\\' => backslashes += 1,
                '"' => {
                    try buf.appendNTimes('\\', backslashes);
                    try buf.append('"');
                    backslashes = 0;
                },
                '%' => {
                    try buf.appendSlice("%%cd:~,");
                    backslashes = 0;
                },
                else => backslashes = 0,
            }
            try buf.append(c);
        }
        if (needs_quotes) {
            try buf.appendNTimes('\\', backslashes);
            try buf.append('"');
        }
    }

    try buf.append('"');
    return try std.unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
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
    state.active_request_id = request.id;
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
    });
}

fn windowsMaybeFinalizeRequest(allocator: std.mem.Allocator, state: *WindowsSharedState) !void {
    var request_id: ?[]u8 = null;
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

    protocol.flushStdoutChunk(windowsStdoutSink(state), &parse_state) catch {};
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
