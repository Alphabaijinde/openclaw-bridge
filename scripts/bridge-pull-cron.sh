#!/usr/bin/env bash
set -euo pipefail

# ---------- 配置 ----------
BRIDGE_DIR="${BRIDGE_DIR:-${HOME}/ai-tasks/bridge}"
LOG_FILE="${BRIDGE_DIR}/logs/bridge-pull-$(date +%Y%m%d).log"
LOCK_FILE="${BRIDGE_DIR}/.bridge-pull.lock"
# -------------------------

cd "${BRIDGE_DIR}"
# 确保日志目录存在
mkdir -p "$(dirname "${LOG_FILE}")"

# 并发控制：使用 flock 防止多个实例同时运行
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] 另一个 bridge-pull 实例正在运行，跳过本次" >> "$LOG_FILE"
    exit 0
fi

{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bridge-pull cron 开始 ==="
  ./scripts/bridge-pull.sh --execute --recover || true
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bridge-pull cron 结束 ==="
  echo "--- heartbeat ---"
  ./scripts/bridge-heartbeat.sh 2>&1 || true
  echo "=== heartbeat done ==="
} >>"${LOG_FILE}" 2>&1
