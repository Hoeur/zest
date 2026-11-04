# Installing ZTest

Each release has one archive per platform on the
[releases page](https://github.com/Hoeur/zest/releases). An archive holds the
`ztest` command, plus `ztest-ui.exe`, the desktop app, on Windows. Nothing
else is needed: there is no installer, runtime or shared library.

| Platform | Archive |
|---|---|
| Windows x64 | `ztest-<version>-x86_64-windows.zip` |
| Windows ARM64 | `ztest-<version>-aarch64-windows.zip` |
| Linux x64 | `ztest-<version>-x86_64-linux.tar.gz` |
| Linux ARM64 | `ztest-<version>-aarch64-linux.tar.gz` |
| macOS Intel | `ztest-<version>-x86_64-macos.tar.gz` |
| macOS Apple Silicon | `ztest-<version>-aarch64-macos.tar.gz` |

The Linux builds are static, so they run on any distribution, including
Alpine. The desktop app is Windows-only for now; on Linux and macOS the
archive has the command-line tool.

## Check the download

Compare the SHA-256 digest of your downloaded archive with its entry in
`SHA256SUMS` on the release page.

```bash
# Linux
sha256sum ztest-0.1.0-alpha-x86_64-linux.tar.gz
# macOS
shasum -a 256 ztest-0.1.0-alpha-aarch64-macos.tar.gz
```

```powershell
# Windows: compare with the line for your archive in SHA256SUMS
(Get-FileHash ztest-0.1.0-alpha-x86_64-windows.zip -Algorithm SHA256).Hash.ToLower()
```

## Linux and macOS

```bash
version=0.1.0-alpha
target=x86_64-linux        # or aarch64-linux, x86_64-macos, aarch64-macos
curl -LO "https://github.com/Hoeur/zest/releases/download/v$version/ztest-$version-$target.tar.gz"
tar -xzf "ztest-$version-$target.tar.gz"
sudo install "ztest-$version-$target/ztest" /usr/local/bin/ztest
ztest --version
```

Without `sudo`, copy `ztest` to `~/.local/bin` or any other folder on your
`PATH`.

On macOS, a file downloaded with a browser is quarantined, and the first run
is blocked because the binary is not notarized. Clear the flag once:

```bash
xattr -d com.apple.quarantine /usr/local/bin/ztest
```

Downloads made with `curl` are not quarantined.

## Windows

1. Download the `.zip` for your machine (x64 for most PCs, ARM64 for
   Snapdragon and other ARM laptops) and extract it, for example to
   `C:\Tools\ztest`.
2. Run `ztest-ui.exe` for the desktop app.
3. To use `ztest` from any terminal, add the folder to your `PATH`:

   ```powershell
   $folder = 'C:\Tools\ztest\ztest-0.1.0-alpha-x86_64-windows'
   $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
   $newPath = (@($userPath, $folder) | Where-Object { $_ }) -join ';'
   [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
   ```

   Set `$folder` to the directory containing `ztest.exe`. Open a new terminal
   and run `ztest --version`.

Windows SmartScreen may warn about an unrecognised app the first time,
because the executables are not code-signed yet. Choose **More info** and
**Run anyway**.

## In CI

Download and extract the ZTest archive in a job step. For GitHub Actions on
Linux:

```yaml
- name: Install ZTest
  run: |
    curl -fsSLO "https://github.com/Hoeur/zest/releases/download/v0.1.0-alpha/ztest-0.1.0-alpha-x86_64-linux.tar.gz"
    tar -xzf ztest-0.1.0-alpha-x86_64-linux.tar.gz
    echo "$PWD/ztest-0.1.0-alpha-x86_64-linux" >> "$GITHUB_PATH"
```

[`CI.md`](./CI.md) shows the rest of the job for each CI system.

## Uninstall

Delete the `ztest` executable (and `ztest-ui.exe` on Windows) and, if you
added it, the folder from your `PATH`. The desktop app keeps run history in a
`.ztest/` folder beside each workspace's `ztest.json`; delete it to remove the
history.
