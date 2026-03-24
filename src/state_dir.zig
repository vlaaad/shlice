const std = @import("std");

pub fn appDataDir(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.getAppDataDir(allocator, "shlice");
}

pub fn ipcSocketPath(allocator: std.mem.Allocator, root: []const u8, shell_id: []const u8, name: []const u8) ![]u8 {
    var hash: u64 = 0xcbf29ce484222325;
    hash = fnv1a(hash, root);
    hash = fnv1a(hash, "/");
    hash = fnv1a(hash, shell_id);
    hash = fnv1a(hash, "/");
    hash = fnv1a(hash, name);
    return std.fmt.allocPrint(allocator, "/tmp/shlice-{x}.sock", .{hash});
}

pub fn ensureLayout(allocator: std.mem.Allocator) ![]u8 {
    const root = try appDataDir(allocator);
    errdefer allocator.free(root);

    std.fs.makeDirAbsolute(root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const registry_dir = try std.fs.path.join(allocator, &.{ root, "registry" });
    defer allocator.free(registry_dir);
    std.fs.makeDirAbsolute(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const shells_dir = try std.fs.path.join(allocator, &.{ root, "shells" });
    defer allocator.free(shells_dir);
    std.fs.makeDirAbsolute(shells_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return root;
}

pub fn registryDir(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "registry" });
}

pub fn shellDir(allocator: std.mem.Allocator, root: []const u8, shell_id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "shells", shell_id });
}

pub fn ensureShellDir(allocator: std.mem.Allocator, root: []const u8, shell_id: []const u8) ![]u8 {
    const path = try shellDir(allocator, root, shell_id);
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            allocator.free(path);
            return err;
        },
    };
    return path;
}

pub fn shellFilePath(allocator: std.mem.Allocator, root: []const u8, shell_id: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "shells", shell_id, name });
}

pub fn deleteShellDir(allocator: std.mem.Allocator, root: []const u8, shell_id: []const u8) !void {
    const path = try shellDir(allocator, root, shell_id);
    defer allocator.free(path);

    deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteTreeAbsolute(path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const base_name = std.fs.path.basename(path);

    var parent = try std.fs.openDirAbsolute(parent_path, .{});
    defer parent.close();
    try parent.deleteTree(base_name);
}

fn fnv1a(hash: u64, bytes: []const u8) u64 {
    var value = hash;
    for (bytes) |byte| {
        value ^= byte;
        value *%= 0x100000001b3;
    }
    return value;
}

test "layout paths contain registry" {
    const root = try appDataDir(std.testing.allocator);
    defer std.testing.allocator.free(root);
    const registry_path = try registryDir(std.testing.allocator, root);
    defer std.testing.allocator.free(registry_path);
    try std.testing.expect(std.mem.indexOf(u8, registry_path, "registry") != null);
}
