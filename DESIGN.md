# ClawKeep 技术方案

## Context

用户需要一个 macOS 桌面应用来守护 openclaw 进程。openclaw 是一个开源 AI agent，通过 npm 安装，gateway 进程监听 localhost:18789。该应用需要：进程存活监控（非轮询）、崩溃日志收集、调用 AI agent 自动修复、多渠道通知、高度可配置化、macOS 状态栏集成。

---

## 1. 整体架构

SwiftUI 前端 + Go 后端双进程架构，通过 gRPC over Unix Domain Socket 通信。

```
┌──────────────────────────────────────────────┐
│            ClawKeep.app Bundle           │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │      SwiftUI 前端 (ClawKeep)       │  │
│  │  • NSStatusItem 状态栏图标+菜单        │  │
│  │  • Settings Window 配置窗口            │  │
│  │  • Log Viewer 日志查看                 │  │
│  └──────────────┬─────────────────────────┘  │
│                 │ gRPC / UDS                  │
│                 │ $TMPDIR/claw-keep.sock  │
│  ┌──────────────┴─────────────────────────┐  │
│  │      keepd (Go daemon)             │  │
│  │  • ProcessMonitor (kqueue + TCP)       │  │
│  │  • LogCollector (fsnotify + ring buf)  │  │
│  │  • AgentDispatcher (CLI exec)          │  │
│  │  • Notifier (飞书/Bark/SMTP)           │  │
│  │  • ConfigManager (TOML hot-reload)     │  │
│  │  • Orchestrator 状态机编排             │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  Contents/MacOS/ClawKeep  (Swift binary) │
│  Contents/MacOS/keepd     (Go binary)    │
└──────────────────────────────────────────────┘
```

选择 gRPC over UDS 的理由：
- 强类型 protobuf，Swift/Go 都有成熟库
- UDS 比 TCP 更安全（文件权限控制），延迟更低
- 支持 server-streaming RPC，实时推送状态和日志到 UI
- UDS 路径使用 `$TMPDIR`（macOS 上是用户隔离的 `/var/folders/.../T/`），避免 `/tmp` 全局可写的安全隐患

SwiftUI 进程职责：启动/管理 keepd 子进程、渲染 UI、转发用户操作。
keepd 进程职责：所有核心逻辑，无 UI 依赖，可独立运行和测试。

### gRPC 重连机制

SwiftUI 客户端需要处理 keepd 崩溃或重启的情况：
- 检测到连接断开后，使用指数退避重连（初始 1s，最大 30s）
- 重连成功后自动重新订阅状态 stream
- 重连期间状态栏图标显示灰色（未监控），避免误导用户

---

## 2. 项目结构

```
claw-keep/
├── Makefile
├── config.example.toml
├── proto/keep/v1/
│   ├── keep.proto          # 主服务定义
│   ├── config.proto            # 配置消息
│   └── types.proto             # 共享类型
├── keepd/                  # Go daemon
│   ├── go.mod / go.sum
│   ├── cmd/keepd/main.go
│   └── internal/
│       ├── config/             # TOML 配置加载/校验/热更新
│       ├── monitor/            # kqueue + TCP 进程监控
│       ├── logcollector/       # 日志收集/解析/归档
│       ├── agent/              # agent 调度 (claude/codex/通用)
│       ├── notifier/           # 飞书/Bark/SMTP 通知
│       ├── orchestrator/       # 核心编排状态机
│       └── grpcserver/         # gRPC 服务实现
├── app/                        # SwiftUI macOS app
│   ├── ClawKeep.xcodeproj/
│   └── ClawKeep/
│       ├── ClawKeepApp.swift
│       ├── DaemonManager.swift # keepd 生命周期管理
│       ├── GRPCClient.swift
│       ├── Views/
│       │   ├── StatusBarView.swift
│       │   ├── SettingsView.swift
│       │   ├── MonitorSection.swift
│       │   ├── AgentSection.swift
│       │   ├── NotifySection.swift
│       │   └── LogView.swift
│       └── Models/
│           ├── AppState.swift
│           └── KeepStatus.swift
└── scripts/
    ├── build.sh
    ├── gen-proto.sh
    └── package.sh
```

---

## 3. 进程监控模块（核心，非轮询）

采用 kqueue + TCP 长连接双保险，完全事件驱动。

