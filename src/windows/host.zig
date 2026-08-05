/// Windows session host — the detached process that owns the ConPTY,
/// accepts client connections via Named Pipe, and relays I/O.
///
/// Concurrency model:
///   - Main thread: event loop using WaitForMultipleObjects
///   - ConPTY reader thread: blocking ReadFile on pty_out_read,
///     signals main thread via an event when data arrives
///   - Per-client: reads are interleaved on main thread via
///     overlapped I/O; writes are blocking (serialized)
///
/// The reader thread is necessary because ConPTY output uses anonymous
/// pipes which don't support overlapped I/O on the read end. The thread
/// reads into a shared buffer protected by a mutex, then signals an
/// event so the main loop can consume it.
const std = @import("std");
const win32 = @import("win32.zig");
const conpty = @import("conpty.zig");
const pipe_ipc = @import("pipe_ipc.zig");
const cmdline = @import("cmdline.zig");

/// Launch a detached session-host process.
/// Returns true if we are the client (host was spawned), false if error.
pub fn launchHost(
    alloc: std.mem.Allocator,
    session_name: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) !void {
    // Build the host command: zmx.exe __host <session_name> [-- args...]
    var host_args = std.ArrayList([]const u8).empty;
    defer host_args.deinit(alloc);

    // Get our own executable path
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_buf);
    try host_args.append(alloc, exe_path);
    try host_args.append(alloc, "__host");
    try host_args.append(alloc, session_name);

    if (args.len > 0) {
        try host_args.append(alloc, "--");
        for (args) |arg| {
            try host_args.append(alloc, arg);
        }
    }

    const cmd_wide = try cmdline.buildCommandLine(alloc, host_args.items);
    defer alloc.free(cmd_wide);

    var cwd_wide: ?[:0]u16 = null;
    defer if (cwd_wide) |w| alloc.free(w);
    if (cwd.len > 0) {
        cwd_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cwd);
    }

    var si = std.mem.zeroes(win32.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);

    var pi: win32.PROCESS_INFORMATION = undefined;

    if (win32.CreateProcessW(
        null,
        @constCast(cmd_wide.ptr),
        null,
        null,
        0,
        win32.CREATE_NO_WINDOW | win32.CREATE_NEW_PROCESS_GROUP | win32.CREATE_UNICODE_ENVIRONMENT,
        null, // inherit environment
        if (cwd_wide) |w| w.ptr else null,
        &si,
        &pi,
    ) == 0)
        return error.CreateProcessFailed;

    // We don't need these handles in the client
    _ = win32.CloseHandle(pi.hProcess);
    _ = win32.CloseHandle(pi.hThread);
}

/// Entry point for the session host process (invoked as `zmx __host <session_name>`).
/// This runs in a detached process with no console.
pub fn hostMain(
    alloc: std.mem.Allocator,
    session_name: []const u8,
    shell_args: []const []const u8,
    cwd: ?[]const u8,
    cols: u16,
    rows: u16,
) !void {
    // Prevent recursive host creation
    if (std.process.getEnvVarOwned(alloc, "ZMX_HOST_GUARD")) |v| {
        alloc.free(v);
        return error.RecursiveHostDetected;
    } else |_| {}

    // Determine shell command
    var cmd_args = std.ArrayList([]const u8).empty;
    defer cmd_args.deinit(alloc);

    if (shell_args.len > 0) {
        for (shell_args) |arg| try cmd_args.append(alloc, arg);
    } else {
        // Default shell resolution
        const shell = std.process.getEnvVarOwned(alloc, "SHELL") catch
            std.process.getEnvVarOwned(alloc, "COMSPEC") catch
            null;
        defer if (shell) |s| alloc.free(s);
        try cmd_args.append(alloc, shell orelse "cmd.exe");
    }

    // Spawn ConPTY
    var pty = try conpty.ConPty.spawn(
        alloc,
        cmd_args.items,
        cwd,
        session_name,
        cols,
        rows,
    );
    defer pty.close();

    // Write session metadata for `zmx list`
    pipe_ipc.writeSessionMetadata(alloc, session_name, pty.pid) catch |err| {
        std.log.warn("failed to write session metadata: {s}", .{@errorName(err)});
    };
    defer pipe_ipc.removeSessionMetadata(alloc, session_name);

    // Create the named pipe endpoint
    const pipe_name = try pipe_ipc.getPipePath(alloc, session_name);
    defer alloc.free(pipe_name);

    // Run the session event loop
    try sessionLoop(alloc, &pty, pipe_name, session_name);
}

