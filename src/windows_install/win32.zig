//! The Win32 surface the setup program, launcher and uninstaller use,
//! declared here so the program links nothing beyond the system DLLs.

const std = @import("std");

pub const HANDLE = std.os.windows.HANDLE;
pub const HKEY = *opaque {};
pub const HWND = *opaque {};
pub const DWORD = u32;
pub const BOOL = i32;
pub const HRESULT = i32;
pub const WCHAR = u16;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn parse(comptime text: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        var guid: GUID = undefined;
        guid.data1 = std.fmt.parseInt(u32, text[0..8], 16) catch unreachable;
        guid.data2 = std.fmt.parseInt(u16, text[9..13], 16) catch unreachable;
        guid.data3 = std.fmt.parseInt(u16, text[14..18], 16) catch unreachable;
        guid.data4[0] = std.fmt.parseInt(u8, text[19..21], 16) catch unreachable;
        guid.data4[1] = std.fmt.parseInt(u8, text[21..23], 16) catch unreachable;
        for (0..6) |index| {
            guid.data4[2 + index] = std.fmt.parseInt(u8, text[24 + 2 * index ..][0..2], 16) catch unreachable;
        }
        return guid;
    }
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: DWORD,
};

/// PROPVARIANT, 16 bytes on 32-bit and 24 bytes on 64-bit Windows; only
/// the VT_LPWSTR form is used here.
pub const PROPVARIANT = extern struct {
    vt: u16,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    value: [2]usize = .{ 0, 0 },
};

/// The longest path the wide-character file APIs accept.
pub const MAX_PATH_WIDE: usize = 32768;

pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_READ: DWORD = 0x20019;
pub const KEY_WRITE: DWORD = 0x20006;
pub const REG_SZ: DWORD = 1;
pub const REG_DWORD: DWORD = 4;
pub const ERROR_SUCCESS: i32 = 0;
pub const ERROR_FILE_NOT_FOUND: i32 = 2;

pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const SYNCHRONIZE: DWORD = 0x0010_0000;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x400;
pub const CREATE_NO_WINDOW: DWORD = 0x0800_0000;

pub const MB_OK: u32 = 0x0;
pub const MB_RETRYCANCEL: u32 = 0x5;
pub const MB_YESNO: u32 = 0x4;
pub const MB_ICONERROR: u32 = 0x10;
pub const MB_ICONQUESTION: u32 = 0x20;
pub const MB_SETFOREGROUND: u32 = 0x10000;
pub const IDYES: i32 = 6;
pub const IDRETRY: i32 = 4;

pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
pub const SHCNE_ASSOCCHANGED: i32 = 0x0800_0000;
pub const SHCNF_IDLIST: u32 = 0;
pub const VT_LPWSTR: u16 = 31;
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
pub const MOVEFILE_WRITE_THROUGH: DWORD = 0x8;

pub const FOLDERID_LocalAppData = GUID.parse("F1B32785-6FBA-4FCF-9D55-7B8E7F157091");
/// The current user's Start menu Programs folder.
pub const FOLDERID_Programs = GUID.parse("A77F5D77-2E2B-44C3-A6A2-ABA601054A51");
pub const CLSID_ShellLink = GUID.parse("00021401-0000-0000-C000-000000000046");
pub const IID_IShellLinkW = GUID.parse("000214F9-0000-0000-C000-000000000046");
pub const IID_IPersistFile = GUID.parse("0000010B-0000-0000-C000-000000000046");
pub const IID_IPropertyStore = GUID.parse("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
pub const PKEY_AppUserModel_ID: PROPERTYKEY = .{ .fmtid = GUID.parse("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), .pid = 5 };

pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

pub const IShellLinkW = extern struct {
    vtable: *const Vtbl,
    pub const Vtbl = extern struct {
        unknown: IUnknownVtbl,
        GetPath: *const anyopaque,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetArguments: *const anyopaque,
        SetArguments: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const fn (*IShellLinkW, [*:0]const u16, i32) callconv(.winapi) HRESULT,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*IShellLinkW, [*:0]const u16) callconv(.winapi) HRESULT,
    };
};

pub const IPersistFile = extern struct {
    vtable: *const Vtbl,
    pub const Vtbl = extern struct {
        unknown: IUnknownVtbl,
        GetClassID: *const anyopaque,
        IsDirty: *const anyopaque,
        Load: *const anyopaque,
        Save: *const fn (*IPersistFile, [*:0]const u16, BOOL) callconv(.winapi) HRESULT,
        SaveCompleted: *const anyopaque,
        GetCurFile: *const anyopaque,
    };
};

pub const IPropertyStore = extern struct {
    vtable: *const Vtbl,
    pub const Vtbl = extern struct {
        unknown: IUnknownVtbl,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        GetValue: *const anyopaque,
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
        Commit: *const fn (*IPropertyStore) callconv(.winapi) HRESULT,
    };
};

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HANDLE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn K32EnumProcesses(lpidProcess: [*]DWORD, cb: DWORD, lpcbNeeded: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CopyFileW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, bFailIfExists: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: ?[*:0]const u16, dwFlags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetTempPathW(nBufferLength: DWORD, lpBuffer: [*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetSystemDirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

pub extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: u32) callconv(.winapi) i32;
pub extern "user32" fn AllowSetForegroundWindow(dwProcessId: DWORD) callconv(.winapi) BOOL;

pub extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, dwFlags: DWORD, hToken: ?HANDLE, ppszPath: *?[*:0]u16) callconv(.winapi) HRESULT;
pub extern "shell32" fn SHChangeNotify(wEventId: i32, uFlags: u32, dwItem1: ?*const anyopaque, dwItem2: ?*const anyopaque) callconv(.winapi) void;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: DWORD, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

pub extern "advapi32" fn RegCreateKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, Reserved: DWORD, lpClass: ?[*:0]const u16, dwOptions: DWORD, samDesired: DWORD, lpSecurityAttributes: ?*anyopaque, phkResult: *HKEY, lpdwDisposition: ?*DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: DWORD, samDesired: DWORD, phkResult: *HKEY) callconv(.winapi) i32;
pub extern "advapi32" fn RegSetValueExW(hKey: HKEY, lpValueName: ?[*:0]const u16, Reserved: DWORD, dwType: DWORD, lpData: [*]const u8, cbData: DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: ?[*:0]const u16, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteValueW(hKey: HKEY, lpValueName: ?[*:0]const u16) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteTreeW(hKey: HKEY, lpSubKey: ?[*:0]const u16) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteKeyW(hKey: HKEY, lpSubKey: [*:0]const u16) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryInfoKeyW(
    hKey: HKEY,
    lpClass: ?[*]u16,
    lpcchClass: ?*DWORD,
    lpReserved: ?*DWORD,
    lpcSubKeys: ?*DWORD,
    lpcbMaxSubKeyLen: ?*DWORD,
    lpcbMaxClassLen: ?*DWORD,
    lpcValues: ?*DWORD,
    lpcbMaxValueNameLen: ?*DWORD,
    lpcbMaxValueLen: ?*DWORD,
    lpcbSecurityDescriptor: ?*DWORD,
    lpftLastWriteTime: ?*anyopaque,
) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

test "GUIDs parse from their registry form" {
    const guid = GUID.parse("00021401-0000-0000-C000-000000000046");
    try std.testing.expectEqual(@as(u32, 0x00021401), guid.data1);
    try std.testing.expectEqual(@as(u8, 0xC0), guid.data4[0]);
    try std.testing.expectEqual(@as(u8, 0x46), guid.data4[7]);
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 16), @sizeOf(PROPVARIANT));
}
