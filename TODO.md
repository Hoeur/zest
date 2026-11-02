# ZTest TODO

## Status Legend

```text
[ ] Not started
[-] In progress
[x] Completed
[!] Blocked
```

---

## Review Follow-up — 2026-10-31

- [x] Reject oversized CLI and core HTTP timeouts without panicking
- [x] Add native keyboard-focusable request/response tabs and body modes
- [x] Keep Tab/Shift+Tab navigation outside hidden and disabled editors
- [x] Normalize source formatting with Zig 0.17
- [x] Complete native request interaction verification after the keyboard changes
- [x] Compare the mockup and implementation; preserve visual QA evidence in `design-qa.md`
- [ ] Connect desktop auth and environment variables to the shared core
- [ ] Add live assertion editing and evaluation
- [ ] Save and reopen `.ztest` requests

The next feature slice is desktop auth/environment integration. Suite management,
history, load testing, exported reports, CI examples, and release packaging follow
in the phases below. `ztest init` from the roadmap is also still unimplemented.

---

## Phase 0 — Repository Setup

- [-] Create repository
- [x] Initialize Zig project
- [x] Add `.gitignore`
- [x] Add `README.md`
- [ ] Add `LICENSE`
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
- [ ] Mask UI
- [x] Mask CLI
- [x] Mask logs
- [ ] Mask reports
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
DPI handling, dark styling, and routed screens. Native API controls support
keyboard navigation; other sample screens still need complete keyboard support.
Navigation entries below track routing, not functional screen completion. API
Tests sends real requests with editable headers and None/Raw/JSON bodies.

### Integration

- [x] Windows Win32/GDI+ integration
- [ ] Evaluate cross-platform GUI support, including zgui compatibility
- [x] Create application window
- [x] Render loop
- [-] Keyboard input (API controls and Ctrl+1–7 page navigation implemented)
- [x] Mouse input
- [x] DPI scaling

### Design System

- [x] Dark theme
- [x] colors
- [x] typography
- [x] spacing
- [x] buttons
- [x] native API inputs
- [-] tables (sample data only)
- [x] tabs
- [ ] modal
- [ ] toast
- [x] status badge

### Navigation

- [x] Sidebar routing
- [x] Dashboard route (sample data)
- [x] API Tests route (live requests; remaining features below)
- [x] Test Suites route (sample data)
- [x] Load Tests route (sample data)
- [x] Reports route (placeholder)
- [x] Environments route (placeholder)
- [x] Settings route (placeholder)

---

## Phase 10 — API Testing UI

### Request Builder

- [x] Method dropdown
- [x] URL input
- [x] Send button
- [x] Cancel pending request without blocking the window
- [ ] Save button

### Params

- [ ] key
- [ ] value
- [ ] enable/disable
- [ ] delete row

### Headers

- [x] key (one `Name: value` per line)
- [x] value
- [ ] enable/disable
- [ ] secret mask

### Auth

- [ ] No Auth
- [ ] Basic Auth
- [ ] Bearer Token
- [ ] API Key

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
- [ ] Connect auth and environment variables to the core models
- [ ] Evaluate assertions against the live response
- [ ] Save and reopen `.ztest` requests

The live response viewer supports text selection, copying, and scrolling.
Requests have a 30-second timeout and a 4 MiB response limit; previews mark
truncation above 64 KiB. Dashboard, suite, and load screens remain illustrative.

---

## Phase 11 — Assertions UI

- [ ] Add assertion button
- [ ] Assertion type selector
- [ ] Operator selector
- [ ] Expected value
- [ ] Actual value
- [ ] Passed state
- [ ] Failed state
- [ ] Delete assertion
- [ ] Duplicate assertion
- [ ] Reorder assertions

---

## Phase 12 — Test Suites UI

### Suite Management

- [ ] Create suite
- [ ] Rename suite
- [ ] Delete suite
- [ ] Duplicate suite