/// The core session event loop.
///
/// Uses a ConPTY reader thread + WaitForMultipleObjects pattern.
/// The reader thread does blocking ReadFile on the ConPTY output pipe
/// (anonymous pipes don't support overlapped I/O) and signals an event
/// when data arrives. The main thread then distributes it to clients.
fn sessionLoop(
    alloc: std.mem.Allocator,
    pty: *conpty.ConPty,
    pipe_name: [:0]const u16,
    _: []const u8,
) !void {
    // Events for WaitForMultipleObjects
    const pty_data_event = win32.CreateEventW(null, 1, 0, null) orelse // manual reset
        return error.CreateEventFailed;
    defer _ = win32.CloseHandle(pty_data_event);

    const accept_event = win32.CreateEventW(null, 1, 0, null) orelse
        return error.CreateEventFailed;
    defer _ = win32.CloseHandle(accept_event);

    // Shared buffer for ConPTY output
    var pty_mutex: std.Thread.Mutex = .{};
    var pty_buf = try std.ArrayList(u8).initCapacity(alloc, 65536);
    defer pty_buf.deinit(alloc);
    var pty_eof = false;

    // Reader thread
    const ReaderCtx = struct {
        pty_ref: *conpty.ConPty,
        buf: *std.ArrayList(u8),
        mutex: *std.Thread.Mutex,
        event: win32.HANDLE,
        eof: *bool,
        alloc: std.mem.Allocator,
    };

    var reader_ctx = ReaderCtx{
        .pty_ref = pty,
        .buf = &pty_buf,
        .mutex = &pty_mutex,
        .event = pty_data_event,
        .eof = &pty_eof,
        .alloc = alloc,
    };

    const reader_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *ReaderCtx) void {
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = ctx.pty_ref.readOutput(&tmp) catch break;
                if (n == 0) break; // EOF

                ctx.mutex.lock();
                ctx.buf.appendSlice(ctx.alloc, tmp[0..n]) catch {};
                ctx.mutex.unlock();

                _ = win32.SetEvent(ctx.event);
            }
            ctx.mutex.lock();
            ctx.eof.* = true;
            ctx.mutex.unlock();
            _ = win32.SetEvent(ctx.event);
        }
    }.run, .{&reader_ctx});
    defer reader_thread.join();

    // Create first pipe instance and start accepting
    var listen_pipe = try pipe_ipc.createServer(pipe_name);
    var accept_ov = try pipe_ipc.beginAccept(listen_pipe, accept_event);

    const Client = struct {
        pipe: win32.HANDLE,
        write_buf: std.ArrayList(u8),
        read_buf: std.ArrayList(u8),
        is_initialized: bool,
    };

    var clients = std.ArrayList(*Client).empty;
    defer {
        for (clients.items) |c| {
            _ = win32.CloseHandle(c.pipe);
            c.write_buf.deinit(alloc);
            c.read_buf.deinit(alloc);
            alloc.destroy(c);
        }
        clients.deinit(alloc);
    }

    // Input buffer for PTY
    var pty_input_buf = std.ArrayList(u8).empty;
    defer pty_input_buf.deinit(alloc);

    var running = true;

    while (running) {
        // Build wait array: [pty_data_event, accept_event, child_process]
        var handles: [3]win32.HANDLE = undefined;
        handles[0] = pty_data_event;
        handles[1] = accept_event;
        handles[2] = pty.process;

        const result = win32.WaitForMultipleObjects(3, &handles, 0, 100); // 100ms timeout for client I/O

        if (result == win32.WAIT_OBJECT_0) {
            // ConPTY data available
            _ = win32.ResetEvent(pty_data_event);

            pty_mutex.lock();
            const data = alloc.dupe(u8, pty_buf.items) catch {
                pty_mutex.unlock();
                continue;
            };
            pty_buf.clearRetainingCapacity();
            const is_eof = pty_eof;
            pty_mutex.unlock();
            defer alloc.free(data);

            if (data.len > 0) {
                // Broadcast to all clients
                var i: usize = clients.items.len;
                while (i > 0) {
                    i -= 1;
                    const client = clients.items[i];
                    // Build IPC message: [tag:1][len:4][payload]
                    const ipc_header = @import("../ipc.zig");
                    ipc_header.appendMessage(alloc, &client.write_buf, .Output, data) catch {
                        // Remove dead client
                        _ = win32.CloseHandle(client.pipe);
                        client.write_buf.deinit(alloc);
                        client.read_buf.deinit(alloc);
                        alloc.destroy(client);
                        _ = clients.orderedRemove(i);
                        continue;
                    };

                    // Flush write buffer
                    flushClient(client) catch {
                        _ = win32.CloseHandle(client.pipe);
                        client.write_buf.deinit(alloc);
                        client.read_buf.deinit(alloc);
                        alloc.destroy(client);
                        _ = clients.orderedRemove(i);
                    };
                }
            }

            if (is_eof) {
                running = false;
            }
        } else if (result == win32.WAIT_OBJECT_0 + 1) {
            // New client connected
            _ = win32.ResetEvent(accept_event);

            // Check if connect succeeded
            var bytes_transferred: u32 = 0;
            if (win32.GetOverlappedResult(listen_pipe, &accept_ov, &bytes_transferred, 0) != 0 or
                win32.GetLastError() == win32.ERROR_PIPE_CONNECTED)
            {
                const client = try alloc.create(Client);
                client.* = .{
                    .pipe = listen_pipe,
                    .write_buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
                    .read_buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
                    .is_initialized = false,
                };
                try clients.append(alloc, client);
            }

            // Create next pipe instance for accepting
            listen_pipe = pipe_ipc.createServerInstance(pipe_name) catch break;
            accept_ov = pipe_ipc.beginAccept(listen_pipe, accept_event) catch break;
        } else if (result == win32.WAIT_OBJECT_0 + 2) {
            // Child process exited
            running = false;
        }

        // Poll all clients for incoming data (non-blocking reads)
        {
            var i: usize = clients.items.len;
            while (i > 0) {
                i -= 1;
                const client = clients.items[i];

                // Try non-blocking read
                var tmp: [4096]u8 = undefined;
                const n = pipe_ipc.pipeRead(client.pipe, &tmp) catch {
                    // Client disconnected
                    _ = win32.CloseHandle(client.pipe);
                    client.write_buf.deinit(alloc);
                    client.read_buf.deinit(alloc);
                    alloc.destroy(client);
                    _ = clients.orderedRemove(i);
                    continue;
                };

                if (n == 0) {
                    // Client disconnected
                    _ = win32.CloseHandle(client.pipe);
                    client.write_buf.deinit(alloc);
                    client.read_buf.deinit(alloc);
                    alloc.destroy(client);
                    _ = clients.orderedRemove(i);
                    continue;
                }

                client.read_buf.appendSlice(alloc, tmp[0..n]) catch continue;

                // Process IPC messages from client
                processClientMessages(alloc, client, pty, &pty_input_buf) catch {};
            }
        }

        // Flush PTY input
        if (pty_input_buf.items.len > 0) {
            var offset: usize = 0;
            while (offset < pty_input_buf.items.len) {
                const written = pty.writeInput(pty_input_buf.items[offset..]) catch break;
                offset += written;
            }
            pty_input_buf.clearRetainingCapacity();
        }
    }

    // Cleanup: close the listening pipe
    _ = win32.CloseHandle(listen_pipe);
}

