#!/usr/bin/env bats
#
# Black-box tests: every test runs bin/heroku-scripts with a stubbed `heroku`
# on PATH, so nothing here ever touches a real Heroku account. The stub serves
# a fixed pipelines:info table and otherwise echoes its argv (bracketed) so we
# can assert on how arguments are routed.

# `run --separate-stderr` (used by the empty-output tests) needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
  TESTDIR="$(mktemp -d)"
  mkdir -p "$TESTDIR/bin"
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\napp-two        production\napp-three        staging\n' "$2"
  exit 0
fi
printf 'HEROKU'
for a in "$@"; do printf ' [%s]' "$a"; done
printf '\n'
STUB
  chmod +x "$TESTDIR/bin/heroku"
  PATH="$TESTDIR/bin:$PATH"
  SCRIPT="${BATS_TEST_DIRNAME}/../bin/heroku-scripts"
  cd "$TESTDIR"
}

teardown() {
  rm -rf "$TESTDIR"
}

@test "apps lists only apps in the requested stage" {
  run "$SCRIPT" apps mypipe staging
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "app-one" ]
  [ "${lines[1]}" = "app-three" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "apps rejects the wrong argument count" {
  run "$SCRIPT" apps onlyone
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "pipeline-cmd prints a header and one record per app" {
  run "$SCRIPT" pipeline-cmd mypipe staging "config"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;output" ]
  [[ "$output" == *"app-one;"* ]]
  [[ "$output" == *"app-three;"* ]]
}

# heroku stub where app-one is slow, so completion order (app-three first)
# differs from sorted order (app-one first).
_heroku_stub_slow_app_one() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\napp-three        staging\n' "$2"; exit 0
fi
[ "$3" = "app-one" ] && sleep 0.4
echo "out-$3"
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "pipeline-cmd streams records in completion order by default" {
  _heroku_stub_slow_app_one
  run "$SCRIPT" pipeline-cmd mypipe staging "config" --concurrency=2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;output" ]
  [ "${lines[1]}" = "app-three;out-app-three" ]
  [ "${lines[2]}" = "app-one;out-app-one" ]
}

@test "pipeline-cmd --no-stream emits rows sorted by app name" {
  _heroku_stub_slow_app_one
  run "$SCRIPT" pipeline-cmd mypipe staging "config" --concurrency=2 --no-stream
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;output" ]
  [ "${lines[1]}" = "app-one;out-app-one" ]
  [ "${lines[2]}" = "app-three;out-app-three" ]
}

# heroku stub where app-one has output but app-three is empty.
_heroku_stub_app_three_empty() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\napp-three        staging\n' "$2"; exit 0
fi
app=""; prev=""
for a in "$@"; do [[ "$prev" == "-a" ]] && app="$a"; prev="$a"; done
[ "$app" = "app-one" ] && echo "value-for-app-one"
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "pipeline-cmd skips empty output and reports a count on stderr" {
  _heroku_stub_app_three_empty
  # Capture to files rather than via `run`, whose stderr normalization (leading
  # newline / empty-line handling) varies across bats versions.
  "$SCRIPT" pipeline-cmd mypipe staging "config:get X" >stdout.txt 2>stderr.txt
  grep -q "app-one;value-for-app-one" stdout.txt
  ! grep -q "app-three" stdout.txt
  # A blank line separates the output from the summary.
  [ -z "$(head -n 1 stderr.txt)" ]
  grep -q "1 app(s) with empty output skipped" stderr.txt
  grep -q -- "-a/--all" stderr.txt
  # stderr is not a terminal here, so no ANSI styling is emitted.
  ! grep -qF $'\033' stderr.txt
}

@test "pipeline-cmd -a includes empty output and prints no skip summary" {
  _heroku_stub_app_three_empty
  run --separate-stderr "$SCRIPT" pipeline-cmd mypipe staging "config:get X" -a
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-one;value-for-app-one"* ]]
  [[ "$output" == *"app-three;"* ]]
  [[ "$stderr" != *"skipped"* ]]
}

# heroku stub: app-one has a single-line value, app-three is multi-line.
_heroku_stub_multiline() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\napp-three        staging\n' "$2"; exit 0
fi
app=""; prev=""
for a in "$@"; do [[ "$prev" == "-a" ]] && app="$a"; prev="$a"; done
case "$app" in
  app-one)   echo "single-value";;
  app-three) printf 'line-one\nline-two\n';;
esac
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "pipeline-cmd --table renders an aligned table" {
  _heroku_stub_multiline
  run "$SCRIPT" pipeline-cmd mypipe staging "config:get X" --table --no-stream
  [ "$status" -eq 0 ]
  # Column width is the widest app name (app-three = 9).
  [ "${lines[0]}" = "appname   | output" ]
  [[ "${lines[1]}" == *"-+-"* ]]
  [ "${lines[2]}" = "app-one   | single-value" ]
}

