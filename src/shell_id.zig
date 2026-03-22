const std = @import("std");

pub const Error = error{
    EmptyShellId,
    InvalidShellId,
};

pub fn validate(value: []const u8) Error!void {
    if (value.len == 0) return error.EmptyShellId;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-') continue;
        return error.InvalidShellId;
    }
    if (isReservedWindowsName(value)) return error.InvalidShellId;
}

pub fn generate(allocator: std.mem.Allocator) ![]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_-";
    var bytes: [10]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    var result = try allocator.alloc(u8, bytes.len);
    for (bytes, 0..) |byte, index| {
        result[index] = alphabet[byte % alphabet.len];
    }
    return result;
}

fn isReservedWindowsName(value: []const u8) bool {
    const reserved = [_][]const u8{
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    };
    for (reserved) |name| {
        if (std.ascii.eqlIgnoreCase(value, name)) return true;
    }
    return false;
}

test "validate accepts portable ids" {
    try validate("shell_01-test");
}

test "validate rejects spaces" {
    try std.testing.expectError(error.InvalidShellId, validate("bad id"));
}

test "validate rejects reserved windows names" {
    try std.testing.expectError(error.InvalidShellId, validate("CON"));
}

test "generate creates valid ids" {
    const value = try generate(std.testing.allocator);
    defer std.testing.allocator.free(value);
    try validate(value);
}
