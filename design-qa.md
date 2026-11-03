# Desktop Design Review

## Every page, live — 2026-11-03

Each page was compared with its mockup in `ui/` side by side, using real data: a
workspace copied from `examples/api` with a run history and one suite that runs
without a network. Left is the mockup, right the app under Wine at 1448 × 1000.
Wine draws no Segoe Fluent icons, so icons show as boxes there; on Windows they
are the icons of the mockups.

- Dashboard: `docs/design-qa/dashboard-live-comparison.jpg`
- API Tests: `docs/design-qa/api-builder-live-comparison.jpg`
- Test Suites: `docs/design-qa/test-suites-live-comparison.jpg`
- Load Tests: `docs/design-qa/load-dashboard-live-comparison.jpg`

What matches: the sidebar, top bar (search with Ctrl K, environment menu,
notifications), page headers and their split buttons, the stat cards with
sparklines and changes, the results trend and recent activity, the paged test-run
table with suite filter and row menus; the API builder's header status, menus,
line numbers, variable panel, response meta and the assertion rows with operator,
value, unit and delete; the suite list with search and filters, totals,
configuration cards, tabs, progress bar, result filters and expandable cases; the
load settings, stat cards, six live charts and endpoint table.

Deliberate differences:

- No Pro upgrade card or account avatar: ZTest has neither.
- Test Suites shows **Open** where the mockup has **Schedule**, and a **Last Run**
  card where it has **Scheduled Run**: suites are not scheduled. Results are a flat
  list, as `.ztest` files have no groups.
- The load charts for CPU and memory are ZTest's own (the load generator's), since
  the app cannot see the server.
- Native menus, file dialogs and edit scroll bars follow Windows; the app asks for
  dark menus and scroll bars on Windows 10 1809 and later.

Not verifiable under Wine: Zig 0.17's networking fails there before connecting,
so sending, suites that send requests and load tests were covered by
`zig build test` on Linux instead (runner cancellation, the desktop suite run, the
desktop load run and history).

---

# API Builder Design Review (2026-10-31)

## Scope and evidence

This review verifies restoration of the API builder layout within the existing Windows renderer, while preserving the working HTTP controls. It does not claim a pixel-identical recreation of every decorative detail or implementation of planned features.

- Source: `ui/ChatGPT Image Oct 30, 2026, 02_36_45 PM-2.png`, 1448 × 1086 pixels.
- Final executable: `zig-out/bin/ztest-ui.exe`.
- Final implementation capture: `docs/design-qa/api-builder-live.jpg`, 1146 × 794 pixels.
- Full comparison: `docs/design-qa/api-builder-comparison.jpg`.
- Focused comparisons: `docs/design-qa/api-builder-request-comparison.jpg` and `docs/design-qa/api-builder-results-comparison.jpg`.
- Additional viewport checked interactively: maximized Windows window, 1536 × 816 pixels.
- State: POST request with raw/JSON input and a real HTTP 200 response from a loopback fixture. The source depicts a saved request and configured assertions; the app honestly labels its request as unsaved and its assertion editor as planned.

The source and final implementation were opened together in one comparison input. The comparison artifacts preserve each image's aspect ratio and normalize the full view to 1000 pixels wide per panel and focused regions to 900 pixels wide. These are composition comparisons across different-height viewports, not a pixel-difference metric. Windows title-bar chrome and display density are not treated as product layout defects.

## Comparison history and fixes

1. **P1, fixed: request structure replaced.** Restored Params/Headers/Auth/Body/Tests tabs, the body-type sidebar, format selection, code area, and environment column. The focused request comparison confirms their order and alignment. Headers and body now occupy their intended tabs instead of parallel text areas.
2. **P1, fixed: results composition replaced.** Restored separate Response and Assertions columns and Body/Headers/Cookies/Raw response tabs. The focused results comparison confirms this hierarchy.
3. **P2, fixed: primary action and method-field alignment.** Send is an owner-drawn native button using the existing amber token. Its keyboard/button semantics remain native. The method selector now sits inside a 40-pixel framed field aligned with the URL and Send controls; this was checked after the earlier short-selector capture.
4. **P2, fixed: editor typography.** Headers, body, and response use Consolas; surrounding controls retain Segoe UI. The final capture confirms the monospace text and readable hierarchy.

## Required fidelity surfaces

- **Fonts/typography:** the repository's existing font families, title hierarchy, and text sizes are retained. Code editors use monospace text. JSON colors were added in the follow-up below; line-number gutters remain future polish.
- **Spacing/layout:** the reference's major regions, tab order, body sidebar, and two-column results are restored. Smaller windows use shorter scrollable editors; maximizing preserves the same layout. Automated geometry checks cover the minimum window size.
- **Colors/tokens:** existing dark backgrounds, panel borders, amber selection states, and status colors are reused. Native selectors now use dark rendering; scrollbars retain Windows styling.
- **Image quality/assets:** the existing project logo and icon resources are retained without replacement artwork. The source's alternate logo and Mac window chrome are outside this layout correction.
- **Copy/content:** real response data replaces illustrative results. Unset environments and planned assertions are not shown as configured, passing, or saved. Unsupported body types and future actions remain disabled.

No actionable P0/P1/P2 findings remain within the layout-restoration scope.

## Functional verification

Verified in the final executable against a local HTTP server:

