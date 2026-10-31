# Repository Guidelines

## Project Structure & Module Organization

- `src/root.zig` contains the `zest` unit-test library and its self-tests.
- `src/main.zig`, `src/cli.zig`, and `src/commands/` provide the ZTest CLI entry point, argument parsing, and commands.
- `src/core/` contains shared configuration, HTTP, assertions, `.ztest` parsing, suite execution, and secret redaction. Keep testing business logic here so CLI and UI can share it.
- `src/ui/` contains the Windows Win32/GDI+ desktop shell; runtime assets live in `src/ui/assets/`. `ui/` and `docs/assets/` hold design references and mockups.
- `examples/` demonstrates the library. Consult `ARCHITECTURE.md` and `docs/TEST_FORMAT.md` for implementation and suite-format contracts; roadmap features may be unimplemented.

## Build, Test, and Development Commands

Use Zig 0.17.0 or newer (`build.zig.zon`). Run from the repository root:

- `zig build`: build and install the CLI and, on Windows, desktop executable into `zig-out/bin/`.
- `zig build run -- --help`: run the CLI with forwarded arguments.
- `zig build test`: run library, CLI/core, and UI state/layout tests.
- `zig build demo`: run passing/skipped example tests.
- `zig build failures`: demonstrate intentional test failures; expect a nonzero exit.
- `zig build ui`: launch the desktop shell on Windows.
- `zig build -Doptimize=ReleaseFast`: build optimized executables.
- `zig fmt --check build.zig src examples`: check formatting; omit `--check` to apply it.

## Coding Style & Naming Conventions

Use four-space indentation and `zig fmt`. Follow existing camelCase function names, PascalCase types, and snake_case files and fields. Document public behavior with `///` and module purpose with `//!`. Make allocator ownership and result lifetimes explicit; pair owned resources with `defer` cleanup.

## Testing Guidelines

Use descriptive Zig `test "behavior"` blocks with `std.testing`, colocated with implementation or in `*_test.zig`. Ensure new test modules are imported by an existing test root or wired into `build.zig`. HTTP integration tests use scripted loopback servers. Cover failures, cleanup, and changed contracts; no numeric coverage threshold is configured. Library examples use `pub fn name(t: *T) !void` suite methods.

## Commit & Pull Request Guidelines

History currently contains only `init zest`; no established commit format exists. Write concise imperative subjects and keep commits focused. PRs should describe behavior changes, link relevant issues, list validation commands/results, and include screenshots for UI changes. Keep `.zig-cache/` and `zig-out/` out of commits.

## Security & Configuration

Keep credentials out of fixtures and committed configuration. Reference environment variables through `{ "env": "NAME" }` in `ztest.json`. Preserve secret masking and TLS verification when changing request or reporting paths.