fn flushClient(client: anytype) !void {
    while (client.write_buf.items.len > 0) {
        const n = try pipe_ipc.pipeWrite(client.pipe, client.write_buf.items);
        if (n == 0) break;
        const alloc_ref = client.write_buf.allocator orelse std.heap.c_allocator;
        _ = alloc_ref;
        // Shift buffer manually
        const remaining = client.write_buf.items.len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, client.write_buf.items[0..remaining], client.write_buf.items[n..]);
        }
        client.write_buf.items.len = remaining;
    }
}

fn processClientMessages(
    alloc: std.mem.Allocator,
    client: anytype,
    pty: *conpty.ConPty,
    pty_input: *std.ArrayList(u8),
) !void {
    const ipc = @import("../ipc.zig");

    while (true) {
        const available = client.read_buf.items;
        const total = ipc.expectedLength(available) orelse break;
        if (available.len < total) break;

        const hdr = std.mem.bytesToValue(ipc.Header, available[0..@sizeOf(ipc.Header)]);
        const payload = available[@sizeOf(ipc.Header)..total];

        switch (hdr.tag) {
            .Input => {
                try pty_input.appendSlice(alloc, payload);
            },
            .Send => {
                try pty_input.appendSlice(alloc, payload);
            },
            .Resize => {
                if (payload.len == @sizeOf(ipc.Resize)) {
                    const resize = std.mem.bytesToValue(ipc.Resize, payload[0..@sizeOf(ipc.Resize)]);
                    pty.resize(resize.cols, resize.rows) catch {};
                }
            },
            .Init => {
                client.is_initialized = true;
                if (payload.len == @sizeOf(ipc.Resize)) {
                    const resize = std.mem.bytesToValue(ipc.Resize, payload[0..@sizeOf(ipc.Resize)]);
                    pty.resize(resize.cols, resize.rows) catch {};
                }
            },
            .Kill => {
                pty.terminate();
            },
            .Detach => {
                // Client wants to detach — do nothing, they'll close the pipe
            },
            .DetachAll => {
                // Detach all — close all client connections
            },
            .Info => {
                var info = std.mem.zeroes(ipc.Info);
                info.pid = @intCast(pty.pid);
                info.clients_len = @intCast(if (client.is_initialized) 0 else 0); // ponytail: simplified
                try ipc.appendMessage(alloc, &client.write_buf, .Info, std.mem.asBytes(&info));
            },
            .History => {
                // ponytail: send empty history for now, terminal state serialization is complex
                try ipc.appendMessage(alloc, &client.write_buf, .History, "");
            },
            else => {},
        }

        // Advance read buffer
        const remaining = available.len - total;
        if (remaining > 0) {
            std.mem.copyForwards(u8, client.read_buf.items[0..remaining], client.read_buf.items[total..]);
        }
        client.read_buf.items.len = remaining;
    }
}
