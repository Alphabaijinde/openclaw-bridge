#!/usr/bin/env bash
# ============================================================
# bridge-setup-cron.sh - 自动配置 cron 定时任务
# 
# 用法:
#   bridge-setup-cron.sh              # 配置当前侧的 cron
#   bridge-setup-cron.sh --remove     # 移除 cron 配置
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bridge-lib.sh"

REMOVE="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove) REMOVE="true"; shift ;;
        *)        err "未知参数: $1"; exit 1 ;;
    esac
done

ROLE="$(bridge_role)"
CRON_COMMENT="# OpenClaw Bridge - ${ROLE} side"
CRON_PULL="*/5 * * * * BRIDGE_DIR=${BRIDGE_ROOT} BRIDGE_ROLE=${ROLE} ${SCRIPT_DIR}/bridge-pull-cron.sh >> ${BRIDGE_ROOT}/logs/cron.log 2>&1 ${CRON_COMMENT}"
CRON_HEARTBEAT="*/10 * * * * BRIDGE_DIR=${BRIDGE_ROOT} BRIDGE_ROLE=${ROLE} bash ${SCRIPT_DIR}/bridge-heartbeat.sh >> ${BRIDGE_ROOT}/logs/cron.log 2>&1 ${CRON_COMMENT}"

setup_cron() {
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    
    # 移除旧的 bridge cron（如果有）
    local cleaned_cron
    cleaned_cron=$(CURRENT_CRON="$current_cron" python3 - <<'PY'
import os

blocked = (
    'OpenClaw Bridge',
    'bridge-pull-cron.sh',
    'bridge-pull.sh',
    'bridge-heartbeat.sh',
)

for line in os.environ.get('CURRENT_CRON', '').splitlines():
    if not line.strip():
        continue
    if any(token in line for token in blocked):
        continue
    print(line)
PY
)
    
    # 添加新的 cron
    local new_cron
    if [[ -n "$cleaned_cron" ]]; then
        new_cron="${cleaned_cron}
${CRON_PULL}
${CRON_HEARTBEAT}"
    else
        new_cron="${CRON_PULL}
${CRON_HEARTBEAT}"
    fi
    
    echo "$new_cron" | crontab -
    
    log_info "Cron 配置完成 (${ROLE} 侧)"
    log_info "Pull+Heartbeat: 每 5 分钟"
    log_info "Heartbeat: 每 10 分钟"
    
    # 验证
    crontab -l | grep "OpenClaw Bridge"
}

remove_cron() {
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    
    local cleaned_cron
    cleaned_cron=$(CURRENT_CRON="$current_cron" python3 - <<'PY'
import os

blocked = (
    'OpenClaw Bridge',
    'bridge-pull-cron.sh',
    'bridge-pull.sh',
    'bridge-heartbeat.sh',
)

for line in os.environ.get('CURRENT_CRON', '').splitlines():
    if not line.strip():
        continue
    if any(token in line for token in blocked):
        continue
    print(line)
PY
)
    
    if [[ -n "$cleaned_cron" ]]; then
        echo "$cleaned_cron" | crontab -
        log_info "Cron 已移除 (${ROLE} 侧)"
    else
        log_info "没有找到 Bridge cron"
    fi
}

if [[ "$REMOVE" == "true" ]]; then
    remove_cron
else
    setup_cron
fi