### Tests

- [ ] Add test
- [ ] Edit test
- [ ] Delete test
- [ ] Duplicate test
- [ ] Reorder test
- [ ] Enable test
- [ ] Disable test

### Execution

- [ ] Run suite
- [ ] Stop suite
- [ ] Progress bar
- [ ] Passed count
- [ ] Failed count
- [ ] Skipped count
- [ ] Duration

### Result Details

- [ ] Request
- [ ] Response
- [ ] Logs
- [ ] Assertions
- [ ] Failure reason

---

## Phase 13 — Test History

- [ ] Save execution
- [ ] Run ID
- [ ] Timestamp
- [ ] Environment
- [ ] Result
- [ ] Duration
- [ ] Failure details
- [ ] Request metrics
- [ ] History UI
- [ ] Delete history
- [ ] Clear history

---

## Phase 14 — Load Testing Core

### Configuration

- [ ] Virtual users
- [ ] Duration
- [ ] Ramp-up
- [ ] Target RPS
- [ ] Timeout

### Execution

- [ ] Worker system
- [ ] Scheduler
- [ ] Connection reuse
- [ ] Graceful cancellation
- [ ] Rate limiter
- [ ] Scenario runner

### Reliability

- [ ] Avoid thread explosion
- [ ] Bound memory usage
- [ ] Backpressure
- [ ] Connection limits

---

## Phase 15 — Load Metrics

- [ ] Total requests
- [ ] Successful requests
- [ ] Failed requests
- [ ] RPS
- [ ] average latency
- [ ] minimum latency
- [ ] maximum latency
- [ ] p50
- [ ] p90
- [ ] p95
- [ ] p99
- [ ] failure rate
- [ ] active VUs
- [ ] bytes received
- [ ] bytes sent

---

## Phase 16 — Load Testing UI

- [ ] Endpoint
- [ ] Virtual users
- [ ] Duration
- [ ] Ramp-up
- [ ] Start
- [ ] Stop

### Live Metrics

- [ ] RPS
- [ ] Active users
- [ ] Success
- [ ] Failure
- [ ] Average latency

### Charts

- [ ] Request rate
- [ ] p50
- [ ] p95
- [ ] p99
- [ ] error rate
- [ ] active VUs

### Results Table

- [ ] Endpoint
- [ ] Method
- [ ] Requests
- [ ] RPS
- [ ] Average
- [ ] p95
- [ ] p99
- [ ] Error %

---

## Phase 17 — Reporting

- [x] Console reporter
- [ ] JSON reporter
- [ ] HTML reporter
- [ ] JUnit reporter

### Report Data

- [ ] application version
- [ ] test timestamp
- [ ] test environment
- [ ] tests
- [ ] assertions
- [ ] failures
- [ ] durations
- [ ] load metrics

---

## Phase 18 — CI/CD

- [x] Headless mode (CLI)
- [x] Stable exit codes
- [ ] GitHub Actions example
- [ ] GitLab CI example
- [ ] Jenkins example
- [ ] Azure DevOps example
- [ ] CI documentation

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

- [-] Secret redaction (CLI implemented; UI and exported reports pending)
- [-] Token redaction (CLI configured secrets implemented)
- [-] Password redaction (CLI configured secrets implemented)
- [x] TLS validation
- [x] Response-size limit
- [-] Request-size limit (desktop drafts limited; engine-wide limit pending)
- [ ] Parser fuzzing
- [-] Invalid UTF-8 handling (desktop previews implemented; broader validation pending)
- [-] malformed JSON handling (desktop and suite bodies validated; fuzzing pending)
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

- [ ] API testing
- [ ] CLI
- [ ] desktop application
- [ ] assertions
- [ ] reusable test suites
- [ ] variables
- [ ] environments
- [ ] load testing
- [ ] metrics
- [ ] reports
- [ ] CI integration
- [ ] cross-platform releases
