const std = @import("std");

pub fn writeFileAbsolute(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
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
