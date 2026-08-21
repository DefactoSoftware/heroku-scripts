# heroku-scripts

A small bash CLI that wraps the [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli)
to run commands against every app in a pipeline stage.

Replaces the older Elixir version of this tool.

## Requirements

- macOS or Linux
- `bash` (any version that ships with the OS is fine)
- The `heroku` CLI, installed and authenticated (`heroku login`)
- [`jq`](https://jqlang.org) — only needed for the `deploy-slug` command

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
heroku-scripts pipeline-cmd <pipeline> <stage> "<heroku command>" [--concurrency=N] [--retries=N] [--no-stream] [-a] [--table|--csv]
heroku-scripts config-replace <pipeline> <stage> <VAR> <old-value> <new-value> [--concurrency=N] [--dry-run] [-a|--all] [--table|--csv] [--no-stream]
heroku-scripts pipeline-task <pipeline> <stage> <MixTask> [--concurrency=N]
heroku-scripts promote <app> <to-team> <pipeline> [--dry-run] [--yes]
heroku-scripts deploy-slug <target-app> [--from=<source-app>] [--dry-run] [--yes]
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

`pipeline-cmd` prints one record per app. On a terminal it renders an aligned
table; when the output is piped or redirected it switches to CSV
(`appname;output`) so it stays easy to parse and grep. Force either with
`--table` or `--csv`.

```
# on a terminal
appname        | output
---------------+-----------------------------------------
my-app         | EMAIL_SENDER: noreply@example.com
my-app-worker  | EMAIL_SENDER: noreply@example.com

# piped
appname;output
my-app;EMAIL_SENDER: noreply@example.com
my-app-worker;EMAIL_SENDER: noreply@example.com
```

Records stream out as each app finishes (in completion order), so output
appears progressively instead of all at once at the end — table mode included,
since the column width comes from the app list. Pass `--no-stream` to
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

### Retrying transient connection errors

`ps:exec`-style commands occasionally fail with a transient connection error
even though the dyno is up — Heroku's exec-manager rejects the credential
handshake, the SSH tunnel drops mid-session, or keepalives time out. These
show up more under parallel load and succeed on a plain re-run. Pass
`--retries=N` to re-run an app up to N extra times (with increasing backoff)
when its output matches one of those known-transient errors:

```sh
heroku-scripts pipeline-cmd my-pipe production 'ps:exec bin/rails runner "Some.task"' --retries=3
```

Genuine command failures — anything that doesn't match the known connection
errors — are never retried, and a persistently failing app still emits its
last error as its record. The default is `--retries=0` (unchanged behavior).

One caveat: a mid-session drop can happen *after* the remote command started
running, so only use `--retries` with commands that are safe to run twice.

### Replace a config var's value across a stage, only where it currently matches

`config-replace` is a guarded `config:set`: it reads each app's current value
first and only writes on apps where that value is exactly the one you expect.

```sh
heroku-scripts config-replace my-pipe production SMTP_HOST smtp.old.example smtp.new.example
```

Apps that don't have the var at all are skipped (with a count on stderr, or a
`skipped: SMTP_HOST not set` record when you pass `-a`/`--all`), and apps whose
value is something else entirely are left untouched but reported, so drift
stays visible. One blind spot: `config:get` prints the same empty line for an
unset var and one set to the empty string, so a var set to `""` is treated as
not set.

```
appname;output
my-app;SMTP_HOST: smtp.new.example
my-app-worker;skipped: SMTP_HOST is "smtp.other.example" (expected "smtp.old.example")
```

Pass `--dry-run` to see what would change without setting anything — it still
reads every app's current value, so it needs credentials like a real run:

```sh
heroku-scripts config-replace my-pipe production SMTP_HOST smtp.old.example smtp.new.example --dry-run
# my-app;would set SMTP_HOST=smtp.new.example (currently smtp.old.example)
```

`--concurrency`, `--no-stream`, and `--table`/`--csv` behave exactly as in
`pipeline-cmd`.

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

### Deploy an already-built slug to another app

`deploy-slug` releases an existing slug to an app — a deploy without a build,
the same mechanism the [detroit CI slug
pipeline](https://github.com/DefactoSoftware/detroit/blob/master/.github/workflows/release-heroku-slug-pipeline.yml)
uses. It looks up the slug the source app is *currently running* (config-var
changes and rollbacks reuse their code's slug, so this is the newest
slug-carrying release, not just the last code deploy) and creates a release
with it on the target app:

```sh
heroku-scripts deploy-slug detroit-new-customer --from=detroit-production
```

Without `--from`, it scans every `detroit-*` app your credential can see and
picks the most recently **built** slug among the ones currently running:

```sh
heroku-scripts deploy-slug detroit-new-customer
```

Ranking is by slug build time, not release time, on purpose: some detroit
apps opt out of auto deploys, so a plain `config:set` on a stale app creates
a newer *release* of older *code* — a latest-release comparison would pick
the wrong slug.

Before releasing anything it prints the slug, its commit, where it came from,
and what the target currently runs (including a warning when the target
already runs that exact slug — releasing it again only restarts dynos), then
asks for confirmation. Pass `--dry-run` to preview the API call without
running it, or `--yes` to skip the prompt. This command needs `jq`, and both
lookups and the release go through your normal heroku CLI credentials.

## Development

Static analysis runs through [ShellCheck](https://www.shellcheck.net/) and the
test suite through [bats](https://github.com/bats-core/bats-core); both run in
CI on every push:

```sh
shellcheck bin/heroku-scripts install.sh
bats test
```

The tests stub the `heroku` CLI on `PATH`, so they never touch a real account.
