# OpenClaw 桥接层

公司与个人 OpenClaw 之间的任务流转中枢。

## 核心理念

- **任务池**：GitHub 仓库作为任务池（inbox/running/done）
- **双向流转**：公司 ↔ 家里 双向任务流转
- **异步执行**：两边不需要同时在线，任务提交后由执行方拉取并执行

## 架构

```
                    ┌─────────────────┐
                    │  GitHub 仓库    │
                    │  (任务池)       │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              │              ▼
      ┌───────────────┐       │       ┌───────────────┐
      │   公司侧      │       │       │    家里侧     │
      │ bridge-push   │       │       │ bridge-push    │
      │ bridge-pull   │       │       │ bridge-pull    │
      │ + 执行任务    │       │       │ + 执行任务     │
      └───────────────┘       │       └───────────────┘
              │               │               │
              └───────────────┼───────────────┘
                              │
                        Feishu 通知
```

## 任务流转

```
发起方: bridge-push.sh --push
        → 创建任务 JSON → Git Push → 仓库

执行方: bridge-pull.sh --execute (cron 轮询)
        → Git Pull → 领取任务 → 执行 → 写结果 → Git Push

状态流转: inbox → running → done (或 failed)
```

## 双向任务流

| 方向 | 发起方 | 执行方 | 场景 |
|------|--------|--------|------|
| 公司 → 家里 | 公司 push | 家里 pull+execute | 公司无法访问的资源 |
| 家里 → 公司 | 家里 push | 公司 pull+execute | 公司侧执行的任务 |

## 目录结构

```
bridge/
├── README.md
├── bridge.env.example          # 配置模板（复制为 bridge.env）
├── schemas/
│   ├── task.schema.json        # 任务单 Schema
│   └── result.schema.json      # 结果回传 Schema
├── tasks/
│   ├── inbox/                  # 待处理（家里 → 公司）
│   ├── running/                # 执行中
│   ├── done/                   # 完成任务
│   └── failed/                 # 失败任务
├── artifacts/
│   └── summaries/              # 脱敏摘要（Phase 1 上限 2000 字）
├── logs/
│   └── bridge-YYYY-MM-DD.log   # 每日日志
└── scripts/
    ├── bridge-push.sh          # 推送任务（家里侧）
    ├── bridge-pull.sh          # 拉取任务（公司侧）
    ├── bridge-execute.sh       # 执行任务（公司侧）
    ├── bridge-sync.sh          # 同步结果（家里侧）
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
./scripts/bridge-push.sh \
  --title "生成今日 GitHub Trending 分析" \
  --task-type public-research \
  --instruction "抓取 GitHub Trending，生成深度分析报告" \
  --allowed-actions "fetch_public,summarize"
```

### 3. 公司侧：拉取并执行

```bash
# 定时轮询（建议每 5 分钟）
*/5 * * * * ~/ai-tasks/bridge/scripts/bridge-pull.sh

# 手动执行
./scripts/bridge-pull.sh --execute
```

### 4. 家里侧：同步结果

```bash
./scripts/bridge-sync.sh
```

## 任务通道

| 通道 | 说明 | 自动执行 |
|------|------|----------|
| safe-auto | 只读、低敏、可重试任务 | ✅ |
| sandbox-auto | 隔离环境内执行 | ❌ Phase 1 |
| human-review | 必须人工审核 | ❌ |

## Phase 1 约束

- 仅支持 home → company 单向任务流
- 仅允许 `safe-auto` 通道
- 仅允许白名单内的 `task_type`
- 最大摘要 2000 字符
- Artifact 使用 opaque ID，不返回 URL
- 公司侧有权重新分类任务风险

## 安全原则

1. 不交换凭据 / OAuth / SSH Key
2. 不交换公司文档全文
3. 不交换原始日志
4. 桥接层仅视为低敏任务中转层
5. 公司侧拥有最终风险分类权

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
# 手动清理（公司侧）
./scripts/bridge-pull.sh --recover
```

### Schema 验证失败
```bash
# 验证任务单
jq -e '.task_id, .payload, .status' tasks/inbox/bridge-*.json
# 使用 ajv 严格验证
ajv validate -s schemas/task.schema.json -d tasks/inbox/bridge-*.json
```
