# ZTest TODO

## Status Legend

```text
[ ] Not started
[-] In progress
[x] Completed
[!] Blocked
```

---

## Review Follow-up — 2026-11-03

- [x] Add an MIT `LICENSE`
- [x] Add runnable example suites (`examples/api/`) and an offline echo server
- [x] Add GitHub Actions CI: format, tests on Windows/Linux/macOS, example suites, a short load test
- [x] Let `--help` and `--version` win anywhere on the command line
- [x] Add `ztest init`
- [x] Add `--report json|junit|html[=path]` to `ztest run`
- [x] Add `query` and `auth` statements to `.ztest`, and a writer that round-trips with the parser
- [x] Desktop: Params, Auth, environments with masked secrets, live assertions, Open/Save, stepping through a suite's tests
- [x] Add `ztest load` with users, ramp-up, rate limit, percentiles and a JSON report
- [x] Fuzz the parser, writer, assertions, drafts, config and templates; add an engine-wide request-size limit
- [x] Evaluate cross-platform desktop UI (`docs/UI_PLATFORM.md`)

Next: run the dvui spike from `docs/UI_PLATFORM.md` and release packaging.
Smaller gaps: form-urlencoded and multipart bodies (core supports them, the format
and desktop do not), proxy support, and scenario load tests from a `.ztest` suite.

---

## UI Design Follow-up — 2026-11-03

Every desktop page now follows its mockup in `ui/` and shows real data. The Pro
upgrade card and the account avatar are left out: ZTest has neither.

