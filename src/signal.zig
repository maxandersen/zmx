const std = @import("std");
const builtin = @import("builtin");

/// On Windows, signals don't exist. This module compiles to no-ops.
/// On POSIX, it provides the self-pipe signal mechanism.

pub var sig_pipe: [2]i32 = .{ -1, -1 };

pub fn ignoreSigpipe() void {
    if (comptime builtin.os.tag == .windows) return;
    const lib_posix = @import("posix.zig");
    const act: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.IGN },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &act, null);
}

pub fn installWakeHandler(sig: u6) void {
    if (comptime builtin.os.tag == .windows) return;
    const lib_posix = @import("posix.zig");
    const act: lib_posix.Sigaction = .{
        .handler = .{ .sigaction = wakeSignalPipeImpl },
        .mask = lib_posix.sigemptyset(),
        .flags = lib_posix.SA.SIGINFO,
    };
    lib_posix.sigaction(@as(lib_posix.SIG, @enumFromInt(sig)), &act, null);
}

fn wakeSignalPipeImpl(_: @import("posix.zig").SIG, _: *const @import("posix.zig").siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

pub fn openSignalPipe() !void {
    if (comptime builtin.os.tag == .windows) return;
    const lib_posix = @import("posix.zig");
    sig_pipe = try lib_posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainSignalPipe() void {
    if (comptime builtin.os.tag == .windows) return;
    const lib_posix = @import("posix.zig");
    var b: [16]u8 = undefined;
    while (true) {
        const n = lib_posix.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}
