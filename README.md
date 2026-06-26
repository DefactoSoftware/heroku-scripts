# heroku-scripts

A small bash CLI that wraps the [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli)
to run commands against every app in a pipeline stage.

Replaces the older Elixir version of this tool.

## Requirements

- macOS or Linux
- `bash` (any version that ships with the OS is fine)
- The `heroku` CLI, installed and authenticated (`heroku login`)

## Install

Drop the script somewhere on your `$PATH`:

```sh
git clone https://github.com/defactosoftware/heroku-scripts.git
ln -s "$(pwd)/heroku-scripts/bin/heroku-scripts" /usr/local/bin/heroku-scripts
```

Or just run `bin/heroku-scripts` directly from a clone.

## Usage

```sh
heroku-scripts apps <pipeline> <stage>
heroku-scripts pipeline-cmd <pipeline> <stage> "<heroku command>" [--concurrency=N]
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
