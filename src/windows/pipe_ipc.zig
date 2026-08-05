/// Windows Named Pipe IPC transport for zmx sessions.
///
/// Each session creates a named pipe endpoint:
///   \\.\pipe\zmx-<username>-<session_name>
///
/// Session metadata (for `zmx list`) lives in a per-user directory:
///   %LOCALAPPDATA%\zmx\sessions\<session_name>
const std = @import("std");
const win32 = @import("win32.zig");

/// Maximum pipe name length (the full \\.\pipe\... path).
pub const MAX_PIPE_NAME = 256;

/// Build a pipe path for a session: \\.\pipe\zmx-<username>-<session>
pub fn getPipePath(alloc: std.mem.Allocator, session_name: []const u8) ![:0]u16 {
    var user_buf: [256]u8 = undefined;
    const username = try getUsername(&user_buf);

    const path = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\zmx-{s}-{s}", .{ username, session_name });
    defer alloc.free(path);

    return std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
}

/// Get the current username as UTF-8.
pub fn getUsername(buf: *[256]u8) ![]const u8 {
    var wide_buf: [128]u16 = undefined;
    var size: u32 = wide_buf.len;
    if (win32.GetUserNameW(@ptrCast(&wide_buf), &size) == 0)
        return error.GetUserNameFailed;

    // size includes the null terminator
    const wide_slice = wide_buf[0 .. size - 1];
    const len = std.unicode.utf16LeToUtf8(buf, wide_slice) catch return error.Utf16ConversionFailed;
    return buf[0..len];
}

/// Create a named pipe server for a session.
/// Returns the pipe handle in overlapped mode ready for ConnectNamedPipe.
pub fn createServer(pipe_name: [:0]const u16) !win32.HANDLE {
    const handle = win32.CreateNamedPipeW(
        pipe_name.ptr,
        win32.PIPE_ACCESS_DUPLEX | win32.FILE_FLAG_OVERLAPPED | win32.FILE_FLAG_FIRST_PIPE_INSTANCE,
        win32.PIPE_TYPE_BYTE | win32.PIPE_READMODE_BYTE | win32.PIPE_WAIT,
        win32.PIPE_UNLIMITED_INSTANCES,
        65536, // out buffer
        65536, // in buffer
        0,
        null, // ponytail: default security is current-user-only for pipes
    );
    if (handle == win32.INVALID_HANDLE_VALUE)
        return error.CreatePipeFailed;
    return handle;
}

/// Create a new instance of the named pipe for accepting another client.
pub fn createServerInstance(pipe_name: [:0]const u16) !win32.HANDLE {
    const handle = win32.CreateNamedPipeW(
        pipe_name.ptr,
        win32.PIPE_ACCESS_DUPLEX | win32.FILE_FLAG_OVERLAPPED,
        win32.PIPE_TYPE_BYTE | win32.PIPE_READMODE_BYTE | win32.PIPE_WAIT,
        win32.PIPE_UNLIMITED_INSTANCES,
        65536,
        65536,
        0,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE)
        return error.CreatePipeFailed;
    return handle;
}

/// Connect to an existing session's named pipe (client side).
pub fn connectToSession(alloc: std.mem.Allocator, session_name: []const u8) !win32.HANDLE {
    const pipe_name = try getPipePath(alloc, session_name);
    defer alloc.free(pipe_name);

    const handle = win32.CreateFileW(
        pipe_name.ptr,
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        0,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) {
        const err = win32.GetLastError();
        if (err == 2) return error.FileNotFound; // ERROR_FILE_NOT_FOUND
        if (err == 231) return error.PipeBusy; // ERROR_PIPE_BUSY
        return error.ConnectionRefused;
    }
    return handle;
}

/// Check if a session pipe exists by trying to connect.
pub fn sessionExists(alloc: std.mem.Allocator, session_name: []const u8) bool {
    const handle = connectToSession(alloc, session_name) catch return false;
    _ = win32.CloseHandle(handle);
    return true;
}

