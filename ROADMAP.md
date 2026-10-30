# ZTest Roadmap

## Vision

ZTest is a fast, lightweight testing platform built with Zig.

The long-term goal is to provide:

- API testing
- automated test suites
- load testing
- performance metrics
- CI/CD integration
- native desktop UI
- extensible testing capabilities

Core principle:

```text
One Core Engine
├── CLI
├── Desktop UI
└── CI/CD
```

---

## Milestone 0 — Project Foundation

### Goal

Create a clean and maintainable Zig project.

### Deliverables

- Zig project initialized
- `build.zig`
- `build.zig.zon`
- module structure
- application versioning
- configuration loader
- logging system
- common error types
- unit-test setup
- release/debug builds

### Definition of Done

```bash
zig build
zig build test
zig build run
```

all work successfully.

Target version:

```text
v0.1.0-alpha
```

---

## Milestone 1 — HTTP Core

### Goal

Build a reliable HTTP engine.

### Features

- GET
- POST
- PUT
- PATCH
- DELETE
- HEAD
- OPTIONS

Support:

- headers
- query parameters
- JSON body
- raw body
- form data
- cookies
- redirects
- timeout
- TLS
- authentication

### Response Data

Capture:

- status code
- response headers
- response body
- response size
- request duration
- DNS/connect/request timing where possible

### Definition of Done

```bash
ztest api GET https://example.com
```

returns:

```text
200 OK
Time: 82ms
Size: 1.2 KB
```

---

## Milestone 2 — CLI MVP

### Goal

Make ZTest usable without a GUI.

### Commands

```bash
ztest --version
ztest api
ztest run
ztest init
```

Example:

```bash
ztest api GET https://api.example.com/users
```

Example:

```bash
ztest api POST https://api.example.com/login \
  --json '{"email":"test@example.com","password":"123456"}'
```

### Definition of Done

Developers can manually test APIs using only the terminal.

Target version:

```text
v0.2.0
```

---

## Milestone 3 — Assertion Engine

### Goal

Turn API requests into actual tests.

### Assertions

Support:

```text
status == 200
response_time < 500ms
body.success == true
body.token exists
header.content-type contains "application/json"
```

Operators:

```text
==
!=
>
<
>=
<=
exists
not_exists
contains
starts_with
ends_with
```

### Definition of Done

Failed assertions produce useful messages.

Example:

```text
FAILED

Expected:
status == 200

Actual:
status == 500
```

---

## Milestone 4 — Test Runner

### Goal

Run reusable test definitions.

### Features

- test cases
- test suites
- setup
- teardown
- test ordering
- skip test
- disabled test
- test timeout
- suite execution

Example:

```bash
ztest run tests/login.ztest
```

or:

```bash
ztest run tests/
```

### Definition of Done

Users can run complete regression suites from CLI.

Target version:

```text
v0.3.0
```

---

## Milestone 5 — Environments and Variables

### Goal

Support multiple deployment environments.

### Features

Environment profiles:

```text
Development
Staging
Production
```

Variables:

```text
{{baseUrl}}
{{token}}
{{userId}}
```

Support:

- global variables
- environment variables
- suite variables
- test variables
- runtime variables
- secret variables
- response extraction into runtime variables

Variable priority:

```text
Runtime
  ↓
Test
  ↓
Suite
  ↓
Environment
  ↓
Global
```

### Security

Secrets must be masked.

Example:

```text
API_KEY = ********
```

---

## Milestone 6 — Desktop UI Foundation

### Goal

Build the native desktop application.

Current stack (Windows only):

```text
Zig
+
Win32
+
GDI+
```

zgui and Dear ImGui were the original plan, but zgui has not been verified on Zig 0.17. Linux and macOS still need a UI approach.

### Screens

Initial navigation:

```text
Dashboard
API Tests
Test Suites
Load Tests
Reports
Environments
Settings
```

### Definition of Done

Application opens natively and supports routing between major screens.

Target version:

```text
v0.4.0
```

---

## Milestone 7 — API Test Builder

### Goal

Provide a Postman-style testing experience.

### Features

Request builder:

- HTTP method
- URL
- params
- headers
- auth
- body
- tests
- environment variables