@test "pipeline-cmd --table aligns continuation lines of multi-line output" {
  _heroku_stub_multiline
  run "$SCRIPT" pipeline-cmd mypipe staging "config:get X" --table --no-stream
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "app-three | line-one" ]
  # Continuation line: blank app cell, same pipe column, no app name.
  [ "${lines[4]}" = "          | line-two" ]
}

@test "pipeline-cmd --csv forces CSV output" {
  _heroku_stub_multiline
  run "$SCRIPT" pipeline-cmd mypipe staging "config:get X" --csv --no-stream
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;output" ]
  [ "${lines[1]}" = "app-one;single-value" ]
}

@test "pipeline-cmd routes -a before a -- separator" {
  run "$SCRIPT" pipeline-cmd mypipe staging "ps:exec -- ls -la"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ps:exec] [-a] [app-one] [--] [ls] [-la]"* ]]
}

@test "pipeline-cmd rejects a non-positive concurrency" {
  run "$SCRIPT" pipeline-cmd mypipe staging "config" --concurrency=0
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "pipeline-task rejects a non-numeric concurrency" {
  run "$SCRIPT" pipeline-task mypipe staging MyTask --concurrency=abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "an unknown option is rejected" {
  run "$SCRIPT" pipeline-cmd mypipe staging "config" --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "an empty stage reports no apps" {
  run "$SCRIPT" pipeline-cmd mypipe nostage "config"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No apps found"* ]]
}

# heroku stub for config-replace: serves per-app config:get values (with
# spaces, to prove values survive as single argv words) and logs every
# config:set argv to ./set-calls (workers inherit the test's cwd), so tests
# can assert the exact call shape — or that no call happened at all.
_heroku_stub_config_values() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-match        staging\napp-unset        staging\napp-differs        staging\n' "$2"; exit 0
fi
app=""; prev=""
for a in "$@"; do [[ "$prev" == "-a" ]] && app="$a"; prev="$a"; done
if [[ "$1" == "config:get" ]]; then
  # Real config:get prints an empty line when the var is unset.
  case "$app" in
    app-match)   echo "old value";;
    app-differs) echo "other value";;
    app-unset)   echo "";;
  esac
  exit 0
fi
if [[ "$1" == "config:set" ]]; then
  { printf 'SET'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> ./set-calls
  echo "set-done-$app"
  exit 0
fi
echo "unexpected: $*" >&2
exit 1
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "config-replace sets the var where the value matches and uses config:set output as the record" {
  _heroku_stub_config_values
  run --separate-stderr "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value"
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-match;set-done-app-match"* ]]
}

@test "config-replace passes VAR=value and -a app to config:set as separate argv words" {
  _heroku_stub_config_values
  run "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value"
  [ "$status" -eq 0 ]
  # Exactly one config:set, with the space-containing value as ONE word.
  [ "$(wc -l < set-calls | tr -d ' ')" = "1" ]
  grep -qF "SET [config:set] [MY_VAR=new value] [-a] [app-match]" set-calls
}

@test "config-replace skips apps without the var and reports a count on stderr" {
  _heroku_stub_config_values
  # File capture rather than `run`, matching the empty-output test above.
  "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value" >stdout.txt 2>stderr.txt
  ! grep -q "app-unset" stdout.txt
  [ -z "$(head -n 1 stderr.txt)" ]
  grep -q "1 app(s) without MY_VAR skipped" stderr.txt
  grep -q -- "-a/--all" stderr.txt
}

@test "config-replace -a includes unset apps with a not-set record" {
  _heroku_stub_config_values
  run --separate-stderr "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value" -a
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-unset;skipped: MY_VAR not set"* ]]
  [[ "$stderr" != *"skipped"* ]]
}

@test "config-replace leaves a different value alone and emits a mismatch record" {
  _heroku_stub_config_values
  run "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value"
  [ "$status" -eq 0 ]
  [[ "$output" == *'app-differs;skipped: MY_VAR is "other value" (expected "old value")'* ]]
  ! grep -q "app-differs" set-calls
}

@test "config-replace --dry-run reports would-set records and never calls config:set" {
  _heroku_stub_config_values
  run "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-match;would set MY_VAR=new value (currently old value)"* ]]
  # The stub logs every config:set; the file never existing proves none ran.
  [ ! -e set-calls ]
}

