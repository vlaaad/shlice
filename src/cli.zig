const std = @import("std");
const shell_id = @import("shell_id.zig");

pub const Parsed = union(enum) {
    help,
    list,
    status: StatusOptions,
    start: StartOptions,
    exec: ExecOptions,
    stop: StopOptions,
    broker: BrokerOptions,
};

pub const StatusOptions = struct {
    id: ?[]const u8,
};

pub const StartOptions = struct {
    id: ?[]const u8,
    command: []const []const u8,
};

pub const ExecOptions = struct {
    id: []const u8,
    timeout_seconds: u32,
    command: ?[]const u8,
};

pub const StopOptions = struct {
    id: []const u8,
};

pub const BrokerOptions = struct {
    root: []const u8,
    id: []const u8,
    cwd: []const u8,
    command: []const []const u8,
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    _ = allocator;
    if (argv.len <= 1) return .help;

    const command_name = argv[1];
    if (isHelp(command_name)) return .help;
    if (std.mem.eql(u8, command_name, "list")) return .list;
    if (std.mem.eql(u8, command_name, "status")) return .{ .status = try parseStatus(argv[2..]) };
    if (std.mem.eql(u8, command_name, "start")) return .{ .start = try parseStart(argv[2..]) };
    if (std.mem.eql(u8, command_name, "exec")) return .{ .exec = try parseExec(argv[2..]) };
    if (std.mem.eql(u8, command_name, "stop")) return .{ .stop = try parseStop(argv[2..]) };
    if (std.mem.eql(u8, command_name, "__broker")) return .{ .broker = try parseBroker(argv[2..]) };
    return error.UnknownCommand;
}

fn parseStatus(args: []const []const u8) !StatusOptions {
    var id: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelp(arg)) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "--id")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            id = args[index];
            try shell_id.validate(id.?);
            continue;
        }
        return error.InvalidArguments;
    }
    return .{ .id = id };
}

fn parseStart(args: []const []const u8) !StartOptions {
    var id: ?[]const u8 = null;
    var separator_index: ?usize = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelp(arg)) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "--")) {
            separator_index = index;
            break;
        }
        if (std.mem.eql(u8, arg, "--id")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            id = args[index];
            try shell_id.validate(id.?);
            continue;
        }
        return error.InvalidArguments;
    }

    if (separator_index == null) return error.InvalidArguments;
    const command = if (separator_index) |start| args[(start + 1)..] else args[args.len..args.len];
    if (command.len == 0) return error.InvalidArguments;
    return .{ .id = id, .command = command };
}

fn parseExec(args: []const []const u8) !ExecOptions {
    var id: []const u8 = "main";
    var timeout_seconds: u32 = 5;
    var command: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelp(arg)) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "--id")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            id = args[index];
            try shell_id.validate(id);
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            timeout_seconds = try std.fmt.parseUnsigned(u32, args[index], 10);
            continue;
        }
        if (command == null) {
            command = arg;
            continue;
        }
        return error.InvalidArguments;
    }

    return .{ .id = id, .timeout_seconds = timeout_seconds, .command = command };
}

fn parseStop(args: []const []const u8) !StopOptions {
    if (args.len == 0) return .{ .id = "main" };
    if (args.len == 1) {
        if (isHelp(args[0])) return error.ShowHelp;
        try shell_id.validate(args[0]);
        return .{ .id = args[0] };
    }
    return error.InvalidArguments;
}

fn parseBroker(args: []const []const u8) !BrokerOptions {
    var root: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var separator_index: ?usize = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            separator_index = index;
            break;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            root = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--id")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            id = args[index];
            try shell_id.validate(id.?);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwd")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            cwd = args[index];
            continue;
        }
        return error.InvalidArguments;
    }

    if (root == null or id == null or cwd == null) return error.InvalidArguments;
    const command = if (separator_index) |start| args[(start + 1)..] else args[args.len..args.len];
    return .{ .root = root.?, .id = id.?, .cwd = cwd.?, .command = command };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-?") or
        std.mem.eql(u8, arg, "help");
}

test "parse list" {
    const parsed = try parse(std.testing.allocator, &.{ "shlice", "list" });
    try std.testing.expect(parsed == .list);
}

test "exec defaults id to main" {
    const parsed = try parse(std.testing.allocator, &.{ "shlice", "exec", "echo hi" });
    try std.testing.expect(parsed == .exec);
    try std.testing.expectEqualStrings("main", parsed.exec.id);
}

test "start parses separator command" {
    const parsed = try parse(std.testing.allocator, &.{ "shlice", "start", "--id", "demo", "--", "bash", "-lc", "pwd" });
    try std.testing.expect(parsed == .start);
    try std.testing.expectEqualStrings("demo", parsed.start.id.?);
    try std.testing.expectEqual(@as(usize, 3), parsed.start.command.len);
}

test "start requires a command" {
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, &.{ "shlice", "start" }));
}

test "stop defaults id to main" {
    const parsed = try parse(std.testing.allocator, &.{ "shlice", "stop" });
    try std.testing.expect(parsed == .stop);
    try std.testing.expectEqualStrings("main", parsed.stop.id);
}

test "stop accepts positional id" {
    const parsed = try parse(std.testing.allocator, &.{ "shlice", "stop", "demo" });
    try std.testing.expect(parsed == .stop);
    try std.testing.expectEqualStrings("demo", parsed.stop.id);
}