### 3.1 kqueue 监控（主机制）

利用 macOS kqueue 的 `EVFILT_PROC + NOTE_EXIT`，内核级事件通知，零 CPU 开销：

```
流程：
1. 查找目标进程 PID：
   a. 优先读取 PID 文件（配置项 pid_file，如 ~/.openclaw/gateway.pid）
   b. PID 文件不存在或无效时，fallback 到 sysctl KERN_PROC 按进程名查找
2. kqueue 注册 EVFILT_PROC + NOTE_EXIT + EV_ONESHOT
3. kevent() 阻塞等待 → 进程退出时内核立即唤醒
4. 发送 EventExit 事件，携带 PID 和退出码
5. 进入"等待进程重新出现"循环（短间隔查找 PID 文件 / sysctl）
6. 找到新 PID 后重新注册 kqueue
```

关键：kqueue 是内核级通知，不是轮询。进程退出的瞬间就能感知，延迟在微秒级。

支持 PID 文件的原因：如果 openclaw-gateway 是通过 node 或包装脚本启动的，sysctl 按进程名匹配可能不一致。PID 文件是更可靠的发现方式。

### 3.2 TCP 长连接探活（辅助机制）

覆盖 kqueue 无法检测的场景（如进程还在但服务已 hang/端口不响应）：

```
流程：
1. 建立到 host:port 的 TCP 连接
2. 连接成功后，用 kqueue EVFILT_READ 监听 socket fd
3. 对端关闭连接时 kevent 返回 EOF → 发送 EventPortDown
4. 切换到重连模式，端口恢复后发送 EventPortUp
```

也是事件驱动，不轮询。只在连接断开后的重连阶段有短暂的间隔等待。

### 3.3 可选：health command

配置项 `health_command`（如 `openclaw health`），仅在 TCP 连接成功但需要深度检查时按需调用，不定期轮询。

### 3.4 事件合并

Monitor 合并 kqueue 和 TCP 两个通道的事件，同一次崩溃去重（取先到的），向 Orchestrator 发送统一事件。

---

## 4. 日志收集模块

### 4.1 监控的日志路径（可配置）

- `/tmp/openclaw/openclaw-YYYY-MM-DD.log` — daily JSONL 日志
- `~/.openclaw/logs/gateway.log` — 持久日志
- `~/.openclaw/logs/gateway.err.log` — 错误日志

### 4.2 实现方式

- 使用 `fsnotify`（macOS 上底层也是 kqueue）监听文件变化，事件驱动
- 每个文件一个 Tailer goroutine，增量读取新内容
- 解析 JSONL 格式为结构化 LogEntry
- 内存中维护 RingBuffer（默认 200 行），崩溃时立即快照，不需要重新读文件
- 日期切换时自动跟踪新的 daily log 文件

### 4.3 崩溃归档

崩溃发生时：
1. RingBuffer 快照最近 N 行日志
2. 读取 gateway.err.log 尾部
3. 组装 CrashReport（退出码、时间、日志、stderr）
4. 序列化为 JSON 存入 `~/.claw-keep/crashes/crash-{timestamp}.json`
5. 定期清理超过 max_archive_days 的旧归档

---

## 5. Agent 调度模块

### 5.1 设计原则

- Agent 用用户自己安装的 CLI，不内置任何 agent
- 通过配置文件定义 agent 的 CLI 路径、参数、环境变量
- 支持多种 agent，可配置默认使用哪个
- 无头模式运行（非交互）

### 5.2 Agent 接口

```go
type Agent interface {
    Name() string
    Available() bool  // 检查 CLI 是否存在于配置路径
    Repair(ctx context.Context, req *RepairRequest) (*RepairResult, error)
}
```

### 5.3 内置适配器

| Agent | CLI 命令示例 | 说明 |
|-------|-------------|------|
| claude | `claude -p --model sonnet "{prompt}"` | Claude Code print mode |
| codex | `codex exec "{prompt}"` | OpenAI Codex 非交互模式 |
| generic | 用户自定义命令模板 | 通用适配器，支持任意 CLI |

### 5.4 Prompt 模板

