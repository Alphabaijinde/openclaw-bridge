# Bridge cron / heartbeat runbook

## 概述

本系统通过 GitHub 仓库作为任务池，实现公司侧和家里侧双向任务流转。

- **任务池仓库**: `ai-tasks` (或其他配置的任务仓库)
- **任务状态目录**: `inbox/` (待处理) → `running/` (执行中) → `done/` (已完成)
- **心跳文件**: `.heartbeat/{role}.json`

---

## Cron 配置

### 公司侧 (Linux)

```bash
# 任务拉取 + 心跳 (每5分钟一次，heartbeat 已内置)
*/5 * * * * BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company /home/user/ai-tasks/bridge/scripts/bridge-pull-cron.sh >> /home/user/ai-tasks/bridge/logs/company-pull.log 2>&1
```

### 家里侧 (Mac)

**前置依赖**:
```bash
# 安装 jq (如果没有)
brew install jq

# 确认 gh 已登录 (用于 git credential)
gh auth status
```

**配置 cron**:
```bash
# 方法 1: 使用 bridge-setup-cron.sh 自动配置
BRIDGE_ROLE=home BRIDGE_DIR=/Users/user/openclaw/ai-tasks/bridge /Users/user/openclaw/ai-tasks/bridge/scripts/bridge-setup-cron.sh

# 方法 2: 手动添加 cron
crontab -e
# 添加以下行:
*/5 * * * * BRIDGE_DIR=/Users/user/openclaw/ai-tasks/bridge BRIDGE_ROLE=home /Users/user/openclaw/ai-tasks/bridge/scripts/bridge-pull-cron.sh >> /Users/user/openclaw/ai-tasks/bridge/logs/home-pull.log 2>&1
```

**注意**: Mac 上 cron 默认没有 PATH，需要在脚本中指定完整路径或设置环境变量。

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
  "last_heartbeat": "2026-04-14T06:40:37Z",
  "hostname": "user",
  "status": "alive"
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

- 频率: 每 5 分钟 (随 bridge-pull-cron.sh 一起执行)
- 更新内容: 时间戳、主机名、状态
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

### 问题: 心跳没有推送到远程

**症状**: 本地心跳文件更新了，但没有推送到 GitHub

**排查步骤**:

1. 检查 git remote 配置
   ```bash
   git remote -v
   ```

2. 检查 gh 认证状态 (公司侧 Linux)
   ```bash
   gh auth status
   ```
   - 如果显示 SSH，需要确认 remote 是 SSH URL
   - 如果显示 HTTPS，需要确认 credential helper 正常

3. 测试手动推送
   ```bash
   BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company bash /home/user/ai-tasks/bridge/scripts/bridge-heartbeat.sh
   git push
   ```

### 问题: 家里侧 Mac cron 不运行

**排查步骤**:

1. 确认 cron 服务是否启用
   ```bash
   crontab -l
   ```

2. 检查 Mac 上 cron 是否有权限
   ```bash
   # Mac 需要在 System Settings > Privacy & Security > Full Disk Access 添加 cron
   ```

3. 检查脚本是否有执行权限
   ```bash
   chmod +x /Users/user/openclaw/ai-tasks/bridge/scripts/bridge-pull-cron.sh
   ```

4. 检查日志
   ```bash
   tail -f /Users/user/openclaw/ai-tasks/bridge/logs/home-pull.log
   ```

---

## 常用命令

```bash
# 手动触发任务拉取 (公司侧)
BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company /home/user/ai-tasks/bridge/scripts/bridge-pull-cron.sh

# 手动触发心跳 (公司侧)
BRIDGE_DIR=/home/user/ai-tasks/bridge BRIDGE_ROLE=company bash /home/user/ai-tasks/bridge/scripts/bridge-heartbeat.sh

# 手动触发任务拉取 (家里侧 Mac)
BRIDGE_DIR=/Users/user/openclaw/ai-tasks/bridge BRIDGE_ROLE=home /Users/user/openclaw/ai-tasks/bridge/scripts/bridge-pull-cron.sh

# 查看任务队列状态
cd /home/user/ai-tasks/bridge
ls -la inbox/
ls -la running/
ls -la done/

# 查看最近提交
git log --oneline -10

# 查看心跳状态
BRIDGE_ROLE=company bash scripts/bridge-status.sh
BRIDGE_ROLE=home bash scripts/bridge-status.sh
```

---

## 当前状态 (2026-04-14)

### 公司侧 (Linux - 当前配置)

**当前 crontab 配置**:
```bash
*/5 * * * * /home/user/ai-tasks/bridge/scripts/bridge-pull-cron.sh
```

**角色识别方式**: 通过 `bridge.env` 文件中的 `BRIDGE_ROLE=company` 配置识别，不需要在 crontab 中设置环境变量。

**bridge.env 配置内容**:
```bash
BRIDGE_ROLE=company
OPENCLAW_SIDE=company
BRIDGE_GIT_REMOTE=git@github.com:Alphabaijinde/openclaw-bridge.git
```

### 家里侧 (Mac - 待配置)

| 侧别 | 最后心跳 | 状态 |
|------|----------|------|
| 公司 | 2026-04-14 06:40 | ✅ 在线 |
| 家里 | 2026-04-12 01:40 | ⚠️ 离线 (待配置) |

### 待确认事项

- [ ] 家里侧 Mac 的 cron 是否已配置？
- [ ] 家里侧 Mac 上 gh 是否已登录？
- [ ] 家里侧 Mac 上的 bridge 仓库路径是什么？

---

## GitHub Trending 分析缺失问题

### 问题描述

最近几天 (4月11-14日) 的 GitHub Trending 分析为空，只有项目列表，没有深度分析。

### 根因分析

从 `fetch.log` 日志分析：
```
[2026-04-14 09:00:10] 尝试使用模型: opencode/big-pickle
```
模型启动后卡住，没有后续日志 (如 "已生成 AI 详细分析" 或 "超时/重试")。

**可能原因**:
1. `opencode/big-pickle` 模型在 cron 环境下启动慢/卡住
2. 脚本逻辑问题 - 第一个模型失败后没有继续尝试备选模型
3. 90秒 timeout 不够

### 缺失的数据

| 日期 | 状态 |
|------|------|
| 4月11日 | 缺失 (没有抓取) |
| 4月12日 | ❌ 有列表无分析 |
| 4月13日 | ❌ 有列表无分析 |
| 4月14日 | ❌ 有列表无分析 |

### 修复建议

1. 手动运行 fetch.sh 补全分析:
   ```bash
   cd /home/user/ai-tools/github-trending
   rm -f work_jszr_linux/AI趋势/2026-04-*-GitHub-Trending.md  # 清除旧文件
   ./scripts/fetch.sh --analyze
   ```

2. 检查脚本中模型顺序是否正确遍历

3. 考虑增加 timeout 或改用更快的模型

---

## 相关文件

- `scripts/bridge-pull-cron.sh` - cron 包装脚本
- `scripts/bridge-pull.sh` - 任务拉取主脚本
- `scripts/bridge-heartbeat.sh` - 心跳更新脚本
- `scripts/bridge-lib.sh` - 共享工具函数
- `scripts/bridge-setup-cron.sh` - 自动配置 cron 脚本
- `CRON_RUNBOOK.md` - 本文档
