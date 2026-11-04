# Desktop UI platform evaluation

Status: recommendation, November 2026. Nothing here is implemented yet; the
Windows Win32/GDI+ app keeps working while this is decided.

## The question

ZTest's Windows desktop app draws with GDI+ and uses native edit and combo box
controls. The prototype will test whether the existing request editor can move
to a shared desktop interface for Windows, Linux, and macOS.

## What the app needs from a toolkit

- **Text editing that people trust**: multi-line editors with selection,
  clipboard, undo/redo, IME, and good performance on a few hundred KiB of JSON.
  This is the hardest requirement and the one most toolkits do worst.
- **Custom drawing** for the dashboard, charts and the load-test graphs.
- **A dark, branded look** matching the mockups in `ui/`.
- **Keyboard access and high-DPI** on all three platforms.
- **Builds with the project's current toolchain** and keeps dependencies small.
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

| | Text editing | Look and drawing | Integration | Platforms | Main risk |
|---|---|---|---|---|---|
| **A. Native per OS** (Win32 now, GTK 4, AppKit) | Best: each OS's own editor | Native, but three looks to theme | Direct platform APIs | All three | Three UI code bases to keep in step |
| **B. dvui** (immediate mode, SDL3 backend) | Single and multi-line entry, IME on SDL | Full custom drawing, easy to theme | Uses the project's existing build system | Windows, Linux, macOS via SDL3, plus web | Large-document editing and toolchain compatibility |
| **C. Dear ImGui** (zgui or cimgui) | `InputTextMultiline` | Themable | C++ dependency and bindings | All three | Editor polish and C++ build |
| **D. Capy** (native widgets) | Native | Native | Native controls | No macOS yet | Pre-production status |
| **E. System webview** (WebView2, WebKitGTK, WKWebView) + HTML front end | Excellent (CodeMirror or Monaco) | Exactly the mockups, rich charts | Shared core behind a small IPC layer | All three | Two languages; WebView2 runtime on Windows; bigger memory |

Notes from each project's own page, checked November 2026:

- dvui lists SDL2, SDL3, raylib, DX11, OpenGL/GLFW and web backends, single
  and multi-line text entry with IME on SDL and web. The prototype must verify
  compatibility with the current project build. [dvui](https://github.com/david-vanderson/dvui)
- zgui bundles Dear ImGui 1.92 and builds with a glfw/wgpu backend.
  Its compatibility with the current project build has yet to be verified.
  [zgui](https://github.com/zig-gamedev/zgui)
- Capy was marked pre-production and had limited macOS support at the time
  of evaluation. [Capy](https://github.com/capy-ui/capy)

## Recommendation

**Move the desktop app to dvui with its SDL3 backend (option B), after a
two-day spike that proves the editor.** Keep the Win32 app until the dvui one
reaches parity, then retire it.

Why:

- It can draw the custom dashboard and charts across all three target desktop
  platforms using the project's current language.
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

1. It builds and runs on Windows, Linux, and macOS with the current project
   toolchain. Pin the toolkit revision used for the prototype.
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
