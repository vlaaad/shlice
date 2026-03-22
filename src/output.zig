const std = @import("std");

pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\shlice
        \\
        \\  shlice start [--id <shell-id>] -- <custom-command...>
        \\  shlice exec [--id <shell-id>] [--timeout <seconds>] <command>
        \\  echo "<command>" | shlice exec [--id <shell-id>]
        \\  shlice stop [<shell-id>]
        \\  shlice status [--id <shell-id>]
        \\  shlice list
        \\
        \\Help flags: -h, --help, -?
        \\Default shell id: main
        \\
    );
}

pub fn printStarted(id: []const u8) !void {
    try std.io.getStdOut().writer().print("started {s}\n", .{id});
}

pub fn printStopped(id: []const u8) !void {
    try std.io.getStdOut().writer().print("stopped {s}\n", .{id});
}

pub fn printError(message: []const u8) !void {
    try std.io.getStdErr().writer().print("error: {s}\n", .{message});
}

pub fn printStatusHeader(writer: anytype) !void {
    try writer.writeAll("id\tstatus\tpid\tbroker\tcmd\tcwd\n");
}

pub fn printNoShells(writer: anytype) !void {
    try writer.writeAll("no shells\n");
}

pub fn printStatusLine(writer: anytype, id: []const u8, status: []const u8, pid: ?u32, broker_pid: ?u32, command_line: []const u8, cwd: []const u8) !void {
    if (pid) |live_pid| {
        if (broker_pid) |live_broker_pid| {
            try writer.print("{s}\t{s}\t{d}\t{d}\t{s}\t{s}\n", .{ id, status, live_pid, live_broker_pid, command_line, cwd });
        } else {
            try writer.print("{s}\t{s}\t{d}\t-\t{s}\t{s}\n", .{ id, status, live_pid, command_line, cwd });
        }
    } else {
        if (broker_pid) |live_broker_pid| {
            try writer.print("{s}\t{s}\t-\t{d}\t{s}\t{s}\n", .{ id, status, live_broker_pid, command_line, cwd });
        } else {
            try writer.print("{s}\t{s}\t-\t-\t{s}\t{s}\n", .{ id, status, command_line, cwd });
        }
    }
}

test "usage mentions exec and list" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try printUsage(buffer.writer());
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "shlice exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "shlice list") != null);
}
