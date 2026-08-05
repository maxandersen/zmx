/// Raw Win32 API declarations not available in std.os.windows.
/// Keep this file minimal — only declare what zmx actually calls.
const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const WORD = windows.WORD;
pub const BYTE = windows.BYTE;
pub const HRESULT = windows.HRESULT;
pub const LPVOID = *anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const SIZE_T = usize;
pub const COORD = extern struct { X: c_short, Y: c_short };
pub const INFINITE = windows.INFINITE;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;

// --- Process creation flags ---
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const DETACHED_PROCESS: DWORD = 0x00000008;
pub const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;

// --- STARTUPINFOW flags ---
pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;

// --- Pipe constants ---
pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
pub const PIPE_ACCESS_INBOUND: DWORD = 0x00000001;
pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;
pub const PIPE_READMODE_BYTE: DWORD = 0x00000000;
pub const PIPE_WAIT: DWORD = 0x00000000;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
pub const NMPWAIT_USE_DEFAULT_WAIT: DWORD = 0x00000000;

// --- Generic access ---
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const OPEN_EXISTING: DWORD = 3;

// --- Job object ---
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK: DWORD = 0x00000800;
pub const JobObjectExtendedLimitInformation: c_int = 9;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: SIZE_T,
    MaximumWorkingSetSize: SIZE_T,
    ActiveProcessLimit: DWORD,
    Affinity: SIZE_T,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: SIZE_T,
    JobMemoryLimit: SIZE_T,
    PeakProcessMemoryUsed: SIZE_T,
    PeakJobMemoryUsed: SIZE_T,
};

// --- ConPTY ---
pub const HPCON = *anyopaque;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: SIZE_T = 0x00020016;

pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPWSTR = null,
    lpDesktop: ?LPWSTR = null,
    lpTitle: ?LPWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*BYTE = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{},
    lpAttributeList: ?LPVOID = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?LPVOID = null,
    bInheritHandle: BOOL = 0,
};

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

// --- Console ---
pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: extern struct { Left: c_short, Top: c_short, Right: c_short, Bottom: c_short },
    dwMaximumWindowSize: COORD,
};

// --- Extern function declarations ---
pub extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HPCON) callconv(.c) HRESULT;
pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.c) HRESULT;
pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.c) void;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?LPVOID,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *SIZE_T,
) callconv(.c) BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: LPVOID,
    dwFlags: DWORD,
    Attribute: SIZE_T,
    lpValue: ?LPVOID,
    cbSize: SIZE_T,
    lpPreviousValue: ?LPVOID,
    lpReturnSize: ?*SIZE_T,
) callconv(.c) BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: LPVOID) callconv(.c) void;

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?LPVOID,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) BOOL;

pub extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
) callconv(.c) HANDLE;

pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.c) BOOL;
pub extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.c) BOOL;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.c) HANDLE;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.c) BOOL;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.c) BOOL;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.c) BOOL;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*SECURITY_ATTRIBUTES,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?LPCWSTR,
) callconv(.c) ?HANDLE;

pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.c) BOOL;

pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(
    nCount: DWORD,
    lpHandles: [*]const HANDLE,
    bWaitAll: BOOL,
    dwMilliseconds: DWORD,
) callconv(.c) DWORD;

pub extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.c) BOOL;

pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.c) BOOL;

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
) callconv(.c) ?HANDLE;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: LPVOID,
    cbJobObjectInformationLength: DWORD,
) callconv(.c) BOOL;

pub extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: DWORD) callconv(.c) BOOL;

pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;
pub extern "kernel32" fn GetLastError() callconv(.c) DWORD;
pub extern "kernel32" fn GetUserNameW(lpBuffer: LPWSTR, pcbBuffer: *DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.c) BOOL;
pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.c) ?HANDLE;

pub const STD_INPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -10)));
pub const STD_OUTPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -11)));
pub const STD_ERROR_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -12)));

pub const ERROR_IO_PENDING: DWORD = 997;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;
pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_NO_DATA: DWORD = 232;
pub const ERROR_PIPE_NOT_CONNECTED: DWORD = 233;
pub const ERROR_OPERATION_ABORTED: DWORD = 995;
pub const ERROR_MORE_DATA: DWORD = 234;
pub const STILL_ACTIVE: DWORD = 259;

pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.c) BOOL;

pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;

/// Succeed or return the Win32 error as a Zig error.
pub fn hrSuccess(hr: HRESULT) !void {
    if (hr >= 0) return;
    return error.Win32Error;
}

pub fn closeHandleOpt(h: ?HANDLE) void {
    if (h) |handle| {
        if (handle != INVALID_HANDLE_VALUE) _ = CloseHandle(handle);
    }
}
