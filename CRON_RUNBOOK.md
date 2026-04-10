# Bridge cron / heartbeat runbook

## 概述

本系统通过 GitHub 仓库作为任务池，实现公司侧和家里侧双向任务流转。

- **任务池仓库**: `ai-tasks` (或其他配置的任务仓库)
- **任务状态目录**: `inbox/` (待处理) → `running/` (执行中) → `done/` (已完成)
- **心跳文件**: `.heartbeat/{role}.json`

---

## Cron 配置

### 公司侧 (Company)

```bash
# 任务拉取 (每5分钟)
*/5 * * * * BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company /home/user/ai-tasks/bridge/scripts/bridge-pull-cron.sh >> /home/user/ai-tasks/bridge/logs/company-pull.log 2>&1

# 心跳 (每10分钟)
*/10 * * * * BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company bash /home/user/ai-tasks/bridge/scripts/bridge-heartbeat.sh >> /home/user/ai-tasks/bridge/logs/company-heartbeat.log 2>&1
```

### 家里侧 (Home)

```bash
# 任务拉取 (每5分钟)
*/5 * * * * BRIDGE_DIR=/Users/user/openclaw/ai-tasks/bridge BRIDGE_ROLE=home /Users/user/openclaw/ai-tasks/bridge/scripts/bridge-pull-cron.sh >> /Users/user/openclaw/ai-tasks/bridge/logs/home-pull.log 2>&1

# 心跳 (每10分钟)
*/10 * * * * BRIDGE_DIR=/Users/user/openclaw/ai-tasks/bridge BRIDGE_ROLE=home bash /Users/user/openclaw/ai-tasks/bridge/scripts/bridge-heartbeat.sh >> /Users/user/openclaw/ai-tasks/bridge/logs/home-heartbeat.log 2>&1
```

---

## 心跳机制

### 心跳文件位置

```
.heartbeat/
├── company.json    # 公司侧心跳
└── home.json       # 家里侧心跳
```

### 心跳内容示例

```json
{
  "role": "company",
  "last_heartbeat": "2026-04-10T14:30:00+08:00",
  "uptime_seconds": 86400,
  "cron_status": "healthy"
}
```

### 查看心跳状态

```bash
# 查看两边心跳
cd /home/user/ai-tasks/bridge
git pull --rebase
cat .heartbeat/company.json
cat .heartbeat/home.json
```

### 心跳更新时间

- 频率: 每 10 分钟一次
- 更新内容: 时间戳、运行状态
- 推送: 每次心跳都会 git commit + push

---

## 锁机制

### 锁文件位置

- 目录锁 (当前实现): `.bridge-pull.lockdir/`
- 旧版文件锁 (已废弃): `.bridge-pull.lock` (忽略即可)

### 锁作用

防止多个 cron 实例同时拉取任务导致冲突。

### 故障时清理锁

如果 cron 卡住，可以手动清理：

```bash
rm -rf /home/user/ai-tasks/bridge/.bridge-pull.lockdir
```

---

## 日志位置

| 侧别 | 日志文件 |
|------|----------|
| 公司 | `/home/user/ai-tasks/bridge/logs/company-pull.log` |
| 公司 | `/home/user/ai-tasks/bridge/logs/company-heartbeat.log` |
| 家里 | `/Users/user/openclaw/ai-tasks/bridge/logs/home-pull.log` |
| 家里 | `/Users/user/openclaw/ai-tasks/bridge/logs/home-heartbeat.log` |

---

## 故障排查

### 问题: cron 一直跳过不执行

**症状**: 任务没有被拉取，日志显示 "Skipping - lock exists"

**排查步骤**:

1. 检查锁文件是否存在
   ```bash
   ls -la /home/user/ai-tasks/bridge/.bridge-pull.lockdir
   ```

2. 如果锁存在但没有进程在运行，手动删除
   ```bash
   rm -rf /home/user/ai-tasks/bridge/.bridge-pull.lockdir
   ```

3. 手动运行一次测试
   ```bash
   BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company /home/user/ai-tasks/bridge/scripts/bridge-pull-cron.sh
   ```

### 问题: 家里侧 cron 不运行

**排查步骤**:

1. 确认 cron 服务是否启用
   ```bash
   crontab -l
   ```

2. 检查 Mac 上 flock 是否可用 (Mac 默认没有 flock)
   - 当前实现使用目录锁，不依赖 flock
   - 如果是旧版脚本需要更新

3. 检查日志
   ```bash
   tail -f /Users/user/openclaw/ai-tasks/bridge/logs/home-pull.log
   ```

### 问题: 心跳显示离线

**排查步骤**:

1. 手动运行心跳脚本
   ```bash
   BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company bash /home/user/ai-tasks/bridge/scripts/bridge-heartbeat.sh
   ```

2. 检查网络连接
   ```bash
   git -C /home/user/ai-tasks/bridge remote -v
   ```

3. 检查 git 认证是否有效
   ```bash
   git -C /home/user/ai-tasks/bridge push --dry-run
   ```

---

## 常用命令

```bash
# 手动触发任务拉取 (公司侧)
BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company /home/user/ai-tasks/bridge/scripts/bridge-pull-cron.sh

# 手动触发心跳 (公司侧)
BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company bash /home/user/ai-tasks/bridge/scripts/bridge-heartbeat.sh

# 查看任务队列状态
cd /home/user/ai-tasks/bridge
ls -la inbox/
ls -la running/
ls -la done/

# 查看最近提交
git log --oneline -10
```

---

## 相关文件

- `scripts/bridge-pull-cron.sh` - cron 包装脚本
- `scripts/bridge-pull.sh` - 任务拉取主脚本
- `scripts/bridge-heartbeat.sh` - 心跳更新脚本
- `scripts/bridge-lib.sh` - 共享工具函数
- `CRON_RUNBOOK.md` - 本文档
