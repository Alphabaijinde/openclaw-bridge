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
    local override="${2:-false}"
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
            if [[ "$override" == "true" || -z "${!key+x}" ]]; then
                export "$key"="$val"
            fi
        fi
    done < "$env_file"
}

_load_env "${BRIDGE_ROOT}/bridge.env.example" "false"
_load_env "${BRIDGE_ROOT}/bridge.env" "true"

SCHEMAS_DIR="${BRIDGE_ROOT}/schemas"
BRIDGE_TASKS_DIR="${BRIDGE_TASKS_DIR:-${BRIDGE_ROOT}/tasks}"
BRIDGE_ARTIFACTS_DIR="${BRIDGE_ARTIFACTS_DIR:-${BRIDGE_ROOT}/artifacts}"
BRIDGE_LOGS_DIR="${BRIDGE_LOGS_DIR:-${BRIDGE_ROOT}/logs}"
BRIDGE_GIT_REMOTE="${BRIDGE_GIT_REMOTE:-}"
BRIDGE_GIT_BRANCH="${BRIDGE_GIT_BRANCH:-main}"
ALLOWED_TASK_TYPES="${ALLOWED_TASK_TYPES:-status-summary,public-research,daily-report,obsidian-write,state-sync}"
ALLOWED_ACTIONS_DEFAULT="${ALLOWED_ACTIONS_DEFAULT:-read_status,summarize,write_obsidian,fetch_public}"

BRIDGE_ROLE="${BRIDGE_ROLE:-home}"
BRIDGE_ROLE="$(printf '%s' "$BRIDGE_ROLE" | tr '[:upper:]' '[:lower:]')"
case "$BRIDGE_ROLE" in
    home|company) BRIDGE_ROLE="$BRIDGE_ROLE" ;;
    *) BRIDGE_ROLE="home" ;;
esac

OPENCLAW_SIDE="${OPENCLAW_SIDE:-$BRIDGE_ROLE}"

mkdir -p \
    "${BRIDGE_TASKS_DIR}/inbox" \
    "${BRIDGE_TASKS_DIR}/running" \
    "${BRIDGE_TASKS_DIR}/done" \
    "${BRIDGE_TASKS_DIR}/failed" \
    "${BRIDGE_ARTIFACTS_DIR}/summaries" \
    "${BRIDGE_LOGS_DIR}"

bridge_role() {
    echo "${BRIDGE_ROLE:-home}"
}

bridge_peer_role() {
    case "$(bridge_role)" in
        home) echo "company" ;;
        company) echo "home" ;;
        *) echo "home" ;;
    esac
}

bridge_role_label() {
    case "${1:-$(bridge_role)}" in
        home) echo "家里侧" ;;
        company) echo "公司侧" ;;
        *) echo "未知侧" ;;
    esac
}

bridge_direction_label() {
    local source_site="${1:-$(bridge_role)}"
    local target_site="${2:-$(bridge_peer_role)}"
    echo "$(bridge_role_label "$source_site") → $(bridge_role_label "$target_site")"
}

bridge_default_target_site() {
    local configured_target="${BRIDGE_DEFAULT_TARGET:-}"
    local local_role
    local_role="$(bridge_role)"
    local normalized_target
    normalized_target="$(printf '%s' "$configured_target" | tr '[:upper:]' '[:lower:]')"

    case "$normalized_target" in
        home|company)
            if [[ "$normalized_target" != "$local_role" ]]; then
                echo "$normalized_target"
                return 0
            fi
            ;;
    esac

    echo "any"
}

bridge_local_obsidian_dir() {
    case "$(bridge_role)" in
        home)
            echo "${HOME_OBSIDIAN_DIR:-${BRIDGE_ROOT}/../Obsidian}"
            ;;
        company)
            echo "${COMPANY_OBSIDIAN_DIR:-${HOME_OBSIDIAN_DIR:-${BRIDGE_ROOT}/../Obsidian}}"
            ;;
        *)
            echo "${HOME_OBSIDIAN_DIR:-${BRIDGE_ROOT}/../Obsidian}"
            ;;
    esac
}

bridge_now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

bridge_add_seconds_utc() {
    local seconds="${1:-0}"
    python3 - "$seconds" <<'PY'
import sys
from datetime import datetime, timedelta, timezone

seconds = int(sys.argv[1])
print((datetime.now(timezone.utc) + timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
}

bridge_iso_to_epoch() {
    local iso="${1:-}"
    python3 - "$iso" <<'PY'
import sys
from datetime import datetime, timezone

iso = sys.argv[1]
if not iso:
    print(0)
    raise SystemExit(0)

dt = datetime.strptime(iso, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
PY
}

task_matches_local_target() {
    local task_file="$1"
    local local_role="${2:-$(bridge_role)}"
    local target
    target="$(jq -r '.target // ""' "$task_file")"
    [[ "$target" == "$local_role" || "$target" == "any" ]]
}

task_matches_local_source() {
    local task_file="$1"
    local local_role="${2:-$(bridge_role)}"
    [[ "$(jq -r '.source // ""' "$task_file")" == "$local_role" ]]
}

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
    local task_id source target task_type lane instruction
    task_id=$(jq -r '.task_id // ""' "$task_file")
    source=$(jq -r '.source // ""' "$task_file")
    target=$(jq -r '.target // ""' "$task_file")
    task_type=$(jq -r '.task_type // ""' "$task_file")
    lane=$(jq -r '.lane // ""' "$task_file")
    instruction=$(jq -r '.payload.instruction // ""' "$task_file")

    if ! [[ "$task_id" =~ ^bridge-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$ ]]; then
        log_error "Invalid task_id: $task_id"
        return 1
    fi

    if [[ "$source" != "home" && "$source" != "company" ]]; then
        log_error "source '$source' is invalid"
        return 1
    fi

    if [[ "$target" != "home" && "$target" != "company" && "$target" != "any" ]]; then
        log_error "target '$target' is invalid"
        return 1
    fi

    if [[ "$target" != "any" && "$source" == "$target" ]]; then
        log_error "source and target must differ for bidirectional flow"
        return 1
    fi

    local allowed_types="${ALLOWED_TASK_TYPES:-status-summary,public-research,daily-report,obsidian-write,state-sync}"
    local allowed_type
    local found_type="false"
    IFS=',' read -ra allowed_types_array <<< "$allowed_types"
    for allowed_type in "${allowed_types_array[@]}"; do
        if [[ "$allowed_type" == "$task_type" ]]; then
            found_type="true"
            break
        fi
    done
    if [[ "$found_type" != "true" ]]; then
        log_error "task_type '$task_type' not in whitelist"
        return 1
    fi

    if [[ "$lane" != "safe-auto" ]]; then
        log_error "lane '$lane' not allowed (must be safe-auto)"
        return 1
    fi

    if [[ ${#instruction} -gt 1000 ]]; then
        log_error "instruction exceeds 1000 characters"
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
    now="$(bridge_now_utc)"
    expiry="$(bridge_add_seconds_utc "$lease_ttl")"
    
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
    expiry_ts=$(bridge_iso_to_epoch "$expiry")
    
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
    
    log "DEBUG" "Feishu: level=$level title=$title"
    
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
    
    local curl_result
    curl_result=$(curl -s -X POST "${FEISHU_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    
    if echo "$curl_result" | grep -q '"code":0'; then
        log "DEBUG" "Feishu notification sent successfully"
    else
        log_warn "Feishu notification failed: $curl_result"
    fi
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

# ---- 执行侧风险重判 ----
executor_risk_check() {
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

company_risk_check() {
    executor_risk_check "$@"
}
