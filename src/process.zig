const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

extern "c" fn getpid() c_int;
extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(windows.WINAPI) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn GetExitCodeProcess(
    process: windows.HANDLE,
    exit_code: *windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn GetProcessId(process: windows.HANDLE) callconv(windows.WINAPI) windows.DWORD;
extern "kernel32" fn TerminateProcess(
    process: windows.HANDLE,
    exit_code: windows.UINT,
) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(windows.WINAPI) windows.DWORD;

pub fn isAlive(pid: u32) bool {
    if (pid == 0) return false;

    if (@import("builtin").os.tag == .windows) {
        return isAliveWindows(pid);
    }
    return isAlivePosix(pid);
}

pub fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(getpid()),
    };
}

pub fn terminate(pid: u32) bool {
    if (pid == 0) return false;
    if (@import("builtin").os.tag == .windows) {
        return terminateWindows(pid);
    }
    return terminatePosix(pid, @as(@TypeOf(std.posix.SIG.TERM), std.posix.SIG.TERM));
}

pub fn forceKill(pid: u32) bool {
    if (pid == 0) return false;
    if (@import("builtin").os.tag == .windows) {
        return terminateWindows(pid);
    }
    return terminatePosix(pid, @as(@TypeOf(std.posix.SIG.KILL), std.posix.SIG.KILL));
}

pub fn waitUntilDead(pid: u32, timeout_ms: u64) bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (!isAlive(pid)) return true;
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    return !isAlive(pid);
}

pub fn pidFromChildId(value: anytype) u32 {
    return switch (builtin.os.tag) {
        .windows => switch (@typeInfo(@TypeOf(value))) {
            .Pointer => blk: {
                const handle: windows.HANDLE = @ptrCast(value);
                break :blk @intCast(GetProcessId(handle));
            },
            .Optional => blk: {
                if (value) |handle_value| {
                    const handle: windows.HANDLE = @ptrCast(handle_value);
                    break :blk @intCast(GetProcessId(handle));
                }
                break :blk 0;
            },
            .Int, .ComptimeInt => @intCast(value),
            else => 0,
        },
        else => switch (@typeInfo(@TypeOf(value))) {
            .Int, .ComptimeInt => @intCast(value),
            else => 0,
        },
    };
}

pub fn resolveExecutable(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(command) or hasPathSeparator(command)) {
        return allocator.dupe(u8, command);
    }

    const path_value = std.process.getEnvVarOwned(allocator, "PATH") catch return error.FileNotFound;
    defer allocator.free(path_value);

    if (builtin.os.tag == .windows) {
        const extensions = try windowsExecutableExtensions(allocator, command);
        defer freeStringList(allocator, extensions);
        var parts = std.mem.splitScalar(u8, path_value, ';');
        while (parts.next()) |dir| {
            if (dir.len == 0) continue;
            for (extensions) |extension| {
                const candidate_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, extension });
                defer allocator.free(candidate_name);
                const candidate = try std.fs.path.join(allocator, &.{ dir, candidate_name });
                defer allocator.free(candidate);
                if (fileExists(candidate)) return allocator.dupe(u8, candidate);
            }
        }
        return error.FileNotFound;
    }

    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, command });
        defer allocator.free(candidate);
        if (fileExists(candidate)) return allocator.dupe(u8, candidate);
    }
    return error.FileNotFound;
}

fn isAlivePosix(pid: u32) bool {
    const posix = std.posix;
    const converted_pid: posix.pid_t = @intCast(pid);
    posix.kill(converted_pid, 0) catch |err| switch (err) {
        error.PermissionDenied => return true,
        error.ProcessNotFound => return false,
        else => return false,
    };
    return true;
}

fn hasPathSeparator(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, std.fs.path.sep) != null or std.mem.indexOfScalar(u8, value, '/') != null or std.mem.indexOfScalar(u8, value, '\\') != null;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn windowsExecutableExtensions(allocator: std.mem.Allocator, command: []const u8) ![][]u8 {
    if (std.fs.path.extension(command).len != 0) {
        const single = try allocator.alloc([]u8, 1);
        single[0] = try allocator.dupe(u8, "");
        return single;
    }

    const path_ext = std.process.getEnvVarOwned(allocator, "PATHEXT") catch try allocator.dupe(u8, ".COM;.EXE;.BAT;.CMD");
    defer allocator.free(path_ext);

    var list = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, list.items);

    var parts = std.mem.splitScalar(u8, path_ext, ';');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try list.append(try allocator.dupe(u8, part));
    }
    if (list.items.len == 0) try list.append(try allocator.dupe(u8, ".EXE"));
    return list.toOwnedSlice();
}

fn freeStringList(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn terminatePosix(pid: u32, signal: @TypeOf(std.posix.SIG.TERM)) bool {
    const converted_pid: std.posix.pid_t = @intCast(pid);
    std.posix.kill(converted_pid, signal) catch return false;
    return true;
}

fn isAliveWindows(pid: u32) bool {
    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
    const SYNCHRONIZE: windows.DWORD = 0x00100000;
    const STILL_ACTIVE: windows.DWORD = 259;

    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, windows.FALSE, pid) orelse return false;
    defer _ = CloseHandle(handle);

    var exit_code: windows.DWORD = 0;
    if (GetExitCodeProcess(handle, &exit_code) == windows.FALSE) return false;
    return exit_code == STILL_ACTIVE;
}

fn terminateWindows(pid: u32) bool {
    const PROCESS_TERMINATE: windows.DWORD = 0x0001;
    const SYNCHRONIZE: windows.DWORD = 0x00100000;

    const handle = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, windows.FALSE, pid) orelse return false;
    defer _ = CloseHandle(handle);

    return TerminateProcess(handle, 1) != windows.FALSE;
}

test "current process is alive" {
    try std.testing.expect(isAlive(currentPid()));
}
