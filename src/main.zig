const std = @import("std");

const usage_text =
    \\shlice
    \\
    \\  shlice start [shell]
    \\  shlice start -- <custom-command...>
    \\  shlice eval [--timeout <seconds>] [<code>]
    \\  echo "<code>" | shlice eval
    \\  shlice stop
    \\  shlice status
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse {
        try writeUsage();
        return;
    };

    if (std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "help"))
    {
        try writeUsage();
        return;
    }

    const stdout = std.io.getStdOut().writer();
    if (std.mem.eql(u8, command, "start") or
        std.mem.eql(u8, command, "eval") or
        std.mem.eql(u8, command, "stop") or
        std.mem.eql(u8, command, "status"))
    {
        try stdout.print("TODO: {s}\n", .{command});
        return;
    }

    const stderr = std.io.getStdErr().writer();
    try stderr.print("unknown command: {s}\n\n", .{command});
    try writeUsageTo(stderr);
    std.process.exit(1);
}

fn writeUsage() !void {
    try writeUsageTo(std.io.getStdOut().writer());
}

fn writeUsageTo(writer: anytype) !void {
    try writer.writeAll(usage_text ++ "\n");
}

test "help text mentions eval" {
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "shlice eval") != null);
}