@test "config-replace rejects the wrong argument count" {
  run "$SCRIPT" config-replace mypipe staging MY_VAR "old value"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "config-replace rejects a non-positive concurrency" {
  run "$SCRIPT" config-replace mypipe staging MY_VAR old new --concurrency=0
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "config-replace surfaces a failed config:get as an error record and never writes" {
  # A failed lookup must not have its error text compared against <old-value> —
  # here the message IS the old value, the worst case for that comparison.
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-geterr        staging\n' "$2"; exit 0
fi
if [[ "$1" == "config:get" ]]; then
  echo "old value" >&2
  exit 1
fi
if [[ "$1" == "config:set" ]]; then
  : >> ./set-calls
  exit 0
fi
STUB
  chmod +x "$TESTDIR/bin/heroku"
  run "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value"
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-geterr;error: old value"* ]]
  [ ! -e set-calls ]
}

@test "config-replace surfaces a failed config:set as the app's record, not a skip" {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-match        staging\n' "$2"; exit 0
fi
if [[ "$1" == "config:get" ]]; then
  echo "old value"
  exit 0
fi
if [[ "$1" == "config:set" ]]; then
  echo "Boom: rate limited" >&2
  exit 1
fi
STUB
  chmod +x "$TESTDIR/bin/heroku"
  run --separate-stderr "$SCRIPT" config-replace mypipe staging MY_VAR "old value" "new value"
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-match;Boom: rate limited"* ]]
  [[ "$stderr" != *"skipped"* ]]
}

@test "promote --dry-run prints commands without running or prompting" {
  run "$SCRIPT" promote my-app team pipe --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run: heroku apps:transfer team -a my-app-staging"* ]]
  [[ "$output" != *"HEROKU"* ]]
}

@test "promote aborts when the prompt is declined" {
  run "$SCRIPT" promote my-app team pipe <<< "n"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborted."* ]]
}

@test "promote passes a metacharacter team name as one literal arg (no eval)" {
  run "$SCRIPT" promote my-app 'evil; touch PWNED' pipe --yes
  [ "$status" -eq 0 ]
  [ ! -e PWNED ]
  [[ "$output" == *"[apps:transfer] [evil; touch PWNED] [-a] [my-app-staging]"* ]]
}

@test "version flag prints the name and version" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "heroku-scripts "* ]]
}

# Replaces the argv-echo heroku stub with one that reveals the inherited
# HEROKU_API_KEY, so we can assert the key reaches the (backgrounded) heroku.
_heroku_stub_reveals_key() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\n' "$2"; exit 0
fi
echo "key=${HEROKU_API_KEY:-unset}"
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "HEROKU_SCRIPTS_OP_REF resolves the key via op and passes it to heroku" {
  _heroku_stub_reveals_key
  cat > "$TESTDIR/bin/op" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "read" ] && { echo "op-key-for:$2"; exit 0; }
exit 1
STUB
  chmod +x "$TESTDIR/bin/op"

  HEROKU_SCRIPTS_OP_REF="op://vault/Heroku/credential" \
    run "$SCRIPT" pipeline-cmd mypipe staging "config"
  [ "$status" -eq 0 ]
  [[ "$output" == *"key=op-key-for:op://vault/Heroku/credential"* ]]
}

@test "an existing HEROKU_API_KEY is used as-is and op is never called" {
  _heroku_stub_reveals_key
  cat > "$TESTDIR/bin/op" <<'STUB'
#!/usr/bin/env bash
echo "op should not have been called" >&2; exit 99
STUB
  chmod +x "$TESTDIR/bin/op"

  HEROKU_API_KEY="preset-key" HEROKU_SCRIPTS_OP_REF="op://vault/Heroku/credential" \
    run "$SCRIPT" pipeline-cmd mypipe staging "config"
  [ "$status" -eq 0 ]
  [[ "$output" == *"key=preset-key"* ]]
  [[ "$output" != *"op should not have been called"* ]]
}

# heroku stub that counts its invocations in ./stub-calls (tests cd into
# $TESTDIR, and the script's workers inherit that cwd) and fails with a
# transient connection error until the third call.
_heroku_stub_flaky_connection() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\n' "$2"; exit 0
fi
n=$(cat ./stub-calls 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > ./stub-calls
if [ "$n" -lt 3 ]; then
  echo "Could not connect to dyno!"
  exit 1
fi
echo "success-after-$n"
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "pipeline-cmd --retries re-runs transient connection errors until success" {
  _heroku_stub_flaky_connection
  HEROKU_SCRIPTS_RETRY_DELAY=0 \
    run --separate-stderr "$SCRIPT" pipeline-cmd mypipe staging "ps:exec ls" --retries=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-one;success-after-3"* ]]
  [[ "$stderr" == *"transient connection error, retrying (1/2)"* ]]
  [[ "$stderr" == *"transient connection error, retrying (2/2)"* ]]
}

@test "pipeline-cmd without --retries keeps the single-attempt behavior" {
  _heroku_stub_flaky_connection
  run "$SCRIPT" pipeline-cmd mypipe staging "ps:exec ls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-one;Could not connect to dyno!"* ]]
  [ "$(cat stub-calls)" = "1" ]
}

