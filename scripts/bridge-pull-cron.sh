#!/usr/bin/env bash
set -euo pipefail

# ---------- 配置 ----------
BRIDGE_DIR="${BRIDGE_DIR:-${HOME}/ai-tasks/bridge}"
LOG_FILE="${BRIDGE_DIR}/logs/bridge-pull-$(date +%Y%m%d).log"
# -------------------------

cd "${BRIDGE_DIR}"
# 确保日志目录存在
mkdir -p "$(dirname "${LOG_FILE}")"

{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bridge-pull cron 开始 ==="
  ./scripts/bridge-pull.sh --execute --recover
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bridge-pull cron 结束 ==="
} >>"${LOG_FILE}" 2>&1