/// Start an overlapped ConnectNamedPipe. Returns the OVERLAPPED struct.
/// The caller must provide an event handle.
pub fn beginAccept(pipe: win32.HANDLE, event: win32.HANDLE) !win32.OVERLAPPED {
    var ov = win32.OVERLAPPED{ .hEvent = event };
    if (win32.ConnectNamedPipe(pipe, &ov) != 0) {
        // Already connected
        return ov;
    }
    const err = win32.GetLastError();
    if (err == win32.ERROR_IO_PENDING) return ov; // normal: waiting
    if (err == win32.ERROR_PIPE_CONNECTED) return ov; // client was faster
    return error.ConnectNamedPipeFailed;
}

/// Read from a pipe handle (blocking).
pub fn pipeRead(handle: win32.HANDLE, buf: []u8) !usize {
    var read: u32 = 0;
    if (win32.ReadFile(handle, buf.ptr, @intCast(buf.len), &read, null) == 0) {
        const err = win32.GetLastError();
        if (err == win32.ERROR_BROKEN_PIPE or err == win32.ERROR_PIPE_NOT_CONNECTED)
            return 0; // EOF
        return error.ReadFailed;
    }
    return @intCast(read);
}

/// Write to a pipe handle (blocking, handles partial writes).
pub fn pipeWrite(handle: win32.HANDLE, data: []const u8) !usize {
    var written: u32 = 0;
    if (win32.WriteFile(handle, data.ptr, @intCast(data.len), &written, null) == 0) {
        const err = win32.GetLastError();
        if (err == win32.ERROR_BROKEN_PIPE or err == win32.ERROR_NO_DATA)
            return error.BrokenPipe;
        return error.WriteFailed;
    }
    return @intCast(written);
}

// --- Session metadata for `zmx list` ---

/// Get the session metadata directory path.
pub fn getSessionMetadataDir(alloc: std.mem.Allocator) ![]const u8 {
    const local_app = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch
        return error.NoLocalAppData;
    defer alloc.free(local_app);
    return std.fmt.allocPrint(alloc, "{s}\\zmx\\sessions", .{local_app});
}

/// Write session metadata file for `zmx list` discovery.
pub fn writeSessionMetadata(alloc: std.mem.Allocator, session_name: []const u8, pid: u32) !void {
    const dir_path = try getSessionMetadataDir(alloc);
    defer alloc.free(dir_path);

    // Ensure directory exists
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try to create parent too
            const parent = std.fs.path.dirname(dir_path) orelse return err;
            std.fs.makeDirAbsolute(parent) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
            std.fs.makeDirAbsolute(dir_path) catch |e3| switch (e3) {
                error.PathAlreadyExists => {},
                else => return e3,
            };
        },
    };

    const file_path = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir_path, session_name });
    defer alloc.free(file_path);

    const content = try std.fmt.allocPrint(alloc, "{d}", .{pid});
    defer alloc.free(content);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Remove session metadata.
pub fn removeSessionMetadata(alloc: std.mem.Allocator, session_name: []const u8) void {
    const dir_path = getSessionMetadataDir(alloc) catch return;
    defer alloc.free(dir_path);

    const file_path = std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir_path, session_name }) catch return;
    defer alloc.free(file_path);

    std.fs.deleteFileAbsolute(file_path) catch {};
}

/// List session names from metadata directory. Validates each by trying to connect.
pub fn listSessions(alloc: std.mem.Allocator) !std.ArrayList([]const u8) {
    var sessions = std.ArrayList([]const u8).empty;
    errdefer {
        for (sessions.items) |s| alloc.free(s);
        sessions.deinit(alloc);
    }

    const dir_path = getSessionMetadataDir(alloc) catch return sessions;
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return sessions;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(name);

        // Validate: try connecting
        if (sessionExists(alloc, name)) {
            try sessions.append(alloc, name);
        } else {
            // Stale entry — clean up
            removeSessionMetadata(alloc, name);
            alloc.free(name);
        }
    }

    return sessions;
}
