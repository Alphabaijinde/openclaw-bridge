#!/usr/bin/env bash
# ============================================================
# bridge-push.sh - 推送任务到桥接仓库（家里侧）
# 
# 用法:
#   bridge-push.sh --title "..." --task-type ... --instruction "..."
#   bridge-push.sh --task-file /path/to/task.json
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-lib.sh
source "${SCRIPT_DIR}/bridge-lib.sh"

# ---- 参数默认值 ----
TITLE=""
TASK_TYPE=""
INSTRUCTION=""
ALLOWED_ACTIONS="fetch_public,summarize"
MAX_OUTPUT_CHARS="2000"
TIMEOUT_SECONDS="600"
RETRY_BUDGET="2"
PRIORITY="medium"
REQUESTER="home-openclaw"

# ---- 使用说明 ----
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

推送任务到桥接仓库（家里 OpenClaw → 公司 OpenClaw）

必选参数:
  --title TEXT           任务标题（最多 200 字符）
  --task-type TYPE      任务类型
                        可选: status-summary, public-research, daily-report,
                              obsidian-write, state-sync
  --instruction TEXT    任务指令（最多 1000 字符）

可选参数:
  --allowed-actions A   允许的动作，逗号分隔
                        默认: fetch_public,summarize
                        可选: read_status, summarize, write_obsidian, fetch_public
  --max-output N        最大输出字符数，默认 2000
  --timeout N           超时秒数，默认 600
  --retry N             重试次数，默认 2
  --priority LEVEL      优先级: low, medium, high，默认 medium
  --task-file FILE      从已有 JSON 文件导入任务（跳过交互式输入）
  --push                立即推送到远程（需要 git remote 已配置）
  --help                显示帮助

示例:
  $(basename "$0") \\
    --title "生成今日 GitHub Trending 分析" \\
    --task-type public-research \\
    --instruction "抓取 GitHub Trending 页面，分析 Top 10 项目，生成 16 号格式报告"

  $(basename "$0") --task-file ./my-task.json --push
EOF
}

# ---- 解析参数 ----
TASK_FILE=""
PUSH_NOW="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)          TITLE="$2";        shift 2 ;;
        --task-type)      TASK_TYPE="$2";    shift 2 ;;
        --instruction)    INSTRUCTION="$2"; shift 2 ;;
        --allowed-actions) ALLOWED_ACTIONS="$2"; shift 2 ;;
        --max-output)     MAX_OUTPUT_CHARS="$2"; shift 2 ;;
        --timeout)        TIMEOUT_SECONDS="$2"; shift 2 ;;
        --retry)          RETRY_BUDGET="$2"; shift 2 ;;
        --priority)       PRIORITY="$2";    shift 2 ;;
        --task-file)      TASK_FILE="$2";   shift 2 ;;
        --push)           PUSH_NOW="true";  shift ;;
        --help|-h)        usage; exit 0 ;;
        *)                err "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---- 验证必要参数 ----
if [[ -n "$TASK_FILE" ]]; then
    if [[ ! -f "$TASK_FILE" ]]; then
        err "任务文件不存在: $TASK_FILE"
        exit 1
    fi
    
    # 复制到 inbox
    TASK_ID=$(jq -r '.task_id' "$TASK_FILE")
    DEST="${BRIDGE_TASKS_DIR}/inbox/${TASK_ID}.json"
    
    if ! validate_task_schema "$TASK_FILE"; then
        err "Schema 验证失败"
        exit 1
    fi
    
    cp "$TASK_FILE" "$DEST"
    info "任务已复制到 inbox: $DEST"
    log_info "Task imported: $TASK_ID from $TASK_FILE"
    
elif [[ -z "$TITLE" || -z "$TASK_TYPE" || -z "$INSTRUCTION" ]]; then
    err "缺少必要参数: --title, --task-type, --instruction"
    usage
    exit 1
