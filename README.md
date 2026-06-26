# heroku-scripts

A small bash CLI that wraps the [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli)
to run commands against every app in a pipeline stage.

Replaces the older Elixir version of this tool.

## Requirements

- macOS or Linux
- `bash` (any version that ships with the OS is fine)
- The `heroku` CLI, installed and authenticated (`heroku login`)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/heroku-scripts/main/install.sh | sh
```

Or manually:

```sh
curl -fsSL https://raw.githubusercontent.com/DefactoSoftware/heroku-scripts/main/bin/heroku-scripts -o ~/.local/bin/heroku-scripts
chmod +x ~/.local/bin/heroku-scripts
```

## Authentication

The `heroku` CLI must be authenticated. heroku-scripts picks credentials in
this order:

1. **`HEROKU_API_KEY`** — if already set, it is used as-is, so
   `HEROKU_API_KEY=… heroku-scripts …` always works.
2. **1Password** — if `HEROKU_SCRIPTS_OP_REF` holds a [1Password secret
   reference](https://developer.1password.com/docs/cli/secret-references/) and
   `HEROKU_API_KEY` is not set, the key is read once via the [1Password
   CLI](https://developer.1password.com/docs/cli/) (`op`) and reused for every
   call.
3. Otherwise the heroku CLI's own stored login (`heroku login`) is used.

### Why the 1Password option exists

If your heroku credentials are brokered by 1Password (shell plugin / desktop
app), every `heroku` call triggers an interactive approval and account
selector. `pipeline-cmd` runs heroku in parallel, backgrounded subshells with
no controlling terminal, so those prompts can't be answered and the run stalls.
Resolving the key **once, up front** sidesteps this: 1Password approves a single
time and the exported key flows to every child process.

Store your Heroku API key in 1Password, then point the script at it (add this to
your shell profile):

```sh
export HEROKU_SCRIPTS_OP_REF="op://Private/Heroku/credential"
```

Get the reference from the 1Password app (right-click a field → _Copy Secret
Reference_) or `op item get "Heroku" --format json`.

Prefer not to configure the script? Use `op run` instead — no env var needed:

```sh
HEROKU_API_KEY="op://Private/Heroku/credential" op run -- heroku-scripts apps my-pipe staging
```

## Usage

```sh
heroku-scripts apps <pipeline> <stage>
heroku-scripts pipeline-cmd <pipeline> <stage> "<heroku command>" [--concurrency=N] [--no-stream] [-a]
heroku-scripts pipeline-task <pipeline> <stage> <MixTask> [--concurrency=N]
heroku-scripts promote <app> <to-team> <pipeline> [--dry-run] [--yes]
```

Run `heroku-scripts help` for the full command list.

### Examples

List every app in the `staging` stage of the `my-pipe` pipeline:

```sh
heroku-scripts apps my-pipe staging
```

Set a config var on every staging app:

```sh
heroku-scripts pipeline-cmd my-pipe staging "config:set EMAIL_SENDER=noreply@example.com"
```

`pipeline-cmd` prints a header line followed by one record per app:

```
appname;output
my-app;EMAIL_SENDER: noreply@example.com
my-app-worker;EMAIL_SENDER: noreply@example.com
```

Records stream out as each app finishes (in completion order), so output
appears progressively instead of all at once at the end. Pass `--no-stream` to
withhold output until every app finishes and print it sorted by app name —
useful for reproducible, diff-friendly output.

Apps whose output is empty (e.g. `config:get` for a var that isn't set) are
skipped by default, and a count of skipped apps is printed to stderr. Pass
`-a`/`--all` to include them:

```sh
heroku-scripts pipeline-cmd my-pipe production "config:get ADFS_METADATA_URL"
# ...only apps that have the var...
# 18 app(s) with empty output skipped (use -a/--all to include them)
```

The output field is the app's raw combined heroku output, so it may span
multiple lines and contain semicolons. Treat the stream as something to read
or grep, not as strict CSV.

Run a mix task on every production app, four at a time:

```sh
heroku-scripts pipeline-task my-pipe production GiveRaiseToPeople --concurrency=4
```

Move an app and its `-staging` sibling to another team and pipeline:

```sh
heroku-scripts promote my-app my-team my-pipe
```

`promote` runs destructive, largely irreversible operations, so it prints what
it will do and asks for confirmation first. Pass `--dry-run` to preview the
exact `heroku` commands, or `--yes` to skip the prompt.

## Development

Static analysis runs through [ShellCheck](https://www.shellcheck.net/) and the
test suite through [bats](https://github.com/bats-core/bats-core); both run in
CI on every push:

```sh
shellcheck bin/heroku-scripts
bats test
```

The tests stub the `heroku` CLI on `PATH`, so they never touch a real account.
