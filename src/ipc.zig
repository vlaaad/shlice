const std = @import("std");
const builtin = @import("builtin");

pub const FrameKind = enum(u8) {
    exec = 'E',
    stop = 'S',
    ready = 'R',
    stdout = 'O',
    stderr = 'e',
    complete = 'C',
    stopped = 'T',
    err = 'X',
};

pub const Frame = struct {
    kind: FrameKind,
    payload: []u8,
};

pub const Completion = struct {
    exit_code: i32,
    timed_out: bool,
};

pub fn bindUnixServer(path: []const u8) !std.net.Server {
    if (builtin.os.tag == .windows) @panic("unix sockets are unavailable on windows");
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(path);
    return address.listen(.{});
}

pub fn connectUnixStream(path: []const u8) !std.net.Stream {
    if (builtin.os.tag == .windows) @panic("unix sockets are unavailable on windows");
    return std.net.connectUnixSocket(path);
}

pub fn createFifo(allocator: std.mem.Allocator, path: []const u8) !void {
    if (builtin.os.tag == .windows) @panic("fifo helpers are unavailable on windows");
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    if (builtin.os.tag == .linux) {
        switch (std.posix.errno(std.os.linux.mknod(path_z.ptr, std.os.linux.S.IFIFO | 0o600, 0))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
        return;
    }

    const c = @cImport({
        @cInclude("errno.h");
        @cInclude("sys/stat.h");
    });
    if (c.mkfifo(path_z.ptr, 0o600) != 0) return error.Unexpected;
}

pub fn openFifoReadWrite(path: []const u8) !std.fs.File {
    return std.fs.openFileAbsolute(path, .{ .mode = .read_write });
}

pub fn openFifoRead(path: []const u8) !std.fs.File {
    return std.fs.openFileAbsolute(path, .{ .mode = .read_only });
}

pub fn openFifoWrite(path: []const u8) !std.fs.File {
    return std.fs.openFileAbsolute(path, .{ .mode = .write_only });
}

pub fn sendFrame(stream: *std.net.Stream, kind: FrameKind, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try stream.writeAll(&header);
    if (payload.len != 0) try stream.writeAll(payload);
}

pub fn readFrame(allocator: std.mem.Allocator, stream: *std.net.Stream, max_payload: usize) !?Frame {
    var header: [5]u8 = undefined;
    const first_read = try stream.read(header[0..1]);
    if (first_read == 0) return null;
    try readExact(stream, header[1..]);

    const kind: FrameKind = @enumFromInt(header[0]);
    const payload_len = std.mem.readInt(u32, header[1..5], .little);
    if (payload_len > max_payload) return error.InvalidData;

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExact(stream, payload);
    return .{ .kind = kind, .payload = payload };
}

pub fn sendFrameFile(file: *std.fs.File, kind: FrameKind, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try file.writeAll(&header);
    if (payload.len != 0) try file.writeAll(payload);
}

pub fn readFrameFile(allocator: std.mem.Allocator, file: *std.fs.File, max_payload: usize) !?Frame {
    var header: [5]u8 = undefined;
    const first_read = try file.read(header[0..1]);
    if (first_read == 0) return null;
    try readExactFile(file, header[1..]);

    const kind: FrameKind = @enumFromInt(header[0]);
    const payload_len = std.mem.readInt(u32, header[1..5], .little);
    if (payload_len > max_payload) return error.InvalidData;

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExactFile(file, payload);
    return .{ .kind = kind, .payload = payload };
}

pub fn encodeCompletion(allocator: std.mem.Allocator, completion: Completion) ![]u8 {
    const payload = try allocator.alloc(u8, 5);
    std.mem.writeInt(i32, payload[0..4], completion.exit_code, .little);
    payload[4] = @intFromBool(completion.timed_out);
    return payload;
}

pub fn decodeCompletion(payload: []const u8) !Completion {
    if (payload.len != 5) return error.InvalidData;
    return .{
        .exit_code = std.mem.readInt(i32, payload[0..4], .little),
        .timed_out = payload[4] != 0,
    };
}

fn readExact(stream: *std.net.Stream, buffer: []u8) !void {
    var index: usize = 0;
    while (index < buffer.len) {
        const bytes_read = try stream.read(buffer[index..]);
        if (bytes_read == 0) return error.EndOfStream;
        index += bytes_read;
    }
}

fn readExactFile(file: *std.fs.File, buffer: []u8) !void {
    var index: usize = 0;
    while (index < buffer.len) {
        const bytes_read = try file.read(buffer[index..]);
        if (bytes_read == 0) return error.EndOfStream;
        index += bytes_read;
    }
}
