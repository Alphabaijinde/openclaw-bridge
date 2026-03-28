#!/usr/bin/env bash
# ============================================================
# bridge-status.sh - 查询任务状态
#
# 用法:
#   bridge-status.sh            # 显示所有任务状态
#   bridge-status.sh --id XXXX   # 显示指定任务详情
#   bridge-status.sh --watch     # 实时监控
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-lib.sh
source "${SCRIPT_DIR}/bridge-lib.sh"

# ---- 参数 ----
TASK_ID=""
WATCH="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)    TASK_ID="$2"; shift 2 ;;
        --watch) WATCH="true"; shift ;;
        *)       err "未知参数: $1"; exit 1 ;;
    esac
done

count_direction_tasks() {
    local source_site="$1"
    local target_site="$2"
    local total=0
    local dir f

    for dir in inbox running done failed; do
        for f in "${BRIDGE_TASKS_DIR}/${dir}"/bridge-*.json; do
            [[ -f "$f" ]] || continue
            if [[ "$(jq -r '.source // ""' "$f")" == "$source_site" && "$(jq -r '.target // ""' "$f")" == "$target_site" ]]; then
                ((total++)) || true
            fi
        done
    done

    echo "$total"
}

# ---- 主流程 ----
main() {
    if [[ -n "$TASK_ID" ]]; then
        show_task_detail "$TASK_ID"
    elif [[ "$WATCH" == "true" ]]; then
        watch_tasks
    else
        show_all_status
    fi
}

# ---- 显示所有任务状态 ----
show_all_status() {
    info "====== Bridge 任务状态 ======"
    echo ""
    info "Role: $(bridge_role_label) ($(bridge_role))"
    info "Default target: $(bridge_role_label "$(bridge_default_target_site)")"
    echo ""

    count_tasks
    echo ""

    echo "方向总览："
    echo "  家里侧 → 公司侧: $(count_direction_tasks home company)"
    echo "  公司侧 → 家里侧: $(count_direction_tasks company home)"
    echo ""

    for dir in inbox running done failed; do
        echo "【${dir}】"

        local found=0
        for f in "${BRIDGE_TASKS_DIR}/${dir}"/bridge-*.json; do
            [[ -f "$f" ]] || continue
            found=1

            local tid status source target lane priority executor
            tid=$(basename "$f" .json)
            status=$(jq -r '.status // "unknown"' "$f")
            source=$(jq -r '.source // "unknown"' "$f")
            target=$(jq -r '.target // "unknown"' "$f")
            lane=$(jq -r '.lane // "safe-auto"' "$f")
            priority=$(jq -r '.priority // "medium"' "$f")
            executor=$(jq -r '._claim.executor // .executor // "-"' "$f")

            local status_color
            case "$status" in
                pending)   status_color="${BLUE}$status${NC}" ;;
                running)   status_color="${YELLOW}$status${NC}" ;;
                success)   status_color="${GREEN}$status${NC}" ;;
                failed|needs_review) status_color="${RED}$status${NC}" ;;
                *)         status_color="$status" ;;
            esac

            printf "  %-30s [%s] %s→%s %-8s %-6s %s\n" \
                "$tid" "$status_color" "$source" "$target" "$lane" "$priority" "$executor"
        done

        [[ "$found" == "0" ]] && echo "  (无)"
        echo ""
    done
}

# ---- 显示单个任务详情 ----
show_task_detail() {
    local tid="$1"
    local found=0

    for dir in inbox running done failed; do
        local f="${BRIDGE_TASKS_DIR}/${dir}/${tid}.json"
        [[ -f "$f" ]] || continue
        found=1

        echo ""
        info "====== 任务详情: $tid ======"
        echo ""

        echo "基本信息："
        jq -r '
            "  task_id: \(.task_id // "")",
            "  flow_version: \(.flow_version // "v1")",
            "  source: \(.source // "")",
            "  target: \(.target // "")",
            "  title: \(.title // "")",
            "  lane: \(.lane // "")",
            "  priority: \(.priority // "medium")",
            "  task_type: \(.task_type // "")",
            "  status: \(.status // "")",
            "  requester: \(.requester // "-")",
            "  executor: \(.executor // ._claim.executor // "-")"
        ' "$f"

        echo ""
        echo "时间："
        jq -r '
            "  created_at: \(.created_at // "-")",
            "  updated_at: \(.updated_at // "-")",
            "  completed_at: \(.completed_at // "-")",
            "  claimed_at: \(._claim.claimed_at // "-")",
            "  lease_expires_at: \(._claim.lease_expires_at // "-")"
        ' "$f"

        echo ""
        echo "指令："
        jq -r '.payload.instruction // ""' "$f" | fold -s -w 80 | sed 's/^/  /'

        if jq -e '.result.summary' "$f" >/dev/null 2>&1; then
            echo ""
            echo "结果摘要："
            jq -r '.result.summary' "$f" | fold -s -w 80 | sed 's/^/  /'
        fi

        if jq -e '.failure_info' "$f" >/dev/null 2>&1; then
            echo ""
            echo "失败信息："
            jq -r '.failure_info | to_entries[] | "  \(.key): \(.value | tostring)"' "$f"
        fi

        echo ""
        break
    done

    [[ "$found" == "0" ]] && err "任务不存在: $tid"
}

# ---- 实时监控 ----
watch_tasks() {
    info "监控任务状态 (Ctrl+C 退出)..."
    local last_state=""

    while true; do
        clear
        echo "监控时间: $(date '+%H:%M:%S')"
        echo "角色: $(bridge_role_label) ($(bridge_role))"
        echo ""

        local inbox running done failed
        inbox=$(find "${BRIDGE_TASKS_DIR}/inbox" -name 'bridge-*.json' 2>/dev/null | wc -l)
        running=$(find "${BRIDGE_TASKS_DIR}/running" -name 'bridge-*.json' 2>/dev/null | wc -l)
        done=$(find "${BRIDGE_TASKS_DIR}/done" -name 'bridge-*.json' 2>/dev/null | wc -l)
        failed=$(find "${BRIDGE_TASKS_DIR}/failed" -name 'bridge-*.json' 2>/dev/null | wc -l)

        echo "inbox: $inbox | running: $running | done: $done | failed: $failed"
        echo ""

        local latest
        latest=$(find "${BRIDGE_TASKS_DIR}/running" "${BRIDGE_TASKS_DIR}/inbox" -name 'bridge-*.json' 2>/dev/null | sort -r | head -3)

        if [[ -n "$latest" ]]; then
            echo "活跃任务："
            for f in $latest; do
                local tid status source target executor lease
                tid=$(basename "$f" .json)
                status=$(jq -r '.status // "unknown"' "$f")
                source=$(jq -r '.source // "unknown"' "$f")
                target=$(jq -r '.target // "unknown"' "$f")
                executor=$(jq -r '._claim.executor // .executor // "-"' "$f")
                lease=$(jq -r '._claim.lease_expires_at // "-"' "$f")
                echo "  $tid | $status | ${source}→${target} | $executor | lease: $lease"
            done
        fi

        local current_state="i:${inbox} r:${running} d:${done} f:${failed}"
        if [[ "$current_state" != "$last_state" ]]; then
            last_state="$current_state"
            log_info "State changed: $current_state"
        fi

        sleep 10
    done
}

main "$@"
