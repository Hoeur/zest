# `.ztest` format

A `.ztest` file describes one suite of API tests. This is the specification for
the parser in `src/core/parser/` and the runner in `src/core/runner/`.

## Example

```text
# Login, then read the profile.
suite "Authentication"

var baseUrl = "https://api.example.com"

setup
  POST {{baseUrl}}/login
  header Content-Type application/json
  body {
    "email": "test@example.com",
    "password": "123456"
  }
  expect status == 200
  extract token = body.token
end

test "Read the profile"
  timeout 2s
  GET {{baseUrl}}/me
  header Authorization Bearer {{token}}
  expect status == 200
  expect response_time < 500ms
  expect body.user.id exists
end

test "Not ready yet"
  skip
  GET {{baseUrl}}/billing
end

teardown
  DELETE {{baseUrl}}/session
  header Authorization Bearer {{token}}
end
```

## Lines

- Statements are line-based. Blank lines are ignored, and indentation has no meaning.
- `\n` and `\r\n` line endings both work, and a UTF-8 byte order mark is ignored.
- A comment starts with `#` and takes a whole line. Trailing comments are not
  allowed, because `#` is valid in a URL or header value.
- A comment-like line inside a `body { ... }` block is part of the body.
- Keywords and HTTP methods are case-sensitive. Methods are uppercase.

## Grammar

```text
file       = suite-line { blank | variable | setup | teardown | test } ;
suite-line = "suite" string EOL ;
setup      = "setup" EOL { hook-item } "end" EOL ;
teardown   = "teardown" EOL { hook-item } "end" EOL ;
test       = "test" string EOL { test-item } "end" EOL ;

test-item  = hook-item | "skip" EOL | "disabled" EOL ;
hook-item  = blank | variable | timeout | request | header | body | expect | extract ;

variable   = "var" [ "secret" ] name "=" ( string | number | "true" | "false" ) EOL ;
timeout    = "timeout" time EOL ;
request    = METHOD text EOL ;
header     = "header" word text EOL ;
body       = "body" ( json-block | string ) EOL ;
expect     = "expect" assertion EOL ;
extract    = "extract" [ "secret" ] name "=" target EOL ;

name       = letter-digit-or-underscore, { letter-digit-or-underscore } ;
time       = number ( "ms" | "s" ) ;
string     = '"' JSON-escaped characters on one line '"' ;
text       = the rest of the line, without surrounding spaces ;
word       = characters up to the next space ;
json-block = a balanced { } or [ ] block, which may span lines ;
```

`METHOD` is any of `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`,
`TRACE` or `CONNECT`.

## Rules

- `suite` must be the first statement, and a file has exactly one.
- A suite needs at least one test, so a file that runs nothing cannot pass in CI.
- A suite has at most one `setup` and one `teardown`, which can appear anywhere.
- Every test, `setup` and `teardown` must send exactly one request and close with `end`.
- A test has at most one `body`. `skip` and `disabled` are for tests only.
- Statements inside a test can be in any order.

## Statements

**`var`** defines a value for `{{name}}`. A `var` in a test applies to that test
and overrides the suite's value. An `extract` overrides both. `var secret name`
hides the value from results.

**`timeout`** limits one request. A time needs a unit, and must be above zero.
Without one, a request has 30 seconds.

**Request line** is a method and URL. The URL is raw text, so it can hold
`{{variables}}` and `#` fragments.

**`header`** takes a name, then the rest of the line as the value. There is no
colon after the name. Repeat it for more headers.

**`body`** is either JSON or a quoted string:

```text
body { "name": "Ada", "id": {{id}} }
body "plain text\nwith a line break"
```

A JSON body is checked after variables are replaced, not while parsing, because
`{{id}}` above is not valid JSON until then. Brackets inside JSON strings do not
count towards the balance.

**`expect`** is the same expression `ztest api --assert` takes:

```text
status == 200
response_time < 500ms
body.items[0].name == "Apple"
body.token exists
header.content-type contains "application/json"
```

The value of an `expect` is a literal, so `{{name}}` only works inside quotes.

**`extract`** stores a value from the response for later requests in the suite.
The source is any `expect` target: `status`, `response_time`, `body`,
`body.<path>` or `header.<name>`. JSON strings lose their quotes, and
`response_time` is a number of milliseconds. Extracts only run when every
`expect` in that case passed, and a value that cannot be found fails the case.
`extract secret name` hides the value from results, even if an `expect` fails.

**`skip`** does not run the test, and counts it as skipped. **`disabled`** does
not run or count it.

## Variables

`{{name}}` is replaced in URLs, header names and values, bodies and quoted
`expect` values.

- Lookup order is extracted values, then the test's `var`, the suite's, the
  chosen environment's, and the global ones in `ztest.json`.
- A name that is not defined fails the case, and its request is not sent.
- Only letters, digits and `_` make a variable, so `{{ name }}` and `{{}}` stay
  as written.
- Values are inserted as they are and not replaced again, so a `var` cannot refer
  to another one. Quotes in a value are not escaped in a JSON body.

## Environments

`ztest.json` in the current directory can define variables for every file:

```json
{
  "variables": { "version": "v1" },
  "environments": {
    "staging": {
      "baseUrl": "https://staging.example.com",
      "apiKey": { "env": "STAGING_API_KEY" }
    }
  }
}
```

- `variables` always apply. `--env <name>` adds that environment's variables,
  which override them. An environment name can be anything.
- A value is a string, number, `true` or `false`, or `{ "env": "NAME" }`, which
  reads a process environment variable and is always secret.
- An unknown environment, or an `{ "env": ... }` value that is unset or empty in
  the variables being used, stops the run before any request is sent.

## Secrets

A value from `var secret`, `extract secret` or `{ "env": "NAME" }` is sent as
normal, and shown as `********` in results and error messages, in every test and
later file of the run. The list starts with every `var secret` in a suite, so a
test cannot show another test's value.

- Keep real keys in process environment variables. A `var secret` is hidden in
  results but is still written in the file. ZTest stores no secrets itself.
- Only the exact value is hidden. An encoded copy, such as a Basic auth header or
  a JSON-escaped value inside a larger object, is not recognized.
- `ztest api` has no variables, so it does not mask anything.

## Running

```bash
ztest run tests/login.ztest
ztest run tests/
ztest run tests/ --fail-fast
ztest run tests/ --env staging
```

A directory runs its `.ztest` files, including subdirectories, in sorted order.
Hidden directories and links are skipped. Every file is parsed first, so a syntax
error sends no requests.

- **Order:** `setup`, then each test in file order, then `teardown`.
- **Failures:** a failed test does not stop the next one. `--fail-fast` stops
  after the first failure, including later files.
- **Failed `setup`:** the suite's tests do not run. `teardown` still does, because
  `setup` may have created something, so a `teardown` that needs a value `setup`
  never extracted also fails.
- **Hooks** do not run if every test in the suite is skipped or disabled, and
  count towards the summary only when they fail.
- **Ctrl-C** stops the run and does not run `teardown`.

| Exit code | Meaning |
|---|---|
| `0` | Every test that ran passed |
| `1` | A test or hook failed, including a bad URL or an undefined variable |
| `2` | A file is missing or has a syntax error, an environment is unknown or incomplete, or no test ran at all |
| `3` | Internal error |
| `130` | Interrupted by Ctrl-C |

## Errors

The parser stops at the first problem and reports its line and a message, so a
caller can print `tests/login.ztest:12: this body is never closed`.

## Not in the format yet

Query parameters and cookies go in the URL and a `header`. There is no `auth`
statement, or form or multipart body. A JSON key
containing `.` or `[` cannot be named in a path.
