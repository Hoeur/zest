# Releasing ZTest

Releases are built by `zig build release` and published by
`.github/workflows/release.yml` when a `v*` tag is pushed.

## What `zig build release` makes

From any one machine with Zig 0.17, it cross-compiles the release targets with
`ReleaseSafe` (safety checks kept, debug info stripped) and writes, into
`zig-out/release/`:

- `ztest-<version>-<arch>-<os>.zip` for Windows, with `ztest.exe` and
  `ztest-ui.exe`;
- `ztest-<version>-<arch>-<os>.tar.gz` for Linux (static, musl) and macOS,
  with `ztest`;
- `SHA256SUMS`, in `sha256sum` format.

Every archive also holds `README.md`, `LICENSE` and `CHANGELOG.md`, all inside
one `ztest-<version>-<arch>-<os>/` folder. The version comes from
`build.zig.zon`. When the build machine matches a target, that build is run
once with `--version` as a check.

Archives are written by `tools/package.zig` with the standard library only,
so packaging needs no `zip` or `tar` on the machine. Every file gets the time
from `-Dsource-date-epoch=<unix seconds>`, or 1980-01-01 without it, so the
same sources give the same archives; the workflow passes the last commit's
time.

## Cutting a release

1. Set `.version` in `build.zig.zon`, for example `"0.2.0"`.
2. In `CHANGELOG.md`, move the entries from `[Unreleased]` into a new
   `## [0.2.0] - YYYY-MM-DD` section with today's date, and update the links
   at the bottom.
3. Optional dry run: run the **Release** workflow by hand from the Actions
   tab on the branch. It builds and verifies everything without publishing.
4. Commit, then tag and push:

   ```bash
   git tag v0.2.0
   git push origin main v0.2.0
   ```

The workflow then:

1. **build** checks that the tag equals `v` + the `build.zig.zon` version and
   that the changelog has a dated section for it, checks formatting, runs the
   tests, and builds the archives.
2. **verify** runs on each platform's own runner: checks the archive against
   `SHA256SUMS`, extracts it, checks `--version`, and runs the example suites
   and a short load test against the offline echo server.
3. **publish** creates the GitHub release with every archive and
   `SHA256SUMS`, using the changelog section as the notes. Versions with a
   `-` suffix, such as `0.1.0-alpha`, are marked as pre-releases.

If any step fails nothing is published. Fix it, delete the tag
(`git push --delete origin v0.2.0 && git tag -d v0.2.0`), and tag again.

## Runners

The verify job uses `windows-11-arm` and `ubuntu-24.04-arm` for ARM64 and
`macos-15-intel` for Intel Macs. GitHub provides the ARM runners for public
repositories; a private repository needs larger runners, or those two matrix
entries removed.

## Not done yet

- The executables are not code-signed or notarized, so Windows SmartScreen
  and macOS Gatekeeper warn on first run ([`INSTALL.md`](./INSTALL.md)
  explains the workaround).
- No package-manager formulas (winget, Homebrew, Scoop) yet.