使用 Go template，变量包括：
- `{{.ExitCode}}` — 退出码
- `{{.CrashTime}}` — 崩溃时间
- `{{.TailLogs}}` — 崩溃前日志
- `{{.StderrSnapshot}}` — stderr
- `{{.ErrLogTail}}` — gateway.err.log 尾部

用户可在配置文件中完全自定义 prompt 模板。

### 5.5 调度流程

```
崩溃检测 → 收集日志 → 渲染 prompt → 选择 agent → 执行修复
                                                    ↓
                                              成功 → 通知 + 重启 openclaw
                                              失败 → 通知 + 可选 fallback 到其他 agent
```

---

## 6. 通知模块

### 6.1 支持的通道

| 通道 | 实现方式 | 配置项 |
|------|---------|--------|
| 飞书 | Webhook POST（支持签名） | webhook_url, secret |
| Bark | HTTP GET/POST 到 Bark server | server_url, device_key |
| SMTP | 标准 SMTP 发送邮件 | host, port, user, pass, from, to, tls |

### 6.2 触发事件（可配置）

- `crash` — 进程崩溃
- `repair_start` — 开始修复
- `repair_success` — 修复成功
- `repair_fail` — 修复失败
- `restart` — 进程重启
- `agent_timeout` — agent 执行超时

用户在配置中选择哪些事件触发通知。

### 6.3 消息格式

飞书使用 Interactive Card 富文本格式，Bark 使用标题+正文，邮件使用 HTML 模板。包含：事件类型、时间、退出码、简要日志摘要、修复状态。

---

## 7. 配置系统

### 7.1 格式：TOML

路径：`~/.claw-keep/config.toml`，支持 fsnotify 热更新。

### 7.2 完整配置示例

```toml
[monitor]
process_name = "openclaw-gateway"
pid_file = "~/.openclaw/gateway.pid"  # 可选，优先通过 PID 文件发现进程
host = "127.0.0.1"
port = 18789
enable_kqueue = true
enable_tcp_probe = true
tcp_probe_timeout_ms = 3000
health_command = ""              # 可选，如 "openclaw health"
restart_cooldown_sec = 30
max_restart_attempts = 5

[log]
watch_paths = [
  "/tmp/openclaw/",
  "~/.openclaw/logs/"
]
crash_archive_dir = "~/.claw-keep/crashes/"
tail_lines_on_crash = 200
max_archive_days = 30

[agent]
default_agent = "claude"

[[agent.agents]]
name = "claude"
cli_path = "/usr/local/bin/claude"
cli_args = ["-p", "--model", "sonnet"]
working_dir = "~/.openclaw/"
timeout_sec = 300

[[agent.agents]]
name = "codex"
cli_path = "/usr/local/bin/codex"
cli_args = ["exec"]
working_dir = "~/.openclaw/"
timeout_sec = 300

[[agent.agents]]
name = "custom"
cli_path = "/usr/local/bin/my-agent"
cli_args = ["--fix"]
working_dir = "~/.openclaw/"
timeout_sec = 600
[agent.agents.env]
MY_API_KEY = "xxx"

[repair]
auto_repair = true
auto_restart = true
restart_command = "/usr/local/bin/openclaw"  # 建议使用绝对路径
restart_args = ["gateway"]
max_repair_attempts = 3
prompt_template = """
openclaw-gateway 进程崩溃了。
退出码: {{.ExitCode}}
崩溃时间: {{.CrashTime}}

错误日志:
```
{{.ErrLogTail}}
```

运行日志:
```
{{.TailLogs}}
```

请分析崩溃原因并修复。
"""

[notify]
notify_on = ["crash", "repair_success", "repair_fail"]

[notify.feishu]
enabled = true
webhook_url = "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"
secret = ""

[notify.bark]
enabled = true
server_url = "https://api.day.app"
device_key = "your-device-key"

[notify.smtp]
enabled = false
host = "smtp.example.com"
port = 465
username = "alert@example.com"
password = "xxx"
from = "alert@example.com"
to = ["dev@example.com"]
use_tls = true
```

---

## 8. Orchestrator 状态机

核心编排逻辑，管理从监控到修复的完整生命周期：

