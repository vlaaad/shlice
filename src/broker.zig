const std = @import("std");
const cli = @import("cli.zig");
const fs_atomic = @import("fs_atomic.zig");
const process = @import("process.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const state_dir = @import("state_dir.zig");

const stop_file_name = "stop.request";
const error_file_name = "error.txt";
const request_file_name = "request.json";
const completion_file_name = "completion.json";
const stdout_file_name = "stdout.log";
const stderr_file_name = "stderr.log";
const completion_grace_ms: i64 = 100;

const SharedState = struct {
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
    completion_observed_at_ms: ?i64 = null,
    shutdown: bool = false,
};

pub fn run(allocator: std.mem.Allocator, options: cli.BrokerOptions) !u8 {
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
    var stderr_file = child.stderr.?;
    child.stderr = null;

    if (!try waitForReady(allocator, &stdout_file)) {
        _ = process.forceKill(process.pidFromChildId(child.id));
        _ = child.wait() catch {};
        stdin_file.close();
        stderr_file.close();
        try writeErrorFile(allocator, options.root, options.id, "shell did not become ready before timeout");
        try cleanup(allocator, options.root, options.id);
        return 1;
    }

    try registry.upsert(allocator, options.root, .{
        .id = options.id,
        .status = .ready,
        .pid = process.pidFromChildId(child.id),
        .broker_pid = process.currentPid(),
        .command_line = command_line,
        .cwd = options.cwd,
    });

    var shared = SharedState{
        .allocator = allocator,
        .root = options.root,
        .id = options.id,
        .command_line = command_line,
        .cwd = options.cwd,
        .shell_pid = process.pidFromChildId(child.id),
    };

    var stdout_thread = try std.Thread.spawn(.{}, pumpStdout, .{ &shared, stdout_file });
    var stderr_thread = try std.Thread.spawn(.{}, pumpStderr, .{ &shared, stderr_file });
    defer stdin_file.close();

    const stop_path = try state_dir.shellFilePath(allocator, options.root, options.id, stop_file_name);
    defer allocator.free(stop_path);

    while (true) {
        if (fileExists(stop_path)) {
            shared.mutex.lock();
            shared.shutdown = true;
            shared.mutex.unlock();
            _ = process.terminate(process.pidFromChildId(child.id));
            if (!process.waitUntilDead(process.pidFromChildId(child.id), 1500)) _ = process.forceKill(process.pidFromChildId(child.id));
            _ = child.wait() catch {};
            break;
        }

        if (!process.isAlive(process.pidFromChildId(child.id))) {
            shared.mutex.lock();
            shared.shutdown = true;
            shared.mutex.unlock();
            _ = child.wait() catch {};
            break;
        }

        try maybeStartRequest(allocator, &shared, &stdin_file);
        try maybeFinalizeRequest(allocator, &shared);
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    try maybeFinalizeRequest(allocator, &shared);
    stdout_thread.join();
    stderr_thread.join();
    try cleanup(allocator, options.root, options.id);
    return 0;
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

fn waitForReady(allocator: std.mem.Allocator, stdout_file: *std.fs.File) !bool {
    var state = ReadyWaitState{ .allocator = allocator };
    var thread = try std.Thread.spawn(.{}, waitForReadyReader, .{ &state, stdout_file });
    defer thread.join();

    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        state.mutex.lock();
        const done = state.done;
        const ready = state.ready;
        state.mutex.unlock();
        if (done) return ready;
        std.time.sleep(25 * std.time.ns_per_ms);
    }

    stdout_file.close();
    return false;
}

const ReadyWaitState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    ready: bool = false,
};

fn waitForReadyReader(state: *ReadyWaitState, stdout_file: *std.fs.File) void {
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

fn maybeStartRequest(allocator: std.mem.Allocator, shared: *SharedState, stdin_file: *std.fs.File) !void {
    var busy = false;
    shared.mutex.lock();
    busy = shared.active_request_id != null;
    shared.mutex.unlock();
    if (busy) return;

    const request_path = try state_dir.shellFilePath(allocator, shared.root, shared.id, request_file_name);
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

    const stdout_path = try state_dir.shellFilePath(allocator, shared.root, shared.id, stdout_file_name);
    defer allocator.free(stdout_path);
    const stderr_path = try state_dir.shellFilePath(allocator, shared.root, shared.id, stderr_file_name);
    defer allocator.free(stderr_path);
    const completion_path = try state_dir.shellFilePath(allocator, shared.root, shared.id, completion_file_name);
    defer allocator.free(completion_path);

    std.fs.deleteFileAbsolute(stdout_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    std.fs.deleteFileAbsolute(stderr_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    std.fs.deleteFileAbsolute(completion_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };

    const stdout_log = try std.fs.createFileAbsolute(stdout_path, .{ .truncate = true });
    errdefer stdout_log.close();
    const stderr_log = try std.fs.createFileAbsolute(stderr_path, .{ .truncate = true });
    errdefer stderr_log.close();

    try stdin_file.writeAll(exec_command);

    shared.mutex.lock();
    defer shared.mutex.unlock();
    shared.active_request_id = @constCast(request.id);
    shared.active_stdout = stdout_log;
    shared.active_stderr = stderr_log;
    shared.active_exit_code = null;
    shared.saw_begin = false;
    shared.saw_end = false;
    shared.completion_observed_at_ms = null;
    try registry.upsert(allocator, shared.root, .{
        .id = shared.id,
        .status = .busy,
        .pid = shared.shell_pid,
        .broker_pid = process.currentPid(),
        .command_line = shared.command_line,
        .cwd = shared.cwd,
    });
}

fn maybeFinalizeRequest(allocator: std.mem.Allocator, shared: *SharedState) !void {
    var request_id: ?[]const u8 = null;
    var stdout_log: ?std.fs.File = null;
    var stderr_log: ?std.fs.File = null;
    var exit_code: i32 = 1;
    var should_finish = false;
    var shutting_down = false;

    shared.mutex.lock();
    shutting_down = shared.shutdown;
    if (shared.active_request_id) |active_id| {
        const completion_ready = shared.saw_end and shared.completion_observed_at_ms != null and std.time.milliTimestamp() - shared.completion_observed_at_ms.? >= completion_grace_ms;
        if (completion_ready or shutting_down) {
            should_finish = true;
            request_id = active_id;
            stdout_log = shared.active_stdout;
            stderr_log = shared.active_stderr;
            exit_code = shared.active_exit_code orelse if (shutting_down) 124 else 1;
            shared.active_request_id = null;
            shared.active_stdout = null;
            shared.active_stderr = null;
            shared.active_exit_code = null;
            shared.saw_begin = false;
            shared.saw_end = false;
            shared.completion_observed_at_ms = null;
        }
    }
    shared.mutex.unlock();

    if (!should_finish) return;

    if (stdout_log) |file| file.close();
    if (stderr_log) |file| file.close();

    const completion_path = try state_dir.shellFilePath(allocator, shared.root, shared.id, completion_file_name);
    defer allocator.free(completion_path);
    const request_path = try state_dir.shellFilePath(allocator, shared.root, shared.id, request_file_name);
    defer allocator.free(request_path);

    const completion = try protocol.stringifyCompletion(allocator, .{
        .id = request_id.?,
        .exit_code = exit_code,
        .timed_out = shutting_down and exit_code == 124,
    });
    defer allocator.free(completion);
    try fs_atomic.writeFileAbsolute(allocator, completion_path, completion);
    std.fs.deleteFileAbsolute(request_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    allocator.free(request_id.?);
    try registry.upsert(allocator, shared.root, .{
        .id = shared.id,
        .status = .ready,
        .pid = shared.shell_pid,
        .broker_pid = process.currentPid(),
        .command_line = shared.command_line,
        .cwd = shared.cwd,
    });
}

fn pumpStdout(shared: *SharedState, file: std.fs.File) void {
    defer file.close();
    var pending = std.ArrayList(u8).init(shared.allocator);
    defer pending.deinit();
    var parse_state = protocol.StdoutParseState{};
    var buffer: [2048]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buffer) catch return;
        if (bytes_read == 0) {
            flushPendingStdout(shared, pending.items, &parse_state) catch {};
            return;
        }

        pending.appendSlice(buffer[0..bytes_read]) catch return;
        const parse_len = completedPrefixLen(pending.items);
        if (parse_len == 0) continue;

        shared.mutex.lock();
        const active_id = shared.active_request_id;
        const active_writer = shared.active_stdout;
        if (active_id != null and active_writer != null) {
            const parsed = protocol.parseStdoutChunk(active_writer.?.writer(), pending.items[0..parse_len], &parse_state) catch {
                shared.mutex.unlock();
                return;
            };
            if (parsed.began_request) {
                shared.saw_begin = true;
                shared.saw_end = false;
                shared.completion_observed_at_ms = null;
            }
            if (parsed.ended_request) {
                shared.saw_end = true;
                shared.completion_observed_at_ms = std.time.milliTimestamp();
            }
            if (parsed.exit_code) |exit_code| shared.active_exit_code = exit_code;
        }
        shared.mutex.unlock();
        trimFront(&pending, parse_len);
    }
}

fn pumpStderr(shared: *SharedState, file: std.fs.File) void {
    defer file.close();
    var buffer: [2048]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buffer) catch return;
        if (bytes_read == 0) return;

        shared.mutex.lock();
        if (shared.active_stderr) |stderr_file| {
            stderr_file.writeAll(buffer[0..bytes_read]) catch {
                shared.mutex.unlock();
                return;
            };
        }
        shared.mutex.unlock();
    }
}

fn writeErrorFile(allocator: std.mem.Allocator, root: []const u8, id: []const u8, message: []const u8) !void {
    const path = try state_dir.shellFilePath(allocator, root, id, error_file_name);
    defer allocator.free(path);
    try fs_atomic.writeFileAbsolute(allocator, path, message);
}

fn cleanup(allocator: std.mem.Allocator, root: []const u8, id: []const u8) !void {
    try registry.remove(allocator, root, id);
    try state_dir.deleteShellDir(allocator, root, id);
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

fn completedPrefixLen(bytes: []const u8) usize {
    const last_escape = std.mem.lastIndexOfScalar(u8, bytes, 0x1b) orelse return bytes.len;
    if (std.mem.indexOfScalarPos(u8, bytes, last_escape, 0x07) != null) return bytes.len;
    return last_escape;
}

fn trimFront(list: *std.ArrayList(u8), amount: usize) void {
    if (amount == 0) return;
    const remaining = list.items.len - amount;
    std.mem.copyForwards(u8, list.items[0..remaining], list.items[amount..]);
    list.shrinkRetainingCapacity(remaining);
}

fn flushPendingStdout(shared: *SharedState, bytes: []const u8, parse_state: *protocol.StdoutParseState) !void {
    if (bytes.len == 0) return;
    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (shared.active_stdout) |stdout_file| {
        _ = try protocol.parseStdoutChunk(stdout_file.writer(), bytes, parse_state);
    }
}

test "ready marker is prompt marker" {
    try std.testing.expect(protocol.chunkContainsReady(protocol.ready_marker));
}