@test "pipeline-cmd --retries surfaces a persistent transient error after the last attempt" {
  _heroku_stub_flaky_connection
  HEROKU_SCRIPTS_RETRY_DELAY=0 \
    run --separate-stderr "$SCRIPT" pipeline-cmd mypipe staging "ps:exec ls" --retries=1
  [ "$status" -eq 0 ]
  # Two attempts (initial + 1 retry), both flaky, so the error is the record.
  [[ "$output" == *"app-one;Could not connect to dyno!"* ]]
  [ "$(cat stub-calls)" = "2" ]
}

# heroku stub that counts invocations and always fails with a NON-transient
# error, so retries must not kick in.
_heroku_stub_real_failure() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\napp-one        staging\n' "$2"; exit 0
fi
n=$(cat ./stub-calls 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > ./stub-calls
echo "bash: some-remote-cmd: command not found"
exit 127
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "pipeline-cmd --retries never retries a genuine command failure" {
  _heroku_stub_real_failure
  HEROKU_SCRIPTS_RETRY_DELAY=0 \
    run --separate-stderr "$SCRIPT" pipeline-cmd mypipe staging "ps:exec some-remote-cmd" --retries=3
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-one;bash: some-remote-cmd: command not found"* ]]
  [ "$(cat stub-calls)" = "1" ]
  [[ "$stderr" != *"retrying"* ]]
}

@test "pipeline-cmd rejects a non-numeric retries value" {
  run "$SCRIPT" pipeline-cmd mypipe staging "config" --retries=abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

# Writes a curl stub that speaks deploy-slug's platform-API dialect: it
# answers GETs from the case table passed in $1 (a chunk of shell script),
# and logs every POST — method, path, bearer token, body — to ./api-calls so
# tests can assert the exact release call, or that none happened. The real
# heroku_api asks curl for the HTTP status on a trailing line (-w), so every
# reply here ends in one.
_curl_stub_platform_api() {
  cat > "$TESTDIR/bin/curl" <<STUB
#!/usr/bin/env bash
method=GET; url=""; body=""; auth=""; prev=""
for a in "\$@"; do
  case "\$prev" in
    -X) method="\$a";;
    -d) body="\$a";;
    -H) [[ "\$a" == "Authorization: Bearer "* ]] && auth="\${a#Authorization: Bearer }";;
  esac
  [[ "\$a" == https://* ]] && url="\$a"
  prev="\$a"
done
path="\${url#https://api.heroku.com}"
if [[ "\$method" == "GET" ]]; then
  case "\$path" in
$1
    *) printf '{}';;
  esac
  printf '\n200'
  exit 0
fi
if [[ "\$method" == "POST" ]]; then
  printf '%s [%s] [%s] [%s]\n' "\$method" "\$path" "\$auth" "\$body" >> ./api-calls
  printf '{"version": 8, "status": "pending"}\n201'
  exit 0
fi
echo "unexpected curl: \$*" >&2
exit 1
STUB
  chmod +x "$TESTDIR/bin/curl"
}

# heroku stub for deploy-slug's --from path: serves releases --json per app
# (app-src's newest release carries no slug, so the slug must come from the
# newest release that does) plus auth:token, with the platform API stubbed
# via _curl_stub_platform_api.
_heroku_stub_slug_api() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth:token" ]]; then
  echo "test-token"
  exit 0
fi
app=""; prev=""
for a in "$@"; do [[ "$prev" == "-a" ]] && app="$a"; prev="$a"; done
if [[ "$1" == "releases" ]]; then
  case "$app" in
    app-src)
      # Ascending on purpose: v41 carries a different slug, so an
      # implementation that takes the first (or first slug-carrying) entry
      # instead of the newest one fails the assertion on the request body.
      echo '[{"version": 41, "slug": {"id": "slug-older"}},
             {"version": 42, "slug": {"id": "slug-src"}},
             {"version": 43, "slug": null}]';;
    app-target)
      echo '[{"version": 7, "slug": {"id": "slug-old"}}]';;
    app-empty)
      echo '[]';;
    *) echo "Couldn't find that app." >&2; exit 1;;
  esac
  exit 0
