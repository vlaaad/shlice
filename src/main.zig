const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const exit_code = app.run(gpa.allocator()) catch |err| {
        _ = gpa.deinit();
        return err;
    };
    _ = gpa.deinit();
    if (exit_code != 0) std.process.exit(exit_code);
}

test {
    std.testing.refAllDecls(@import("app.zig"));
    std.testing.refAllDecls(@import("broker.zig"));
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("locks.zig"));
    std.testing.refAllDecls(@import("output.zig"));
    std.testing.refAllDecls(@import("process.zig"));
    std.testing.refAllDecls(@import("protocol.zig"));
    std.testing.refAllDecls(@import("registry.zig"));
    std.testing.refAllDecls(@import("shell_id.zig"));
    std.testing.refAllDecls(@import("state_dir.zig"));
}
