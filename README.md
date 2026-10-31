# ⚡ ZTest

<p align="center">
  <img src="docs/assets/logo.png" alt="ZTest logo" width="128" />
</p>

<p align="center">
  <strong>Fast, lightweight, native API & load testing — powered by Zig.</strong>
</p>

<p align="center">
  API Testing · Test Suites · Load Testing · Reports · CI/CD
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-powered-F7A41D?logo=zig&logoColor=white" alt="Zig" />
  <img src="https://img.shields.io/badge/status-alpha-orange" alt="Status" />
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-blue" alt="Platforms" />
  <img src="https://img.shields.io/badge/license-TBD-lightgrey" alt="License" />
</p>

---

## 📍 Current State

> **Most of this README describes the planned ZTest product, not what runs today.**
> `ztest api` sends one HTTP or HTTPS request, prints the response, and can check it with `--assert`. `ztest run` runs `.ztest` files or directories, with environments and masked secrets from `ztest.json`. The load, report, and CI sections below are design targets.

What exists today:

- **`zest`**: a small unit-test library for Zig, in `src/root.zig`.
- **Desktop app** (Windows only): `zig build ui` opens the sample dashboard. **API Tests** sends real requests with an editable HTTP method, URL, headers, and None/Raw/JSON body modes. It supports Send/Cancel, status, duration, body size, and selectable Body/Headers views. Enter headers as one `Name: value` per line; JSON is validated before sending. Ctrl+Enter sends from an editor. Authentication controls, environments, assertions, and saving are not yet editable in the UI. Other screens still use sample data or placeholders.

Using `zest`:

```zig
const std = @import("std");
const zest = @import("zest");
const T = zest.T;

const MathTests = struct {
    pub fn addsNumbers(t: *T) !void {
        try t.equal(5, 2 + 3);
    }
};

pub fn main(init: std.process.Init) !void {
    try zest.run(init, .{MathTests});
}
```

Public functions in a suite that take `*T` are discovered at compile time. Optional `beforeEach` and `afterEach` run around each test, and `t.allocator` fails any test that leaks memory. A complete example is in [`examples/demo.zig`](./examples/demo.zig).

---

## 🎬 Demo

> Planned demo flow: create API request → run test → validate assertions → execute suite → inspect results.

Example animation sequence:

```text
Create Request
     ↓
Send Request
     ↓
Receive Response
     ↓
Run Assertions
     ↓
Save Test
     ↓
Run Suite
```

Asset layout (the GIFs have not been recorded yet):

```text
docs/
└── assets/
    ├── ztest-demo.gif
    ├── api-test.gif
    ├── load-test.gif
    ├── dashboard.png
    ├── api-builder.png
    ├── test-suites.png
    └── load-dashboard.png
```

---

## ✨ Overview

**ZTest** is a modern testing tool built with **Zig** for developers, QA engineers, backend engineers, and DevOps teams who want fast API testing and high-performance load testing without a heavyweight runtime.

The long-term idea:

```text
Postman
+
Newman
+
k6
+
Zig performance
=
ZTest
```

ZTest is designed around a single reusable core engine.

```mermaid
flowchart TD
    CLI[CLI]
    UI[Desktop App]
    CI[CI/CD]

    CORE[ZTest Core]

    HTTP[HTTP Engine]
    RUNNER[Test Runner]
    LOAD[Load Engine]
    METRICS[Metrics]
    REPORTS[Reports]

    CLI --> CORE
    UI --> CORE
    CI --> CORE

    CORE --> HTTP
    CORE --> RUNNER
    CORE --> LOAD

    HTTP --> METRICS
    RUNNER --> METRICS
    LOAD --> METRICS

    METRICS --> REPORTS
```

---

## 🚀 Why ZTest?

ZTest focuses on:

- ⚡ Fast startup
- 🧠 Low memory usage
- 📦 Small native binaries
- 🧪 API testing
- ✅ Assertions
- 🧩 Reusable test suites
- 🔥 Load testing
- 📊 Performance metrics
- 🖥 Native desktop UI
- 🤖 CI/CD automation
- 🔐 Secret-safe logging
- 🌍 Cross-platform support

---

## 🧭 Project Status

> ZTest is currently under active development.

Current development path:

