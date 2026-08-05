/// Windows command-line quoting for CreateProcessW.
///
/// The MSVCRT argv parsing rules require each argument to be individually quoted:
///   - Wrap in double-quotes if it contains spaces, quotes, or is empty.
///   - Backslashes before a quote must be doubled.
///   - A trailing run of backslashes must be doubled (the closing quote follows).
///
/// Reference: https://learn.microsoft.com/en-us/cpp/c-runtime-library/parsing-c-command-line-arguments
const std = @import("std");

/// Build a single command-line string from an argv slice.
/// Caller owns the returned slice.
pub fn buildCommandLine(alloc: std.mem.Allocator, args: []const []const u8) ![:0]u16 {
    var utf8_buf = std.ArrayList(u8).empty;
    defer utf8_buf.deinit(alloc);

    for (args, 0..) |arg, i| {
        if (i > 0) try utf8_buf.append(alloc, ' ');
        try quoteArg(alloc, &utf8_buf, arg);
    }

    return std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8_buf.items);
}

fn quoteArg(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and !needsQuoting(arg)) {
        try buf.appendSlice(alloc, arg);
        return;
    }

    try buf.append(alloc, '"');
    var i: usize = 0;
    while (i < arg.len) {
        // Count backslashes
        var num_backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') {
            i += 1;
            num_backslashes += 1;
        }

        if (i == arg.len) {
            // Trailing backslashes: double them (closing quote follows)
            var j: usize = 0;
            while (j < num_backslashes * 2) : (j += 1) {
                try buf.append(alloc, '\\');
            }
            break;
        } else if (arg[i] == '"') {
            // Backslashes before a quote: double them + escape the quote
            var j: usize = 0;
            while (j < num_backslashes * 2) : (j += 1) {
                try buf.append(alloc, '\\');
            }
            try buf.append(alloc, '\\');
            try buf.append(alloc, '"');
        } else {
            // Backslashes not before a quote: keep them as-is
            var j: usize = 0;
            while (j < num_backslashes) : (j += 1) {
                try buf.append(alloc, '\\');
            }
            try buf.append(alloc, arg[i]);
        }
        i += 1;
    }
    try buf.append(alloc, '"');
}

fn needsQuoting(arg: []const u8) bool {
    for (arg) |ch| {
        switch (ch) {
            ' ', '\t', '"', '\\' => return true,
            else => {},
        }
    }
    return false;
}

/// Build a Unicode environment block for CreateProcessW.
/// The block is a sequence of null-terminated UTF-16 strings, terminated by
/// an extra null. `extra` entries are prepended (e.g. ZMX_SESSION=name).
pub fn buildEnvironmentBlock(
    alloc: std.mem.Allocator,
    extra: []const [2][]const u8,
) ![]u16 {
    var buf = std.ArrayList(u16).empty;
    defer buf.deinit(alloc);

    // Prepend extra entries
    for (extra) |kv| {
        const entry = try std.fmt.allocPrint(alloc, "{s}={s}", .{ kv[0], kv[1] });
        defer alloc.free(entry);
        const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, entry);
        defer alloc.free(wide);
        try buf.appendSlice(alloc, wide);
        try buf.append(alloc, 0); // null terminator for this entry
    }

    // Copy inherited environment
    const env_ptr = std.os.windows.kernel32.GetEnvironmentStringsW() orelse return error.OutOfMemory;
    defer _ = std.os.windows.kernel32.FreeEnvironmentStringsW(env_ptr);

    var p: [*]const u16 = env_ptr;
    while (true) {
        // Find end of current string
        var len: usize = 0;
        while (p[len] != 0) : (len += 1) {}
        if (len == 0) break; // double null = end of block
        try buf.appendSlice(alloc, p[0 .. len + 1]); // include null
        p = p + len + 1;
    }

    try buf.append(alloc, 0); // final terminating null
    return buf.toOwnedSlice(alloc);
}

// ─── Tests ───

test "buildCommandLine: simple args" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "/c", "echo", "hello" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe /c echo hello", utf8);
}

test "buildCommandLine: empty argument" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"\"", utf8);
}

test "buildCommandLine: spaces" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "hello world" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"hello world\"", utf8);
}

test "buildCommandLine: quotes" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "say \"hi\"" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"say \\\"hi\\\"\"", utf8);
}

test "buildCommandLine: trailing backslashes" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "C:\\path\\" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"C:\\path\\\\\"", utf8);
}

test "buildCommandLine: backslash before quote" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "a\\\"b" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"a\\\\\\\"b\"", utf8);
}

test "buildCommandLine: unicode" {
    const alloc = std.testing.allocator;
    const result = try buildCommandLine(alloc, &.{ "cmd.exe", "héllo wörld" });
    defer alloc.free(result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, result[0..std.mem.len(result)]);
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("cmd.exe \"héllo wörld\"", utf8);
}
