//! Native rich text colors without changing request text, caret, scroll or undo.
const std = @import("std");
const win = @import("win32.zig");
const theme = @import("theme.zig");
const json = @import("json_tokens.zig");
// Minimal richedit.h / tom.h ABI, matching the repository's Win32 bindings.
// Zig 0.17 no longer provides @cImport.
const c = struct {
    const HMODULE = win.Handle;
    extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) HMODULE;
    extern "kernel32" fn FreeLibrary(HMODULE) callconv(.winapi) i32;
    extern "ole32" fn OleInitialize(?*anyopaque) callconv(.winapi) i32;
    extern "ole32" fn OleUninitialize() callconv(.winapi) void;
    const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
    const IID_ITextDocument: Guid = .{ .a = 0x8cc497c0, .b = 0xa1df, .c = 0x11ce, .d = .{ 0x80, 0x98, 0x00, 0xaa, 0x00, 0x47, 0xbe, 0x5d } };
    const UnknownTable = extern struct {
        QueryInterface: *const fn (*IRichEditOle, *const Guid, *?*anyopaque) callconv(.winapi) i32,
        AddRef: *const fn (*IRichEditOle) callconv(.winapi) u32,
        Release: *const fn (*IRichEditOle) callconv(.winapi) u32,
    };
    const IRichEditOle = extern struct { lpVtbl: *const UnknownTable };
    const DocumentTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ITextDocument) callconv(.winapi) u32,
        // IDispatch (4), then GetName through EndEditCollection (15).
        unused: [19]*const anyopaque,
        Undo: *const fn (*ITextDocument, i32, ?*i32) callconv(.winapi) i32,
    };
    const ITextDocument = extern struct { lpVtbl: *const DocumentTable };
    const CHARRANGE = extern struct { cpMin: i32, cpMax: i32 };
    const GETTEXTEX = extern struct { cb: u32, flags: u32, codepage: u32, lpDefaultChar: ?[*]const u8, lpUsedDefChar: ?*i32 };
    const CHARFORMATW = extern struct {
        cbSize: u32,
        dwMask: u32,
        dwEffects: u32,
        yHeight: i32,
        yOffset: i32,
        crTextColor: u32,
        bCharSet: u8,
        bPitchAndFamily: u8,
        szFaceName: [32]u16,
    };
    const EM_EXGETSEL = 0x0434;
    const EM_EXLIMITTEXT = 0x0435;
    const EM_EXSETSEL = 0x0437;
    const EM_GETOLEINTERFACE = 0x043C;
    const EM_SETBKGNDCOLOR = 0x0443;
    const EM_SETCHARFORMAT = 0x0444;
    const EM_SETEVENTMASK = 0x0445;
    const EM_GETTEXTEX = 0x045E;
    const EM_GETSCROLLPOS = 0x04DD;
    const EM_SETSCROLLPOS = 0x04DE;
    const EM_GETMODIFY = 0x00B8;
    const EM_SETMODIFY = 0x00B9;
    const WM_SETREDRAW = 0x000B;
    const ENM_CHANGE = 1;
    const SCF_SELECTION = 1;
    const SCF_ALL = 4;
    const CFM_COLOR = 0x40000000;
    const GT_DEFAULT = 0;
    const GT_USECRLF = 1;
    const tomSuspend = -9999995;
    const tomResume = -9999994;
};
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Library = struct {
    module: c.HMODULE,
    initialized_ole: bool,

    pub fn init() ?Library {
        const module = c.LoadLibraryW(wide("Msftedit.dll")) orelse return null;
        return .{ .module = module, .initialized_ole = c.OleInitialize(null) >= 0 };
    }
    pub fn deinit(library: Library) void {
        if (library.initialized_ole) c.OleUninitialize();
        _ = c.FreeLibrary(library.module);
    }
};

pub fn configure(handle: win.Handle, editable: bool) void {
    _ = win.SendMessageW(handle, c.EM_SETBKGNDCOLOR, 0, @intCast(rgb(theme.background)));
    _ = win.SendMessageW(handle, c.EM_EXLIMITTEXT, 0, 65536);
    if (editable) _ = win.SendMessageW(handle, c.EM_SETEVENTMASK, 0, c.ENM_CHANGE);
    setColor(handle, c.SCF_ALL, theme.text);
}

