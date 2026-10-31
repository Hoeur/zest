# Architecture

This folder holds **zest**, a Zig unit-test library, and the early **ZTest** CLI
and desktop UI. The HTTP engine, assertions, `.ztest` parser, `ztest api` and
`ztest run` work, including environments and secrets. Load testing in `ROADMAP.md`
and `TODO.md` is planned and not yet built.

## Layout

```text
build.zig          build steps; produces ztest (CLI) and ztest-ui (Windows)
build.zig.zon      package metadata and version
src/root.zig       the whole zest library and its own tests
src/main.zig       ztest entry point: exit codes and command dispatch
src/desktop.zig    desktop entry point rooted in src to share the core engine
src/cli.zig        argument parsing, with no I/O
src/commands/      one file per CLI command
src/core/          logger, config, environments, secret masking, context, exit
                   codes and Ctrl-C handling
src/core/http/     request model, response model and client
src/core/assertions/  assertion model and parser, evaluation and reports
src/core/parser/   .ztest lexer, parser and AST
src/core/runner/   suite execution and {{variable}} replacement
src/ui/            ZTest desktop UI, in progress
examples/          demo.zig passes; failures.zig fails on purpose
ui/, docs/assets/  ZTest desktop mockups
```

## How a zest run works

1. `zest.run` reads the optional name filter and works out colour support, then
   calls `runSuites`.
2. `runSuites` handles each suite type at compile time. `casesOf` collects its
   public functions that take `*T`, and `hookOf` finds `beforeEach` and
   `afterEach`.
3. `Runner.runCase` gives each test a new `T` and `DebugAllocator`, runs it
   through `execute`, then checks for leaks and prints the result.
4. `run` exits with status 1 if a test failed or no test matched.

## Design choices

- **Discovery uses comptime reflection**, so there is no registration step.
- **Assertions return errors**, so the first failed `try` ends the test.
- **Tests run in one process.** A panic stops the run, and the test's name is
  flushed first so the report shows which test was running.
- **Failure messages live in a fixed 2048-byte buffer in `T`**, so reporting a
  failure never allocates.

## ZTest CLI

- **Exit codes** are `0` success, `1` test or request failure, `2` configuration
  or usage error, `3` internal error, and `130` interrupted by Ctrl-C. An HTTP
  error status such as 500 is a completed request, so `ztest api` exits `0`.
- **Ctrl-C:** the first press cancels running work so it can clean up, and the
  second ends the process. Handlers only set an atomic flag.
- **Settings** come from an optional `ztest.json` in the working directory, and
  flags override it. Unknown fields are errors, so a misspelled setting is
  reported rather than ignored.
- **Output:** command results go to stdout and diagnostics to stderr. Both use
  streaming writers, because a positional writer overwrites redirected output.
- **Allocators:** commands use the process arena from `Context`, which is freed
  on exit. Long-running work such as load tests will need its own strategy.

## HTTP engine

`Client` wraps `std.http.Client`, which handles connections, TLS and pooling.

- **Timeouts and cancellation:** the standard client has no request timeout, so
  each request runs as a concurrent task. `send` waits for it and cancels it on
  the deadline or Ctrl-C.
- **Redirects are followed here, not by the standard client.** It cannot resend a
  body, it never sends `privileged_headers`, and it keeps `Authorization` on a
  redirect to another site. Credentials, cookies and API-key headers are dropped
  when a redirect changes the scheme, host or port. An API key in the query is
  part of the first URL only.
- **Memory:** a response lives in the arena passed to `send`. Reuse one `Client`
  to reuse connections.
- **Tests** run against scripted servers on loopback, so they need no network.
  HTTPS is checked by hand, because a local test would need a trusted certificate.

## Assertions

`assertion.zig` turns text such as `body.items[0].name == "Apple"` into an
`Assertion`, and `evaluate.zig` checks those against a `Response`. Neither does
I/O, so the CLI, the planned suite runner and the UI can share them.

- **Usage mistakes are found while parsing.** A value that cannot fit the target,
  such as `status contains "x"`, is exit code `2` and not a test that always fails.
- **Failing is the safe default.** A missing value fails everything except
  `not_exists`, and a path into a body that is not JSON fails everything, so a
  typo cannot pass a `!=` by accident.
- **JSON types are not mixed:** `body.id == "1"` fails when `id` is the number 1.
  Headers and the bare `body` are untyped text, so they compare as numbers only
  against a number.
- **Numbers stay as text** and integers compare exactly, because `f64` cannot hold
  large IDs.
- **Reported values are escaped and cut to 200 bytes,** so a response cannot send
  control codes to the terminal. Bodies that are not UTF-8 are not printed.
- **Paths** cannot yet name a key containing `.` or `[`.

## `.ztest` parser

`docs/TEST_FORMAT.md` is the format's specification. `parser.parse` turns source
into the `Suite` in `ast.zig`.

- **The lexer has two modes.** URLs, header values and JSON bodies are not made
  of tokens, so the parser asks for raw text when a statement needs it.
- **`expect` reuses the assertion parser**, so a file and `--assert` cannot drift apart.
- **Text is checked late where it holds variables.** URLs and JSON bodies are only
  valid once `{{name}}` is replaced, so the runner must check them.
- **The first error stops parsing.** Line numbers are kept on the AST, so the
  runner can report them too.

## Test runner

`Runner` runs a `Suite` and hands each `CaseResult` to a listener. It prints
nothing, so `commands/run.zig` owns the console report and the UI can bring its
own listener. Run semantics are in `docs/TEST_FORMAT.md`.

- **Each case has its own arena,** so a long suite does not keep every response.
  Results only live until the listener returns. Extracted values are copied to an
  arena that lasts for the suite.
- **Requests are built before sending,** so an undefined variable or invalid JSON
  body sends nothing.
- **Every failure inside a case is a test failure,** exit code `1`. An undefined
  variable may come from an earlier failed `extract`, so it is not treated as a
  usage error. Mistakes the parser can find are exit code `2`.
- **One `Client` serves the whole run,** so connections are reused between files.

## Desktop API requests

The Windows API Tests page sends method-and-URL requests through the same HTTP
engine as the CLI. `ui/api_controls.zig` owns native controls for editing,
clipboard, keyboard focus, and scrolling; `ui/screens/api_test.zig` owns their
shared layout and paints response metadata. It shows actual responses rather
than the dashboard's sample data. Request body/header/auth editors, saved tests,
assertions, and environment selection remain future UI work.

`ui/api_request.zig` snapshots each request into an arena and runs it on an
`Io.concurrent` task. The UI polls an atomic completion flag on a 50 ms timer;
only after acquiring it does the UI publish the worker's response or error.
Cancel sets a request-local atomic flag, leaving process shutdown untouched.
Closing the application cancels and joins pending work before freeing memory.
Each manual Send starts a fresh connection pool to avoid expired idle sockets.
Requests use a 30-second timeout and a 4 MiB response limit; text previews show
up to 64 KiB of source text, mark truncation, and handle invalid UTF-8 safely.

## Planned structure

ZTest's plan is one core engine shared by the CLI, desktop UI and CI/CD.
`src/core/` is where that engine will live.
