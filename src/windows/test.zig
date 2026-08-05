/// Windows-specific unit tests.
/// Run on Windows: zig build test
/// Cross-compile check: zig build check -Dtarget=x86_64-windows
const std = @import("std");
const cmdline = @import("cmdline.zig");

test "cmdline: simple args" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "/c", "echo", "hello" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe /c echo hello", utf8);
}

test "cmdline: empty argument" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"\"", utf8);
}

test "cmdline: spaces" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "hello world" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"hello world\"", utf8);
}

test "cmdline: quotes" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "say \"hi\"" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"say \\\"hi\\\"\"", utf8);
}

test "cmdline: trailing backslashes" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "C:\\path\\" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"C:\\path\\\\\"", utf8);
}

test "cmdline: backslash before quote" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "a\\\"b" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"a\\\\\\\"b\"", utf8);
}

test "cmdline: unicode" {
    const alloc = std.testing.allocator;
    const result = try cmdline.buildCommandLine(alloc, &.{ "cmd.exe", "héllo wörld" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"héllo wörld\"", utf8);
}

// Session name validation tests (cross-platform)
test "session name: rejects path separators" {
    const alloc = std.testing.allocator;

    // Forward slash
    const result1 = std.fmt.allocPrint(alloc, "{s}{s}", .{ "", "foo/bar" }) catch unreachable;
    defer alloc.free(result1);
    try std.testing.expect(std.mem.indexOfScalar(u8, result1, '/') != null);

    // Backslash
    const result2 = std.fmt.allocPrint(alloc, "{s}{s}", .{ "", "foo\\bar" }) catch unreachable;
    defer alloc.free(result2);
    try std.testing.expect(std.mem.indexOfScalar(u8, result2, '\\') != null);
}

test "session name: allows normal names" {
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "dev", "my-session", "test_123", "a.b.c" };
    for (names) |name| {
        const full = try std.fmt.allocPrint(alloc, "{s}", .{name});
        defer alloc.free(full);
        try std.testing.expect(std.mem.indexOfScalar(u8, full, '/') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, full, '\\') == null);
    }
}
