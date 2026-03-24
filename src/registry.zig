const std = @import("std");
const fs_atomic = @import("fs_atomic.zig");
const process = @import("process.zig");
const shell_id = @import("shell_id.zig");
const state_dir = @import("state_dir.zig");

pub const ShellStatus = enum {
    busy,
    ready,
};

pub const ShellRecord = struct {
    id: []const u8,
    status: ShellStatus,
    pid: ?u32,
    broker_pid: ?u32 = null,
    command_line: []const u8,
    cwd: []const u8,
};

pub fn entryPath(allocator: std.mem.Allocator, root: []const u8, id: []const u8) ![]u8 {
    const registry_root = try state_dir.registryDir(allocator, root);
    defer allocator.free(registry_root);

    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ registry_root, filename });
}

pub fn upsert(allocator: std.mem.Allocator, root: []const u8, record: ShellRecord) !void {
    try shell_id.validate(record.id);
    const path = try entryPath(allocator, root, record.id);
    defer allocator.free(path);

    const dir_path = try state_dir.ensureShellDir(allocator, root, record.id);
    defer allocator.free(dir_path);

    const payload = try std.json.stringifyAlloc(allocator, record, .{ .whitespace = .indent_2 });
    defer allocator.free(payload);

    try fs_atomic.writeFileAbsolute(allocator, path, payload);
}

pub fn remove(allocator: std.mem.Allocator, root: []const u8, id: []const u8) !void {
    const path = try entryPath(allocator, root, id);
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn readOne(allocator: std.mem.Allocator, root: []const u8, id: []const u8) !?ShellRecord {
    const path = try entryPath(allocator, root, id);
    defer allocator.free(path);

    const bytes = readFileAllocAbsolute(allocator, path, 1024 * 128) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(ShellRecord, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return try cloneRecord(allocator, parsed.value);
}

pub fn listAll(allocator: std.mem.Allocator, root: []const u8) ![]ShellRecord {
    const registry_root = try state_dir.registryDir(allocator, root);
    defer allocator.free(registry_root);

    var dir = try std.fs.openDirAbsolute(registry_root, .{ .iterate = true });
    defer dir.close();

    var records = std.ArrayList(ShellRecord).init(allocator);
    errdefer {
        for (records.items) |record| freeRecord(allocator, record);
        records.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ registry_root, entry.name });
        defer allocator.free(full_path);

        const bytes = try readFileAllocAbsolute(allocator, full_path, 1024 * 128);
        defer allocator.free(bytes);
        const parsed = std.json.parseFromSlice(ShellRecord, allocator, bytes, .{ .ignore_unknown_fields = true }) catch {
            continue;
        };
        defer parsed.deinit();
        try records.append(try cloneRecord(allocator, parsed.value));
    }

    sortRecords(records.items);
    return records.toOwnedSlice();
}

pub fn freeRecord(allocator: std.mem.Allocator, record: ShellRecord) void {
    allocator.free(record.id);
    allocator.free(record.command_line);
    allocator.free(record.cwd);
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []ShellRecord) void {
    for (records) |record| freeRecord(allocator, record);
    allocator.free(records);
}

pub fn revalidateAndPrune(allocator: std.mem.Allocator, root: []const u8) !void {
    const registry_root = try state_dir.registryDir(allocator, root);
    defer allocator.free(registry_root);

    var dir = try std.fs.openDirAbsolute(registry_root, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ registry_root, entry.name });
        defer allocator.free(full_path);

        const bytes = readFileAllocAbsolute(allocator, full_path, 1024 * 128) catch {
            try pruneEntryByFilename(allocator, root, entry.name);
            continue;
        };
        defer allocator.free(bytes);

        const parsed = std.json.parseFromSlice(ShellRecord, allocator, bytes, .{ .ignore_unknown_fields = true }) catch {
            try pruneEntryByFilename(allocator, root, entry.name);
            continue;
        };
        defer parsed.deinit();

        const record = parsed.value;
        const broker_alive = if (record.broker_pid) |pid| process.isAlive(pid) else false;
        const shell_alive = if (record.pid) |pid| process.isAlive(pid) else true;
        if (!broker_alive or !shell_alive) {
            try remove(allocator, root, record.id);
            try state_dir.deleteShellDir(allocator, root, record.id);
        }
    }
}

