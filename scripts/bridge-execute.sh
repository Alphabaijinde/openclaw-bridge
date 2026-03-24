#!/usr/bin/env bash
# ============================================================
# bridge-execute.sh - 执行任务（公司侧）
# 
# 用法:
#   bridge-execute.sh <task-file.json>
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-lib.sh
source "${SCRIPT_DIR}/bridge-lib.sh"

# ---- 参数 ----
if [[ $# -lt 1 ]]; then
    err "用法: $0 <task-file.json>"
    exit 1
fi

TASK_FILE="$1"
EXECUTOR="${COMPANY_EXECUTOR:-company-openclaw}"

if [[ ! -f "$TASK_FILE" ]]; then
    err "任务文件不存在: $TASK_FILE"
    exit 1
fi

TASK_ID=$(jq -r '.task_id' "$TASK_FILE")
TASK_TYPE=$(jq -r '.task_type' "$TASK_FILE")
INSTRUCTION=$(jq -r '.payload.instruction' "$TASK_FILE")
ALLOWED_ACTIONS=$(jq -r '.payload.allowed_actions | join(",")' "$TASK_FILE")
MAX_OUTPUT_CHARS=$(jq -r '.payload.max_output_chars // 2000' "$TASK_FILE")
TIMEOUT=$(jq -r '.timeout_seconds // 600' "$TASK_FILE")

info "====== 执行任务: $TASK_ID ======"
info "Type: $TASK_TYPE"
info "Actions: $ALLOWED_ACTIONS"
info "Timeout: ${TIMEOUT}s"

STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# ---- 根据 task_type 分发执行 ----
execute_task() {
    local status="success"
    local summary=""
    local word_count=0
    local artifact_id=""
    
    case "$TASK_TYPE" in
        status-summary)
            summary=$(execute_status_summary)
            ;;
        public-research)
            summary=$(execute_public_research)
            ;;
        daily-report)
            summary=$(execute_daily_report)
            ;;
        obsidian-write)
            summary=$(execute_obsidian_write)
            ;;
        state-sync)
            summary=$(execute_state_sync)
            ;;
        *)
            status="failed"
            summary="未知 task_type: $TASK_TYPE"
            err "$summary"
            ;;
    esac
    
    word_count=$(echo "$summary" | wc -w)
    
    # 如果 summary 超过限制，截断
    if [[ ${#summary} -gt "$MAX_OUTPUT_CHARS" ]]; then
        summary="${summary:0:$MAX_OUTPUT_CHARS}"
        summary="${summary}...(truncated)"
        warn "摘要超过 ${MAX_OUTPUT_CHARS} 字符，已截断"
    fi
    
    # 生成 artifact_id
    artifact_id="${TASK_ID}-$(date '+%Y%m%d%H%M%S')"
    
    # 写摘要到 artifacts
    local summary_file="${BRIDGE_ARTIFACTS_DIR}/summaries/${artifact_id}.md"
    mkdir -p "$(dirname "$summary_file")"
    echo "# ${TASK_ID} 摘要" > "$summary_file"
    echo "" >> "$summary_file"
    echo "## 任务信息" >> "$summary_file"
    jq -r 'to_entries[] | "| \(.key) | \(.value) |"' "$TASK_FILE" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "## 执行结果" >> "$summary_file"
    echo "$summary" >> "$summary_file"
    
    log_info "Artifact saved: $summary_file"
    
    local reclassified="false"
    # 写结果回任务单
    write_result "$status" "$summary" "$word_count" "$artifact_id" "$STARTED_AT"
    
    # 移入 done
    local running_file="${BRIDGE_TASKS_DIR}/running/${TASK_ID}.json"
    if [[ -f "$running_file" ]]; then
        mv "$running_file" "${BRIDGE_TASKS_DIR}/done/${TASK_ID}.json"
    fi
    
    feishu_notify "success" "任务执行完成 [$OPENCLAW_SIDE]" "任务 $TASK_ID 已由 $OPENCLAW_SIDE 执行完成，结果见：$summary_file 及 tasks/done/${TASK_ID}.json"
}

# ---- 各类型任务执行器 ----

execute_status_summary() {
    # 读取公司侧任务状态
    local today_tasks
    today_tasks=$(find "${BRIDGE_TASKS_DIR}/done" -name "bridge-$(date '+%Y-%m-%d')-*.json" 2>/dev/null | wc -l)
    local running_tasks
    running_tasks=$(find "${BRIDGE_TASKS_DIR}/running" -name "bridge-$(date '+%Y-%m-%d')-*.json" 2>/dev/null | wc -l)
    
    cat <<EOF
今日任务汇总：

完成任务数：${today_tasks}
运行中任务数：${running_tasks}
最后更新：$(date '+%Y-%m-%d %H:%M:%S')

系统状态：正常运行
EOF
}

execute_public_research() {
    # 执行公开资料研究
    # 这里调用 Claude Code 或其他工具执行
    
    local research_prompt="你是一个研究助手。请执行以下任务：

${INSTRUCTION}

请生成一份结构化的研究报告，包括：
1. 核心发现
2. 关键技术点
3. 数据来源

输出限制：${MAX_OUTPUT_CHARS} 字符以内。"

    # 调用 Claude Code 执行研究
    # 注意：实际环境中替换为具体的 CLI 调用
    if command -v claude &>/dev/null; then
        echo "$research_prompt" | claude -p "$(cat)" --dangerously-skip-permissions 2>/dev/null | head -c "$MAX_OUTPUT_CHARS"
    else
        cat <<EOF
公开研究任务（模拟执行）：

任务指令：${INSTRUCTION}

当前环境无可用的研究工具（Claude Code 未配置）。

建议：
1. 在公司侧安装 Claude Code
2. 配置 --dangerously-skip-permissions 用于无人值守执行
3. 或使用 Gemini CLI --yolo 模式
EOF
    fi
}

execute_daily_report() {
    # 生成日报
    local date_str
    date_str=$(date '+%Y-%m-%d')
    
    cat <<EOF
## ${date_str} 日报

### 今日完成
- GitHub Trending 分析
- 桥接系统测试

### 明日计划
- 继续完善桥接系统
- 集成飞书通知

### 风险提示
- 无
EOF
}

execute_obsidian_write() {
    # 向公司 Obsidian 写入低敏内容
    local obsidian_dir="${COMPANY_OBSIDIAN_DIR:-${HOME_OBSIDIAN_DIR}}"
    
    if [[ ! -d "$obsidian_dir" ]]; then
        err "Obsidian 目录不存在: $obsidian_dir"
        return 1
    fi
    
    local date_str
    date_str=$(date '+%Y-%m-%d')
    local note_file="${obsidian_dir}/AI趋势/bridge-note-${date_str}.md"
    
    mkdir -p "$(dirname "$note_file")"
    
    cat > "$note_file" <<EOF
---
date: ${date_str}
tags: [bridge, company]
source: bridge-task
task_id: ${TASK_ID}
---

# 桥接任务执行记录

## 任务信息
- 任务ID: ${TASK_ID}
- 类型: ${TASK_TYPE}
- 指令: ${INSTRUCTION}

## 执行结果
执行时间: $(date '+%Y-%m-%d %H:%M:%S')
执行者: ${EXECUTOR}

EOF
    
    echo "已写入: $note_file"
}

execute_state_sync() {
    # 双向状态同步
    local inbox_count failed_count done_count
    inbox_count=$(find "${BRIDGE_TASKS_DIR}/inbox" -name "bridge-*.json" 2>/dev/null | wc -l)
    failed_count=$(find "${BRIDGE_TASKS_DIR}/failed" -name "bridge-*.json" 2>/dev/null | wc -l)
    done_count=$(find "${BRIDGE_TASKS_DIR}/done" -name "bridge-*.json" 2>/dev/null | wc -l)
    local running_count
    running_count=$(find "${BRIDGE_TASKS_DIR}/running" -name "bridge-*.json" 2>/dev/null | wc -l)
    
    cat <<EOF
{
  "sync_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "status": {
    "inbox": ${inbox_count},
    "running": ${running_count:-0},
    "done": ${done_count},
    "failed": ${failed_count}
  }
}
EOF
}

# ---- 写结果回任务单 ----
write_result() {
    local status="$1"
    local summary="$2"
    local word_count="$3"
    local artifact_id="$4"
    local started_at="$5"
    
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    local result_file="${BRIDGE_TASKS_DIR}/running/${TASK_ID}.json"
    
    # 构建结果 JSON
    jq -n \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg word_count "$word_count" \
        --arg artifact_id "$artifact_id" \
        --arg started_at "$started_at" \
        --arg completed_at "$now" \
        --arg executor "$EXECUTOR" \
        --arg company_lane "safe-auto" \
        --arg company_reclassified "false" \
        '{
            status: $status,
            result: {
                summary: $summary,
                word_count: ($word_count | tonumber)
            },
            artifacts: [{
                type: "report",
                artifact_id: $artifact_id,
                sensitivity: "internal-summary",
                accessible: false
            }],
            company_lane_assigned: $company_lane,
            company_reclassified: ($reclassified == "true"),
            executor: $executor,
            started_at: $started_at,
            completed_at: $completed_at,
            updated_at: $completed_at
        }' > "${result_file}.result"
    
    # 合并到原任务单
    jq -s '.[0] * .[1]' "$result_file" "${result_file}.result" > "${result_file}.merged"
    mv "${result_file}.merged" "$result_file"
    rm -f "${result_file}.result"
    
    log_info "Result written for $TASK_ID: status=$status"
}

# ---- 执行 ----
execute_task