fi
echo "unexpected: $*" >&2
exit 1
STUB
  chmod +x "$TESTDIR/bin/heroku"
  _curl_stub_platform_api '    /apps/app-src/slugs/slug-src)
      printf '\''{"created_at":"2026-08-20T09:59:00Z","commit":"abcdef1234567890","commit_description":"Fix the thing"}'\'';;'
}

@test "deploy-slug --from releases the source's newest slug-carrying release to the target" {
  _heroku_stub_slug_api
  run "$SCRIPT" deploy-slug app-target --from=app-src --yes
  [ "$status" -eq 0 ]
  # The preview names the source release and the slug's commit.
  [[ "$output" == *"from:    app-src (v42)"* ]]
  [[ "$output" == *"commit:  abcdef12 (Fix the thing)"* ]]
  [[ "$output" == *"Released v8 on app-target (status: pending)"* ]]
  # Exactly one release call, authenticated with the CLI's token, body built
  # from the slug id and provenance.
  [ "$(wc -l < api-calls | tr -d ' ')" = "1" ]
  grep -qF 'POST [/apps/app-target/releases] [test-token] [{"slug":"slug-src","description":"Deploy abcdef12 (slug from app-src)"}]' api-calls
}

@test "deploy-slug --dry-run prints the release call without posting or prompting" {
  _heroku_stub_slug_api
  run "$SCRIPT" deploy-slug app-target --from=app-src --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would call: POST https://api.heroku.com/apps/app-target/releases with body"* ]]
  # The curl stub logs every POST; the file never existing proves none ran.
  [ ! -e api-calls ]
}

@test "deploy-slug aborts when the prompt is declined" {
  _heroku_stub_slug_api
  run "$SCRIPT" deploy-slug app-target --from=app-src <<< "n"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborted."* ]]
  [ ! -e api-calls ]
}

@test "deploy-slug fails when the source has no slug-carrying release" {
  _heroku_stub_slug_api
  run "$SCRIPT" deploy-slug app-target --from=app-empty --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"No slug-carrying release found on app-empty"* ]]
  [ ! -e api-calls ]
}

@test "deploy-slug fails before the prompt when the target cannot be read" {
  _heroku_stub_slug_api
  run "$SCRIPT" deploy-slug app-gone --from=app-src
  [ "$status" -eq 1 ]
  [[ "$output" == *"Couldn't find that app."* ]]
  [[ "$output" != *"Proceed?"* ]]
  [ ! -e api-calls ]
}

@test "deploy-slug rejects the same app as source and target" {
  run "$SCRIPT" deploy-slug app-src --from=app-src
  [ "$status" -eq 1 ]
  [[ "$output" == *"Source and target are the same app"* ]]
}

@test "deploy-slug rejects an app name that could rewrite the API path" {
  run "$SCRIPT" deploy-slug 'evil/../other'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid app name"* ]]
}

@test "deploy-slug rejects an empty --from= instead of falling back to the scan" {
  run "$SCRIPT" deploy-slug app-target --from=
  [ "$status" -eq 1 ]
  [[ "$output" == *"--from requires an app name"* ]]
}

@test "deploy-slug rejects the wrong argument count" {
  run "$SCRIPT" deploy-slug
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# heroku stub for deploy-slug's no---from path: `apps --all` lists detroit and
# non-detroit apps. detroit-stale has the NEWER release (v900, a config change)
# but its slug was built weeks before detroit-fresh's, so ranking by slug build
# time must pick detroit-fresh's slug.
_heroku_stub_detroit_scan() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth:token" ]]; then
  echo "test-token"
  exit 0
fi
if [[ "$1" == "apps" ]]; then
  printf '=== Team Apps\ndetroit-fresh (eu)\ndetroit-stale (eu)\nother-app (eu)\n'
  exit 0
fi
app=""; prev=""
for a in "$@"; do [[ "$prev" == "-a" ]] && app="$a"; prev="$a"; done
if [[ "$1" == "releases" ]]; then
  case "$app" in
    detroit-stale) echo '[{"version": 900, "slug": {"id": "slug-old"}}]';;
    detroit-fresh) echo '[{"version": 100, "slug": {"id": "slug-new"}}]';;
    my-target)     echo '[]';;
    *) echo "Couldn't find that app." >&2; exit 1;;
  esac
  exit 0
fi
echo "unexpected: $*" >&2
exit 1
STUB
  chmod +x "$TESTDIR/bin/heroku"
  _curl_stub_platform_api '    /apps/detroit-stale/slugs/slug-old)
      printf '\''{"created_at":"2026-08-01T00:00:00Z","commit":"aaaa111122223333","commit_description":"Deploy aaaa1111"}'\'';;
    /apps/detroit-fresh/slugs/slug-new)
      printf '\''{"created_at":"2026-08-21T00:00:00Z","commit":"bbbb444455556666","commit_description":"Deploy bbbb4444"}'\'';;'
}

