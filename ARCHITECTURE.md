# Architecture

This folder holds **zest**, a Zig unit-test library, and the early **ZTest** CLI
and desktop UI. The API and load-testing engine in `ROADMAP.md` and `TODO.md` is
planned and not yet built.

## Layout

```text
build.zig          build steps; produces ztest (CLI) and ztest-ui (Windows)
build.zig.zon      package metadata and version
src/root.zig       the whole zest library and its own tests
src/main.zig       ztest entry point: exit codes and command dispatch
src/cli.zig        argument parsing, with no I/O
src/core/          logger, config, context and exit codes
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

- **Exit codes** are `0` success, `1` test failure, `2` configuration or usage
  error, and `3` internal error.
- **Settings** come from an optional `ztest.json` in the working directory, and
  flags override it. Unknown fields are errors, so a misspelled setting is
  reported rather than ignored.
- **Output:** command results go to stdout and diagnostics to stderr. Both use
  streaming writers, because a positional writer overwrites redirected output.
- **Allocators:** commands use the process arena from `Context`, which is freed
  on exit. Long-running work such as load tests will need its own strategy.

## Planned structure

ZTest's plan is one core engine shared by the CLI, desktop UI and CI/CD.
`src/core/` is where that engine will live.
