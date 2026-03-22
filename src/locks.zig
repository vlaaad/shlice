const std = @import("std");
const process = @import("process.zig");

pub const LockKind = enum {
    start,
    exec,
};

pub const LockFile = struct {
    pid: u32,
};

pub const AcquireResult = enum {
    acquired,
    busy,
    recovered_stale,
};

pub fn lockPath(allocator: std.mem.Allocator, shell_dir: []const u8, kind: LockKind) ![]u8 {
    return std.fs.path.join(allocator, &.{ shell_dir, switch (kind) {
        .start => "start.lock",
        .exec => "exec.lock",
    } });
}

pub fn acquire(allocator: std.mem.Allocator, shell_dir: []const u8, kind: LockKind) !AcquireResult {
    const path = try lockPath(allocator, shell_dir, kind);
    defer allocator.free(path);

    const content = std.json.stringifyAlloc(allocator, LockFile{ .pid = process.currentPid() }, .{});
    const payload = try content;
    defer allocator.free(payload);

    var recovered_stale = false;
    while (true) {
        const file = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (try recoverStaleLock(allocator, path)) {
                    recovered_stale = true;
                    continue;
                }
                return .busy;
            },
            else => return err,
        };
        defer file.close();
        try file.writeAll(payload);
        return if (recovered_stale) .recovered_stale else .acquired;
    }
}

pub fn release(allocator: std.mem.Allocator, shell_dir: []const u8, kind: LockKind) !void {
    const path = try lockPath(allocator, shell_dir, kind);
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn recoverStaleLock(allocator: std.mem.Allocator, path: []const u8) !bool {
    const bytes = readFileAllocAbsolute(allocator, path, 1024 * 16) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(LockFile, allocator, bytes, .{ .ignore_unknown_fields = true }) catch {
        return false;
    };
    defer parsed.deinit();

    if (process.isAlive(parsed.value.pid)) return false;
    try std.fs.deleteFileAbsolute(path);
    return true;
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

test "lock path uses lock suffix" {
    const path = try lockPath(std.testing.allocator, "C:/tmp/example", .exec);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "exec.lock"));
}