@test "deploy-slug without --from picks the most recently built detroit slug, not the newest release" {
  _heroku_stub_detroit_scan
  run "$SCRIPT" deploy-slug my-target --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"from:    detroit-fresh (v100)"* ]]
  [[ "$output" == *"to:      my-target (currently no slug-carrying release yet)"* ]]
  grep -qF '"slug":"slug-new"' api-calls
  ! grep -q "slug-old" api-calls
}

@test "HEROKU_SCRIPTS_OP_REF set but op missing fails clearly" {
  # Restricted PATH: the heroku stub + coreutils, but no `op` anywhere.
  PATH="$TESTDIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HEROKU_SCRIPTS_OP_REF="op://vault/Heroku/credential" \
    run "$SCRIPT" apps mypipe staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"1Password CLI"* ]]
}

# ---------------------------------------------------------------------------
# pipeline-sql
# ---------------------------------------------------------------------------

# heroku stub for pipeline-sql. pipelines:info lists several stages so a test
# picks its app mix by stage name. pg:psql insists on the exact call shape
# (`pg:psql -f <file> -a <app>`), logs its argv to ./psql-calls, copies the
# script it was handed to ./psql-file-<app> (so tests can assert on the file
# contents), and prints the sentinel by reading it out of the script's `\echo`
# line — so tests never hardcode it. Streams are split like the real CLI's:
# the query result (and psqlrc chatter) on stdout; the update banner, the
# "--> Connecting to ..." line, psql's NOTICE/ERROR lines and heroku's own
# errors on stderr.
_heroku_stub_pg_psql() {
  cat > "$TESTDIR/bin/heroku" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pipelines:info" ]]; then
  printf '=== %s\n' "$2"
  printf 'app-two        basic\napp-one        basic\n'
  printf 'app-one        mixed\napp-empty        mixed\napp-err        mixed\n'
  printf 'app-noisy        noise\n'
  printf 'app-one        drift\napp-drift        drift\n'
  printf 'app-nodb        nodb\n'
  printf 'app-notice        notice\n'
  printf 'app-banner        banner\n'
  printf 'app-nullrow        nullrow\n'
  printf 'app-empty        empties\napp-empty2        empties\n'
  exit 0
fi
if [[ "$1" != "pg:psql" || "$2" != "-f" || "$4" != "-a" || $# -ne 5 ]]; then
  echo "unexpected call: $*" >&2
  exit 1
fi
file="$3"; app="$5"
# Build the whole log line first and append it with ONE write: apps run in
# parallel, and several small writes per app can interleave in the file.
line='PSQL'; for a in "$@"; do line="$line [$a]"; done
printf '%s\n' "$line" >> ./psql-calls
cp "$file" "./psql-file-$app"
sentinel="$(sed -n 's/^\\echo //p' "$file")"
echo " ›   Warning: heroku update available from 8.0.0 to 9.0.0." >&2
echo "--> Connecting to postgresql-curved-12345" >&2
case "$app" in
  app-one)    printf '%s\nid\tname\n1\talice\n2\tbob\n' "$sentinel";;
  app-two)    printf '%s\nid\tname\n3\tcarol\n' "$sentinel";;
  app-empty)  printf '%s\nid\tname\n' "$sentinel";;
  app-empty2) printf '%s\nid\tname\n' "$sentinel";;
  # psqlrc chatter lands on stdout BEFORE the sentinel.
  app-noisy)  printf 'Timing is on.\nNull display is "(null)".\n%s\nid\tname\n7\tzed\n' "$sentinel";;
  app-drift)  printf '%s\nid\temail\n9\tx@y.z\n' "$sentinel";;
  # A successful query that also raised a NOTICE (on stderr).
  app-notice)
    echo "psql:$file:15: NOTICE:  identifier will be truncated" >&2
    printf '%s\nid\tname\n5\teve\n' "$sentinel";;
  # A data value that looks exactly like heroku's connecting banner.
  app-banner) printf '%s\nid\tnote\n6\t--> Connecting to postgresql-curved-12345\n' "$sentinel";;
  # `select null as x`: a header and one row whose only cell is empty.
  app-nullrow) printf '%s\nx\n\n' "$sentinel";;
  # A SQL error: psql prefixes the first line with the -f file and line
  # number, then heroku adds its own exit trailer — all on stderr.
  app-err)
    printf '%s\n' "$sentinel"
    printf 'psql:%s:14: ERROR:  relation "users" does not exist\nLINE 1: select * from users\n                      ^\n ›   Error: psql exited with code 3\n' "$file" >&2
    exit 1;;
  # heroku fails before psql ever runs: no sentinel at all.
  app-nodb)   echo " ›   Error: No database found for app-nodb" >&2; exit 1;;