```mermaid
flowchart LR
    A[Foundation]
    B[HTTP Engine]
    C[CLI]
    D[Assertions]
    E[Test Runner]
    F[Desktop UI]
    G[Load Engine]
    H[Reports]

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    G --> H
```

Target stable release:

```text
v1.0.0
```

---

## 🖼 UI Concepts

> These are design mockups, not screenshots. All data shown is illustrative.

### Dashboard

<p align="center">
  <img src="./docs/assets/dashboard.png" alt="ZTest Dashboard mockup" width="100%" />
</p>

Dashboard focuses on:

- Total tests
- Passing tests
- Failing tests
- Response time
- Throughput
- Recent executions
- Test trends

---

### API Test Builder

<p align="center">
  <img src="./docs/assets/api-builder.png" alt="ZTest API Builder mockup" width="100%" />
</p>

Main API workflow:

```mermaid
flowchart LR
    A[Method + URL]
    B[Headers / Params]
    C[Auth]
    D[Body]
    E[Send]
    F[Response]
    G[Assertions]

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
```

---

### Test Suites

<p align="center">
  <img src="./docs/assets/test-suites.png" alt="ZTest Test Suites mockup" width="100%" />
</p>

---

### Load Testing Dashboard

<p align="center">
  <img src="./docs/assets/load-dashboard.png" alt="ZTest Load Testing mockup" width="100%" />
</p>

Load testing focuses on:

```text
Virtual Users
Duration
Ramp-up
RPS
Latency
p50
p95
p99
Errors
```

---

## 🎞 API Testing Animation

Suggested animation:

```text
Select POST
     ↓
Enter URL
     ↓
Add JSON body
     ↓
Send
     ↓
200 OK
     ↓
Add assertions
     ↓
Save test
```

---

## 🔥 Load Testing Animation

Suggested sequence:

```text
Configure Load
     ↓
500 Virtual Users
     ↓
10 Minute Duration
     ↓
2 Minute Ramp-up
     ↓
Start
     ↓
Live Metrics
     ↓
Performance Report
```

---

## 🏗 Architecture

ZTest uses a core-first architecture.

```mermaid
graph TD
    UI[Desktop UI]
    CLI[CLI]
    CICD[CI/CD]

    CORE[ZTest Core]

    HTTP[HTTP Engine]
    ASSERT[Assertion Engine]
    RUNNER[Test Runner]
    LOAD[Load Testing Engine]
    CONFIG[Environment & Variables]
    STORAGE[Local Storage]
    METRICS[Metrics]
    REPORTER[Reporter]

    UI --> CORE
    CLI --> CORE
    CICD --> CORE

    CORE --> HTTP
    CORE --> ASSERT
    CORE --> RUNNER
    CORE --> LOAD
    CORE --> CONFIG
    CORE --> STORAGE

    HTTP --> METRICS
    RUNNER --> METRICS
    LOAD --> METRICS

    METRICS --> REPORTER
```

The desktop UI must not contain testing business logic.

```text
UI → Core ✅

Core → UI ❌
```

---

## 🔄 API Execution Flow

```mermaid
sequenceDiagram
    participant User
    participant UI
    participant Core
    participant HTTP
    participant API
    participant Assert

    User->>UI: Run Test
    UI->>Core: Execute test
    Core->>HTTP: Build request
    HTTP->>API: Send HTTP request
    API-->>HTTP: Response
    HTTP-->>Core: Parsed response
    Core->>Assert: Evaluate assertions
    Assert-->>Core: Pass / Fail
    Core-->>UI: Test result
    UI-->>User: Display result
```

---

## 🔥 Load Testing Flow

```mermaid
flowchart TD
    CONFIG[Load Configuration]
    SCHEDULER[Scheduler]
    WORKERS[Worker Pool]
    HTTP[HTTP Engine]
    TARGET[Target API]
    METRICS[Metrics Collector]
    UI[Live Dashboard]
    REPORT[Final Report]

    CONFIG --> SCHEDULER
    SCHEDULER --> WORKERS
    WORKERS --> HTTP
    HTTP --> TARGET

    TARGET --> HTTP
    HTTP --> METRICS

    METRICS --> UI
    METRICS --> REPORT
```

---

## 📦 Project Structure

Target structure:

