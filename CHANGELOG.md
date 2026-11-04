# Changelog

All notable changes to ZTest are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The release workflow publishes the
section whose heading matches the tag, so keep one `## [version]` heading per
release.

## [Unreleased]

## [0.1.0-alpha] - Unreleased

The first preview: the CLI on Windows, Linux and macOS, and the desktop app on
Windows.

### Added

- `ztest api` sends one HTTP or HTTPS request, prints the response and checks
  it with `--assert`. Basic, Bearer and API-key auth, JSON and raw bodies,
  query parameters, timeouts and redirects.
- `ztest run` runs `.ztest` files and directories: setup and teardown, `query`
  and `auth` statements, extracted values, environments and masked secrets
  from `ztest.json`, fail-fast, and stable exit codes for CI.
- `--report json|junit|html[=path]` on `ztest run`; `--report json` on
  `ztest load`.
- `ztest load` with virtual users, ramp-up, a rate limit, assertions on every
  response, and RPS, failures and p50/p90/p95/p99 latency.
- `ztest init` writes a starter `ztest.json` and `tests/example.ztest`.
- The `zest` unit-test library for Zig.
- Windows desktop app (`ztest-ui.exe`): API Tests request builder with
  Params, Headers, Auth, Body and live assertions; Test Suites with live
  results and report export; Load Tests with live charts; Dashboard and
  Reports from run history; Environments and Settings.
- CI examples for GitHub Actions, GitLab CI, Jenkins and Azure DevOps.
- Release archives for Windows, Linux and macOS on x64 and ARM64, with
  `SHA256SUMS` (`zig build release`).

### Security

- Secrets from `ztest.json` are masked in console output, logs, reports and
  the desktop app. TLS certificates are verified.
- Response and request size limits; the parser, writer, assertions, config
  and templates are fuzzed.

[Unreleased]: https://github.com/Hoeur/zest/compare/v0.1.0-alpha...HEAD
[0.1.0-alpha]: https://github.com/Hoeur/zest/releases/tag/v0.1.0-alpha
