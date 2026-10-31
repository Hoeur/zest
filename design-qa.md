# API Builder Design Review

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

- **Fonts/typography:** the repository's existing font families, title hierarchy, and text sizes are retained. Code editors use monospace text. Colorized JSON and line-number gutters remain follow-up editor polish.
- **Spacing/layout:** the reference's major regions, tab order, body sidebar, and two-column results are restored. Smaller windows use shorter scrollable editors; maximizing preserves the same layout. Automated geometry checks cover the minimum window size.
- **Colors/tokens:** existing dark backgrounds, panel borders, amber selection states, and status colors are reused. Native combo borders and scrollbars retain Windows styling.
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

## Follow-up polish

- P3: native combo and scrollbar styling can be brought closer to the mockup.
- P3: add code-editor syntax colors and line-number gutters.
- P3: improve the long, disabled form-urlencoded label at smaller widths.

## Implementation checklist

- [x] Restore the request tabs and body sidebar.
- [x] Restore environment and results columns.
- [x] Preserve real native editors and Send/Cancel.
- [x] Style Send and align request fields.
- [x] Compare the final executable with the source in full and focused views.
- [x] Verify tab transitions, body modes, real requests, and cancellation.

final result: passed
