#!/usr/bin/env bash
# ============================================================
# bridge-pull.sh - 拉取并领取任务（双向）
# 
# 用法:
#   bridge-pull.sh              # 仅拉取最新任务
#   bridge-pull.sh --execute   # 拉取并执行
#   bridge-pull.sh --recover    # 恢复卡死的任务
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-lib.sh
source "${SCRIPT_DIR}/bridge-lib.sh"

# ---- 参数 ----
EXECUTE="false"
RECOVER="false"
TASK_ID=""
DRY_RUN="false"
HEALTH_CHECK="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)     EXECUTE="true"; shift ;;
        --recover)     RECOVER="true"; shift ;;
        --task-id)     TASK_ID="$2"; shift 2 ;;
        --dry-run)     DRY_RUN="true"; shift ;;
        --health)      HEALTH_CHECK="true"; shift ;;
        *)             err "未知参数: $1"; exit 1 ;;
    esac
done

EXECUTOR="${BRIDGE_EXECUTOR:-${COMPANY_EXECUTOR:-$(bridge_role)-openclaw}}"
LEASE_TTL="${TASK_LEASE_TTL:-600}"

# ---- 健康检查 ----
run_health_check() {
    info "====== 健康检查 ======"
    local role
    role="$(bridge_role)"
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    
    local inbox_count running_count done_count failed_count
    inbox_count=$(find "${BRIDGE_TASKS_DIR}/inbox" -name "bridge-*.json" 2>/dev/null | wc -l)
    running_count=$(find "${BRIDGE_TASKS_DIR}/running" -name "bridge-*.json" 2>/dev/null | wc -l)
    done_count=$(find "${BRIDGE_TASKS_DIR}/done" -name "bridge-*.json" 2>/dev/null | wc -l)
    failed_count=$(find "${BRIDGE_TASKS_DIR}/failed" -name "bridge-*.json" 2>/dev/null | wc -l)
    
    local git_status="ok"
    if [[ -d "${BRIDGE_ROOT}/.git" ]]; then
        if ! git -C "$BRIDGE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            git_status="broken"
        fi
    else
        git_status="not-a-repo"
    fi
    
    local health_report
    health_report=$(jq -n \
        --arg role "$role" \
        --arg timestamp "$now" \
        --arg git_status "$git_status" \
        --argjson inbox "$inbox_count" \
        --argjson running "$running_count" \
        --argjson done "$done_count" \
        --argjson failed "$failed_count" \
        '{
            health: "ok",
            role: $role,
            timestamp: $timestamp,
            git: $git_status,
            tasks: {
                inbox: $inbox,
                running: $running,
                done: $done,
                failed: $failed
            }
        }')
    
    echo "$health_report" | jq .
    
    local health_file="${BRIDGE_ROOT}/.health.json"
    echo "$health_report" > "$health_file"
    
    info "健康检查完成"
    exit 0
}

# ---- 主流程 ----
main() {
    if [[ "$HEALTH_CHECK" == "true" ]]; then
        run_health_check
    fi
    
    info "====== OpenClaw Bridge Pull ======"
    info "Root: ${BRIDGE_ROOT}"
    info "Role: $(bridge_role_label) ($(bridge_role))"
    info "Executor: ${EXECUTOR}"
    info "Mode: $([[ "$EXECUTE" == "true" ]] && echo "pull+execute" || echo "pull only")"
    
    # 1. 从远程拉取最新任务
    if [[ -d "${BRIDGE_ROOT}/.git" ]]; then
        log_info "Pulling from remote..."
        if ! git_pull_rebase "$BRIDGE_ROOT" "$BRIDGE_GIT_BRANCH" 2>/dev/null; then
            log_warn "Git pull failed, using local files"
        fi
    fi
    
    # 2. 恢复过期任务
    if [[ "$RECOVER" == "true" ]]; then
        recover_expired_tasks
    fi
    
    # 3. 按优先级排序任务（priority: high > medium > low）
    local task_files=()
    for task_file in "${BRIDGE_TASKS_DIR}/inbox"/bridge-*.json; do
        [[ -f "$task_file" ]] || continue
        task_matches_local_target "$task_file" || continue
        task_files+=("$task_file")
    done
    
    # 按 priority 排序
    local sorted_files=()
    for priority in high medium low; do
        for task_file in "${task_files[@]}"; do
            local task_priority
            task_priority=$(jq -r '.priority // "medium"' "$task_file")
            if [[ "$task_priority" == "$priority" ]]; then
                sorted_files+=("$task_file")
            fi
        done
    done
    
    # 4. 领取并处理任务
    if [[ -n "$TASK_ID" ]]; then
        task_file="${BRIDGE_TASKS_DIR}/inbox/${TASK_ID}.json"
        if [[ ! -f "$task_file" ]]; then
            err "任务文件不存在: $task_file"
            exit 1
        fi
        claim_and_process "$task_file"
    else
        local count=0
        for task_file in "${sorted_files[@]}"; do
            if claim_and_process "$task_file"; then
                ((count++)) || true
            fi
        done
        info "已领取 $count 个任务"
    fi
    
    # 5. 推回远程（如果有变更）
    push_changes "Tasks claimed/processed"
}

# ---- 恢复过期任务 ----
recover_expired_tasks() {
    warn "检查过期 running 任务..."
    
    for task_file in "${BRIDGE_TASKS_DIR}/running"/bridge-*.json; do
        [[ -f "$task_file" ]] || continue
        task_matches_local_target "$task_file" || continue
        
        if is_lease_expired "$task_file"; then
            TASK_ID=$(basename "$task_file" .json)
            warn "任务 $TASK_ID lease 已过期，标记为 pending"
            
            release_task "$task_file" "lease_expired"
            log_warn "Released expired task: $TASK_ID"
            
            # 移回 inbox
            mv "$task_file" "${BRIDGE_TASKS_DIR}/inbox/"
        fi
    done
}

