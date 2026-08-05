const builtin = @import("builtin");

comptime {
    _ = @import("main.zig");
    _ = @import("util.zig");
    _ = @import("ipc.zig");
    _ = @import("label.zig");
    _ = @import("cfg.zig");

    if (builtin.os.tag == .windows) {
        _ = @import("windows/cmdline.zig");
        _ = @import("windows/test.zig");
    } else {
        _ = @import("socket.zig");
        _ = @import("signal.zig");
        _ = @import("loop.zig");
        _ = @import("daemonize.zig");
    }
}
