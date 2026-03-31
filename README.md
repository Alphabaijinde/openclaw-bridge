# OpenClaw 桥接层

公司与个人 OpenClaw 之间的双向任务流转中枢。

## 核心理念

- **任务池**：GitHub 仓库作为任务池（inbox/running/done/failed）
- **双向流转**：公司 ↔ 家里 双向任务流转
- **角色感知**：脚本通过 `BRIDGE_ROLE=home|company` 识别本机侧
- **异步执行**：任务提交后由目标侧拉取并执行

## 架构

```
                 ┌─────────────────────────┐
                 │     GitHub 任务池       │
                 │ inbox / running / done  │
                 └──────────┬──────────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
          ▼                 │                 ▼
   ┌──────────────┐         │         ┌──────────────┐
   │   家里侧     │◄────────┼────────►│    公司侧    │
   │ push / pull  │         │         │ push / pull  │
   │ execute/sync │         │         │ execute/sync │
   └──────────────┘         │         └──────────────┘
          │                 │                 │
          └─────────────────┼─────────────────┘
                            │
                        Feishu 通知
```

## 任务流转

```
发起方: BRIDGE_ROLE=home|company bridge-push.sh --push
        → 创建任务 JSON（默认 target=any）→ Git Push → 仓库

执行方: BRIDGE_ROLE=home|company bridge-pull.sh --execute (cron 轮询)
        → Git Pull → 领取 any 或本机限定任务 → 执行 → 写结果 → Git Push

状态流转: inbox → running → done / failed
```

## 双向任务流

| 方向 | 发起方 | 执行方 | 场景 |
|------|--------|--------|------|
| 公司 → 家里 | 公司 push | 家里 pull+execute | 公司发起、家里执行 |
| 家里 → 公司 | 家里 push | 公司 pull+execute | 家里发起、公司执行 |

## 目录结构

```
bridge/
├── README.md
├── bridge.env.example          # 配置模板（复制为 bridge.env）
├── schemas/
│   ├── task.schema.json        # 任务单 Schema
│   └── result.schema.json      # 结果回传 Schema
├── tasks/
│   ├── inbox/                  # 待处理（双向）
│   ├── running/                # 执行中
│   ├── done/                   # 完成任务
│   └── failed/                 # 失败/需人工审核
├── artifacts/
│   └── summaries/              # 脱敏摘要（Phase 1 上限 2000 字）
├── logs/
│   └── bridge-YYYY-MM-DD.log   # 每日日志
└── scripts/
    ├── bridge-push.sh          # 推送任务（双向）
    ├── bridge-pull.sh          # 拉取任务（双向）
    ├── bridge-execute.sh       # 执行任务（双向）
    ├── bridge-sync.sh          # 同步结果（双向）
    ├── bridge-status.sh        # 查询状态
    └── bridge-lib.sh          # 共享函数库
```

## 快速开始

### 1. 配置

```bash
cd ~/ai-tasks/bridge
cp bridge.env.example bridge.env
# 编辑 bridge.env 填入实际值
```

### 2. 家里侧：推送任务

```bash
BRIDGE_ROLE=home ./scripts/bridge-push.sh \
  --title "生成今日 GitHub Trending 分析" \
  --task-type public-research \
  --instruction "抓取 GitHub Trending，生成深度分析报告" \
  --allowed-actions "fetch_public,summarize" \
  --push
```

### 3. 公司侧：推送任务到家里

```bash
BRIDGE_ROLE=company ./scripts/bridge-push.sh \
  --title "整理今天的桥接状态" \
  --task-type status-summary \
  --instruction "汇总本日任务状态并写入结果" \
  --push
```

### 4. 双向侧：拉取并执行

```bash
BRIDGE_ROLE=company ./scripts/bridge-pull.sh --execute

# 定时轮询（建议每 5 分钟）
*/5 * * * * BRIDGE_ROLE=company ~/ai-tasks/bridge/scripts/bridge-pull-cron.sh
```

### 5. 同步结果

```bash
BRIDGE_ROLE=home ./scripts/bridge-sync.sh --to-obsidian
```

## 任务通道

| 通道 | 说明 | 自动执行 |
|------|------|----------|
| safe-auto | 只读、低敏、可重试任务 | ✅ |
| sandbox-auto | 隔离环境内执行 | ❌ Phase 1 |
| human-review | 必须人工审核 | ❌ |

## 流转约束

- `target=any` 表示任意侧可领取；`home/company` 表示仅限定侧可领取
- 默认 `lane` 仍为 `safe-auto`
- 仅允许白名单内的 `task_type`
- 最大摘要 2000 字符
- Artifact 使用 opaque ID，不返回 URL
- 执行侧有权重新分类任务风险

## 安全原则

1. 不交换凭据 / OAuth / SSH Key
2. 不交换公司文档全文
3. 不交换原始日志
4. 桥接层仅视为低敏任务中转层
5. 执行侧拥有最终风险分类权

## 日志

日志文件：`logs/bridge-YYYY-MM-DD.log`

每条日志包含：
- 时间戳
- 操作类型（push/pull/execute/sync）
- 任务 ID
- 状态变更
- 错误信息（如有）

## 故障排除

### Git 推送失败
```bash
# 检查 SSH 密钥
ssh -T git@github.com
# 检查远程仓库
git -C "$BRIDGE_ROOT" remote -v
```

### 任务卡在 running
```bash
# 检查 lease 是否过期
cat tasks/running/*.json | jq '._claim.lease_expires_at'
# 手动清理（执行侧）
./scripts/bridge-pull.sh --recover
```

### Schema 验证失败
```bash
# 验证任务单
jq -e '.task_id, .payload, .status' tasks/inbox/bridge-*.json
# 使用 ajv 严格验证
ajv validate -s schemas/task.schema.json -d tasks/inbox/bridge-*.json
```