```
                    ┌──────────┐
          启动 ──→  │ Watching  │ ←─────────────────────────┐
                    └────┬─────┘                            │
                         │ 进程退出事件                      │
                    ┌────▼──────────┐                       │
                    │ Crash Detected│                       │
                    └────┬──────────┘                       │
                         │ 收集日志                          │
                    ┌────▼──────────┐                       │
                    │ Collecting    │                       │
                    └────┬──────────┘                       │
                         │ 日志收集完成                      │
              ┌──────────▼──────────┐                       │
              │ auto_repair=true?   │                       │
              └──┬──────────────┬───┘                       │
            yes  │              │ no                         │
        ┌────────▼───────┐  ┌──▼──────────┐                │
        │ Repairing      │  │ Notify Only │────────────────┤
        └──┬─────────┬───┘  └─────────────┘                │
           │         │ 超时                                  │
           │    ┌────▼──────────────┐                       │
           │    │ Agent Timeout     │──→ 通知 + fallback    │
           │    └───────────────────┘    到其他 agent 或     │
           │                             进入 Retry/Notify  │
           │ agent 完成                                      │
        ┌──▼───────┐                                        │
        │ 修复成功?  │                                        │
        └──┬────┬──┘                                        │
      yes  │    │ no                                        │
   ┌───────▼──┐ │                                           │
   │ Restart  │ │  ┌─────────────────┐                      │
   └───┬──────┘ └─▶│ Retry/Notify    │                      │
       │            └──┬──────────┬──┘                      │
       │          重试  │          │ 达到 max_repair_attempts │
       │          次数  │    ┌─────▼──────────┐              │
       │          未满  │    │ Exhausted      │              │
       │               │    │ (需人工介入)     │              │
       │               │    └─────┬──────────┘              │
       │               │          │ 发送紧急告警通知          │
       │               │          │ 状态栏显示红色警告        │
       │               ▼          │ 等待用户手动操作          │
       │          回到 Repairing  │                          │
       │                          │ 用户手动重置              │
       └──────────────────────────┴──────────────────────────┘
```

每个状态转换都会：
1. 更新 KeepStatus 并通过 gRPC stream 推送到 UI
2. 根据配置决定是否发送通知

### Exhausted 终态说明

当连续修复尝试达到 `max_repair_attempts` 上限后，进入 Exhausted 状态：
- 发送紧急告警通知（所有已启用通道）
- 状态栏图标切换为红色警告状态
- 不再自动重试，避免无限循环
- 用户可通过状态栏菜单"重置监控"手动恢复到 Watching 状态

---

## 9. keepd 自身日志

守护进程自身的可观测性同样重要：

- 日志路径：`~/.claw-keep/logs/keepd.log`
- 日志格式：结构化 JSON（时间、级别、模块、消息）
- 日志轮转：按天轮转，保留最近 7 天（可配置）
- 日志级别：通过配置项 `log_level` 控制（debug / info / warn / error），默认 info
- stdout/stderr：开发模式下同时输出到终端，嵌入 app bundle 运行时仅写文件

配置示例：

```toml
[daemon]
log_level = "info"
log_dir = "~/.claw-keep/logs/"
log_retain_days = 7
```

---

## 10. 状态栏 UI 设计

### 9.1 状态栏图标

| 状态 | 图标 | 颜色 |
|------|------|------|
| 正常运行 | 盾牌 ✓ | 绿色 |
| 进程崩溃 | 盾牌 ✗ | 红色 |
| 修复中 | 盾牌 ⟳ | 橙色 |
| 未监控 | 盾牌 — | 灰色 |

使用 SF Symbols（`shield.checkmark`, `shield.slash`, `shield.lefthalf.filled` 等）。

### 9.2 状态栏下拉菜单

```
┌─────────────────────────────┐
│ ● openclaw-gateway          │  ← 绿点=运行中，红点=挂了
│   PID: 59115 | 运行 2h 35m  │
│─────────────────────────────│
│ 崩溃次数: 0                  │
│ 上次崩溃: 无                 │
│─────────────────────────────│
│ ▶ 手动重启                   │
│ 🔧 触发修复                  │
│ 🔄 重置监控                  │  ← Exhausted 状态下可用，重置到 Watching
│─────────────────────────────│
│ 📋 查看日志...               │  ← 打开 LogView 窗口
│ ⚙ 设置...                   │  ← 打开 SettingsView 窗口
│─────────────────────────────│
│ 退出 ClawKeep          │
└─────────────────────────────┘
```

---

## 11. 配置窗口 UI 设计