Actions:

```text
Send
Save
Run Test
Duplicate
Delete
```

Response viewer:

- status
- latency
- size
- headers
- body
- cookies
- raw response

### Definition of Done

A developer can create, save, and run API tests entirely from the desktop UI.

---

## Milestone 8 — Test Suites UI

### Goal

Manage regression testing visually.

### Features

- suite list
- test list
- create test
- edit test
- reorder tests
- enable/disable tests
- run suite
- execution progress
- test logs
- assertion results
- test history

### Definition of Done

Full regression suites can be executed and inspected through the UI.

Target version:

```text
v0.5.0
```

---

## Milestone 9 — Load Testing Core

### Goal

Build high-performance load generation using Zig.

### Features

- virtual users
- concurrency
- test duration
- ramp-up
- target RPS
- connection reuse
- scenarios
- cancellation
- request scheduling

Example:

```bash
ztest load https://api.example.com/products \
  --users 500 \
  --duration 10m \
  --ramp-up 2m
```

### Definition of Done

ZTest can safely generate controlled concurrent traffic.

---

## Milestone 10 — Performance Metrics

### Metrics

Capture:

```text
Total requests
Successful requests
Failed requests
RPS
Average latency
Minimum latency
Maximum latency
p50
p90
p95
p99
Failure rate
Active users
Bytes sent
Bytes received
```

### Definition of Done

Performance statistics are accurate and reproducible.

Target version:

```text
v0.6.0
```

---

## Milestone 11 — Load Testing UI

### Goal

Visualize load tests in real time.

### Dashboard

Display:

- active users
- RPS
- latency
- p50
- p95
- p99
- failure rate
- request count
- endpoint metrics

Charts:

```text
Requests/sec
Latency
Errors
Virtual Users
CPU
Memory
```

Target version:

```text
v0.7.0
```

---

## Milestone 12 — Reports

### Formats

Support:

```text
Console
JSON
HTML
JUnit XML
```

Examples:

```bash
ztest run tests/ --report json
```

```bash
ztest run tests/ --report junit
```

Reports should include:

- execution information
- pass/fail results
- assertion errors
- timings
- environment
- load-testing metrics

---

## Milestone 13 — CI/CD

### Goal

Make ZTest automation-friendly.

### Requirements

Stable exit codes:

```text
0 = Success
1 = Test failure
2 = Configuration error
3 = ZTest internal error
```

Support examples for:

- GitHub Actions
- GitLab CI
- Jenkins
- Azure DevOps

Target version:

```text
v0.8.0
```

---

## Milestone 14 — Optimization

### Focus

Profile:

- CPU
- memory allocations
- request throughput
- locking
- connection reuse
- parsing
- serialization

Targets:

```text
Fast startup
Low idle memory
Low allocation pressure
High concurrent request throughput
```

Do not optimize before correctness.

---

## Milestone 15 — Packaging

### Platforms

Build releases for:

```text
Windows x86_64
Windows ARM64

Linux x86_64
Linux ARM64

macOS x86_64
macOS ARM64
```

Distribution:

```text
ztest.exe
ztest
```

Users should not need Zig installed.

---

## Milestone 16 — Security

### Requirements

- TLS verification
- secret masking
- token redaction
- password redaction
- secure environment storage
- request-size limits
- response-size limits
- safe parser behavior
- malformed input handling
- fuzz tests

---

## Milestone 17 — V1 Stable Release

Target:

```text
v1.0.0
```

Required features:

- CLI
- desktop UI
- HTTP testing
- assertions
- test suites
- environments
- load testing
- metrics
- reports
- CI/CD integration
- Windows/Linux/macOS builds

---

## Post-V1 Roadmap

### Protocol Support

- WebSocket
- GraphQL
- gRPC
- SSE

### Developer Features

- OpenAPI import
- OpenAPI test generation
- contract testing
- schema validation
- mock server
- custom scripts

### Performance

- distributed load testing
- remote load workers
- multi-machine scenarios

### Extensibility

- plugins
- custom reporters
- custom assertions
- SDK

### Collaboration

- team projects
- shared test collections
- cloud sync
- organization workspaces
