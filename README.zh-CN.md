# ClawKeep 中文文档

[![English README](https://img.shields.io/badge/README-English-111111?style=for-the-badge)](./README.md)

ClawKeep 是一个面向 `openclaw-gateway` 的 macOS 菜单栏工具。
它由一个 SwiftUI 原生 App 和一个内置的 Go 守护进程 `keepd` 组成，用来监控 Gateway、处理异常、发送提醒，并把修复工作交给 Claude Code、Codex 或自定义命令。

## 给用户使用

### 你能用它做什么

- 在菜单栏里查看 `openclaw-gateway` 当前状态
- 快速执行重启、暂停检测、触发修复、重置监控、检查更新
- 在设置窗口里配置监控、修复 Agent、通知和日志
- 接收飞书和 Bark 通知
- 每天自动检查一次 GitHub Release 更新

### 下载与安装

最新版下载地址：

- [Latest Release](https://github.com/CJL-Labs/ClawKeep/releases/latest)

下载 zip 之后，建议这样安装：

1. 先解压 zip。
2. 先在解压出来的目录里点击打开一次 `ClawKeep.app`。
3. 因为当前是未签名应用，如果 macOS 阻止打开，请到 `系统设置 -> 隐私与安全性` 里选择允许打开。
4. 确认能打开之后，再把 `ClawKeep.app` 拖到 `Applications` 或 `~/Applications`。

对这个项目来说，更推荐安装到 `~/Applications/ClawKeep.app`，因为未签名自动更新在用户可写目录里更稳定。

### 怎么使用

1. 打开 ClawKeep。第一次启动会自动弹出设置窗口，同时它也会常驻菜单栏。
2. 在 `监控` 页确认本地 `openclaw-gateway` 的端口和超时设置。
3. 在 `修复 Agent` 页选择 Claude Code、Codex，或者你自己的自定义命令。
4. 在 `通知` 页粘贴飞书机器人 Webhook 或 Bark 推送地址，并先发一条测试消息。
5. 在 `日志` 页填写崩溃时要附带的日志文件路径或 glob。
6. 平时主要从菜单栏弹窗操作，比如重启 Gateway、暂停 5 分钟检测、手动触发修复、手动检查更新。

### 工作原理

- ClawKeep 会同时监控进程状态和本地 TCP 端口。
- 如果发现异常退出，会收集上下文并调用你配置的修复工具。
- 如果一个 Agent 失败或超时，它可以继续尝试下一个可用 Agent。
- 如果你是在手动重启或升级，先用“暂停异常检测”，这样不会被当成崩溃。
- 应用每天会自动检查一次更新，你也可以手动检查。

### 当前支持的用户功能

- 监控 `openclaw-gateway`
- 探测 `127.0.0.1:<port>` 的可用性
- 手动重启或升级时提供宽限期
- 可以从界面里暂停 5 分钟异常检测
- 修复次数耗尽后可以手动重置监控状态
- 自动识别本机是否安装了 `claude` 和 `codex`
- 可设置优先修复工具
- 可配置自定义修复命令、参数和工作目录
- 可编辑修复提示词模板
- 某个 Agent 失败或超时后，可以继续尝试其他可用 Agent
- 修复结束后会做恢复确认
- 飞书机器人 Webhook
- Bark 推送 URL
- 可配置的提醒事件：
  - `crash`
  - `repair_start`
  - `repair_success`
  - `repair_fail`
  - `agent_timeout`
- 状态栏弹窗支持手动检查更新
- 设置页支持手动检查更新
- 每天自动检查一次更新
- 从 GitHub Releases 下载未签名 zip
- 通过外部 helper 替换当前 app 并自动重启

## 给开发者

### 架构

当前包里包含两个部分：

- `ClawKeep`：SwiftUI 菜单栏 App，负责 UI、设置页、更新入口
- `keepd`：Go daemon，负责监控、修复编排、配置、通知、IPC

两者通过本地 Unix domain socket 上的 JSON IPC 通信。

```text
app/       SwiftUI macOS App
keepd/     Go daemon
scripts/   构建、打包、dev-run、更新 helper 脚本
assets/    品牌素材
.github/   GitHub Actions workflow
```

### 环境要求

- macOS 15+
- Go
- Xcode / `xcodebuild`
- 如果需要重新生成 Xcode 工程，可安装 `xcodegen`

### 本地开发

启动完整开发流程：

```bash
./scripts/dev-run.sh
```

生成未签名 Debug 包：

```bash
./scripts/package-local.sh
```

生成未签名 Release 包：

```bash
./scripts/package.sh
```

产物位置：

- `build/Build/Products/<Configuration>/ClawKeep.app`
- `dist/ClawKeep-macos-<Configuration>-unsigned.zip`

### 配置文件

默认配置文件位置：

```text
~/.claw-keep/config.toml
```

当前可配置内容包括：

- Gateway 主机、端口、PID 文件、探测超时、退出宽限期
- 最大修复尝试次数
- 崩溃时要带上的日志路径
- 默认修复 Agent 和自定义命令
- 修复提示词模板
- 飞书和 Bark 通知
- ClawKeep 自身日志目录、级别、保留天数

参考示例见 [`config.example.toml`](./config.example.toml)。

### GitHub Actions 发版

当前仓库自带未签名构建流程。

普通 `push`、`pull_request`、手动触发时：

- 构建 macOS App
- 打包未签名 zip
- 上传 workflow artifact

打 tag 时：

- 创建 GitHub Release
- 上传带 tag 的 zip
- 生成并上传 `latest-macos.json`

推荐发版流程：

```bash
git push origin <branch>
git tag v0.1.0
git push origin v0.1.0
```

### 当前定位

ClawKeep 是一个面向 `openclaw-gateway` 的本地运维型工具。

- 仅支持 macOS
- 以本地 daemon 为中心
- 当前走未签名分发
- 优先通过 Agent 做自动修复
