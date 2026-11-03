# Example API suites

Runnable `.ztest` suites that show the format: query parameters, JSON and raw
bodies, assertions, setup and teardown, extracted values and secrets.

They target any httpbin-compatible server. `echo_server.py` is a small offline
one, which CI uses:

```bash
cd examples/api
python3 echo_server.py 8080 &
ZTEST_EXAMPLE_KEY=demo-key ztest run tests/ --env ci --report junit
```

Without `--env`, `baseUrl` is `https://httpbin.org` from `ztest.json`
(`session.ztest` then needs `--env ci` for its `apiKey`, so run `basics.ztest` alone).