SwiftUI Settings 窗口，TabView 分区：

### Tab 1: 监控

- 进程名（text field，默认 openclaw-gateway）
- 监听地址 + 端口
- kqueue 监控开关
- TCP 探活开关 + 超时
- Health command（可选）
- 重启冷却时间 + 最大重启次数

### Tab 2: Agent

- 默认 agent 下拉选择
- Agent 列表（可增删改）
  - 每个 agent：名称、CLI 路径（带文件选择器）、参数、工作目录、超时、环境变量
- 自动修复开关
- 自动重启开关
- Prompt 模板编辑器（TextEditor，支持模板变量提示）

### Tab 3: 通知

- 飞书：开关 + webhook URL + secret
- Bark：开关 + server URL + device key
- SMTP：开关 + 完整邮件配置
- 触发事件多选（crash / repair_start / repair_success / repair_fail / restart）
- 测试通知按钮（每个通道一个）

### Tab 4: 日志

- 监控路径列表（可增删）
- 崩溃归档目录
- 崩溃抓取行数
- 归档保留天数
- keepd 日志级别（debug / info / warn / error）
- keepd 日志保留天数

### Tab 5: 通用

- 开机自启开关（SMAppService）
- keepd 日志目录（只读展示）

---

## 12. 构建和打包

### 11.1 构建流程

```bash
# 1. 生成 protobuf 代码
scripts/gen-proto.sh
# → keepd/gen/keep/v1/*.go
# → app/ClawKeep/Gen/*.swift

# 2. 编译 Go daemon (universal binary)
cd keepd
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o keepd-arm64 ./cmd/keepd
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o keepd-amd64 ./cmd/keepd
lipo -create -output keepd keepd-arm64 keepd-amd64

# 3. 编译 SwiftUI app (Xcode)
xcodebuild -project app/ClawKeep.xcodeproj \
  -scheme ClawKeep -configuration Release

# 4. 嵌入 keepd 到 .app bundle
cp keepd ClawKeep.app/Contents/MacOS/

# 5. 签名
codesign --deep --force --sign - ClawKeep.app
```

### 11.2 预计体积

- keepd Go binary: ~10-15MB（静态链接）
- SwiftUI app: ~2-3MB
- 总计 .app bundle: ~15-20MB

---

## 13. 关键依赖

### Go (keepd)

| 依赖 | 用途 |
|------|------|
| google.golang.org/grpc | gRPC server |
| github.com/BurntSushi/toml | TOML 配置解析 |
| github.com/fsnotify/fsnotify | 文件变化监听（日志 + 配置热更新） |
| golang.org/x/sys | kqueue syscall |

### Swift (app)

| 依赖 | 用途 |
|------|------|
| grpc-swift-nio-transport | gRPC client |
| swift-protobuf | protobuf 序列化 |

---

## 15. 开机自启

作为守护应用，登录后自动启动是基本预期。

### 方案：SMAppService（macOS 13+）

使用 `ServiceManagement` 框架的 `SMAppService.mainApp` 注册为登录项：

```swift
import ServiceManagement

func enableAutoLaunch() throws {
    try SMAppService.mainApp.register()
}

func disableAutoLaunch() throws {
    try SMAppService.mainApp.unregister()
}
```

优点：
- 系统原生 API，无需手动管理 LaunchAgent plist
- 用户可在"系统设置 → 通用 → 登录项"中查看和管理
- 不需要额外权限

在配置窗口中提供"开机自启"开关，对应调用上述 API。

### 降级方案（macOS 12 及以下）

如需支持旧系统，fallback 到写入 `~/Library/LaunchAgents/com.clawkeep.app.plist`。

---

## 16. 验证方案

1. **单元测试**：每个 Go 模块独立测试（monitor/logcollector/agent/notifier）
2. **集成测试**：启动 keepd，模拟进程崩溃（kill 一个 sleep 进程），验证事件链
3. **端到端测试**：
   - 启动 app → 确认状态栏图标显示绿色
   - kill openclaw-gateway → 确认状态栏变红 + 收到通知
   - 验证日志收集和崩溃归档
   - 验证 agent 调度（用 echo 命令模拟 agent）
   - 修改配置 → 确认热更新生效
4. **通知测试**：配置窗口中每个通道的"测试通知"按钮
