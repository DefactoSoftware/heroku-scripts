#!/usr/bin/env bats
#
# Black-box tests: every test runs bin/heroku-scripts with a stubbed `heroku`
# on PATH, so nothing here ever touches a real Heroku account. The stub serves
# a fixed pipelines:info table and otherwise echoes its argv (bracketed) so we
# can assert on how arguments are routed.

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
