# OpenClaw 桥接层 - 快速部署指南

## 部署概览

```
家里 OpenClaw  (push)     公司 OpenClaw  (pull+execute)
      │                          │
      ↓                          ↑
bridge-push.sh              bridge-pull.sh
      │                          │
      └──────── Git Repo ────────┘
                      │
                      ↓
               bridge-sync.sh
                      │
                      ↓
            家里 OpenClaw 汇总结果
```

## Step 1: 配置 (公司侧)

```bash
cd ~/ai-tasks/bridge
cp bridge.env.example bridge.env
# 编辑 bridge.env:
#   - BRIDGE_GIT_REMOTE: GitHub 仓库地址
#   - BRIDGE_SSH_KEY: 部署密钥路径
#   - COMPANY_OBSIDIAN_DIR: 公司 Obsidian 路径
#   - FEISHU_WEBHOOK_URL: 飞书机器人 Webhook
```

## Step 2: 配置 Git 仓库

```bash
# 在 GitHub/GitLab 创建仓库后:
git remote add origin git@github.com:your-org/openclaw-bridge.git
git push -u origin main
```

## Step 3: 配置定时任务 (公司侧)

```bash
# 每 5 分钟拉取一次
*/5 * * * * ~/ai-tasks/bridge/scripts/bridge-pull.sh --execute >> ~/ai-tasks/bridge/logs/cron.log 2>&1

# 每 10 分钟恢复过期任务
*/10 * * * * ~/ai-tasks/bridge/scripts/bridge-pull.sh --recover >> ~/ai-tasks/bridge/logs/cron.log 2>&1
```

## Step 4: 家里侧 - 推送第一个任务

```bash
cd ~/ai-tasks/bridge
./scripts/bridge-push.sh \
  --title "生成今日 GitHub Trending 分析" \
  --task-type public-research \
  --instruction "抓取 GitHub Trending，分析 Top 10 项目" \
  --allowed-actions "fetch_public,summarize" \
  --priority high \
  --push
```

## Step 5: 查看结果

```bash
# 查询状态
./scripts/bridge-status.sh

# 同步结果到 Obsidian
./scripts/bridge-sync.sh --to-obsidian
```

## 文件位置

| 文件 | 说明 |
|------|------|
| `scripts/bridge-push.sh` | 家里侧：推送任务 |
| `scripts/bridge-pull.sh` | 公司侧：拉取 + 执行 |
| `scripts/bridge-execute.sh` | 公司侧：执行任务 |
| `scripts/bridge-sync.sh` | 家里侧：同步结果 |
| `scripts/bridge-status.sh` | 查询任务状态 |
| `scripts/bridge-lib.sh` | 共享函数库 |
| `schemas/task.schema.json` | 任务单 Schema |
| `schemas/result.schema.json` | 结果回传 Schema |
| `bridge.env.example` | 配置模板 |

## 故障排除

### Git 推送失败
```bash
# 检查 SSH 访问
ssh -T git@github.com
# 检查远程
git remote -v
```

### 任务卡在 running
```bash
# 查看 lease 状态
./scripts/bridge-status.sh --id bridge-2026-03-23-001
# 恢复过期任务
./scripts/bridge-pull.sh --recover
```

### Schema 验证失败
```bash
# 验证任务单
jq -e '.task_id, .payload, .status' tasks/inbox/bridge-*.json
```

## 测试命令

```bash
# 1. 创建测试任务
./scripts/bridge-push.sh \
  --title "测试：状态汇总" \
  --task-type status-summary \
  --instruction "汇总今日任务状态"

# 2. 公司侧领取并执行
./scripts/bridge-pull.sh --execute

# 3. 查看结果
./scripts/bridge-status.sh

# 4. 同步到 Obsidian
./scripts/bridge-sync.sh --to-obsidian
```
