# Running ZTest in CI

`ztest` is one executable with stable exit codes, so any CI system can run it.
Download a release archive ([`INSTALL.md`](./INSTALL.md#in-ci)) or build it
with Zig 0.17 (`zig build -Doptimize=ReleaseSafe`), then run your suites and
keep the reports.

## What the CI step needs

- **Exit codes:** `0` every test passed, `1` a test or hook failed, `2` a
  file, environment or argument is wrong, `3` internal error, `130` interrupted.
  Fail the job on anything but `0`.
- **Secrets:** put keys in the CI system's secret store and reference them from
  `ztest.json` as `{ "env": "NAME" }`. Such values are always hidden in output
  and reports.
- **Reports:** `--report junit=path.xml` for the CI's test view,
  `--report html=path.html` for a page to download, `--report json=path.json`
  for your own tooling. Repeat `--report` for several.

```bash
ztest run tests/ --env staging \
  --report junit=reports/junit.xml \
  --report html=reports/report.html
```

A load test fails the job when any response fails its `--assert`:

```bash
ztest load https://staging.example.com/health --users 20 --duration 30s \
  --assert "status == 200" --assert "response_time < 500ms" \
  --report json=reports/load.json
```

## GitHub Actions

This repository's own workflow is in `.github/workflows/ci.yml`. For a project
that uses ZTest:

```yaml
name: API tests
on: [push, pull_request]

jobs:
  api-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.17.0
      - name: Build ZTest
        run: |
          git clone --depth 1 https://github.com/Hoeur/zest.git "$RUNNER_TEMP/zest"
          (cd "$RUNNER_TEMP/zest" && zig build -Doptimize=ReleaseSafe)
          echo "$RUNNER_TEMP/zest/zig-out/bin" >> "$GITHUB_PATH"
      - name: Run suites
        env:
          STAGING_API_KEY: ${{ secrets.STAGING_API_KEY }}
        run: ztest run tests/ --env staging --report junit=reports/junit.xml --report html=reports/report.html
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: ztest-reports
          path: reports/
```

## GitLab CI

GitLab shows JUnit results on the merge request when the report is declared.

```yaml
api-tests:
  image: alpine:3.20
  variables:
    ZIG_VERSION: "0.17.0"
  before_script:
    - apk add --no-cache git curl xz
    - curl -sSfL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt
    - export PATH="/opt/zig-x86_64-linux-${ZIG_VERSION}:$PATH"
    - git clone --depth 1 https://github.com/Hoeur/zest.git /opt/zest
    - (cd /opt/zest && zig build -Doptimize=ReleaseSafe)
    - export PATH="/opt/zest/zig-out/bin:$PATH"
  script:
    # STAGING_API_KEY comes from Settings > CI/CD > Variables, marked masked.
    - ztest run tests/ --env staging --report junit=reports/junit.xml --report html=reports/report.html
  artifacts:
    when: always
    paths: [reports/]
    reports:
      junit: reports/junit.xml
```

## Jenkins

With the JUnit plugin, results appear in the build's test view.

```groovy
pipeline {
  agent any
  environment {
    STAGING_API_KEY = credentials('staging-api-key')
  }
  stages {
    stage('API tests') {
      steps {
        sh 'ztest run tests/ --env staging --report junit=reports/junit.xml --report html=reports/report.html'
      }
    }
  }
  post {
    always {
      junit 'reports/junit.xml'
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
    }
  }
}
```

The agent needs `ztest` on its `PATH`, built once as above or installed from a
release archive.

## Azure DevOps

```yaml
trigger: [main]
pool:
  vmImage: ubuntu-latest

steps:
  - script: |
      curl -sSfL https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz | tar -xJ -C $(Agent.TempDirectory)
      git clone --depth 1 https://github.com/Hoeur/zest.git $(Agent.TempDirectory)/zest
      cd $(Agent.TempDirectory)/zest && $(Agent.TempDirectory)/zig-x86_64-linux-0.17.0/zig build -Doptimize=ReleaseSafe
      echo "##vso[task.prependpath]$(Agent.TempDirectory)/zest/zig-out/bin"
    displayName: Build ZTest
  - script: ztest run tests/ --env staging --report junit=reports/junit.xml --report html=reports/report.html
    displayName: Run API suites
    env:
      STAGING_API_KEY: $(STAGING_API_KEY)
  - task: PublishTestResults@2
    condition: always()
    inputs:
      testResultsFormat: JUnit
      testResultsFiles: reports/junit.xml
  - publish: reports
    artifact: ztest-reports
    condition: always()
```

## Notes

- The download URLs above follow the layout of Zig's release archives; check
  [ziglang.org/download](https://ziglang.org/download/) for the exact file name
  of your Zig version and platform.
- Once ZTest publishes release archives, replace the build steps with a
  download, as Zig is then not needed on the agent.
- `examples/api/` has suites and an offline echo server; this repository's CI
  runs them, which is a working end-to-end example.
