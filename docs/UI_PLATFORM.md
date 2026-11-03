# Desktop UI platform evaluation

Status: recommendation, November 2026. Nothing here is implemented yet; the
Windows Win32/GDI+ app keeps working while this is decided.

## The question

ZTest's desktop app is Windows-only: `src/ui/` draws with GDI+ and uses native
`EDIT`, Rich Edit and combo box controls. V1 needs Linux and macOS too. Before
building the Test Suites and Load Tests screens for real, the project needs to
decide what those screens will be written in, so they are not written twice.

## What the app needs from a toolkit

- **Text editing that people trust**: multi-line editors with selection,
  clipboard, undo/redo, IME, and good performance on a few hundred KiB of JSON.
  This is the hardest requirement and the one most toolkits do worst.
- **Custom drawing** for the dashboard, charts and the load-test graphs.
- **A dark, branded look** matching the mockups in `ui/`.
- **Keyboard access and high-DPI** on all three platforms.
- **Builds with the project's Zig (0.17)** without a C++ toolchain on every
  developer machine, ideally.
- **Small binaries and fast start-up**, which is the product's promise.

## What already helps

The split in the code base makes any migration smaller than it looks:

- Everything that decides behaviour is outside `src/ui/`'s Win32 files and
  already tested on Linux: the HTTP client, assertions, the `.ztest` parser and
  writer, the runner, the load engine, and the desktop's own logic
  (`src/core/http/draft.zig`, `src/ui/workspace.zig`, `src/ui/api_request.zig`).
- Screens draw through `Canvas` (`src/ui/canvas.zig`); only it and `main.zig`
  touch GDI+. A new renderer replaces those two files for painted content.
- What does not port is the native controls in `api_controls.zig`,
  `rich_edit.zig` and `dark_combo.zig`: about 800 lines that a new toolkit's
  widgets would replace.

## Options

| | Text editing | Look and drawing | Zig fit | Platforms | Main risk |
|---|---|---|---|---|---|
| **A. Native per OS** (Win32 now, GTK 4, AppKit) | Best: each OS's own editor | Native, but three looks to theme | C APIs through Zig externs | All three | Three UI code bases to keep in step |
| **B. dvui** (Zig immediate mode, SDL3 backend) | Single and multi-line entry, IME on SDL | Full custom drawing, easy to theme | Pure Zig, tracks recent Zig | Windows, Linux, macOS via SDL3, plus web | Editor polish on very large text; Zig version lag |
| **C. Dear ImGui** (zgui or cimgui) | `InputTextMultiline`: adequate, not pleasant | Tool-like look, themable | C++ dependency, bindings lag Zig | All three | Feels like a debug tool, C++ build |
| **D. Capy** (Zig, native widgets) | Native | Native | Pure Zig | No macOS yet | Pre-production by its own README, targets Zig 0.14.1 |
| **E. System webview** (WebView2, WebKitGTK, WKWebView) + HTML front end | Excellent (CodeMirror or Monaco) | Exactly the mockups, rich charts | Zig core behind a small IPC layer | All three | Two languages; WebView2 runtime on Windows; bigger memory |

Notes from each project's own page, checked November 2026:

- dvui lists SDL2, SDL3, raylib, DX11, OpenGL/GLFW and web backends, single
  and multi-line text entry with IME on SDL and web, and is tested with Zig
  0.16.0 ([dvui](https://github.com/david-vanderson/dvui)).
- zgui bundles Dear ImGui 1.92 and builds with a glfw/wgpu backend
  ([zgui](https://github.com/zig-gamedev/zgui)); its supported Zig version is
  not stated, and it was not verified on Zig 0.17 here.
- Capy states it is not ready for production, targets Zig 0.14.1, and does
  not yet support macOS beyond buttons, labels and windows
  ([capy](https://github.com/capy-ui/capy)).

## Recommendation

**Move the desktop app to dvui with its SDL3 backend (option B), after a
two-day spike that proves the editor.** Keep the Win32 app until the dvui one
reaches parity, then retire it.

Why:

- It is the only option that is pure Zig, cross-platform today, and able to
  draw the custom dashboard and charts without a second language.
- Immediate mode matches how `app.zig` and the screens already work: state in
  `State`, everything redrawn from it each frame. Screens mostly change their
  drawing calls, not their structure.
- The core already holds all behaviour, so the move is a rewrite of roughly
  3,000 lines of drawing and control code, not of the product.

Choose **E (webview)** instead if exact fidelity to the mockups and a
first-class code editor matter more than a single language and a small
footprint. Choose **A** only if a truly native feel on each OS is a product
requirement; it triples UI maintenance.

## The spike: decide in two days

Build `src/ui_dvui/` with a window, the sidebar, and the API Tests request
editor wired to `Session` and `Workspace`. Pass if:

1. It builds and runs on Windows, Linux and macOS from `zig build ui` on Zig
   0.17, or on a pinned dvui commit with a clear path to 0.17.
2. A 200 KiB JSON body can be pasted, edited and scrolled without visible lag,
   with undo/redo and clipboard working.
3. Tab and Shift+Tab reach every control, and the app is crisp at 100%, 150%
   and 200% scaling.
4. Release binary under 10 MB and cold start under 300 ms on a mid-range laptop.

If 2 fails, try E for the same slice before falling back to A.

## Migration order after a passing spike

1. Port `Canvas` primitives to dvui drawing, so dashboard and sample screens
   render unchanged.
2. Replace the API Tests native controls with dvui widgets, keeping the
   existing `screens/api_test.zig` layout functions and their tests.
3. Build Test Suites on the runner's listener interface (it already reports
   each case as it finishes).
4. Build Load Tests on `load.Engine`, whose `progress()` and per-second series
   are made for a live chart.
5. Retire `win32.zig`, `api_controls.zig`, `rich_edit.zig` and `dark_combo.zig`.