```text
ztest/
├── build.zig
├── build.zig.zon
│
├── src/
│   ├── main.zig
│   │
│   ├── cli/
│   ├── core/
│   ├── http/
│   ├── assertions/
│   ├── parser/
│   ├── config/
│   ├── runner/
│   ├── load/
│   ├── metrics/
│   ├── reporter/
│   ├── storage/
│   └── ui/
│
├── tests/
│   ├── unit/
│   ├── integration/
│   └── e2e/
│
├── examples/
│
├── benchmarks/
│
├── docs/
│   ├── assets/
│   │   ├── ztest-demo.gif
│   │   ├── api-test.gif
│   │   ├── load-test.gif
│   │   ├── dashboard.png
│   │   ├── api-builder.png
│   │   ├── test-suites.png
│   │   └── load-dashboard.png
│   │
│   ├── CLI.md
│   ├── TEST_FORMAT.md
│   └── LOAD_TESTING.md
│
├── README.md
├── ROADMAP.md
├── TODO.md
└── ARCHITECTURE.md
```

---

## 🧪 API Testing

Planned methods:

```text
GET
POST
PUT
PATCH
DELETE
HEAD
OPTIONS
```

Example:

```bash
ztest api GET https://api.example.com/users
```

POST:

```bash
ztest api POST https://api.example.com/login \
  --json '{"email":"test@example.com","password":"123456"}'
```

Example output:

```text
POST https://api.example.com/login

Status     200 OK
Time       82 ms
Size       1.2 KB

{
  "success": true,
  "token": "..."
}
```

---

## ✅ Assertions

Check a response from the command line. Each failure is reported, and the command exits `1`:

```bash
ztest api GET https://api.example.com/users \
  --assert 'status == 200' \
  --assert 'response_time < 500ms' \
  --assert 'body.items[0].name == "Apple"' \
  --assert 'body.token exists' \
  --assert 'header.content-type contains "application/json"'
```

With `--raw`, the report goes to stderr so stdout stays pipeable.

The `.ztest` format uses the same expressions:

```text
expect status == 200
expect body.token exists
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

Execution flow:

```mermaid
flowchart LR
    RESPONSE[HTTP Response]
    ASSERT[Assertion Engine]
    PASS[Passed]
    FAIL[Failed]

    RESPONSE --> ASSERT
    ASSERT -->|true| PASS
    ASSERT -->|false| FAIL
```

Example failure:

```text
✗ Login API

Expected:
status == 200

Actual:
status == 500
```

---

## 🧩 Test Suites

Example:

```text
suite "Authentication"

test "Login successfully"

POST {{baseUrl}}/api/login

header Content-Type application/json

body {
  "email": "test@example.com",
  "password": "123456"
}

expect status == 200
expect response_time < 500ms
expect body.token exists

end
```

Run:

```bash
ztest run tests/login.ztest
```

Run directory:

```bash
ztest run tests/
```

Suite workflow:

```mermaid
flowchart TD
    SUITE[Test Suite]
    SETUP[Setup]
    TEST1[Test 1]
    TEST2[Test 2]
    TESTN[Test N]
    TEARDOWN[Teardown]
    RESULT[Suite Result]

    SUITE --> SETUP
    SETUP --> TEST1
    TEST1 --> TEST2
    TEST2 --> TESTN
    TESTN --> TEARDOWN
    TEARDOWN --> RESULT
```

---

## 🌍 Environments

Environments are named sets of variables in `ztest.json`, and `--env` picks one:

```json
{
  "variables": { "version": "v1" },
  "environments": {
    "staging": {
      "baseUrl": "https://staging.example.com",
      "apiKey": { "env": "STAGING_API_KEY" }
    },
    "production": {
      "baseUrl": "https://api.example.com",
      "apiKey": { "env": "PRODUCTION_API_KEY" }
    }
  }
}
```

```bash
ztest run tests/ --env staging
```

Tests use them like any other variable:

```text
{{baseUrl}}/api/users
```

See [`docs/TEST_FORMAT.md`](docs/TEST_FORMAT.md#environments) for the details.

Variable priority:

```mermaid
flowchart TD
    R[Runtime]
    T[Test]
    S[Suite]
    E[Environment]
    G[Global]

    R --> T
    T --> S
    S --> E
    E --> G