- Body → raw enables the format selector and body editor.
- Switching between Headers and Body retains both drafts and shows the correct native controls.
- POST sends the entered headers and JSON exactly; JSON supplies `application/json`.
- Raw text retains the same draft and sends without an automatic JSON content type.
- None retains the draft but sends a zero-length body.
- Cookies shows the fixture's actual response cookie; Raw shows the actual response status, headers, and body.
- The styled Cancel button cancels a delayed request, restores Send, and re-enables editors.
- The default and maximized window sizes keep the primary controls usable.

`zig build` passed. `zig build test` passed, including request snapshot/cancellation/validation, response previews, and small-window layout checks. Formatting checks and Git whitespace checks passed for the changed files.

The staged UI-only source was also exported to
`zig-out/ui-commit-verification/`, without the separate local API/formatting
changes. Both its desktop/CLI build and a fresh **176/176** test run passed.

## Keyboard and timeout follow-up — 2026-10-31

The keyboard changes were verified separately in
`zig-out/review-fixes/bin/ztest-ui.exe`. The live POST/JSON result and native focus
indicator are captured in
[`docs/design-qa/review-fixes-keyboard.jpg`](docs/design-qa/review-fixes-keyboard.jpg).
This capture was also inspected alongside the original source: the request tabs,
body sidebar/editor/environment regions, and Response/Assertions columns remain
in their intended order. Different viewport heights shorten the editors; this
comparison does not assert pixel equality.

- Ctrl+2 opens API Tests without a pointer.
- Tab/Shift+Tab reaches native tabs, supported body modes, and editors; both
  directions skip hidden and disabled controls, including None-mode editors.
- Space activates request/response tabs and None/Raw modes with a visible focus
  indicator. Native format-selector arrow keys switch Raw text/JSON.
- Headers/Body transitions and None/Raw/JSON switching retain the drafts.
- A loopback POST received the exact JSON body, `application/json`, and custom
  header. Response Headers/Cookies/Raw show the actual fixture data.
- Enter from the URL starts a request; Space on Cancel stops a delayed request
  and re-enables the editors without losing the draft.
- A separate review also fixed the previously crashing CLI timeout and checked
  the timeout boundaries. Those API changes remain local and are excluded from
  the UI-restoration commit.

The fresh-cache working-tree test run passed **179/179 tests**, including the
separate local API changes. The desktop/CLI verification build, full formatting
check, and Git whitespace check passed. The main executable was rebuilt after
the keyboard integration and recaptured as `api-builder-live.jpg`.

## JSON and control polish — 2026-11-02

The final native capture is
[`docs/design-qa/api-builder-polished.jpg`](docs/design-qa/api-builder-polished.jpg).
The source and final build were inspected together in
[`docs/design-qa/api-builder-polish-comparison.jpg`](docs/design-qa/api-builder-polish-comparison.jpg).
The restored request/sidebar/environment and Response/Assertions composition is
preserved. Code uses blue keys, pink strings, amber numbers, and purple literals.
Both closed selectors and their open menus use the dark palette, with an amber
keyboard focus indicator. Windows scrollbars remain a visible fidelity difference.

- Native Rich Edit preserves text editing, selection, scrolling, and Undo/Redo.
  Automated Windows tests check real character colors, UTF-16 selection around
  an emoji, exact CRLF text, owned-buffer cleanup, Undo/Redo, and plain-text reset.
- Interactive typing and Ctrl+Z/Ctrl+Y retained the caret and scrolled position.
  The native method menu supports arrow keys, type selection, and Enter.
- A final loopback POST received the exact multiline JSON, including the emoji,
  with `application/json`. Its HTTP 200 JSON response is colored; response Headers
  remain plain readable text. None/busy bodies are read-only and skipped by Tab.
- Highlighting is bounded to 32,768 UTF-16 units and 4,096 tokens. Larger content
  stays plain text; request validation and payload limits remain in core.
- The isolated staged source in `zig-out/ui-polish-verification/` passed
  **184/184 tests** and built the CLI and desktop executable. The current working
  tree also passed its build/tests. Separate local API/formatting changes remain
  excluded from this UI commit.

## Functional slice — 2026-11-03

Params, Auth, Tests, environments, Open/Save and the suite test switcher were
added inside the existing layout: the Params and Tests editors use the Headers
editor's area and hint line, and Auth uses labelled rows in the request content
area. The Assertions panel now lists real results, failures first, and the
Environment Variables column lists the chosen environment's values with secrets
masked. Open, Save, Run Test, New and Save as Test are now real buttons.

Checked by driving `ztest-ui.exe` under Wine with a virtual display: switching
environments, typing params, choosing Bearer auth (key masked), editing
assertions, saving a new `.ztest`, opening a three-test suite from `tests/`
(its `ztest.json` found in the parent folder), stepping to test 2, and the
missing-secret message on Send. Wine has no Segoe fonts, so the canvas now falls
back to generic families instead of failing to start; icons render as boxes
there. Wine cannot run the engine's sockets, so live sends were verified by the
loopback session tests on Linux rather than in the window. **A pass on real
Windows is still needed** for the native look, Rich Edit colours and live sends.

## Remaining polish

- P3: native scrollbar styling can be brought closer to the mockup.
- P3: add code-editor line-number gutters.
- P3: improve the long, disabled form-urlencoded label at smaller widths.

## Implementation checklist

- [x] Restore the request tabs and body sidebar.
- [x] Restore environment and results columns.
- [x] Preserve real native editors and Send/Cancel.
- [x] Style Send and align request fields.
- [x] Compare the final executable with the source in full and focused views.
- [x] Verify tab transitions, body modes, real requests, and cancellation.

final result: passed
