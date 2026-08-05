/// ConPTY backend — spawn a shell inside a Windows Pseudoconsole,
/// retain handles for read/write/resize/close.
const std = @import("std");
const win32 = @import("win32.zig");
const cmdline = @import("cmdline.zig");

pub const ConPty = struct {
    hpc: win32.HPCON,
    /// Host-side pipe: read ConPTY output from here
    pty_out_read: win32.HANDLE,
    /// Host-side pipe: write input to ConPTY here
    pty_in_write: win32.HANDLE,
    /// Child process handle
    process: win32.HANDLE,
    /// Child main thread handle
    thread: win32.HANDLE,
    /// Process ID
    pid: u32,
    /// Job object that owns the process tree
    job: ?win32.HANDLE,

    // ConPTY-internal handles we must keep alive until close
    pty_in_read: win32.HANDLE,
    pty_out_write: win32.HANDLE,

    // Attribute list allocation (we need to free it)
    attr_list_buf: []align(8) u8,
    alloc: std.mem.Allocator,

    pub fn spawn(
        alloc: std.mem.Allocator,
        args: []const []const u8,
        cwd: ?[]const u8,
        session_name: []const u8,
        cols: u16,
        rows: u16,
    ) !ConPty {
        // Create pipes for ConPTY
        var sa = win32.SECURITY_ATTRIBUTES{
            .bInheritHandle = 1, // ConPTY needs inheritable handles
        };

        var pty_in_read: win32.HANDLE = undefined;
        var pty_in_write: win32.HANDLE = undefined;
        if (win32.CreatePipe(&pty_in_read, &pty_in_write, &sa, 0) == 0)
            return error.CreatePipeFailed;
        errdefer {
            _ = win32.CloseHandle(pty_in_read);
            _ = win32.CloseHandle(pty_in_write);
        }

        var pty_out_read: win32.HANDLE = undefined;
        var pty_out_write: win32.HANDLE = undefined;
        if (win32.CreatePipe(&pty_out_read, &pty_out_write, &sa, 0) == 0)
            return error.CreatePipeFailed;
        errdefer {
            _ = win32.CloseHandle(pty_out_read);
            _ = win32.CloseHandle(pty_out_write);
        }

        // Create the pseudoconsole
        const size = win32.COORD{
            .X = @intCast(cols),
            .Y = @intCast(rows),
        };
        var hpc: win32.HPCON = undefined;
        try win32.hrSuccess(win32.CreatePseudoConsole(
            size,
            pty_in_read,
            pty_out_write,
            0,
            &hpc,
        ));
        errdefer win32.ClosePseudoConsole(hpc);

        // Prepare process attribute list
        var attr_size: usize = 0;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);

        const attr_buf = try alloc.alignedAlloc(u8, 8, attr_size);
        errdefer alloc.free(attr_buf);

        if (win32.InitializeProcThreadAttributeList(@ptrCast(attr_buf.ptr), 1, 0, &attr_size) == 0)
            return error.InitAttributeListFailed;

        if (win32.UpdateProcThreadAttribute(
            @ptrCast(attr_buf.ptr),
            0,
            win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpc,
            @sizeOf(win32.HPCON),
            null,
            null,
        ) == 0)
            return error.UpdateAttributeFailed;

        // Build command line
        const cmd_wide = try cmdline.buildCommandLine(alloc, args);
        defer alloc.free(cmd_wide);

        // Build environment block with ZMX_SESSION
        const extra = [_][2][]const u8{.{ "ZMX_SESSION", session_name }};
        const env_block = try cmdline.buildEnvironmentBlock(alloc, &extra);
        defer alloc.free(env_block);

        // Convert CWD to wide
        var cwd_wide_buf: ?[:0]u16 = null;
        defer if (cwd_wide_buf) |w| alloc.free(w);
        if (cwd) |c| {
            if (c.len > 0) {
                cwd_wide_buf = try std.unicode.utf8ToUtf16LeAllocZ(alloc, c);
            }
        }

        var si = win32.STARTUPINFOEXW{};
        si.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
        si.lpAttributeList = @ptrCast(attr_buf.ptr);

        var pi: win32.PROCESS_INFORMATION = undefined;

        if (win32.CreateProcessW(
            null,
            @constCast(cmd_wide.ptr),
            null,
            null,
            0, // don't inherit handles
            win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT,
            @ptrCast(env_block.ptr),
            if (cwd_wide_buf) |w| w.ptr else null,
            &si,
            &pi,
        ) == 0)
            return error.CreateProcessFailed;
        errdefer {
            _ = win32.CloseHandle(pi.hProcess);
            _ = win32.CloseHandle(pi.hThread);
        }

        // Create a Job Object for process-tree management
        const job = win32.CreateJobObjectW(null, null);
        if (job) |j| {
            var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags =
                win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
                win32.JOB_OBJECT_LIMIT_BREAKAWAY_OK;
            _ = win32.SetInformationJobObject(
                j,
                win32.JobObjectExtendedLimitInformation,
                @ptrCast(&info),
                @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
            );
            _ = win32.AssignProcessToJobObject(j, pi.hProcess);
        }

        return .{
            .hpc = hpc,
            .pty_out_read = pty_out_read,
            .pty_in_write = pty_in_write,
            .process = pi.hProcess,
            .thread = pi.hThread,
            .pid = pi.dwProcessId,
            .job = job,
            .pty_in_read = pty_in_read,
            .pty_out_write = pty_out_write,
            .attr_list_buf = attr_buf,
            .alloc = alloc,
        };
    }

    /// Write input bytes to the ConPTY (keyboard input from clients).
    pub fn writeInput(self: *ConPty, data: []const u8) !usize {
        var written: u32 = 0;
        if (win32.WriteFile(self.pty_in_write, data.ptr, @intCast(data.len), &written, null) == 0) {
            const err = win32.GetLastError();
            if (err == win32.ERROR_BROKEN_PIPE or err == win32.ERROR_NO_DATA)
                return error.BrokenPipe;
            return error.WriteFailed;
        }
        return @intCast(written);
    }

    /// Read output bytes from the ConPTY (shell output to clients).
    /// Blocks until data is available or the pipe breaks (child exit).
    pub fn readOutput(self: *ConPty, buf: []u8) !usize {
        var read: u32 = 0;
        if (win32.ReadFile(self.pty_out_read, buf.ptr, @intCast(buf.len), &read, null) == 0) {
            const err = win32.GetLastError();
            if (err == win32.ERROR_BROKEN_PIPE)
                return 0; // EOF
            return error.ReadFailed;
        }
        return @intCast(read);
    }

    pub fn resize(self: *ConPty, cols: u16, rows: u16) !void {
        const size = win32.COORD{
            .X = @intCast(cols),
            .Y = @intCast(rows),
        };
        try win32.hrSuccess(win32.ResizePseudoConsole(self.hpc, size));
    }

    /// Check if the child process has exited.
    pub fn isChildAlive(self: *ConPty) bool {
        var exit_code: u32 = 0;
        if (win32.GetExitCodeProcess(self.process, &exit_code) == 0) return false;
        return exit_code == win32.STILL_ACTIVE;
    }

    /// Wait for the child process to exit. Returns exit code.
    pub fn waitForChild(self: *ConPty, timeout_ms: u32) !?u32 {
        const result = win32.WaitForSingleObject(self.process, timeout_ms);
        if (result == win32.WAIT_TIMEOUT) return null;
        if (result == win32.WAIT_FAILED) return error.WaitFailed;
        var exit_code: u32 = 0;
        if (win32.GetExitCodeProcess(self.process, &exit_code) == 0)
            return error.GetExitCodeFailed;
        return exit_code;
    }

    /// Terminate the entire process tree via the job object.
    pub fn terminate(self: *ConPty) void {
        if (self.job) |j| {
            _ = win32.TerminateJobObject(j, 1);
        } else {
            _ = win32.TerminateProcess(self.process, 1);
        }
    }

    /// Close all handles. Must be called after the reader thread has stopped.
    pub fn close(self: *ConPty) void {
        // Order matters: close pseudoconsole first (signals EOF to pipes),
        // then close pipe handles, then process handles.
        win32.ClosePseudoConsole(self.hpc);

        _ = win32.CloseHandle(self.pty_in_write);
        _ = win32.CloseHandle(self.pty_out_read);
        _ = win32.CloseHandle(self.pty_in_read);
        _ = win32.CloseHandle(self.pty_out_write);

        win32.DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
        self.alloc.free(self.attr_list_buf);

        _ = win32.CloseHandle(self.process);
        _ = win32.CloseHandle(self.thread);

        if (self.job) |j| _ = win32.CloseHandle(j);
    }
};