# ---- 领取并处理任务 ----
claim_and_process() {
    local task_file="$1"
    local task_id
    task_id=$(basename "$task_file" .json)

    if ! task_matches_local_target "$task_file"; then
        warn "跳过非本机目标任务: $task_id"
        return 0
    fi
    
    log_info "Processing task: $task_id"
    
    # --- 执行侧风险重判（关键步骤）---
    local check_result
    check_result=$(executor_risk_check "$task_file")
    local check_status=$?
    
    if [[ $check_status -eq 1 ]]; then
        # 危险，拒绝执行
        err "风险检查失败: $check_result"
        update_task_status "$task_file" "failed" \
            "unsafe_request" \
            "$check_result" \
            "Task exceeds Phase 1 safety bounds" \
            "failed"
        
        feishu_notify "error" "任务被拒绝" "任务 $task_id 不符合安全要求：$check_result"
        return 1
        
    elif [[ $check_status -eq 2 ]]; then
        # 需要人工审核
        warn "任务需要人工审核: $check_result"
        update_task_status "$task_file" "needs_review" \
            "review_required" \
            "$check_result" \
            "Human review required before execution" \
            "failed"
        
        feishu_notify "warn" "任务需人工审核" "任务 $task_id 需要人工审核：$check_result"
        return 1
    fi
    
    # --- 领取任务 ---
    log_info "Claiming task: $task_id"
    claim_task "$task_file" "$EXECUTOR" "$LEASE_TTL"
    
    # 移入 running
    mv "$task_file" "${BRIDGE_TASKS_DIR}/running/"
    local running_file="${BRIDGE_TASKS_DIR}/running/${task_id}.json"
    log_info "Task moved to running: $task_id"
    
    # --- 执行任务 ---
    if [[ "$EXECUTE" == "true" && "$DRY_RUN" != "true" ]]; then
        info "执行任务: $task_id"
        
        local result
        result=$("${SCRIPT_DIR}/bridge-execute.sh" "$running_file")
        local exec_status=$?
        
        if [[ $exec_status -eq 0 ]]; then
            # 成功
            info "任务执行成功: $task_id"
            # result.json 已在 execute.sh 中写入
        else
            # 失败（可能需要重试）
            err "任务执行失败: $task_id (exit $exec_status)"
            
            # 检查重试次数
            local retry_left
            retry_left=$(jq -r '.retry_budget // 0' "${BRIDGE_TASKS_DIR}/running/${task_id}.json")
            if [[ "$retry_left" -gt 0 ]]; then
                warn "剩余重试次数: $retry_left，标记任务为 pending 等待重试"
                
                # 写回 pending（减少 retry_budget）
                jq '(.retry_budget -= 1) | .status = "pending" | del(._claim)' \
                    "$running_file" \
                    > "${BRIDGE_TASKS_DIR}/inbox/${task_id}.json"
                rm "$running_file"
            else
                # 重试次数用尽，标记失败
                err "重试次数耗尽: $task_id"
                update_task_status \
                    "$running_file" \
                    "failed" \
                    "quota_exceeded" \
                    "Retry budget exhausted" \
                    "Manual intervention required" \
                    "failed"
            fi
        fi
    else
        info "Dry-run 或未执行: $task_id"
        info "任务已移入 running，等待 --execute"
    fi
    
    return 0
}

# ---- 更新任务状态 ----
update_task_status() {
    local task_file="$1"
    local status="$2"
    local failure_type="${3:-unknown}"
    local message="${4:-}"
    local recovery_hint="${5:-}"
    local final_dir="${6:-done}"
    
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    local update_json
    update_json=$(jq -n \
        --arg status "$status" \
        --arg failure_type "$failure_type" \
        --arg message "$message" \
        --arg recovery_hint "$recovery_hint" \
        --arg now "$now" \
        --arg executor "$EXECUTOR" \
        '{
            status: $status,
            updated_at: $now,
            completed_at: $now,
            executor: $executor,
            failure_info: {
                failure_type: $failure_type,
                message: $message,
                recovery_hint: $recovery_hint
            }
        }')
    
    local merged
    merged=$(jq -s '.[0] * .[1]' "$task_file" <(echo "$update_json"))
    echo "$merged" | jq '.' > "$task_file"
    
    # 移入对应目录
    local task_id
    task_id=$(basename "$task_file" .json)
    mv "$task_file" "${BRIDGE_TASKS_DIR}/${final_dir}/${task_id}.json"
    
    log_info "Task $task_id moved to $final_dir with status $status"
}

# ---- 推送变更 ----
push_changes() {
    local msg="${1:-bridge auto sync}"
    
    if [[ ! -d "${BRIDGE_ROOT}/.git" ]]; then
        log_debug "Not a git repo, skipping push"
        return 0
    fi
    
    if git -C "$BRIDGE_ROOT" diff --cached --quiet 2>/dev/null && \
       git -C "$BRIDGE_ROOT" diff --quiet 2>/dev/null; then
        log_debug "No changes to push"
        return 0
    fi
    
    if git_push "$BRIDGE_ROOT" "$BRIDGE_GIT_BRANCH" "$msg"; then
        log_info "Changes pushed to remote"
    else
        log_warn "Push failed, changes are local"
    fi
}

main "$@"
