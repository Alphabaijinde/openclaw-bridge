# Bridge cron / heartbeat runbook

This repo now treats the source checkout as canonical and the two runtime clones as the active cron targets:

- Home runtime: `/tmp/openclaw-bridge-home-sync`
- Company runtime: `/tmp/openclaw-bridge-company-sync`

## Cron shape

Each side runs two cron entries:

- `*/5 * * * * BRIDGE_DIR=<clone> BRIDGE_ROLE=<home|company> <clone>/scripts/bridge-pull-cron.sh`
- `*/10 * * * * BRIDGE_DIR=<clone> BRIDGE_ROLE=<home|company> bash <clone>/scripts/bridge-heartbeat.sh`

The cron wrapper now uses a directory lock (`.bridge-pull.lockdir`) instead of `flock`, so it works on systems that do not ship `flock`.

## Scripts

- `scripts/bridge-pull-cron.sh`
  - resolves its own path
  - sources `scripts/bridge-lib.sh`
  - acquires the portable lock
  - runs `scripts/bridge-pull.sh --execute --recover`
  - then runs `scripts/bridge-heartbeat.sh`

- `scripts/bridge-heartbeat.sh`
  - writes `.heartbeat/<role>.json`
  - does `git pull --rebase` before writing
  - commits and pushes the heartbeat update

- `scripts/bridge-lib.sh`
  - shared helpers for repo/root/path resolution
  - `git_pull_rebase()` now uses `--rebase --autostash`

## Pull flow

The pull flow is:

1. cron calls `bridge-pull-cron.sh`
2. wrapper acquires the lock
3. `bridge-pull.sh --execute --recover` pulls tasks and processes them
4. `bridge-heartbeat.sh` refreshes the local heartbeat and pushes it upstream

## Current implementation notes

- Repository root is derived from `bridge-lib.sh` (`BRIDGE_ROOT`), not a hardcoded home path.
- The old `.bridge-pull.lock` file from the previous implementation is not used anymore.
- The status command should be run with `BRIDGE_ROLE=home` or `BRIDGE_ROLE=company` when you want the correct side label.