/// Wire text uses Windows CRLF; highlighting uses Rich Edit's internal CR
/// positions, so a multiline string never shifts subsequent color ranges.
fn text(allocator: std.mem.Allocator, handle: win.Handle, crlf: bool) ![]u16 {
    const length = win.GetWindowTextLengthW(handle);
    const buffer = try allocator.alloc(u16, @as(usize, @intCast(length)) * (if (crlf) @as(usize, 2) else 1) + 1);
    errdefer allocator.free(buffer);
    const options: c.GETTEXTEX = .{ .cb = @intCast(buffer.len * 2), .flags = if (crlf) c.GT_USECRLF else c.GT_DEFAULT, .codepage = 1200, .lpDefaultChar = null, .lpUsedDefChar = null };
    const count = win.SendMessageW(handle, c.EM_GETTEXTEX, @intFromPtr(&options), @bitCast(@intFromPtr(buffer.ptr)));
    return allocator.realloc(buffer, @intCast(@max(0, count)));
}

/// Caller owns the UTF-8 result; temporary UTF-16 storage is released here.
pub fn read(allocator: std.mem.Allocator, handle: win.Handle) ![]const u8 {
    const content = try text(allocator, handle, true);
    defer allocator.free(content);
    return std.unicode.utf16LeToUtf8Alloc(allocator, content);
}

/// Best effort: if TOM is unavailable, keep the native editor functional rather
/// than applying formatting that could replace the user's undo history.
pub fn highlight(handle: win.Handle, enabled: bool) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const content = text(arena.allocator(), handle, false) catch return;
    var ole: ?*c.IRichEditOle = null;
    if (win.SendMessageW(handle, c.EM_GETOLEINTERFACE, 0, @bitCast(@intFromPtr(&ole))) == 0 or ole == null) return;
    defer _ = ole.?.lpVtbl.Release(ole.?);
    var document: ?*c.ITextDocument = null;
    if (ole.?.lpVtbl.QueryInterface(ole.?, &c.IID_ITextDocument, @ptrCast(&document)) < 0 or document == null) return;
    const doc = document.?;
    defer _ = doc.lpVtbl.Release(doc);
    if (doc.lpVtbl.Undo(doc, c.tomSuspend, null) < 0) return;
    defer _ = doc.lpVtbl.Undo(doc, c.tomResume, null);

    var selection: c.CHARRANGE = undefined;
    const focus = win.GetFocus();
    var scroll: win.Point = .{};
    _ = win.SendMessageW(handle, c.EM_EXGETSEL, 0, @bitCast(@intFromPtr(&selection)));
    _ = win.SendMessageW(handle, c.EM_GETSCROLLPOS, 0, @bitCast(@intFromPtr(&scroll)));
    const modified = win.SendMessageW(handle, c.EM_GETMODIFY, 0, 0);
    const events = win.SendMessageW(handle, c.EM_SETEVENTMASK, 0, 0);
    _ = win.SendMessageW(handle, c.WM_SETREDRAW, 0, 0);
    defer {
        _ = win.SendMessageW(handle, c.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&selection)));
        _ = win.SendMessageW(handle, c.EM_SETSCROLLPOS, 0, @bitCast(@intFromPtr(&scroll)));
        _ = win.SendMessageW(handle, c.EM_SETMODIFY, @intFromBool(modified != 0), 0);
        _ = win.SendMessageW(handle, c.EM_SETEVENTMASK, 0, events);
        _ = win.SendMessageW(handle, c.WM_SETREDRAW, 1, 0);
        _ = win.InvalidateRect(handle, null, 0);
        if (win.GetFocus() != focus) _ = win.SetFocus(focus);
    }
    setColor(handle, c.SCF_ALL, theme.text);
    if (!enabled or content.len > 32768) return;
    var lexer: json.Lexer = .{ .text = content };
    var count: usize = 0;
    while (lexer.next()) |token| {
        if (count == 4096) break;
        count += 1;
        const range: c.CHARRANGE = .{ .cpMin = @intCast(token.start), .cpMax = @intCast(token.end) };
        _ = win.SendMessageW(handle, c.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&range)));
        setColor(handle, c.SCF_SELECTION, switch (token.kind) {
            .key => theme.blue,
            .string => theme.string,
            .number => theme.amber,
            .literal => theme.purple,
        });
    }
}

