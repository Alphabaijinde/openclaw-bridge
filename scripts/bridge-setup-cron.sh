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
CRON_PULL="*/5 * * * * ${SCRIPT_DIR}/bridge-pull.sh --execute >> ${BRIDGE_ROOT}/logs/cron.log 2>&1 ${CRON_COMMENT}"
CRON_RECOVER="*/10 * * * * ${SCRIPT_DIR}/bridge-pull.sh --recover >> ${BRIDGE_ROOT}/logs/cron.log 2>&1 ${CRON_COMMENT}"

setup_cron() {
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    
    # 移除旧的 bridge cron（如果有）
    local cleaned_cron
    cleaned_cron=$(echo "$current_cron" | grep -v "OpenClaw Bridge" || true)
    
    # 添加新的 cron
    local new_cron
    if [[ -n "$cleaned_cron" ]]; then
        new_cron="${cleaned_cron}
${CRON_PULL}
${CRON_RECOVER}"
    else
        new_cron="${CRON_PULL}
${CRON_RECOVER}"
    fi
    
    echo "$new_cron" | crontab -
    
    log_info "Cron 配置完成 (${ROLE} 侧)"
    log_info "Pull: 每 5 分钟"
    log_info "Recover: 每 10 分钟"
    
    # 验证
    crontab -l | grep "OpenClaw Bridge"
}

remove_cron() {
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    
    local cleaned_cron
    cleaned_cron=$(echo "$current_cron" | grep -v "OpenClaw Bridge" || true)
    
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
