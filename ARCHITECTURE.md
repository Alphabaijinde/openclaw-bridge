# OpenClaw 桥接层 - 24小时任务流转系统

## 系统架构

### 核心概念

- **任务池**：GitHub 仓库（inbox/running/done/failed）
- **双向流转**：公司 ↔ 家里 双向任务派发和领取
- **异步执行**：两侧不需要同时在线，通过 Git 仓库同步
- **定时轮询**：每 5 分钟自动检查任务池

### 架构图

```
                    ┌─────────────────┐
                    │  GitHub 仓库    │
                    │  (任务池)       │
                    │ tasks/inbox     │
                    │ tasks/running   │
                    │ tasks/done      │
                    │ tasks/failed    │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              │              ▼
      ┌───────────────┐       │       ┌───────────────┐
      │   公司侧      │       │       │    家里侧     │
      │ bridge-push   │       │       │ bridge-push    │
      │ bridge-pull   │       │       │ bridge-pull    │
      │ + execute     │       │       │ + execute      │
      │ (cron 5min)   │       │       │ (cron 5min)    │
      └───────────────┘       │       └───────────────┘
              │               │               │
              └───────────────┼───────────────┘
                              │
                        Feishu 通知
```

## 任务流转流程

### 推送任务（发起方）

```bash
bridge-push.sh \
  --title "任务标题" \
  --task-type status-summary \
  --instruction "任务指令" \
  --push
```

1. 创建任务 JSON 文件到 `tasks/inbox/`
2. Git 推送到远程仓库
3. 发送 Feishu 通知

### 领取任务（执行方）

```bash
bridge-pull.sh --execute
```

1. Git pull 拉取最新任务
2. 扫描 `tasks/inbox/` 中匹配的任务
3. 风险检查（executor_risk_check）
4. 领取任务（claim_task）
5. 移入 `tasks/running/`
6. 执行任务（bridge-execute.sh）
7. 更新状态，移入 `tasks/done/` 或 `tasks/failed/`
8. Git push 回传结果

### 任务状态流转

```
inbox → running → done
  ↑        │
  └────────┴→ failed (或重试回 inbox)
```

## 关键脚本

| 脚本 | 功能 | 使用方 |
|------|------|--------|
| `bridge-push.sh` | 推送任务到仓库 | 发起方 |
| `bridge-pull.sh` | 拉取并领取任务 | 执行方 |
| `bridge-execute.sh` | 执行具体任务 | 执行方 |
| `bridge-sync.sh` | 同步结果到 Obsidian | 发起方 |
| `bridge-status.sh` | 查询任务状态 | 两侧 |
| `bridge-lib.sh` | 共享函数库 | 两侧 |

## 定时任务配置

### 公司侧（已配置）

```bash
# 每 5 分钟拉取并执行
*/5 * * * * ~/ai-tasks/bridge/scripts/bridge-pull-cron.sh

# 每 10 分钟恢复过期任务
*/10 * * * * ~/ai-tasks/bridge/scripts/bridge-pull.sh --recover
```

### 家里侧（待配置）

```bash
# 每 5 分钟拉取并执行
*/5 * * * * ~/ai-tasks/bridge/scripts/bridge-pull.sh --execute >> ~/ai-tasks/bridge/logs/cron.log 2>&1

# 每 10 分钟恢复过期任务
*/10 * * * * ~/ai-tasks/bridge/scripts/bridge-pull.sh --recover >> ~/ai-tasks/bridge/logs/cron.log 2>&1
```

## 任务类型

| 类型 | 说明 | 自动执行 |
|------|------|----------|
| status-summary | 状态汇总 | ✅ |
| public-research | 公开信息研究 | ✅ |
| daily-report | 每日报告 | ✅ |
| obsidian-write | Obsidian 笔记 | ✅ |
| state-sync | 状态同步 | ✅ |

## 安全机制

### 风险检查

- **safe-auto**：自动执行
- **sandbox-auto**：隔离环境执行（Phase 2）
- **human-review**：人工审核（Phase 2）

### 任务约束

- 仅支持 home → company 或 company → home 双向流转
- 最大摘要 2000 字符
- Artifact 使用 opaque ID
- 不交换凭据、公司文档、原始日志

## 通知机制

| 事件 | 通知内容 |
|------|----------|
| 任务推送 | 任务 ID + 推送方 |
| 任务拒绝 | 任务 ID + 拒绝原因 |
| 需人工审核 | 任务 ID + 审核要求 |
| 任务完成 | 任务 ID + 结果摘要 |

## 目录结构

```
bridge/
├── bridge.env              # 环境配置
├── bridge.env.example      # 配置模板
├── schemas/
│   ├── task.schema.json    # 任务单 Schema
│   └── result.schema.json  # 结果 Schema
├── tasks/
│   ├── inbox/              # 待处理
│   ├── running/            # 执行中
│   ├── done/               # 已完成
│   └── failed/             # 失败
├── artifacts/summaries/    # 脱敏摘要
├ logs/                     # 每日日志
└── scripts/                # 核心脚本
```

## 故障排除

### Git 推送失败

```bash
ssh -T git@github.com
git -C "$BRIDGE_ROOT" remote -v
```

### 任务卡在 running

```bash
# 检查 lease 状态
cat tasks/running/*.json | jq '._claim.lease_expires_at'

# 恢复过期任务
./scripts/bridge-pull.sh --recover
```

### Schema 验证失败

```bash
# 验证任务单
jq -e '.task_id, .payload, .status' tasks/inbox/bridge-*.json
```

## 当前状态

- ✅ 公司侧 cron 已配置
- ⚠️ 家里侧 cron 待配置
- ✅ Feishu 通知已打通
- ✅ 双向任务流转已实现
