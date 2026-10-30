# ZTest TODO

## Status Legend

```text
[ ] Not started
[-] In progress
[x] Completed
[!] Blocked
```

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
- [ ] Add graceful shutdown
- [ ] Add signal handling where supported

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

- [ ] Define `HttpRequest`
- [ ] Define HTTP method enum
- [ ] Add URL parsing
- [ ] Add query parameters
- [ ] Add request headers
- [ ] Add request cookies
- [ ] Add raw request body
- [ ] Add JSON request body
- [ ] Add form-urlencoded body
- [ ] Add multipart/form-data

### Authentication

- [ ] Basic Auth
- [ ] Bearer Token
- [ ] API Key header
- [ ] API Key query parameter

### HTTP Client

- [ ] GET
- [ ] POST
- [ ] PUT
- [ ] PATCH
- [ ] DELETE
- [ ] HEAD
- [ ] OPTIONS

### Network

- [ ] HTTPS
- [ ] TLS verification
- [ ] timeout
- [ ] redirects
- [ ] connection reuse
- [ ] keep-alive
- [ ] proxy support later

### Response Model

- [ ] Status code
- [ ] Status text
- [ ] Headers
- [ ] Cookies
- [ ] Body
- [ ] Response size
- [ ] Request duration

### Tests

- [ ] GET test
- [ ] POST test
- [ ] redirect test
- [ ] timeout test
- [ ] invalid host test
- [ ] malformed response test

---

## Phase 3 — API CLI

- [ ] Add `ztest api`
- [ ] Method argument
- [ ] URL argument
- [ ] `--header`
- [ ] `--query`
- [ ] `--json`
- [ ] `--body`
- [ ] `--timeout`
- [ ] `--auth`
- [ ] Pretty JSON output
- [ ] Raw output mode
- [ ] Show status code
- [ ] Show duration
- [ ] Show response size

Example target:

```bash
ztest api GET https://api.example.com/users
```

---

## Phase 4 — Assertion Engine

### Core

- [ ] Define assertion interface
- [ ] Assertion result model
- [ ] Error message formatting

### Status Assertions

- [ ] equals
- [ ] not equals
- [ ] greater than
- [ ] less than

### Timing Assertions

- [ ] response time <
- [ ] response time <=
- [ ] response time >
- [ ] response time >=

### Body Assertions

- [ ] property exists
- [ ] property does not exist
- [ ] equals
- [ ] not equals
- [ ] contains
- [ ] starts with
- [ ] ends with

### Header Assertions

- [ ] exists
- [ ] equals
- [ ] contains

### JSON

- [ ] JSON parser
- [ ] property path parser
- [ ] nested object lookup
- [ ] array lookup

Example:

```text
body.user.id exists
body.items[0].name == "Apple"
```

---

## Phase 5 — Test Definition

### Format

- [ ] Finalize `.ztest` format
- [ ] Define grammar
- [ ] Write parser specification

### Lexer

- [ ] Token types
- [ ] strings
- [ ] numbers
- [ ] identifiers
- [ ] operators
- [ ] comments
- [ ] line numbers
- [ ] parsing errors

### Parser

- [ ] Parse suite
- [ ] Parse test
- [ ] Parse request
- [ ] Parse headers
- [ ] Parse body
- [ ] Parse assertions
- [ ] Parse variables

### AST

- [ ] Suite AST
- [ ] Test AST
- [ ] Request AST
- [ ] Assertion AST

---

## Phase 6 — Test Runner

- [ ] Test execution model
- [ ] Suite execution
- [ ] Setup hooks
- [ ] Teardown hooks
- [ ] Skip test
- [ ] Disable test
- [ ] Test timeout
- [ ] Fail-fast mode
- [ ] Continue-on-failure mode
- [ ] Execution summary
- [ ] Exit codes

Example:

```bash
ztest run tests/
```

---

## Phase 7 — Variables and Environments

### Variables

- [ ] Global variables
- [ ] Environment variables
- [ ] Suite variables
- [ ] Test variables
- [ ] Runtime variables

### Variable Syntax

```text
{{baseUrl}}
{{token}}
```

- [ ] Variable parser
- [ ] Variable interpolation
- [ ] Missing variable error

### Environments

- [ ] Development
- [ ] Staging
- [ ] Production
- [ ] custom environments

### Secrets

- [ ] Secret flag
- [ ] Mask UI
- [ ] Mask CLI
- [ ] Mask logs
- [ ] Mask reports
- [ ] Secure local storage strategy

---

## Phase 8 — Response Extraction

- [ ] Extract body property
- [ ] Extract response header
- [ ] Store extracted value
- [ ] Use variable in later requests

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

### Integration

- [-] Evaluate current Zig GUI library
- [ ] Verify zgui on Zig 0.17
- [ ] Create application window
- [ ] Render loop
- [ ] Keyboard input
- [ ] Mouse input
- [ ] DPI scaling

### Design System

- [ ] Dark theme
- [ ] colors
- [ ] typography
- [ ] spacing
- [ ] buttons
- [ ] inputs
- [ ] tables
- [ ] tabs
- [ ] modal
- [ ] toast
- [ ] status badge

### Navigation

- [ ] Sidebar
- [ ] Dashboard
- [ ] API Tests
- [ ] Test Suites
- [ ] Load Tests
- [ ] Reports
- [ ] Environments
- [ ] Settings

---

## Phase 10 — API Testing UI

### Request Builder

- [ ] Method dropdown
- [ ] URL input
- [ ] Send button
- [ ] Save button

### Params

- [ ] key
- [ ] value
- [ ] enable/disable
- [ ] delete row

### Headers

- [ ] key
- [ ] value
- [ ] enable/disable
- [ ] secret mask

### Auth

- [ ] No Auth
- [ ] Basic Auth
- [ ] Bearer Token
- [ ] API Key

### Body

- [ ] None
- [ ] JSON
- [ ] Raw
- [ ] form-urlencoded
- [ ] multipart

### Response

- [ ] Status
- [ ] Duration
- [ ] Size
- [ ] Body
- [ ] Headers
- [ ] Cookies
- [ ] Raw

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

- [ ] Console reporter
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

- [ ] Headless mode
- [ ] Stable exit codes
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

- [ ] Secret redaction
- [ ] Token redaction
- [ ] Password redaction
- [ ] TLS validation
- [ ] Response-size limit
- [ ] Request-size limit
- [ ] Parser fuzzing
- [ ] Invalid UTF-8 handling
- [ ] malformed JSON handling
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
