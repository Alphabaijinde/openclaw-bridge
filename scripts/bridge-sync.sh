#!/usr/bin/env bash
# ============================================================
# bridge-sync.sh - 同步结果（双向）
# 
# 用法:
#   bridge-sync.sh              # 拉取所有已完成任务
#   bridge-sync.sh --task-id X  # 拉取指定任务结果
#   bridge-sync.sh --to-obsidian # 同时写入 Obsidian
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-lib.sh
source "${SCRIPT_DIR}/bridge-lib.sh"

# ---- 参数 ----
TASK_ID=""
TO_OBSIDIAN="false"
PULL_REMOTE="true"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)      TASK_ID="$2";    shift 2 ;;
        --to-obsidian)  TO_OBSIDIAN="true"; shift ;;
        --no-pull)      PULL_REMOTE="false"; shift ;;
        *)              err "未知参数: $1"; exit 1 ;;
    esac
done

OBSIDIAN_DIR="$(bridge_local_obsidian_dir)"
BRIDGE_NOTES_DIR="${OBSIDIAN_DIR}/AI趋势/Bridge任务"

# ---- 主流程 ----
main() {
    info "====== OpenClaw Bridge Sync ======"
    info "Role: $(bridge_role_label) ($(bridge_role))"
    
    # 1. 从远程拉取
    if [[ "$PULL_REMOTE" == "true" && -d "${BRIDGE_ROOT}/.git" ]]; then
        info "从远程拉取最新变更..."
        if ! git_pull_rebase "$BRIDGE_ROOT" "$BRIDGE_GIT_BRANCH" 2>/dev/null; then
            log_warn "Git pull failed, using local files"
        fi
    fi
    
    local synced=0
    
    # 2. 收集已完成任务
    if [[ -n "$TASK_ID" ]]; then
        # 指定任务
        for result_file in "${BRIDGE_TASKS_DIR}/done/${TASK_ID}.json" \
                           "${BRIDGE_TASKS_DIR}/failed/${TASK_ID}.json"; do
            [[ -f "$result_file" ]] || continue
            task_matches_local_source "$result_file" || continue
            sync_task_result "$result_file"
            ((synced++)) || true
        done
    else
        # 所有已完成任务
        for result_file in "${BRIDGE_TASKS_DIR}/done"/bridge-*.json \
                           "${BRIDGE_TASKS_DIR}/failed"/bridge-*.json; do
            [[ -f "$result_file" ]] || continue
            task_matches_local_source "$result_file" || continue
            sync_task_result "$result_file"
            ((synced++)) || true
        done
    fi
    
    info "同步完成: $synced 个任务"
    
    # 3. 显示统计
    echo ""
    count_tasks
}

# ---- 同步单个任务结果 ----
sync_task_result() {
    local result_file="$1"
    local tid
    tid=$(basename "$result_file" .json)
    
    # 读取结果
    local status summary artifact_id word_count completed_at executor
    status=$(jq -r '.status' "$result_file")
    summary=$(jq -r '.result.summary // ""' "$result_file")
    artifact_id=$(jq -r '.artifacts[0].artifact_id // ""' "$result_file")
    word_count=$(jq -r '.result.word_count // 0' "$result_file")
    completed_at=$(jq -r '.completed_at // ""' "$result_file")
    executor=$(jq -r '.executor // "unknown"' "$result_file")
    local source_site target_site flow_version
    source_site=$(jq -r '.source // "unknown"' "$result_file")
    target_site=$(jq -r '.target // "unknown"' "$result_file")
    flow_version=$(jq -r '.flow_version // "v1"' "$result_file")
    
    info "同步任务: $tid (status=$status, direction=${source_site}->${target_site}, flow=${flow_version}, executor=$executor)"
    log_info "Syncing task $tid: status=$status direction=${source_site}->${target_site}"
    
    # 打印摘要
    if [[ -n "$summary" ]]; then
        echo ""
        echo "=== $tid 摘要 ==="
        echo "$summary" | head -20
        echo "..."
        echo ""
    fi
    
    # 写入本机 Obsidian
    if [[ "$TO_OBSIDIAN" == "true" ]]; then
        write_to_obsidian "$result_file"
    fi
}

# ---- 写入 Obsidian ----
write_to_obsidian() {
    local result_file="$1"
    local tid
    tid=$(basename "$result_file" .json)
    
    local status summary task_type title completed_at executor
    status=$(jq -r '.status' "$result_file")
    summary=$(jq -r '.result.summary // ""' "$result_file")
    task_type=$(jq -r '.task_type // ""' "$result_file")
    title=$(jq -r '.title // ""' "$result_file")
    completed_at=$(jq -r '.completed_at // ""' "$result_file")
    executor=$(jq -r '.executor // "unknown"' "$result_file")
    local source_site target_site executor_lane reclassified flow_version
    source_site=$(jq -r '.source // "unknown"' "$result_file")
    target_site=$(jq -r '.target // "unknown"' "$result_file")
    flow_version=$(jq -r '.flow_version // "v1"' "$result_file")
    executor_lane=$(jq -r '.executor_site_assigned // .company_lane_assigned // "unknown"' "$result_file")
    reclassified=$(jq -r '.executor_reclassified // .company_reclassified // false' "$result_file")
    
    mkdir -p "$BRIDGE_NOTES_DIR"
    
    local date_str
    date_str=$(date '+%Y-%m-%d')
    local note_file="${BRIDGE_NOTES_DIR}/${tid}.md"
    
    cat > "$note_file" <<EOF
---
date: ${date_str}
tags: [bridge, sync, ${status}]
source: bridge-sync
task_id: ${tid}
completed_at: ${completed_at}
---

# 桥接任务结果: ${tid}

## 任务信息
- **标题**: ${title}
- **类型**: ${task_type}
- **方向**: ${source_site} → ${target_site}
- **Flow**: ${flow_version}
- **Lane**: ${executor_lane}
- **重新分类**: ${reclassified}

## 执行结果
- **状态**: ${status}
- **执行者**: ${executor}
- **完成时间**: ${completed_at}
- **摘要字数**: ${word_count:-0}

## 脱敏摘要

${summary}

## 公司侧决策

| 字段 | 值 |
|------|-----|
| executor_site_assigned | ${executor_lane} |
| executor_reclassified | ${reclassified} |
| executor | ${executor} |
| source | ${source_site} |
| target | ${target_site} |

## 原始任务单

\`\`\`json
$(jq '.' "$result_file")
\`\`\`

---
*由 bridge-sync.sh 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')*
EOF
    
    ok "已写入 Obsidian: $note_file"
    log_info "Written to Obsidian: $note_file"
}

main "$@"
