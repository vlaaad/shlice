const std = @import("std");
const broker = @import("broker.zig");
const cli = @import("cli.zig");
const locks = @import("locks.zig");
const output = @import("output.zig");
const process = @import("process.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const shell_id = @import("shell_id.zig");
const state_dir = @import("state_dir.zig");

pub fn run(allocator: std.mem.Allocator) !u8 {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = cli.parse(allocator, argv) catch |err| {
        switch (err) {
            error.ShowHelp => {
                try output.printUsage(std.io.getStdOut().writer());
                return 0;
            },
            error.UnknownCommand => {
                try output.printError("unknown command");
            },
            error.InvalidArguments => {
                try output.printError("invalid arguments");
            },
            error.MissingShellId => {
                try output.printError("missing required --id");
            },
            error.MissingValue => {
                try output.printError("missing flag value");
            },
            error.InvalidShellId, error.EmptyShellId => {
                try output.printError("invalid shell id");
            },
            else => return err,
        }
        try output.printUsage(std.io.getStdErr().writer());
        return 1;
    };

    switch (parsed) {
        .help => try output.printUsage(std.io.getStdOut().writer()),
        .list => try runList(allocator),
        .status => |opts| return try runStatus(allocator, opts.id),
        .start => |opts| return try runStart(allocator, opts),
        .exec => |opts| return try runExec(allocator, opts),
        .stop => |opts| return try runStop(allocator, opts.id),
        .broker => |opts| return try broker.run(allocator, opts),
    }
    return 0;
}

fn runList(allocator: std.mem.Allocator) !void {
    const root = try state_dir.ensureLayout(allocator);
    defer allocator.free(root);
    try registry.revalidateAndPrune(allocator, root);

    const records = try registry.listAll(allocator, root);
    defer registry.freeRecords(allocator, records);

    const stdout = std.io.getStdOut().writer();
    if (records.len == 0) {
        try output.printNoShells(stdout);
        return;
    }
    try output.printStatusHeader(stdout);
    for (records) |record| {
        try output.printStatusLine(stdout, record.id, @tagName(record.status), record.pid, record.broker_pid, record.command_line, record.cwd);
    }
}

fn runStatus(allocator: std.mem.Allocator, id: ?[]const u8) !u8 {
    const root = try state_dir.ensureLayout(allocator);
    defer allocator.free(root);
    try registry.revalidateAndPrune(allocator, root);

    if (id) |shell| {
        const maybe_record = try registry.readOne(allocator, root, shell);
        if (maybe_record) |record| {
            defer registry.freeRecord(allocator, record);
            const stdout = std.io.getStdOut().writer();
            try output.printStatusHeader(stdout);
            try output.printStatusLine(stdout, record.id, @tagName(record.status), record.pid, record.broker_pid, record.command_line, record.cwd);
            return 0;
        }
        try output.printError("shell not found");
        return 1;
    }

    try runList(allocator);
    return 0;
}

fn runStart(allocator: std.mem.Allocator, options: cli.StartOptions) !u8 {
    const root = try state_dir.ensureLayout(allocator);
    defer allocator.free(root);

    const id = if (options.id) |provided| try allocator.dupe(u8, provided) else try allocateFreshId(allocator, root);
    defer allocator.free(id);

    const shell_dir = try state_dir.ensureShellDir(allocator, root, id);
    defer allocator.free(shell_dir);

    const lock_result = try locks.acquire(allocator, shell_dir, .start);
    if (lock_result == .busy) {
        try output.printError("shell start is already in progress");
        return 1;
    }
    defer locks.release(allocator, shell_dir, .start) catch {};

    try registry.revalidateAndPrune(allocator, root);
    if (try registry.readOne(allocator, root, id)) |record| {
        defer registry.freeRecord(allocator, record);
        try output.printError("shell id already exists");
        return 1;
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    try spawnBroker(allocator, root, id, cwd, options.command);
    if (!try waitForShellReady(allocator, root, id)) {
        if (try registry.readOne(allocator, root, id)) |record| {
            defer registry.freeRecord(allocator, record);
            if (record.broker_pid) |broker_pid| _ = process.forceKill(broker_pid);
        }
        const startup_error = try readStartupErrorOrDefault(allocator, root, id);
        defer if (!std.mem.eql(u8, startup_error, "shell start failed")) allocator.free(startup_error);
        try cleanupShellState(allocator, root, id);
        try output.printError(startup_error);
        return 1;
    }

    try output.printStarted(id);
    return 0;
}

fn runStop(allocator: std.mem.Allocator, id: []const u8) !u8 {
    const root = try state_dir.ensureLayout(allocator);
    defer allocator.free(root);

    try registry.revalidateAndPrune(allocator, root);
    const maybe_record = try registry.readOne(allocator, root, id);
    if (maybe_record == null) {
        try output.printError("shell not found");
        return 1;
    }
    const record = maybe_record.?;
    defer registry.freeRecord(allocator, record);

    const stop_path = try state_dir.shellFilePath(allocator, root, id, "stop.request");
    defer allocator.free(stop_path);
    const stop_file = try std.fs.createFileAbsolute(stop_path, .{ .truncate = true });
    stop_file.close();

    if (record.broker_pid) |broker_pid| {
        if (!waitForShellShutdown(allocator, root, id, broker_pid, record.pid)) {
            _ = process.forceKill(broker_pid);
            if (record.pid) |shell_pid| _ = process.forceKill(shell_pid);
            try cleanupShellState(allocator, root, id);
        }
    } else {
        if (record.pid) |shell_pid| _ = process.forceKill(shell_pid);
        try cleanupShellState(allocator, root, id);
    }

    try output.printStopped(id);
    return 0;
}

fn runExec(allocator: std.mem.Allocator, options: cli.ExecOptions) !u8 {
    const root = try state_dir.ensureLayout(allocator);
    defer allocator.free(root);
    try registry.revalidateAndPrune(allocator, root);

    const maybe_record = try registry.readOne(allocator, root, options.id);
    if (maybe_record == null) {
        try output.printError("shell not found");
        return 1;
    }
    const record = maybe_record.?;
    defer registry.freeRecord(allocator, record);

    const shell_dir = try state_dir.ensureShellDir(allocator, root, options.id);
    defer allocator.free(shell_dir);

    const request_path = try state_dir.shellFilePath(allocator, root, options.id, "request.json");
    defer allocator.free(request_path);
    const completion_path = try state_dir.shellFilePath(allocator, root, options.id, "completion.json");
    defer allocator.free(completion_path);
    const stdout_path = try state_dir.shellFilePath(allocator, root, options.id, "stdout.log");
    defer allocator.free(stdout_path);
    const stderr_path = try state_dir.shellFilePath(allocator, root, options.id, "stderr.log");
    defer allocator.free(stderr_path);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(options.timeout_seconds)) * 1000;
    while (true) {
        const lock_result = try locks.acquire(allocator, shell_dir, .exec);
        if (lock_result != .busy) break;
        if (std.time.milliTimestamp() >= deadline) {
            try output.printError("exec timed out waiting for shell");
            return 124;
        }
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    defer locks.release(allocator, shell_dir, .exec) catch {};

    while (true) {
        const current_record = try registry.readOne(allocator, root, options.id);
        if (current_record == null) {
            try output.printError("shell not found");
            return 1;
        }
        const current = current_record.?;
        if (current.status == .ready) {
            registry.freeRecord(allocator, current);
            break;
        }
        registry.freeRecord(allocator, current);
        if (std.time.milliTimestamp() >= deadline) {
            try output.printError("exec timed out waiting for shell");
            return 124;
        }
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    const command = if (options.command) |value| try allocator.dupe(u8, value) else try readCommandFromStdin(allocator);
    defer allocator.free(command);
    if (command.len == 0) {
        try output.printError("missing command");
        return 1;
    }

    const request_id = try shell_id.generate(allocator);
    defer allocator.free(request_id);

    try cleanupExecArtifacts(stdout_path, stderr_path, completion_path);

    const request_body = try protocol.stringifyRequest(allocator, .{ .id = request_id, .command = command });
    defer allocator.free(request_body);
    try writeFileAtomicAbsolute(allocator, request_path, request_body);

    var stdout_offset: u64 = 0;
    var stderr_offset: u64 = 0;
    var completion_seen = false;
    while (!completion_seen) {
        try streamNewBytes(stdout_path, &stdout_offset, std.io.getStdOut().writer());
        try streamNewBytes(stderr_path, &stderr_offset, std.io.getStdErr().writer());

        const completion_bytes = readFileAllocAbsolute(allocator, completion_path, 1024 * 32) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (completion_bytes) |bytes| {
            defer allocator.free(bytes);
            const completion = protocol.parseCompletion(allocator, bytes) catch {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            defer {
                allocator.free(completion.id);
            }
            if (std.mem.eql(u8, completion.id, request_id)) {
                completion_seen = true;
                try streamNewBytes(stdout_path, &stdout_offset, std.io.getStdOut().writer());
                try streamNewBytes(stderr_path, &stderr_offset, std.io.getStdErr().writer());
                std.fs.deleteFileAbsolute(request_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
                if (completion.timed_out) {
                    try cleanupExecArtifacts(stdout_path, stderr_path, completion_path);
                    try output.printError("exec timed out");
                    return 124;
                }
                try cleanupExecArtifacts(stdout_path, stderr_path, completion_path);
                return @intCast(@min(@max(completion.exit_code, 0), 255));
            }
        }

        if (std.time.milliTimestamp() >= deadline) {
            try output.printError("exec timed out");
            return 124;
        }
        std.time.sleep(25 * std.time.ns_per_ms);
    }
    return 0;
}

fn allocateFreshId(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    while (true) {
        const id = try shell_id.generate(allocator);
        errdefer allocator.free(id);
        if (try registry.readOne(allocator, root, id)) |record| {
            registry.freeRecord(allocator, record);
            allocator.free(id);
            continue;
        }
        return id;
    }
}

fn spawnBroker(allocator: std.mem.Allocator, root: []const u8, id: []const u8, cwd: []const u8, command: []const []const u8) !void {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    const args_len: usize = 8;
    const args = try allocator.alloc([]const u8, args_len);
    defer allocator.free(args);

    args[0] = self_path;
    args[1] = "__broker";
    args[2] = "--root";
    args[3] = root;
    args[4] = "--id";
    args[5] = id;
    args[6] = "--cwd";
    args[7] = cwd;
    if (command.len != 0) {
        const separator_index = 8;
        const extended = try allocator.alloc([]const u8, args_len + 1 + command.len);
        defer allocator.free(extended);
        @memcpy(extended[0..8], args[0..8]);
        extended[separator_index] = "--";
        @memcpy(extended[(separator_index + 1)..], command);

        var child = std.process.Child.init(extended, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        return;
    }

    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return;
}

fn waitForShellReady(allocator: std.mem.Allocator, root: []const u8, id: []const u8) !bool {
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        if (try registry.readOne(allocator, root, id)) |record| {
            defer registry.freeRecord(allocator, record);
            if (record.status == .ready) return true;
        }

        const error_path = try state_dir.shellFilePath(allocator, root, id, "error.txt");
        defer allocator.free(error_path);
        if (absolutePathExists(error_path)) return false;

        std.time.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

fn readStartupErrorOrDefault(allocator: std.mem.Allocator, root: []const u8, id: []const u8) ![]const u8 {
    const error_path = try state_dir.shellFilePath(allocator, root, id, "error.txt");
    defer allocator.free(error_path);

    const file = std.fs.openFileAbsolute(error_path, .{}) catch return "shell start failed";
    defer file.close();
    return file.readToEndAlloc(allocator, 4096) catch "shell start failed";
}

fn waitForShellShutdown(allocator: std.mem.Allocator, root: []const u8, id: []const u8, broker_pid: u32, shell_pid: ?u32) bool {
    const shell_dir = state_dir.shellDir(allocator, root, id) catch return false;
    defer allocator.free(shell_dir);

    const deadline = std.time.milliTimestamp() + 2500;
    while (std.time.milliTimestamp() < deadline) {
        if (!process.isAlive(broker_pid) and (shell_pid == null or !process.isAlive(shell_pid.?))) return true;
        std.fs.accessAbsolute(shell_dir, .{}) catch return true;
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

fn cleanupShellState(allocator: std.mem.Allocator, root: []const u8, id: []const u8) !void {
    try registry.remove(allocator, root, id);
    try state_dir.deleteShellDir(allocator, root, id);
}

fn readCommandFromStdin(allocator: std.mem.Allocator) ![]u8 {
    return std.io.getStdIn().reader().readAllAlloc(allocator, 1024 * 256);
}

fn cleanupExecArtifacts(stdout_path: []const u8, stderr_path: []const u8, completion_path: []const u8) !void {
    std.fs.deleteFileAbsolute(stdout_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    std.fs.deleteFileAbsolute(stderr_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
    std.fs.deleteFileAbsolute(completion_path) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
}

fn streamNewBytes(path: []const u8, offset: *u64, writer: anytype) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    if (stat.size <= offset.*) return;
    try file.seekTo(offset.*);
    var remaining = stat.size - offset.*;
    var buffer: [2048]u8 = undefined;
    while (remaining > 0) {
        const want = @min(buffer.len, remaining);
        const bytes_read = try file.read(buffer[0..want]);
        if (bytes_read == 0) break;
        try writer.writeAll(buffer[0..bytes_read]);
        offset.* += bytes_read;
        remaining -= bytes_read;
    }
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn absolutePathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn writeFileAtomicAbsolute(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    const file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(temp_path, path);
}