fn setColor(handle: win.Handle, scope: usize, color: u32) void {
    var format = std.mem.zeroes(c.CHARFORMATW);
    format.cbSize = @sizeOf(c.CHARFORMATW);
    format.dwMask = c.CFM_COLOR;
    format.crTextColor = rgb(color);
    _ = win.SendMessageW(handle, c.EM_SETCHARFORMAT, scope, @bitCast(@intFromPtr(&format)));
}
fn rgb(argb: u32) u32 {
    return ((argb & 0xFF) << 16) | (argb & 0xFF00) | ((argb >> 16) & 0xFF);
}

test "native JSON colors preserve UTF-16 selection CRLF wire text and undo redo" {
    const library = Library.init() orelse return error.SkipZigTest;
    defer library.deinit();
    const handle = win.CreateWindowExW(0, wide("RICHEDIT50W"), wide(""), win.ES_MULTILINE, 0, 0, 320, 200, null, null, win.GetModuleHandleW(null), null) orelse return error.CreateControlFailed;
    defer _ = win.DestroyWindow(handle);
    configure(handle, true);
    const original = "{\r\n  \"x\": \"😀\",\r\n  \"n\": 42\r\n}";
    _ = win.SetWindowTextW(handle, wide(original));
    _ = win.SendMessageW(handle, 0x00CD, 0, 0); // EM_EMPTYUNDOBUFFER
    _ = win.SendMessageW(handle, win.EM_SETSEL, 0, 0);
    _ = win.SendMessageW(handle, 0x00C2, 1, @bitCast(@intFromPtr(wide(" ")))); // EM_REPLACESEL
    const selection: c.CHARRANGE = .{ .cpMin = 11, .cpMax = 15 };
    _ = win.SendMessageW(handle, c.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&selection)));
    highlight(handle, true);
    var actual: c.CHARRANGE = undefined;
    _ = win.SendMessageW(handle, c.EM_EXGETSEL, 0, @bitCast(@intFromPtr(&actual)));
    try std.testing.expectEqual(selection, actual);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const owned_wire = try read(std.testing.allocator, handle);
    defer std.testing.allocator.free(owned_wire);
    try std.testing.expectEqualStrings(" " ++ original, owned_wire);
    // Inspect a key's color so a missing TOM interface cannot silently pass.
    const key: c.CHARRANGE = .{ .cpMin = 5, .cpMax = 8 };
    _ = win.SendMessageW(handle, c.EM_EXSETSEL, 0, @bitCast(@intFromPtr(&key)));
    var format = std.mem.zeroes(c.CHARFORMATW);
    format.cbSize = @sizeOf(c.CHARFORMATW);
    _ = win.SendMessageW(handle, 0x043A, c.SCF_SELECTION, @bitCast(@intFromPtr(&format))); // EM_GETCHARFORMAT
    try std.testing.expectEqual(rgb(theme.blue), format.crTextColor);
    try std.testing.expect(win.SendMessageW(handle, 0x00C6, 0, 0) != 0); // EM_CANUNDO
    _ = win.SendMessageW(handle, 0x00C7, 0, 0); // EM_UNDO
    highlight(handle, true);
    try std.testing.expectEqualStrings(original, try read(arena.allocator(), handle));
    _ = win.SendMessageW(handle, 0x0454, 0, 0); // EM_REDO
    highlight(handle, false);
    try std.testing.expectEqualStrings(" " ++ original, try read(arena.allocator(), handle));
    _ = win.SendMessageW(handle, 0x043A, c.SCF_SELECTION, @bitCast(@intFromPtr(&format)));
    try std.testing.expectEqual(rgb(theme.text), format.crTextColor);
}