esac
STUB
  chmod +x "$TESTDIR/bin/heroku"
}

@test "pipeline-sql merges every app's rows under one header, sorted by app" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe basic "select id, name from users"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;id;name" ]
  [ "${lines[1]}" = "app-one;1;alice" ]
  [ "${lines[2]}" = "app-one;2;bob" ]
  [ "${lines[3]}" = "app-two;3;carol" ]
  [ "${#lines[@]}" -eq 4 ]
  [ -z "$stderr" ]
}

@test "pipeline-sql calls pg:psql -f <file> -a <app> once per app" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic "select 1"
  [ "$status" -eq 0 ]
  [ "$(wc -l < psql-calls | tr -d ' ')" = "2" ]
  grep -qE '^PSQL \[pg:psql\] \[-f\] \[[^]]+/\.[^]/]+\] \[-a\] \[app-one\]$' psql-calls
  grep -qE '^PSQL \[pg:psql\] \[-f\] \[[^]]+/\.[^]/]+\] \[-a\] \[app-two\]$' psql-calls
}

@test "pipeline-sql writes the inline SQL and the psql settings into the -f file" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic "select count(*) from users where name = 'o''brien'"
  [ "$status" -eq 0 ]
  grep -qxF "select count(*) from users where name = 'o''brien'" psql-file-app-one
  grep -qxF '\set ON_ERROR_STOP on' psql-file-app-one
  grep -qxF '\set QUIET on' psql-file-app-one
  grep -qxF '\pset format unaligned' psql-file-app-one
  grep -qxF "\\pset fieldsep '\\t'" psql-file-app-one
  grep -qxF "\\pset null ''" psql-file-app-one
  # The sentinel echo comes after every setting and before the SQL.
  awk '/^\\echo / { echo = NR } /^select count/ { sql = NR } /^\\pset null/ { last = NR }
       END { exit !(last < echo && echo < sql) }' psql-file-app-one
  # Both apps got the identical script.
  cmp -s psql-file-app-one psql-file-app-two
}

@test "pipeline-sql --file reads the SQL from a file" {
  _heroku_stub_pg_psql
  printf 'select id,\n       name\nfrom users\n' > query.sql
  run "$SCRIPT" pipeline-sql mypipe basic --file=query.sql
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "app-one;1;alice" ]
  grep -qxF 'select id,' psql-file-app-one
  grep -qxF '       name' psql-file-app-one
  grep -qxF 'from users' psql-file-app-one
}

@test "pipeline-sql --table renders one aligned table with error rows spanning the columns" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe mixed "select id, name from users" --table -a
  [ "$status" -eq 0 ]
  # Widths: app column 9 (app-empty), id 2, name 5 (alice).
  [ "${lines[0]}" = "appname   | id | name" ]
  [ "${lines[1]}" = "----------+----+------" ]
  [ "${lines[2]}" = "app-empty |    |" ]
  [ "${lines[3]}" = 'app-err   | ERROR:  relation "users" does not exist' ]
  [ "${lines[4]}" = "          | LINE 1: select * from users" ]
  [ "${lines[5]}" = "          |                       ^" ]
  [ "${lines[6]}" = "app-one   | 1  | alice" ]
  [ "${lines[7]}" = "app-one   | 2  | bob" ]
  [ "${#lines[@]}" -eq 8 ]
  # No trailing whitespace anywhere.
  ! grep -q '[[:space:]]$' <<< "$output"
}

@test "pipeline-sql turns a failed query into an error record with the psql prefix and heroku trailer removed" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe mixed "select * from users" --csv
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'app-err;ERROR:  relation "users" does not exist' ]
  [ "${lines[2]}" = "LINE 1: select * from users" ]
  [ "${lines[3]}" = "                      ^" ]
  [[ "$output" != *"psql:"* ]]
  [[ "$output" != *"psql exited"* ]]
  # The error did not stop the other apps from being reported.
  [[ "$output" == *"app-one;1;alice"* ]]
}

@test "pipeline-sql reports heroku failing before psql ran (no sentinel) as an error record" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe nodb "select 1" --csv
  [ "$status" -eq 0 ]
  # No app produced a header, so the fallback header is used.
  [ "${lines[0]}" = "appname;output" ]
  [ "${lines[1]}" = "app-nodb;Error: No database found for app-nodb" ]
  [[ "$output" != *"Connecting to"* ]]
  [[ "$output" != *"update available"* ]]
}