```

Higher scopes override lower scopes.

---

## 🔐 Secret Handling

Sensitive values must be protected.

```text
var secret apiKey = "..."
extract secret token = body.token
```

Values read with `{ "env": "NAME" }` in `ztest.json` are secret too, so keys need
not be stored in a file. `ztest run` prints `********` in their place:

```text
Actual:   body.key == "********"
```

Secrets are redacted from `ztest run` output and error messages today. The Desktop
UI and reports are planned, and will take the same masked results.

```mermaid
flowchart LR
    SECRET[Secret Value]
    REDACT[Redaction Layer]

    CLI[CLI]
    UI[UI]
    LOG[Logs]
    REPORT[Reports]

    SECRET --> REDACT

    REDACT --> CLI
    REDACT --> UI
    REDACT --> LOG
    REDACT --> REPORT
```

---

## 🔗 Response Extraction

Values from one response can feed later requests.

Example:

```text
extract token = body.token
```

Then:

```text
Authorization: Bearer {{token}}
```

Flow:

```mermaid
flowchart LR
    LOGIN[Login]
    TOKEN[Extract Token]
    USER[Get User]
    CART[Create Cart]
    CHECKOUT[Checkout]

    LOGIN --> TOKEN
    TOKEN --> USER
    USER --> CART
    CART --> CHECKOUT
```

---

## 🔥 Load Testing

Example:

```bash
ztest load https://api.example.com/products \
  --users 500 \
  --duration 10m \
  --ramp-up 2m
```

Output:

```text
Load Test Complete

Total Requests      1,245,320
Successful          1,235,230
Failed                 10,090

RPS                     2,076

Average Latency          285 ms
p50                      180 ms
p95                      480 ms
p99                      820 ms

Failure Rate              0.8%
```

---

## 📊 Metrics

ZTest will collect:

| Metric | Description |
|---|---|
| Total Requests | Total HTTP requests |
| Successful | Successful responses |
| Failed | Failed responses |
| RPS | Requests per second |
| Avg Latency | Average response latency |
| p50 | Median latency |
| p90 | 90th percentile |
| p95 | 95th percentile |
| p99 | 99th percentile |
| Failure Rate | Failed request percentage |
| Active VUs | Active virtual users |
| Bytes Sent | Outbound traffic |
| Bytes Received | Inbound traffic |

---

## 🖥 Desktop App

Planned navigation:

```text
Dashboard
API Tests
Test Suites
Load Tests
Reports
Environments
Settings
```

Current UI stack (Windows only):

```text
Zig
+
Win32
+
GDI+
```

zgui and Dear ImGui were the original plan, but zgui has not been verified on Zig 0.17.

The desktop application should behave as a thin presentation layer above ZTest Core.

---

## 🧠 Core Design Principle

```mermaid
graph TD
    USER[User]

    CLI[CLI]
    DESKTOP[Desktop App]
    CI[CI Pipeline]

    CORE[ZTest Core]

    USER --> CLI
    USER --> DESKTOP

    CLI --> CORE
    DESKTOP --> CORE
    CI --> CORE
```

One engine.

Multiple interfaces.

---

## 📄 Reports

Planned report formats:

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

```bash
ztest run tests/ --report html
```

---

## 🤖 CI/CD

Example:

```bash
ztest run tests/
```

Exit codes:

```text
0 = Success
1 = Test failure
2 = Configuration error
3 = Internal error
130 = Interrupted by Ctrl-C
```

Pipeline:

```mermaid
flowchart LR
    PUSH[Git Push]
    BUILD[Build]
    ZTEST[Run ZTest]
    PASS{Tests Passed?}
    DEPLOY[Deploy]
    STOP[Stop Pipeline]

    PUSH --> BUILD
    BUILD --> ZTEST
    ZTEST --> PASS

    PASS -->|Yes| DEPLOY
    PASS -->|No| STOP
```

---

## ⚙️ Build

### Requirements

Zig 0.17.0 or newer. Check with:

```bash
zig version
```

Build:

```bash
zig build
```

Tests:

```bash
zig build test
```

Run the example tests:

```bash
zig build demo
```

Show failure output (these tests fail on purpose):

```bash
zig build failures
```

Run the desktop app (Windows only):

```bash
zig build ui
```

Release:

```bash
zig build -Doptimize=ReleaseFast
```

---

## 🛠 Development

The repository has not been published yet. Run the [build commands](#️-build) from the project root.

---

## 🧪 Testing Strategy

```mermaid
flowchart TD
    UNIT[Unit Tests]
    INTEGRATION[Integration Tests]
    E2E[End-to-End Tests]
    PERF[Performance Tests]

    UNIT --> INTEGRATION
    INTEGRATION --> E2E
    E2E --> PERF