- [x] Run history in `.ztest/history.jsonl` (`src/core/history.zig`), written by the desktop
- [x] Dashboard from history: stats with 7-day changes, results trend, recent activity, paged test runs, Run All, New Test
- [x] API Tests: Saved/Unsaved status, Run Test and Send menus, Code Snippets (cURL, ZTest test, URL), Save as Test (including Add to a Suite), line numbers, Insert Variable, variable copy/reveal/filter, response meta, JSON/Text, copy, expand
- [x] Assertions panel: one row per line with operator menu, value, unit, delete, Templates and Add Assertion
- [x] Test Suites: the workspace's `.ztest` files, run on the core runner with Stop and Stop at First Failure, live results with Request/Response/Logs/Assertions, Test Cases, Configuration, History and Artifacts tabs, Export Report (HTML, JSON, JUnit), New Suite
- [x] Load Tests on `load.Engine`: settings with units and advanced options, live stat cards and six charts (CPU and memory are ZTest's own), endpoint results, saved configurations from history
- [x] Reports, Environments and Settings pages; environment menu, notifications and Ctrl+K search in the top bar
- [x] Cancel a running suite between and during requests (`Runner.cancel`)

Under Wine, Zig 0.17's networking fails before connecting, so live sends, suite runs
that send requests and load tests were verified with `zig build test` on Linux; the
pages themselves were checked under Wine against the mockups.

---

## Review Follow-up — 2026-10-31

- [x] Reject oversized CLI and core HTTP timeouts without panicking
- [x] Add native keyboard-focusable request/response tabs and body modes
- [x] Keep Tab/Shift+Tab navigation outside hidden and disabled editors
- [x] Normalize source formatting with Zig 0.17
- [x] Complete native request interaction verification after the keyboard changes
- [x] Compare the mockup and implementation; preserve visual QA evidence in `design-qa.md`
- [x] Connect desktop auth and environment variables to the shared core
- [x] Add live assertion editing and evaluation
- [x] Save and reopen `.ztest` requests

---

## Phase 0 — Repository Setup

- [x] Create repository
- [x] Initialize Zig project
- [x] Add `.gitignore`
- [x] Add `README.md`
- [x] Add `LICENSE`
- [x] Add `ROADMAP.md`
- [x] Add `ARCHITECTURE.md`
- [x] Add `TODO.md`
- [x] Configure `build.zig`
- [x] Configure `build.zig.zon`
- [x] Define app version
- [x] Add debug build
- [x] Add release build
- [x] Configure unit tests

---

## Phase 1 — Application Foundation

### Core

- [x] Create `src/main.zig`
- [x] Create `src/core/`
- [x] Create common error model
- [x] Create logger
- [x] Create configuration loader
- [x] Create application context
- [x] Define allocator strategy
- [x] Add graceful shutdown
- [x] Add signal handling where supported

### CLI

- [x] Parse command-line arguments
- [x] Add `--help`
- [x] Add `--version`
- [x] Add verbose mode
- [x] Add quiet mode
- [x] Add colored console output
- [x] Support disabling colors

---

## Phase 2 — HTTP Engine

### Request Model

- [x] Define `HttpRequest`
- [x] Define HTTP method enum
- [x] Add URL parsing
- [x] Add query parameters
- [x] Add request headers
- [x] Add request cookies
- [x] Add raw request body
- [x] Add JSON request body
- [x] Add form-urlencoded body
- [x] Add multipart/form-data

### Authentication

- [x] Basic Auth
- [x] Bearer Token
- [x] API Key header
- [x] API Key query parameter

### HTTP Client

- [x] GET
- [x] POST
- [x] PUT
- [x] PATCH
- [x] DELETE
- [x] HEAD
- [x] OPTIONS

### Network

- [x] HTTPS
- [x] TLS verification
- [x] timeout
- [x] redirects
- [x] connection reuse
- [x] keep-alive
- [ ] proxy support later

### Response Model

- [x] Status code
- [x] Status text
- [x] Headers
- [x] Cookies
- [x] Body
- [x] Response size
- [x] Request duration

### Tests

- [x] GET test
- [x] POST test
- [x] redirect test
- [x] timeout test
- [x] invalid host test
- [x] malformed response test

---

## Phase 3 — API CLI

- [x] Add `ztest api`
- [x] Method argument
- [x] URL argument
- [x] `--header`
- [x] `--query`
- [x] `--json`
- [x] `--body`
- [x] `--timeout`
- [x] `--auth`
- [x] Pretty JSON output
- [x] Raw output mode
- [x] Show status code
- [x] Show duration
- [x] Show response size

Example target:

```bash
ztest api GET https://api.example.com/users
```

---

## Phase 4 — Assertion Engine

### Core

- [x] Define assertion interface
- [x] Assertion result model
- [x] Error message formatting

### Status Assertions

- [x] equals
- [x] not equals
- [x] greater than
- [x] less than

### Timing Assertions

- [x] response time <
- [x] response time <=
- [x] response time >
- [x] response time >=

### Body Assertions

- [x] property exists
- [x] property does not exist
- [x] equals
- [x] not equals
- [x] contains
- [x] starts with
- [x] ends with

### Header Assertions

- [x] exists
- [x] equals
- [x] contains

### JSON

- [x] JSON parser
- [x] property path parser
- [x] nested object lookup
- [x] array lookup

Example:

```text
body.user.id exists
body.items[0].name == "Apple"
```

---

## Phase 5 — Test Definition

### Format

- [x] Finalize `.ztest` format
- [x] Define grammar
- [x] Write parser specification

### Lexer

- [x] Token types
- [x] strings
- [x] numbers
- [x] identifiers
- [x] operators
- [x] comments
- [x] line numbers
- [x] parsing errors

### Parser

- [x] Parse suite
- [x] Parse test
- [x] Parse request
- [x] Parse headers
- [x] Parse body
- [x] Parse assertions
- [x] Parse variables

### AST

- [x] Suite AST
- [x] Test AST
- [x] Request AST
- [x] Assertion AST

---

## Phase 6 — Test Runner

- [x] Test execution model
- [x] Suite execution
- [x] Setup hooks
- [x] Teardown hooks
- [x] Skip test
- [x] Disable test
- [x] Test timeout
- [x] Fail-fast mode
- [x] Continue-on-failure mode
- [x] Execution summary
- [x] Exit codes

Example:

```bash
ztest run tests/
```

---

## Phase 7 — Variables and Environments

### Variables

- [x] Global variables
- [x] Environment variables
- [x] Suite variables
- [x] Test variables
- [x] Runtime variables

### Variable Syntax

```text
{{baseUrl}}
{{token}}
```

- [x] Variable parser
- [x] Variable interpolation
- [x] Missing variable error

### Environments

- [x] Development
- [x] Staging
- [x] Production
- [x] custom environments

### Secrets

- [x] Secret flag
- [x] Mask UI
- [x] Mask CLI
- [x] Mask logs
- [x] Mask reports
- [x] Secure local storage strategy

---

## Phase 8 — Response Extraction

- [x] Extract body property
- [x] Extract response header
- [x] Store extracted value
- [x] Use variable in later requests

Example:

```text
extract token = body.token
```

Then:

```text
Authorization: Bearer {{token}}
```

---

## Phase 9 — Desktop UI Foundation

The Windows Win32/GDI+ shell provides a window, render loop, mouse navigation,
DPI handling, dark styling, and routed screens. Every page shows real data:
API Tests sends requests, Test Suites runs the workspace's suites, Load Tests runs
the load engine, and Dashboard and Reports read the run history.

### Integration

- [x] Windows Win32/GDI+ integration
- [x] Evaluate cross-platform GUI support, including zgui compatibility (`docs/UI_PLATFORM.md`)
- [x] Create application window
- [x] Render loop
- [x] Keyboard input (API controls, page fields, Ctrl+1–7 pages, Ctrl+K search)
- [x] Mouse input
- [x] DPI scaling

### Design System

- [x] Dark theme
- [x] colors
- [x] typography
- [x] spacing
- [x] buttons
- [x] native API inputs
- [x] tables
- [x] tabs
- [ ] modal
- [x] toast
- [x] status badge

### Navigation

- [x] Sidebar routing
- [x] Dashboard route (run history)
- [x] API Tests route (live requests, auth, environments, assertions, save/open)
- [x] Test Suites route (runs suites live)
- [x] Load Tests route (runs load tests live)
- [x] Reports route (exported reports and run history)
- [x] Environments route (`ztest.json` variables per environment)
- [x] Settings route (version, workspace, limits, shortcuts)

---

## Phase 10 — API Testing UI

### Request Builder

- [x] Method dropdown
- [x] URL input
- [x] Send button
- [x] Cancel pending request without blocking the window
- [x] Save button (Save, Save as, Open, New; Ctrl+S/O/N)

### Params

- [x] key (one `name=value` per line)
- [x] value
- [x] enable/disable (a leading `#` switches a line off)
- [x] delete row

### Headers

- [x] key (one `Name: value` per line)
- [x] value
- [x] enable/disable (a leading `#` switches a line off)
- [-] secret mask (secret variables are masked in the variable list and responses; a literal value typed in a header is shown)

### Auth

- [x] No Auth
- [x] Basic Auth
- [x] Bearer Token
- [x] API Key (header or query; keys are masked unless written as `{{variable}}`)

### Body

- [x] None
- [x] JSON
- [x] Raw
- [ ] form-urlencoded
- [ ] multipart

### Response

- [x] Status
- [x] Duration
- [x] Size
- [x] Body
- [x] Headers
- [x] Cookies
- [x] Raw

### Next Desktop Slice

- [x] Editable request headers and raw/JSON body
- [x] Validate JSON and header lines before sending; retain body drafts across modes
- [x] Connect auth and environment variables to the core models
- [x] Evaluate assertions against the live response
- [x] Save and reopen `.ztest` requests

The live response viewer supports text selection, copying, and scrolling.
Requests have a 30-second timeout and a 4 MiB response limit; previews mark
truncation above 64 KiB. `ztest.json` is read from the open file's folder or the
nearest parent.

---

## Phase 11 — Assertions UI

Assertions are edited as text in the Tests tab, one per line, which covers
adding, deleting, duplicating and reordering. Results show failures first.

- [x] Add assertion button (Edit Assertions focuses the Tests editor)
- [-] Assertion type selector (Templates and Add Assertion add each type; the target is typed)
- [x] Operator selector
- [x] Expected value
- [x] Actual value
- [x] Passed state
- [x] Failed state
- [x] Delete assertion
- [x] Duplicate assertion
- [x] Reorder assertions

---

## Phase 12 — Test Suites UI

### Suite Management

- [x] Create suite (New Suite writes a starter file)
- [ ] Rename suite
- [ ] Delete suite
- [ ] Duplicate suite

### Tests

- [x] Add test (Save as Test → Add to a Suite)
- [x] Edit test (open it in API Tests)
- [ ] Delete test
- [ ] Duplicate test
- [ ] Reorder test
- [ ] Enable test
- [ ] Disable test

### Execution

- [x] Run suite (and Run All on the Dashboard)
- [x] Stop suite
- [x] Progress bar
- [x] Passed count
- [x] Failed count
- [x] Skipped count
- [x] Duration

### Result Details

- [x] Request
- [x] Response
- [x] Logs
- [x] Assertions
- [x] Failure reason

---

## Phase 13 — Test History

- [x] Save execution (desktop runs, in `.ztest/history.jsonl`)
- [ ] Run ID
- [x] Timestamp
- [x] Environment
- [x] Result
- [x] Duration
- [ ] Failure details
- [x] Request metrics
- [x] History UI (Dashboard, Reports, a suite's History tab)
- [ ] Delete history
- [ ] Clear history

---

## Phase 14 — Load Testing Core

### Configuration

- [x] Virtual users
- [x] Duration
- [x] Ramp-up
- [x] Target RPS
- [x] Timeout

### Execution

- [x] Worker system (one task per user)
- [x] Scheduler (shared rate-limit slots)
- [x] Connection reuse (one client per user)
- [x] Graceful cancellation (Ctrl-C prints partial results)
- [x] Rate limiter
- [ ] Scenario runner (one request today; a `.ztest` suite per user is next)

### Reliability

- [x] Avoid thread explosion (at most 1000 users)
- [x] Bound memory usage (per-request arenas, fixed-size histograms)
- [ ] Backpressure
- [x] Connection limits (one connection per user)

---

## Phase 15 — Load Metrics

- [x] Total requests
- [x] Successful requests
- [x] Failed requests
- [x] RPS
- [x] average latency
- [x] minimum latency
- [x] maximum latency
- [x] p50
- [x] p90
- [x] p95
- [x] p99
- [x] failure rate
- [x] active VUs
- [x] bytes received
- [x] bytes sent (estimated from the request line, headers and body)

---

## Phase 16 — Load Testing UI

- [x] Endpoint
- [x] Virtual users
- [x] Duration
- [x] Ramp-up
- [x] Start
- [x] Stop

### Live Metrics

- [x] RPS
- [x] Active users
- [x] Success
- [x] Failure
- [x] Average latency (median while running)

### Charts

- [x] Request rate
- [x] p50
- [x] p95
- [x] p99
- [x] error rate
- [x] active VUs

### Results Table

- [x] Endpoint
- [x] Method
- [x] Requests
- [x] RPS
- [x] Average
- [x] p95
- [x] p99
- [x] Error %

---

## Phase 17 — Reporting

- [x] Console reporter
- [x] JSON reporter
- [x] HTML reporter
- [x] JUnit reporter

### Report Data

- [x] application version
- [x] test timestamp
- [x] test environment
- [x] tests
- [x] assertions
- [x] failures
- [x] durations
- [x] load metrics (`ztest load --report json`)

---

## Phase 18 — CI/CD

- [x] Headless mode (CLI)
- [x] Stable exit codes
- [x] GitHub Actions example (also this repository's own CI)
- [x] GitLab CI example
- [x] Jenkins example
- [x] Azure DevOps example
- [x] CI documentation (`docs/CI.md`)

---

## Phase 19 — Performance

- [ ] Benchmark startup
- [ ] Benchmark idle memory
- [ ] Benchmark HTTP throughput
- [ ] Benchmark load engine
- [ ] Profile allocator usage
- [ ] Reduce allocations
- [ ] Optimize JSON handling
- [ ] Optimize connection pooling
- [ ] Identify lock contention

---

## Phase 20 — Security

- [x] Secret redaction (CLI, desktop and reports)
- [x] Token redaction (configured and extracted secrets)
- [x] Password redaction (configured secrets; desktop auth fields are masked)
- [x] TLS validation
- [x] Response-size limit
- [x] Request-size limit (32 MiB in the engine; desktop drafts smaller)
- [x] Parser fuzzing (`src/core/fuzz_test.zig`)
- [-] Invalid UTF-8 handling (desktop previews implemented; broader validation pending)
- [x] malformed JSON handling (desktop and suite bodies validated and fuzzed)
- [ ] crash recovery

---

## Phase 21 — Packaging

- [ ] Windows x64
- [ ] Windows ARM64
- [ ] Linux x64
- [ ] Linux ARM64
- [ ] macOS Intel
- [ ] macOS Apple Silicon

### Release

- [ ] version tag
- [ ] changelog
- [ ] release archive
- [ ] checksums
- [ ] installation documentation

---

## V1 Definition of Done

ZTest V1 must provide:

- [x] API testing
- [x] CLI
- [-] desktop application (every Windows page works; other platforms pending)
- [x] assertions
- [x] reusable test suites
- [x] variables
- [x] environments
- [-] load testing (CLI and desktop done; scenarios pending)
- [x] metrics
- [x] reports
- [x] CI integration
- [ ] cross-platform releases
