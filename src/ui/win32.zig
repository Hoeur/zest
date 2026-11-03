//! The few Win32 and GDI+ declarations the desktop app needs.

pub const Handle = ?*anyopaque;

pub const Point = extern struct { x: i32 = 0, y: i32 = 0 };
pub const Rect = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

pub const WndProc = *const fn (Handle, u32, usize, isize) callconv(.winapi) isize;

pub const WndClassEx = extern struct {
    cbSize: u32 = @sizeOf(WndClassEx),
    style: u32 = 0,
    lpfnWndProc: WndProc,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: Handle,
    hIcon: Handle = null,
    hCursor: Handle = null,
    hbrBackground: Handle = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: Handle = null,
};

pub const Msg = extern struct {
    hwnd: Handle = null,
    message: u32 = 0,
    wParam: usize = 0,
    lParam: isize = 0,
    time: u32 = 0,
    pt: Point = .{},
};

pub const PaintStruct = extern struct {
    hdc: Handle = null,
    fErase: i32 = 0,
    rcPaint: Rect = .{},
    fRestore: i32 = 0,
    fIncUpdate: i32 = 0,
    rgbReserved: [32]u8 = @splat(0),
};

pub const MinMaxInfo = extern struct {
    ptReserved: Point,
    ptMaxSize: Point,
    ptMaxPosition: Point,
    ptMinTrackSize: Point,
    ptMaxTrackSize: Point,
};

pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_PAINT = 0x000F;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_CAPTURECHANGED = 0x0215;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_COMMAND = 0x0111;
pub const WM_DRAWITEM = 0x002B;
pub const BS_OWNERDRAW = 0x000B;
pub const DrawItemStruct = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemAction: u32,
    itemState: u32,
    hwndItem: Handle,
    hDC: Handle,
    rcItem: Rect,
    itemData: usize,
};
pub const WM_TIMER = 0x0113;
pub const WM_KEYDOWN = 0x0100;
pub const WM_SETFONT = 0x0030;
pub const WM_CTLCOLOREDIT = 0x0133;
pub const WM_CTLCOLORLISTBOX = 0x0134;
pub const WM_CTLCOLORSTATIC = 0x0138;
pub const CB_ADDSTRING = 0x0143;
pub const CB_GETCURSEL = 0x0147;
pub const CB_SETCURSEL = 0x014E;
pub const EM_SETLIMITTEXT = 0x00C5;
pub const EM_SETSEL = 0x00B1;
pub const VK_RETURN = 0x0D;
pub const VK_TAB = 0x09;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const WS_CHILD = 0x40000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_TABSTOP = 0x00010000;
pub const WS_VSCROLL = 0x00200000;
pub const ES_AUTOHSCROLL = 0x0080;
pub const ES_MULTILINE = 0x0004;
pub const ES_AUTOVSCROLL = 0x0040;
pub const ES_READONLY = 0x0800;
pub const ES_WANTRETURN = 0x1000;
pub const CBN_SELCHANGE = 1;
pub const EN_CHANGE = 0x0300;
pub const CBS_DROPDOWNLIST = 0x0003;
pub const SW_HIDE = 0;
pub const ES_PASSWORD = 0x0020;
pub const EM_SETPASSWORDCHAR = 0x00CC;
pub const WM_APP = 0x8000;
pub const WM_MOUSELEAVE = 0x02A3;
pub const TME_LEAVE = 0x0002;
pub const CB_GETDROPPEDSTATE = 0x0157;
pub const TrackMouseEventInfo = extern struct {
    cbSize: u32 = 0,
    dwFlags: u32 = 0,
    hwndTrack: Handle = null,
    dwHoverTime: u32 = 0,
};
pub const EN_VSCROLL = 0x0602;
pub const EM_GETSEL = 0x00B0;
pub const EM_GETLINECOUNT = 0x00BA;
pub const EM_LINEINDEX = 0x00BB;
pub const EM_REPLACESEL = 0x00C2;
pub const EM_LINEFROMCHAR = 0x00C9;
pub const EM_GETFIRSTVISIBLELINE = 0x00CE;
pub const EM_POSFROMCHAR = 0x00D6;
pub const MF_STRING = 0x0000;
pub const MF_GRAYED = 0x0001;
pub const MF_CHECKED = 0x0008;
pub const MF_SEPARATOR = 0x0800;
pub const TPM_RETURNCMD = 0x0100;
pub const TPM_NONOTIFY = 0x0080;
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;
pub const FileTime = extern struct { low: u32 = 0, high: u32 = 0 };
pub const SystemTime = extern struct {
    year: u16 = 0,
    month: u16 = 0,
    day_of_week: u16 = 0,
    day: u16 = 0,
    hour: u16 = 0,
    minute: u16 = 0,
    second: u16 = 0,
    milliseconds: u16 = 0,
};
pub const CB_GETCOUNT = 0x0146;