@test "pipeline-sql skips apps with no rows and reports a count on stderr" {
  _heroku_stub_pg_psql
  "$SCRIPT" pipeline-sql mypipe mixed "select id, name from users" --csv >stdout.txt 2>stderr.txt
  ! grep -q "app-empty" stdout.txt
  grep -q "app-one;1;alice" stdout.txt
  # A blank line separates the output from the summary; no ANSI styling when
  # stderr is not a terminal.
  [ -z "$(head -n 1 stderr.txt)" ]
  grep -q "1 app(s) with no rows skipped" stderr.txt
  grep -q -- "-a/--all" stderr.txt
  ! grep -qF $'\033' stderr.txt
}

@test "pipeline-sql -a includes a no-rows app as one empty row and prints no skip summary" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe mixed "select id, name from users" --csv -a
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "app-empty;;" ]
  [[ "$stderr" != *"skipped"* ]]
}

@test "pipeline-sql discards psqlrc output printed before the sentinel" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe noise "select id, name from users"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;id;name" ]
  [ "${lines[1]}" = "app-noisy;7;zed" ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" != *"Timing"* ]]
  [[ "$output" != *"Null display"* ]]
}

@test "pipeline-sql warns on stderr when an app's columns differ but still emits its rows" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe drift "select id, name from users"
  [ "$status" -eq 0 ]
  # app-drift sorts first, so its header wins.
  [ "${lines[0]}" = "appname;id;email" ]
  [ "${lines[1]}" = "app-drift;9;x@y.z" ]
  [ "${lines[2]}" = "app-one;1;alice" ]
  [ "${lines[3]}" = "app-one;2;bob" ]
  [ "$stderr" = "pipeline-sql: app-one: columns differ from app-drift (id, name vs id, email)" ]
}

@test "pipeline-sql accepts SQL that starts with a -- comment after an end-of-options --" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic --csv -- $'-- who is there\nselect 1'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;id;name" ]
  [[ "$output" == *"app-one;1;alice"* ]]
  # The comment line and the statement both reach the psql script.
  grep -qx -- '-- who is there' psql-file-app-one
  grep -qx 'select 1' psql-file-app-one
}

@test "pipeline-sql requires the SQL, inline or via --file" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic
  [ "$status" -eq 1 ]
  [[ "$output" == *"No SQL given"* ]]
  [[ "$output" == *"Usage:"* ]]
  [ ! -e psql-calls ]
}

@test "pipeline-sql rejects inline SQL combined with --file" {
  _heroku_stub_pg_psql
  printf 'select 1\n' > query.sql
  run "$SCRIPT" pipeline-sql mypipe basic "select 1" --file=query.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"not both"* ]]
  [[ "$output" == *"Usage:"* ]]
  [ ! -e psql-calls ]
}

@test "pipeline-sql fails clearly on an unreadable --file" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic --file=does-not-exist.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot read SQL file: does-not-exist.sql"* ]]
  [ ! -e psql-calls ]
}

@test "pipeline-sql rejects an unknown option" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic "select 1" --no-stream
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --no-stream"* ]]
  [ ! -e psql-calls ]
}

@test "pipeline-sql rejects a non-positive concurrency" {
  _heroku_stub_pg_psql
  run "$SCRIPT" pipeline-sql mypipe basic "select 1" --concurrency=0
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "pipeline-sql forwards a NOTICE on stderr with the app name instead of treating it as data" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe notice "select id, name from users"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;id;name" ]
  [ "${lines[1]}" = "app-notice;5;eve" ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$stderr" = "pipeline-sql: app-notice: NOTICE:  identifier will be truncated" ]
}

@test "pipeline-sql keeps a result value that looks like heroku's connecting banner" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe banner "select id, note from notes"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "app-banner;6;--> Connecting to postgresql-curved-12345" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pipeline-sql keeps a trailing row whose only cell is empty" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe nullrow "select null as x"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "appname;x" ]
  [ "${lines[1]}" = "app-nullrow;" ]
  [ "${#lines[@]}" -eq 2 ]
  # It is a real row, not a "no rows" app.
  [[ "$stderr" != *"skipped"* ]]
}

@test "pipeline-sql -a treats an empty-celled row as data, not as a no-rows placeholder" {
  _heroku_stub_pg_psql
  run --separate-stderr "$SCRIPT" pipeline-sql mypipe nullrow "select null as x" -a
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "app-nullrow;" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pipeline-sql keeps the header when every app returns zero rows" {
  _heroku_stub_pg_psql
  "$SCRIPT" pipeline-sql mypipe empties "select id, name from users where false" --csv >stdout.txt 2>stderr.txt
  [ "$(cat stdout.txt)" = "appname;id;name" ]
  grep -q "2 app(s) with no rows skipped" stderr.txt
}