else
    # ---- 生成任务单 ----
    TASK_ID=$(generate_task_id)
    IDEMPOTENCY_KEY="${TASK_ID}-v1"
    CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    # 分割 allowed_actions
    IFS=',' read -ra ACTIONS_ARRAY <<< "$ALLOWED_ACTIONS"
    jq_array=""
    for action in "${ACTIONS_ARRAY[@]}"; do
        jq_array="${jq_array}\"$action\","
    done
    jq_array="${jq_array%,}"
    
    # 构建任务 JSON
    TASK_JSON=$(jq -n \
        --arg task_id "$TASK_ID" \
        --arg idempotency_key "$IDEMPOTENCY_KEY" \
        --arg source "home" \
        --arg target "company" \
        --arg requester "$REQUESTER" \
        --arg title "$TITLE" \
        --arg lane "safe-auto" \
        --arg priority "$PRIORITY" \
        --arg task_type "$TASK_TYPE" \
        --arg policy_version "v1" \
        --arg sensitivity "low" \
        --arg instruction "$INSTRUCTION" \
        --argjson allowed_actions "[${jq_array}]" \
        --arg max_output "$MAX_OUTPUT_CHARS" \
        --arg timeout "$TIMEOUT_SECONDS" \
        --arg retry "$RETRY_BUDGET" \
        --arg status "pending" \
        --arg created "$CREATED_AT" \
        '{
            task_id: $task_id,
            idempotency_key: $idempotency_key,
            source: $source,
            target: $target,
            requester: $requester,
            title: $title,
            lane: $lane,
            priority: $priority,
            task_type: $task_type,
            policy_version: $policy_version,
            sensitivity: $sensitivity,
            payload: {
                instruction: $instruction,
                allowed_actions: $allowed_actions,
                max_output_chars: ($max_output | tonumber)
            },
            timeout_seconds: ($timeout | tonumber),
            retry_budget: ($retry | tonumber),
            status: $status,
            created_at: $created,
            updated_at: $created
        }')
    
    # 保存到 inbox
    DEST="${BRIDGE_TASKS_DIR}/inbox/${TASK_ID}.json"
    mkdir -p "$(dirname "$DEST")"
    echo "$TASK_JSON" | jq '.' > "$DEST"
    
    info "任务已创建: $TASK_ID"
    info "保存位置: $DEST"
    log_info "Task created: $TASK_ID task_type=$TASK_TYPE lane=safe-auto"
    
    # 敏感信息扫描
    if ! scan_sensitive "$INSTRUCTION"; then
        warn "指令可能包含敏感信息，请检查任务单"
        feishu_notify "warn" "任务含敏感词" "$TASK_ID: $TITLE"
    fi
fi

# ---- 推送到远程 ----
if [[ "$PUSH_NOW" == "true" ]]; then
    if [[ -z "$BRIDGE_GIT_REMOTE" ]]; then
        err "BRIDGE_GIT_REMOTE 未配置，无法推送"
        err "请设置 bridge.env 中的 BRIDGE_GIT_REMOTE"
        exit 1
    fi
    
    info "正在推送到远程..."
    log_info "Pushing to remote: $BRIDGE_GIT_REMOTE"
    
    # 确保 git 已初始化
    if [[ ! -d "${BRIDGE_ROOT}/.git" ]]; then
        git -C "$BRIDGE_ROOT" init
        git_setup "$BRIDGE_ROOT" "$BRIDGE_GIT_REMOTE" "$BRIDGE_GIT_BRANCH"
    fi
    
    COMMIT_MSG="feat(bridge): push task ${TASK_ID:-$(
        basename "$TASK_FILE" .json
    )} from home-openclaw"
    
    if git_push "$BRIDGE_ROOT" "$BRIDGE_GIT_BRANCH" "$COMMIT_MSG"; then
        ok "已推送: $COMMIT_MSG"
        feishu_notify "info" "任务已推送" "${TASK_ID:-N/A} 已推送到桥接仓库"
    else
        err "推送失败"
        exit 1
    fi
fi

# ---- 显示任务摘要 ----
if [[ -n "$TASK_ID" || -n "$TASK_FILE" ]]; then
    TASK_DISPLAY="${TASK_ID:-$(basename "$TASK_FILE" .json)}"
    echo ""
    info "任务摘要:"
    jq -r 'to_entries[] | "  \(.key): \(.value)"' "$DEST" 2>/dev/null | head -15
fi
