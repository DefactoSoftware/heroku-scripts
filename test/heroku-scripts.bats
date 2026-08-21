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
