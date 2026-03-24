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