fn pruneEntryByFilename(allocator: std.mem.Allocator, root: []const u8, entry_name: []const u8) !void {
    if (!std.mem.endsWith(u8, entry_name, ".json")) return;
    const id = entry_name[0 .. entry_name.len - ".json".len];
    remove(allocator, root, id) catch {};
    state_dir.deleteShellDir(allocator, root, id) catch {};
}

fn lessThan(_: void, lhs: ShellRecord, rhs: ShellRecord) bool {
    return std.mem.lessThan(u8, lhs.id, rhs.id);
}

fn cloneRecord(allocator: std.mem.Allocator, record: ShellRecord) !ShellRecord {
    const id = try allocator.dupe(u8, record.id);
    errdefer allocator.free(id);

    const command_line = try allocator.dupe(u8, record.command_line);
    errdefer allocator.free(command_line);

    const cwd = try allocator.dupe(u8, record.cwd);
    errdefer allocator.free(cwd);
    return .{
        .id = id,
        .status = record.status,
        .pid = record.pid,
        .broker_pid = record.broker_pid,
        .command_line = command_line,
        .cwd = cwd,
    };
}

fn sortRecords(records: []ShellRecord) void {
    var index: usize = 1;
    while (index < records.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and lessThan({}, records[cursor], records[cursor - 1])) : (cursor -= 1) {
            std.mem.swap(ShellRecord, &records[cursor], &records[cursor - 1]);
        }
    }
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

test "status stringifies via json" {
    const payload = try std.json.stringifyAlloc(std.testing.allocator, ShellRecord{
        .id = "demo",
        .status = .ready,
        .pid = 42,
        .broker_pid = 7,
        .command_line = "sh",
        .cwd = "/tmp",
    }, .{});
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "ready") != null);
}

test "registry upsert read and list are stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    try std.fs.makeDirAbsolute(registry_root);

    const shells_root = try std.fs.path.join(std.testing.allocator, &.{ root, "shells" });
    defer std.testing.allocator.free(shells_root);
    try std.fs.makeDirAbsolute(shells_root);

    try upsert(std.testing.allocator, root, .{
        .id = "beta",
        .status = .ready,
        .pid = null,
        .broker_pid = null,
        .command_line = "bash",
        .cwd = "/workspace",
    });
    try upsert(std.testing.allocator, root, .{
        .id = "alpha",
        .status = .busy,
        .pid = process.currentPid(),
        .broker_pid = process.currentPid(),
        .command_line = "zsh",
        .cwd = "/tmp",
    });

    const single = (try readOne(std.testing.allocator, root, "beta")).?;
    defer freeRecord(std.testing.allocator, single);
    try std.testing.expectEqualStrings("beta", single.id);

    const records = try listAll(std.testing.allocator, root);
    defer freeRecords(std.testing.allocator, records);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("alpha", records[0].id);
    try std.testing.expectEqualStrings("beta", records[1].id);
}

test "revalidate prunes dead broker state" {
    if (@import("builtin").os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ root, "registry" });
    defer std.testing.allocator.free(registry_root);
    try std.fs.makeDirAbsolute(registry_root);

    const shells_root = try std.fs.path.join(std.testing.allocator, &.{ root, "shells" });
    defer std.testing.allocator.free(shells_root);
    try std.fs.makeDirAbsolute(shells_root);

    try upsert(std.testing.allocator, root, .{
        .id = "dead",
        .status = .busy,
        .pid = 999999,
        .broker_pid = 999999,
        .command_line = "sh",
        .cwd = "/tmp",
    });

    try revalidateAndPrune(std.testing.allocator, root);
    const maybe_record = try readOne(std.testing.allocator, root, "dead");
    defer if (maybe_record) |record| freeRecord(std.testing.allocator, record);
    try std.testing.expect(maybe_record == null);
}
