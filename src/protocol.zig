const std = @import("std");

pub const ready_marker = "\x1b]133;A\x07";
pub const prompt_end_marker = "\x1b]133;B\x07";
pub const command_begin_marker = "\x1b]133;C\x07";
pub const command_done_prefix = "\x1b]133;D;";

pub const Request = struct {
    id: []const u8,
    command: []const u8,
};

pub const Completion = struct {
    id: []const u8,
    exit_code: i32,
    timed_out: bool,
};

pub fn buildExecCommand(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    if (command.len != 0 and command[command.len - 1] == '\n') {
        return allocator.dupe(u8, command);
    }
    return std.fmt.allocPrint(allocator, "{s}\n", .{command});
}

pub fn stringifyRequest(allocator: std.mem.Allocator, request: Request) ![]u8 {
    return std.json.stringifyAlloc(allocator, request, .{ .whitespace = .indent_2 });
}

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(Request, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try allocator.dupe(u8, parsed.value.id);
    errdefer allocator.free(id);
    return .{
        .id = id,
        .command = try allocator.dupe(u8, parsed.value.command),
    };
}

pub fn stringifyCompletion(allocator: std.mem.Allocator, completion: Completion) ![]u8 {
    return std.json.stringifyAlloc(allocator, completion, .{ .whitespace = .indent_2 });
}

pub fn parseCompletion(allocator: std.mem.Allocator, bytes: []const u8) !Completion {
    const parsed = try std.json.parseFromSlice(Completion, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const id = try allocator.dupe(u8, parsed.value.id);
    return .{
        .id = id,
        .exit_code = parsed.value.exit_code,
        .timed_out = parsed.value.timed_out,
    };
}

pub const StdoutParse = struct {
    wrote_data: bool,
    began_request: bool,
    ended_request: bool,
    exit_code: ?i32,
};

pub const StdoutParseState = struct {
    inside_prompt: bool = false,
};

pub fn parseStdoutChunk(writer: anytype, chunk: []const u8, state: *StdoutParseState) !StdoutParse {
    var result = StdoutParse{
        .wrote_data = false,
        .began_request = false,
        .ended_request = false,
        .exit_code = null,
    };

    var index: usize = 0;
    while (index < chunk.len) {
        const escape_index = std.mem.indexOfScalarPos(u8, chunk, index, 0x1b) orelse {
            if (!state.inside_prompt and chunk[index..].len != 0) {
                try writer.writeAll(chunk[index..]);
                result.wrote_data = true;
            }
            break;
        };

        if (!state.inside_prompt and escape_index > index) {
            try writer.writeAll(chunk[index..escape_index]);
            result.wrote_data = true;
        }

        const marker_end = std.mem.indexOfScalarPos(u8, chunk, escape_index, 0x07) orelse {
            if (!state.inside_prompt) {
                try writer.writeAll(chunk[escape_index..]);
                result.wrote_data = true;
            }
            break;
        };

        const marker = chunk[escape_index .. marker_end + 1];
        if (std.mem.eql(u8, marker, ready_marker)) {
            state.inside_prompt = true;
        } else if (std.mem.eql(u8, marker, prompt_end_marker)) {
            state.inside_prompt = false;
        } else if (std.mem.eql(u8, marker, command_begin_marker)) {
            state.inside_prompt = false;
            result.began_request = true;
        } else if (parseExitCode(marker)) |exit_code| {
            state.inside_prompt = false;
            result.ended_request = true;
            result.exit_code = exit_code;
        } else if (!state.inside_prompt) {
            try writer.writeAll(marker);
            result.wrote_data = true;
        }

        index = marker_end + 1;
    }

    return result;
}

pub fn chunkContainsReady(chunk: []const u8) bool {
    return std.mem.indexOf(u8, chunk, ready_marker) != null;
}

fn parseExitCode(marker: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, marker, command_done_prefix)) return null;
    const body = marker[command_done_prefix.len .. marker.len - 1];
    return std.fmt.parseInt(i32, body, 10) catch null;
}

test "parse stdout strips generic markers" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const chunk = command_begin_marker ++ "hello" ++ command_done_prefix ++ "3\x07";
    var state = StdoutParseState{};
    const parsed = try parseStdoutChunk(out.writer(), chunk, &state);
    try std.testing.expect(parsed.began_request);
    try std.testing.expect(parsed.ended_request);
    try std.testing.expectEqual(@as(?i32, 3), parsed.exit_code);
    try std.testing.expectEqualStrings("hello", out.items);
}

test "parse stdout strips prompt text" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    var state = StdoutParseState{};
    const chunk = ready_marker ++ "user=> " ++ prompt_end_marker ++ command_begin_marker ++ "1\n" ++ command_done_prefix ++ "0\x07";
    const parsed = try parseStdoutChunk(out.writer(), chunk, &state);
    try std.testing.expect(parsed.began_request);
    try std.testing.expect(parsed.ended_request);
    try std.testing.expectEqualStrings("1\n", out.items);
}

test "ready accepts prompt marker" {
    try std.testing.expect(chunkContainsReady(ready_marker));
}
