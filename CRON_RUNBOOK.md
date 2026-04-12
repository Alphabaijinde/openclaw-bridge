# Bridge cron / heartbeat runbook

## Runtime layout

- Home runtime: `/tmp/openclaw-bridge-home-sync`
- Company runtime: `/tmp/openclaw-bridge-company-sync`

## Cron model

Each side runs one cron entry:

- `*/5 * * * * BRIDGE_DIR=<clone> BRIDGE_ROLE=<home|company> <clone>/scripts/bridge-pull-cron.sh`

`bridge-pull-cron.sh` already calls `bridge-heartbeat.sh`, so we do not schedule a separate heartbeat cron anymore.

## Script flow

- `scripts/bridge-setup-cron.sh`
  - installs the single pull cron for the current role
  - removes old cron entries for that role before adding the new one

- `scripts/bridge-pull-cron.sh`
  - resolves its own path
  - sources `bridge-lib.sh`
  - acquires a portable directory lock at `.bridge-pull.lockdir`
  - runs `bridge-pull.sh --execute --recover`
  - then runs `bridge-heartbeat.sh`

- `scripts/bridge-heartbeat.sh`
  - writes `.heartbeat/<role>.json`
  - pulls latest remote state with `git pull --rebase`
  - commits and pushes the heartbeat update

- `scripts/bridge-lib.sh`
  - resolves repo paths and shared config
  - `git_pull_rebase()` uses `--rebase --autostash`
  - falls back to `BRIDGE_GIT_REMOTE` when `origin` is not configured

## Why the old setup broke

We saw a failure mode where both sides were alive locally, but each clone kept showing the other side as stale.

Root causes:

1. The old cron wrapper depended on `flock`, which is not available everywhere.
2. The runtime clones were out of sync and some were in bad git states.
3. A separate heartbeat cron raced with the pull cron and created extra contention.
4. `bridge-status.sh` defaults to `home` unless `BRIDGE_ROLE` is set.

## Recovery rule

If a runtime clone gets out of sync, reseed it from the repaired source state, reinstall cron, and then verify the latest heartbeat files in both clones.

## Verification

Run these with the role explicitly set:

```bash
BRIDGE_ROLE=home bash scripts/bridge-status.sh
BRIDGE_ROLE=company bash scripts/bridge-status.sh
```

Both sides are considered online when their own `.heartbeat/<role>.json` files update; the peer side may lag until the next pull cycle completes.
