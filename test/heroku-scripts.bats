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

@test "HEROKU_SCRIPTS_OP_REF set but op missing fails clearly" {
  # Restricted PATH: the heroku stub + coreutils, but no `op` anywhere.
  PATH="$TESTDIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HEROKU_SCRIPTS_OP_REF="op://vault/Heroku/credential" \
    run "$SCRIPT" apps mypipe staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"1Password CLI"* ]]
}