```

Unit testing:

```text
URL parser
Variable resolver
Assertions
Lexer
Parser
Metrics
Percentiles
```

Integration:

```text
HTTP
 ↓
Response
 ↓
Assertions
```

E2E:

```text
.ztest
 ↓
Parser
 ↓
Runner
 ↓
HTTP
 ↓
Assertions
 ↓
Report
```

---

## ⚡ Performance Philosophy

```text
Correctness
   ↓
Measurement
   ↓
Profiling
   ↓
Optimization
```

Performance changes should be benchmark-driven.

---

## 🧠 Memory Philosophy

```mermaid
flowchart TD
    APP[Application Lifetime]
    GPA[General Allocator]

    REQUEST[Request Lifetime]
    ARENA[Temporary Arena]

    LOAD[Load Testing]
    BUFFER[Reusable / Bounded Buffers]

    APP --> GPA
    REQUEST --> ARENA
    LOAD --> BUFFER
```

Goals:

- predictable allocations
- bounded memory
- low fragmentation
- safe ownership
- easy cleanup

---

## 🛡 Security

Security requirements:

- TLS verification
- token redaction
- API key masking
- password redaction
- secure secret storage
- request-size limits
- response-size limits
- malformed-input handling
- parser fuzzing

---

## 🗺 Roadmap

```mermaid
timeline
    title ZTest Development Roadmap

    v0.1 : Foundation

    v0.2 : HTTP Engine
         : CLI MVP

    v0.3 : Assertions
         : Test Runner
         : Suites

    v0.4 : Variables
         : Extraction
         : Desktop App

    v0.5 : API Builder
         : Test Suites UI
         : History

    v0.6 : Load Engine
         : Metrics
         : Percentiles

    v0.7 : Load Testing UI
         : Charts

    v0.8 : Reports
         : JUnit
         : CI/CD

    v1.0 : Stable CLI
         : Stable Desktop App
         : Cross-platform Release
```

Full roadmap:

[`ROADMAP.md`](./ROADMAP.md)

---

## 🎯 V1 Scope

```text
API Testing
Assertions
Test Suites
Environments
Variables
Desktop UI
CLI
Load Testing
Reports
CI/CD
```

Not part of initial MVP:

```text
Cloud Sync
Distributed Load Testing
Team Workspace
Plugin Marketplace
Advanced Protocols
```

---

## 🔮 Future

### Protocols

- WebSocket
- GraphQL
- gRPC
- SSE

### API Development

- OpenAPI import
- schema validation
- generated tests
- contract testing
- mock server

### Performance

- distributed load testing
- remote workers
- multi-machine scenarios

### Extensibility

- plugins
- custom reporters
- custom assertions
- scripting
- SDK

### Collaboration

- team workspaces
- shared projects
- cloud sync
- shared collections

---

## 🤝 Contributing

Before contributing, review:

```text
TODO.md
ROADMAP.md
ARCHITECTURE.md
```

Potential contribution areas:

- Zig
- networking
- HTTP
- parsers
- concurrency
- load testing
- metrics
- native UI
- testing
- documentation

---

## 📚 Documentation

| Document | Purpose |
|---|---|
| [`README.md`](./README.md) | Project overview |
| [`ROADMAP.md`](./ROADMAP.md) | Development roadmap |
| [`TODO.md`](./TODO.md) | Engineering tasks |
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | System architecture |
| `docs/CLI.md` (planned) | CLI usage |
| `docs/TEST_FORMAT.md` | `.ztest` format |
| `docs/LOAD_TESTING.md` (planned) | Load testing |

---

## 💡 Principles

```text
Core first.
CLI second.
UI third.
```

```text
Correctness before optimization.
Benchmarks before assumptions.
One engine for every interface.
```

---

## 📜 License

License will be defined before the first public release.

---

<p align="center">
  Built with ⚡ Zig
</p>

<p align="center">
  <strong>Test fast. Ship confidently.</strong>
</p>
