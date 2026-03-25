#!/usr/bin/env bash
# ============================================================
# OpenClaw 桥接层 - 共享函数库
# bridge-lib.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_ROOT="$(dirname "$SCRIPT_DIR")"

# ---- 加载环境配置（不影响 BRIDGE_ROOT） ----
_load_env() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^# ]] && continue
        [[ -z "$key" ]] && continue
        # 清除空格
        key="$(echo "$key" | xargs)"
        [[ -z "$key" ]] && continue
        [[ "$key" == "BRIDGE_ROOT" ]] && continue
        
        # 处理 val，删除首尾引号和回车
        val="$(echo "$val" | sed 's/\r$//' | xargs)"
        # 删除首尾引号（如果成对出现）
        if [[ "$val" =~ ^\".*\"$ ]] || [[ "$val" =~ ^\'.*\'$ ]]; then
            val="${val:1:-1}"
        fi
        
        if [[ -n "$key" ]]; then
            # 如果变量未设置，则设置它
            if [[ -z "${!key:-}" ]]; then
                export "$key"="$val"
            fi
        fi
    done < "$env_file"
}

_load_env "${BRIDGE_ROOT}/bridge.env"
_load_env "${BRIDGE_ROOT}/bridge.env.example"

SCHEMAS_DIR="${BRIDGE_ROOT}/schemas"
BRIDGE_TASKS_DIR="${BRIDGE_TASKS_DIR:-${BRIDGE_ROOT}/tasks}"
BRIDGE_ARTIFACTS_DIR="${BRIDGE_ARTIFACTS_DIR:-${BRIDGE_ROOT}/artifacts}"
BRIDGE_LOGS_DIR="${BRIDGE_LOGS_DIR:-${BRIDGE_ROOT}/logs}"
BRIDGE_GIT_REMOTE="${BRIDGE_GIT_REMOTE:-}"
BRIDGE_GIT_BRANCH="${BRIDGE_GIT_BRANCH:-main}"
ALLOWED_TASK_TYPES="${ALLOWED_TASK_TYPES:-status-summary,public-research,daily-report,obsidian-write,state-sync}"
ALLOWED_ACTIONS_DEFAULT="${ALLOWED_ACTIONS_DEFAULT:-read_status,summarize,write_obsidian,fetch_public}"

# ---- 日志函数 ----
log() {
    local level="${1:-INFO}"
    local msg="${2:-}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_file="${BRIDGE_LOGS_DIR}/bridge-$(date '+%Y-%m-%d').log"
    
    mkdir -p "$(dirname "$log_file")"
    echo "[$ts] [$level] $msg" | tee -a "$log_file"
}

log_info()  { log "INFO" "$*"; }
log_warn()  { log "WARN" "$*"; }
log_error() { log "ERROR" "$*"; }
log_debug() { [[ "${LOG_LEVEL:-info}" == "debug" ]] && log "DEBUG" "$*"; }

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

# ---- Git 操作 ----
git_setup() {
    local dir="${1:-.}"
    local remote="${2:-}"
    local branch="${3:-main}"
    
    git -C "$dir" config --local user.email "${BRIDGE_GIT_USER_EMAIL:-bridge@local}" 2>/dev/null || true
    git -C "$dir" config --local user.name  "${BRIDGE_GIT_USER_NAME:-Bridge}" 2>/dev/null || true
    
    if [[ -n "$remote" ]]; then
        git -C "$dir" remote add origin "$remote" 2>/dev/null || \
            git -C "$dir" remote set-url origin "$remote"
        git -C "$dir" checkout -b "$branch" 2>/dev/null || \
            git -C "$dir" checkout "$branch" 2>/dev/null || true
    fi
}

git_push() {
    local dir="${1:-.}"
    local branch="${2:-main}"
    local msg="${3:-auto commit}"
    
    git -C "$dir" add -A
    if git -C "$dir" diff --cached --quiet; then
        log_debug "No changes to commit"
        return 0
    fi
    
    git -C "$dir" commit -m "$msg"
    
    if [[ -n "${BRIDGE_SSH_KEY:-}" ]]; then
        GIT_SSH_COMMAND="ssh -i '${BRIDGE_SSH_KEY}'" git -C "$dir" push -u origin "$branch"
    else
        git -C "$dir" push -u origin "$branch"
    fi
}

git_pull_rebase() {
    local dir="${1:-.}"
    local branch="${2:-main}"
    
    if [[ -n "${BRIDGE_SSH_KEY:-}" ]]; then
        GIT_SSH_COMMAND="ssh -i '${BRIDGE_SSH_KEY}'" git -C "$dir" pull --rebase origin "$branch"
    else
        git -C "$dir" pull --rebase origin "$branch"
    fi
}

# ---- 任务 ID 生成 ----
generate_task_id() {
    local date_str
    date_str="$(date '+%Y-%m-%d')"
    local seq
    seq=$(find "${BRIDGE_TASKS_DIR}/inbox" "${BRIDGE_TASKS_DIR}/running" "${BRIDGE_TASKS_DIR}/done" \
        -name "bridge-${date_str}-*.json" 2>/dev/null | wc -l)
    printf "bridge-%s-%03d" "$date_str" $((seq + 1))
}

# ---- Schema 验证 ----
validate_task_schema() {
    local task_file="$1"
    
    if [[ ! -f "$task_file" ]]; then
        log_error "Task file not found: $task_file"
        return 1
    fi
    
    # 基本字段检查（jq 验证）
    if ! jq -e '
        .task_id |
        startswith("bridge-") |
        and(.task_id | test("^bridge-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$")) |
        and(.payload.instruction | length <= 1000)
    ' "$task_file" >/dev/null 2>&1; then
        log_error "Schema validation failed: $task_file"
        return 1
    fi
    
    # task_type 白名单检查
    local allowed_types="status-summary public-research daily-report obsidian-write state-sync"
    local task_type
    task_type=$(jq -r '.task_type // ""' "$task_file")
    if [[ ! " $allowed_types " =~ " $task_type " ]]; then
        log_error "task_type '$task_type' not in whitelist"
        return 1
    fi
    
    # lane 检查（Phase 1 仅允许 safe-auto）
    local lane
    lane=$(jq -r '.lane // ""' "$task_file")
    if [[ "$lane" != "safe-auto" ]]; then
        log_error "lane '$lane' not allowed in Phase 1 (must be safe-auto)"
        return 1
    fi
    
    return 0
}

# ---- Lease 管理 ----
claim_task() {
    local task_file="$1"
    local executor="${2:-unknown}"
    local lease_ttl="${3:-600}"
    
    local now expiry
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    expiry=$(date -u -d "+${lease_ttl} seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
        date -u -v+${lease_ttl}s '+%Y-%m-%dT%H:%M:%SZ')
    
    jq --arg executor "$executor" \
       --arg now "$now" \
       --arg expiry "$expiry" '
        .status = "running" |
        ._claim = {
            executor: $executor,
            claimed_at: $now,
            lease_expires_at: $expiry
        } |
        .updated_at = $now
    ' "$task_file" > "${task_file}.tmp" && mv "${task_file}.tmp" "$task_file"
}

release_task() {
    local task_file="$1"
    local reason="${2:-lease_expired}"
    
    jq --arg reason "$reason" \
       --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        .status = "pending" |
        del(._claim) |
        .updated_at = $now |
        .failure_info = {
            failure_type: $reason,
            message: "Task lease expired or was released",
            recovery_hint: "Task can be re-claimed"
        }
    ' "$task_file" > "${task_file}.tmp" && mv "${task_file}.tmp" "$task_file"
}

is_lease_expired() {
    local task_file="$1"
    local expiry
    expiry=$(jq -r '._claim.lease_expires_at // ""' "$task_file")
    
    if [[ -z "$expiry" ]]; then
        return 1  # 没有 lease，不过期
    fi
    
    local now_ts expiry_ts
    now_ts=$(date -u '+%s')
    expiry_ts=$(date -u -d "$expiry" '+%s' 2>/dev/null || echo 0)
    
    [[ "$now_ts" -gt "$expiry_ts" ]]
}

# ---- 飞书通知 ----
feishu_notify() {
    local level="${1:-info}"
    local title="${2:-}"
    local content="${3:-}"
    
    if [[ -z "${FEISHU_WEBHOOK_URL:-}" ]]; then
        log_warn "FEISHU_WEBHOOK_URL not set, skipping notification"
        return 0
    fi
    
    log "DEBUG" "Feishu notification: level=$level title=$title"
    
    local color
    case "$level" in
        error)  color="red" ;;
        warn)   color="orange" ;;
        success) color="green" ;;
        *)      color="blue" ;;
    esac
    
    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg content "$content" \
        --arg color "$color" \
        '{
            msg_type: "interactive",
            card: {
                header: {
                    title: { tag: "plain_text", content: $title },
                    color: $color
                },
                elements: [{
                    tag: "markdown",
                    content: $content
                }]
            }
        }')
    
    curl -s -X POST "${FEISHU_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null
}

