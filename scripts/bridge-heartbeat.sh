#!/usr/bin/env bash
# ============================================================
# bridge-heartbeat.sh - 心跳上报，证明本侧在线且 cron 正常运行
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bridge-lib.sh"

ROLE="$(bridge_role)"
HEARTBEAT_DIR="${BRIDGE_ROOT}/.heartbeat"
mkdir -p "$HEARTBEAT_DIR"

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
HEARTBEAT_FILE="${HEARTBEAT_DIR}/${ROLE}.json"

jq -n \
    --arg role "$ROLE" \
    --arg ts "$TIMESTAMP" \
    --arg hostname "$(hostname 2>/dev/null || echo 'unknown')" \
    '{role: $role, last_heartbeat: $ts, hostname: $hostname, status: "alive"}' > "$HEARTBEAT_FILE"

# Push heartbeat to remote
if [[ -d "${BRIDGE_ROOT}/.git" ]]; then
    git -C "$BRIDGE_ROOT" add ".heartbeat/${ROLE}.json"
    git -C "$BRIDGE_ROOT" -c user.name="${BRIDGE_GIT_USER_NAME:-bridge}" \
        -c user.email="${BRIDGE_GIT_USER_EMAIL:-bridge@local}" \
        commit -m "chore(heartbeat): ${ROLE} alive at ${TIMESTAMP}" >/dev/null 2>&1 || true
    
    if [[ -n "${BRIDGE_SSH_KEY:-}" ]]; then
        GIT_SSH_COMMAND="ssh -i '${BRIDGE_SSH_KEY}'" git -C "$BRIDGE_ROOT" push origin "$BRIDGE_GIT_BRANCH" >/dev/null 2>&1 || true
    else
        git -C "$BRIDGE_ROOT" push origin "$BRIDGE_GIT_BRANCH" >/dev/null 2>&1 || true
    fi
fi