pub const OpenFileName = extern struct {
    lStructSize: u32 = @sizeOf(OpenFileName),
    hwndOwner: Handle = null,
    hInstance: Handle = null,
    lpstrFilter: ?[*]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: isize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};
pub const OFN_OVERWRITEPROMPT = 0x00000002;
pub const OFN_NOCHANGEDIR = 0x00000008;
pub const OFN_PATHMUSTEXIST = 0x00000800;
pub const OFN_FILEMUSTEXIST = 0x00001000;
pub const OFN_EXPLORER = 0x00080000;

pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOW = 5;
pub const SRCCOPY = 0x00CC0020;
pub const IDC_ARROW = 32512;
pub const IDC_HAND = 32649;
pub const IDI_APP = 1;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) Handle;

pub extern "user32" fn RegisterClassExW(class: *const WndClassEx) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: Handle, menu: Handle, instance: Handle, param: ?*anyopaque) callconv(.winapi) Handle;
pub extern "user32" fn DefWindowProcW(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;
pub extern "user32" fn ShowWindow(hwnd: Handle, cmd: i32) callconv(.winapi) i32;
pub extern "user32" fn GetMessageW(msg: *Msg, hwnd: Handle, min: u32, max: u32) callconv(.winapi) i32;
pub extern "user32" fn TranslateMessage(msg: *const Msg) callconv(.winapi) i32;
pub extern "user32" fn DispatchMessageW(msg: *const Msg) callconv(.winapi) isize;
pub extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
pub extern "user32" fn InvalidateRect(hwnd: Handle, rect: ?*const Rect, erase: i32) callconv(.winapi) i32;
pub extern "user32" fn BeginPaint(hwnd: Handle, paint: *PaintStruct) callconv(.winapi) Handle;
pub extern "user32" fn EndPaint(hwnd: Handle, paint: *const PaintStruct) callconv(.winapi) i32;
pub extern "user32" fn GetClientRect(hwnd: Handle, rect: *Rect) callconv(.winapi) i32;
pub extern "user32" fn LoadCursorW(instance: Handle, name: usize) callconv(.winapi) Handle;
pub extern "user32" fn SetCursor(cursor: Handle) callconv(.winapi) Handle;
pub extern "user32" fn LoadIconW(instance: Handle, name: usize) callconv(.winapi) Handle;
pub extern "user32" fn SetWindowPos(hwnd: Handle, after: Handle, x: i32, y: i32, w: i32, h: i32, flags: u32) callconv(.winapi) i32;
pub extern "user32" fn SetProcessDpiAwarenessContext(context: isize) callconv(.winapi) i32;
pub extern "user32" fn GetDpiForWindow(hwnd: Handle) callconv(.winapi) u32;
pub extern "user32" fn SendMessageW(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;
pub extern "user32" fn SetWindowTextW(hwnd: Handle, text: [*:0]const u16) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextW(hwnd: Handle, text: [*]u16, max: i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextLengthW(hwnd: Handle) callconv(.winapi) i32;
pub extern "user32" fn EnableWindow(hwnd: Handle, enabled: i32) callconv(.winapi) i32;
pub extern "user32" fn IsWindowEnabled(hwnd: Handle) callconv(.winapi) i32;
pub extern "user32" fn SetFocus(hwnd: Handle) callconv(.winapi) Handle;
pub extern "user32" fn GetFocus() callconv(.winapi) Handle;
pub extern "user32" fn GetKeyState(key: i32) callconv(.winapi) i16;
pub extern "user32" fn SetTimer(hwnd: Handle, id: usize, ms: u32, callback: ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(hwnd: Handle, id: usize) callconv(.winapi) i32;
pub extern "user32" fn IsDialogMessageW(hwnd: Handle, msg: *Msg) callconv(.winapi) i32;
pub extern "user32" fn DestroyWindow(hwnd: Handle) callconv(.winapi) i32;
pub extern "user32" fn PostMessageW(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) i32;
pub extern "user32" fn SetWindowLongPtrW(hwnd: Handle, index: i32, value: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hwnd: Handle, index: i32) callconv(.winapi) isize;

pub extern "user32" fn CreatePopupMenu() callconv(.winapi) Handle;
pub extern "user32" fn AppendMenuW(menu: Handle, flags: u32, id: usize, text: ?[*:0]const u16) callconv(.winapi) i32;
pub extern "user32" fn TrackPopupMenu(menu: Handle, flags: u32, x: i32, y: i32, reserved: i32, hwnd: Handle, rect: ?*const Rect) callconv(.winapi) i32;
pub extern "user32" fn DestroyMenu(menu: Handle) callconv(.winapi) i32;
pub extern "user32" fn ClientToScreen(hwnd: Handle, point: *Point) callconv(.winapi) i32;
pub extern "user32" fn ScreenToClient(hwnd: Handle, point: *Point) callconv(.winapi) i32;
pub extern "user32" fn GetParent(hwnd: Handle) callconv(.winapi) Handle;
pub extern "user32" fn SetCapture(hwnd: Handle) callconv(.winapi) Handle;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) i32;
pub extern "user32" fn TrackMouseEvent(info: *TrackMouseEventInfo) callconv(.winapi) i32;
pub extern "user32" fn OpenClipboard(hwnd: Handle) callconv(.winapi) i32;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
pub extern "user32" fn SetClipboardData(format: u32, memory: Handle) callconv(.winapi) Handle;
pub extern "user32" fn CloseClipboard() callconv(.winapi) i32;
pub extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) Handle;
pub extern "kernel32" fn GlobalLock(memory: Handle) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: Handle) callconv(.winapi) i32;
pub extern "kernel32" fn GlobalFree(memory: Handle) callconv(.winapi) Handle;
pub extern "kernel32" fn FileTimeToLocalFileTime(utc: *const FileTime, local: *FileTime) callconv(.winapi) i32;
pub extern "kernel32" fn FileTimeToSystemTime(time: *const FileTime, system: *SystemTime) callconv(.winapi) i32;

pub extern "comdlg32" fn GetOpenFileNameW(info: *OpenFileName) callconv(.winapi) i32;
pub extern "comdlg32" fn GetSaveFileNameW(info: *OpenFileName) callconv(.winapi) i32;

pub extern "gdi32" fn CreateCompatibleDC(hdc: Handle) callconv(.winapi) Handle;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: Handle, w: i32, h: i32) callconv(.winapi) Handle;
pub extern "gdi32" fn SelectObject(hdc: Handle, object: Handle) callconv(.winapi) Handle;
pub extern "gdi32" fn DeleteObject(object: Handle) callconv(.winapi) i32;
pub extern "gdi32" fn DeleteDC(hdc: Handle) callconv(.winapi) i32;
pub extern "gdi32" fn BitBlt(dst: Handle, x: i32, y: i32, w: i32, h: i32, src: Handle, sx: i32, sy: i32, op: u32) callconv(.winapi) i32;
pub extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) Handle;
pub extern "gdi32" fn SetTextColor(hdc: Handle, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn SetBkColor(hdc: Handle, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn CreateFontW(height: i32, width: i32, escapement: i32, orientation: i32, weight: i32, italic: u32, underline: u32, strikeout: u32, charset: u32, output_precision: u32, clip_precision: u32, quality: u32, pitch: u32, face: [*:0]const u16) callconv(.winapi) Handle;

pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: Handle, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;

pub extern "shlwapi" fn SHCreateMemStream(data: [*]const u8, size: u32) callconv(.winapi) Handle;

pub const RectF = extern struct { x: f32, y: f32, w: f32, h: f32 };
pub const PointF = extern struct { x: f32, y: f32 };

pub const GdiplusStartupInput = extern struct {
    version: u32 = 1,
    debug_callback: ?*anyopaque = null,
    suppress_background_thread: i32 = 0,
    suppress_external_codecs: i32 = 0,
};

pub const SmoothingModeAntiAlias = 4;
pub const TextRenderingHintClearTypeGridFit = 5;
pub const UnitPixel = 2;
pub const StringFormatFlagsNoWrap = 0x1000;
pub const StringFormatFlagsMeasureTrailingSpaces = 0x0800;
pub const StringTrimmingEllipsisCharacter = 3;
pub const CombineModeReplace = 0;
pub const InterpolationModeHighQualityBicubic = 7;

pub extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) callconv(.winapi) i32;
pub extern "gdiplus" fn GdiplusShutdown(token: usize) callconv(.winapi) void;
pub extern "gdiplus" fn GdipCreateFromHDC(hdc: Handle, graphics: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeleteGraphics(graphics: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetSmoothingMode(graphics: Handle, mode: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetTextRenderingHint(graphics: Handle, hint: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetInterpolationMode(graphics: Handle, mode: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCreateBitmapFromStream(stream: Handle, bitmap: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDrawImageRect(graphics: Handle, image: Handle, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDisposeImage(image: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipScaleWorldTransform(graphics: Handle, sx: f32, sy: f32, order: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipGraphicsClear(graphics: Handle, color: u32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetClipRect(graphics: Handle, x: f32, y: f32, w: f32, h: f32, mode: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipResetClip(graphics: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCreateSolidFill(color: u32, brush: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetSolidFillColor(brush: Handle, color: u32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeleteBrush(brush: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCreatePen1(color: u32, width: f32, unit: i32, pen: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetPenColor(pen: Handle, color: u32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetPenWidth(pen: Handle, width: f32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeletePen(pen: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCreatePath(fill_mode: i32, path: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipResetPath(path: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeletePath(path: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipAddPathArc(path: Handle, x: f32, y: f32, w: f32, h: f32, start: f32, sweep: f32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipClosePathFigure(path: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipFillPath(graphics: Handle, brush: Handle, path: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDrawPath(graphics: Handle, pen: Handle, path: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipFillRectangle(graphics: Handle, brush: Handle, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipFillPolygon2(graphics: Handle, brush: Handle, points: [*]const PointF, count: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipFillEllipse(graphics: Handle, brush: Handle, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDrawLine(graphics: Handle, pen: Handle, x1: f32, y1: f32, x2: f32, y2: f32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDrawLines(graphics: Handle, pen: Handle, points: [*]const PointF, count: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCreateFontFamilyFromName(name: [*:0]const u16, collection: Handle, family: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeleteFontFamily(family: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipGetGenericFontFamilySansSerif(family: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipGetGenericFontFamilyMonospace(family: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCreateFont(family: Handle, size: f32, style: i32, unit: i32, font: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeleteFont(font: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipStringFormatGetGenericTypographic(format: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipCloneStringFormat(format: Handle, clone: *Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDeleteStringFormat(format: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetStringFormatFlags(format: Handle, flags: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetStringFormatAlign(format: Handle, alignment: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetStringFormatLineAlign(format: Handle, alignment: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipSetStringFormatTrimming(format: Handle, trimming: i32) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipDrawString(graphics: Handle, text: [*]const u16, length: i32, font: Handle, layout: *const RectF, format: Handle, brush: Handle) callconv(.winapi) i32;
pub extern "gdiplus" fn GdipMeasureString(graphics: Handle, text: [*]const u16, length: i32, font: Handle, layout: *const RectF, format: Handle, box: *RectF, code_points: ?*i32, lines: ?*i32) callconv(.winapi) i32;

// The app's own CPU time and memory, for the load test charts.
pub const EN_SETFOCUS = 0x0100;
pub const EN_KILLFOCUS = 0x0200;
pub const ProcessMemoryCounters = extern struct {
    cb: u32 = @sizeOf(ProcessMemoryCounters),
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
};
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
pub extern "kernel32" fn GetProcessTimes(process: Handle, creation: *FileTime, exit: *FileTime, kernel: *FileTime, user: *FileTime) callconv(.winapi) i32;
pub extern "kernel32" fn K32GetProcessMemoryInfo(process: Handle, counters: *ProcessMemoryCounters, size: u32) callconv(.winapi) i32;
pub extern "uxtheme" fn SetWindowTheme(hwnd: Handle, app: ?[*:0]const u16, list: ?[*:0]const u16) callconv(.winapi) i32;
pub extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) Handle;
pub extern "kernel32" fn GetProcAddress(module: Handle, name: ?*const anyopaque) callconv(.winapi) ?*const anyopaque;