# ---- 任务计数统计 ----
count_tasks() {
    local dir="${1:-${BRIDGE_TASKS_DIR}}"
    echo "inbox: $(find "${dir}/inbox" -name '*.json' 2>/dev/null | wc -l)"
    echo "running: $(find "${dir}/running" -name '*.json' 2>/dev/null | wc -l)"
    echo "done: $(find "${dir}/done" -name '*.json' 2>/dev/null | wc -l)"
    echo "failed: $(find "${dir}/failed" -name '*.json' 2>/dev/null | wc -l)"
}

# ---- 敏感信息扫描 ----
scan_sensitive() {
    local text="$1"
    local patterns="${FORBIDDEN_PATTERNS:-}"
    
    # 基本敏感词扫描
    local forbidden="\.env|OAuth|cookie|token|secret|credential|/etc/|passwd"
    patterns="${patterns:-$forbidden}"
    
    if echo "$text" | grep -Ei "$patterns" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ---- 公司侧风险重判 ----
company_risk_check() {
    local task_file="$1"
    
    local task_type instruction
    task_type=$(jq -r '.task_type // ""' "$task_file")
    instruction=$(jq -r '.payload.instruction // ""' "$task_file")
    
    IFS=',' read -ra _allowed_types <<< "${ALLOWED_TASK_TYPES:-status-summary,public-research,daily-report,obsidian-write,state-sync}"
    local match=0
    for allowed in "${_allowed_types[@]}"; do
        [[ "$allowed" == "$task_type" ]] && match=1 && break
    done
    if [[ "$match" -eq 0 ]]; then
        echo "FAIL: task_type '$task_type' not in whitelist"
        return 1
    fi
    
    local allowed_actions_str
    allowed_actions_str=$(jq -r '.payload.allowed_actions // [] | join(",")' "$task_file")
    IFS=',' read -ra _allowed_actions <<< "${allowed_actions_str}"
    IFS=',' read -ra _valid_actions <<< "${ALLOWED_ACTIONS_DEFAULT:-read_status,summarize,write_obsidian,fetch_public}"
    for action in "${_allowed_actions[@]}"; do
        local valid=0
        for va in "${_valid_actions[@]}"; do
            [[ "$va" == "$action" ]] && valid=1 && break
        done
        if [[ "$valid" -eq 0 ]]; then
            echo "FAIL: allowed_actions '$action' not permitted"
            return 1
        fi
    done
    
    # 敏感词扫描 instruction
    if ! scan_sensitive "$instruction"; then
        echo "FAIL: instruction contains forbidden patterns"
        return 1
    fi
    
    # 外部 API 调用检查（instruction 提及敏感操作）
    if echo "$instruction" | grep -Ei "(export|download|全部|full context|原始)" >/dev/null 2>&1; then
        echo "REVIEW: instruction may require human review"
        return 2
    fi
    
    # 检查是否需要生成 URL
    if echo "$instruction" | grep -Ei "(generate url|生成链接|返回链接|返回 url)" >/dev/null 2>&1; then
        echo "REVIEW: instruction may generate accessible URL"
        return 2
    fi
    
    # 全部通过
    echo "PASS: safe-auto"
    return 0
}
