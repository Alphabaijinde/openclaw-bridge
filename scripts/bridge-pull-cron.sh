#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-lib.sh
source "${SCRIPT_DIR}/bridge-lib.sh"

BRIDGE_DIR="${BRIDGE_DIR:-${BRIDGE_ROOT}}"
LOG_FILE="${BRIDGE_DIR}/logs/bridge-pull-$(date +%Y%m%d).log"
LOCK_DIR="${BRIDGE_DIR}/.bridge-pull.lockdir"

mkdir -p "$(dirname "${LOG_FILE}")"

acquire_lock() {
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        trap 'rm -rf "${LOCK_DIR}"' EXIT
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] 另一个 bridge-pull 实例正在运行，跳过本次" >> "$LOG_FILE"
    return 1
}

if ! acquire_lock; then
    exit 0
fi

{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bridge-pull cron 开始 ==="
  "${SCRIPT_DIR}/bridge-pull.sh" --execute --recover || true
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bridge-pull cron 结束 ==="
  echo "--- heartbeat ---"
  BRIDGE_DIR="${BRIDGE_DIR}" BRIDGE_ROLE="$(bridge_role)" bash "${SCRIPT_DIR}/bridge-heartbeat.sh" 2>&1 || true
  echo "=== heartbeat done ==="
} >>"${LOG_FILE}" 2>&1
