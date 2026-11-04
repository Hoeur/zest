# Running ZTest in CI

`ztest` is one executable with stable exit codes, so any CI system can run it.
Install a published ZTest release, run your suites, and keep the reports.
The Linux examples below use a pinned x64 archive. For other runners, see
the [platform downloads](INSTALL.md).

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
      - name: Install ZTest
        env:
          ZTEST_VERSION: 0.1.0-alpha
        run: |
          cd "$RUNNER_TEMP"
          archive="ztest-$ZTEST_VERSION-x86_64-linux.tar.gz"
          curl -fsSLO "https://github.com/Hoeur/zest/releases/download/v$ZTEST_VERSION/$archive"
          tar -xzf "$archive"
          echo "$PWD/${archive%.tar.gz}" >> "$GITHUB_PATH"
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
    ZTEST_VERSION: "0.1.0-alpha"
  before_script:
    - apk add --no-cache curl
    - |
      archive="ztest-$ZTEST_VERSION-x86_64-linux.tar.gz"
      curl -fsSLO "https://github.com/Hoeur/zest/releases/download/v$ZTEST_VERSION/$archive"
      tar -xzf "$archive"
      export PATH="$PWD/${archive%.tar.gz}:$PATH"
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

[Install ZTest](INSTALL.md) on the Jenkins agent and put `ztest` on its `PATH`.

## Azure DevOps

```yaml
trigger: [main]
pool:
  vmImage: ubuntu-latest

steps:
  - script: |
      set -eu
      cd "$(Agent.TempDirectory)"
      archive="ztest-$ZTEST_VERSION-x86_64-linux.tar.gz"
      curl -fsSLO "https://github.com/Hoeur/zest/releases/download/v$ZTEST_VERSION/$archive"
      tar -xzf "$archive"
      echo "##vso[task.prependpath]$PWD/${archive%.tar.gz}"
    displayName: Install ZTest
    env:
      ZTEST_VERSION: 0.1.0-alpha
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

- When updating the pinned version, check the [release downloads](https://github.com/Hoeur/zest/releases) for the matching platform archive and checksum.
- `examples/api/` has suites and an offline echo server; this repository's CI
  runs them, which is a working end-to-end example.
