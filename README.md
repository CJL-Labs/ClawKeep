<p align="center">
  <img src="assets/logo/clawkeep-logo.svg" width="160" alt="ClawKeep logo">
</p>

# ClawKeep

ClawKeep is a macOS menu bar companion for `openclaw-gateway`.
It keeps a local daemon alive, watches the gateway process, collects crash context, notifies you when something goes wrong, and can hand recovery work to coding agents such as Claude Code or Codex.

## What It Does

- Monitors `openclaw-gateway` on `127.0.0.1`
- Detects exits with a grace window for planned restarts or upgrades
- Collects crash context and relevant log paths
- Triggers automated repair attempts through Claude Code, Codex, or a custom CLI command
- Falls back across configured agents when one fails or times out
- Sends notifications for crash, repair start, repair success, repair failure, and agent timeout
- Exposes a native macOS settings UI and menu bar control surface
- Builds unsigned macOS app bundles with GitHub Actions and publishes GitHub Releases on tags
- Checks GitHub Releases for updates and can install newer unsigned builds automatically

## Feature Highlights

### Native macOS app

ClawKeep is a SwiftUI menu bar app with a bundled Go daemon (`keepd`).
The app provides:

- A live status view in the menu bar popup
- Quick actions to restart the gateway, pause detection for maintenance, trigger repair, reset monitoring, check updates, and install updates
- A full settings window for monitor, agent, notification, and log configuration

### Crash monitoring and repair orchestration

The bundled daemon:

- Watches the target process and TCP health
- Distinguishes between unexpected exits and planned maintenance windows
- Verifies service recovery after repair
- Tracks repair attempts and stops after the configured limit

### Agent-driven remediation

ClawKeep can auto-detect and prefer:

- Claude Code
- Codex

You can also configure a custom repair command and prompt template.
If one repair tool fails or times out, ClawKeep can continue with the next available option.

### Notifications

The daemon supports:

- Feishu
- Bark
- SMTP via config file

The current app UI exposes Feishu and Bark directly, while SMTP remains available through `config.toml`.

### Unsigned update flow

This project currently distributes unsigned macOS builds.
ClawKeep can:

- Check GitHub Releases manually
- Check once per day automatically
- Download the latest unsigned zip
- Replace the current app via an external helper and relaunch

For the smoothest unsigned auto-update flow, install the app somewhere writable such as `~/Applications/ClawKeep.app`.

## Architecture

```text
SwiftUI app
  -> menu bar UI
  -> settings UI
  -> local JSON IPC client
  -> update checker / installer trigger

keepd (Go daemon)
  -> process + TCP monitoring
  -> config watching
  -> notification dispatch
  -> repair orchestration
  -> Unix domain socket IPC server
```

The app and daemon communicate over local JSON IPC on a Unix domain socket.
There is no protobuf or gRPC step in the current packaging flow.

## Requirements

- macOS 15+
- Xcode / `xcodebuild`
- Go
- Optional: `xcodegen` if you want to regenerate the Xcode project locally

## Quick Start

Run the full local development flow:

```bash
./scripts/dev-run.sh
```

Build an unsigned debug app bundle:

```bash
./scripts/package-local.sh
```

Build an unsigned release bundle:

```bash
./scripts/package.sh
```

Outputs:

- App bundle: `build/Build/Products/<Configuration>/ClawKeep.app`
- Zip artifact: `dist/ClawKeep-macos-<Configuration>-unsigned.zip`

## Configuration

ClawKeep creates and maintains a local config file at:

```text
~/.claw-keep/config.toml
```

The config covers:

- Monitor target and health probe settings
- Log paths to collect during repair
- Preferred repair agent and fallback agents
- Custom prompt template
- Notification channels
- Daemon log directory, level, and retention

See [`config.example.toml`](config.example.toml) for the full shape.

## Updating

ClawKeep now includes an unsigned GitHub Release based update flow.

Behavior:

- The app can check for updates from the menu bar popup and settings window
- It also picks a daily check time automatically
- On tagged releases, GitHub Actions publishes both the app zip and `latest-macos.json`
- The app compares versions, downloads the latest zip, validates its SHA-256 when available, and relaunches after replacement

Caveats:

- This is not a signed / notarized distribution flow
- Auto-update works best when the app bundle lives in a user-writable directory
- GitHub Actions produces unsigned artifacts

## GitHub Actions Release Flow

On every push, pull request, and manual workflow run:

- Build the unsigned macOS app
- Upload the app bundle and zip as workflow artifacts

On Git tags:

- Create a GitHub Release
- Rename the zip to include the tag
- Generate `latest-macos.json`
- Upload both the zip and manifest to the release

Recommended release flow:

```bash
git push origin <branch>
git tag v0.1.0
git push origin v0.1.0
```

## Repository Layout

```text
app/       SwiftUI macOS app
keepd/     Go daemon and orchestration logic
scripts/   local build, packaging, dev-run, and release helper scripts
assets/    branding assets
.github/   GitHub Actions workflows
```

## Current Scope

ClawKeep is optimized for local, operator-friendly workflows around `openclaw-gateway`.
It is intentionally pragmatic:

- Native macOS only
- Local daemon only
- Unsigned build pipeline
- Agent-first remediation instead of a fixed repair playbook

---

## 中文版

ClawKeep 是一个面向 `openclaw-gateway` 的 macOS 菜单栏守护工具。
它由一个 SwiftUI 原生菜单栏 App 和一个内置的 Go 后台守护进程 `keepd` 组成，用来监控 Gateway、收集崩溃现场、发送通知，并调用 Claude Code / Codex / 自定义命令去自动修复。

### 主要功能

- 监控本机 `openclaw-gateway`
- 支持 TCP 健康检查和进程退出检测
- 提供维护窗口，避免手动重启或手动升级被误判为异常
- 发生异常时自动收集日志路径和崩溃上下文
- 调用 Claude Code、Codex 或自定义命令进行自动修复
- 修复工具超时或失败时可以 fallback 到其他工具
- 支持飞书、Bark，以及通过配置文件启用 SMTP 通知
- 菜单栏弹窗里可以直接执行重启、暂停检测、触发修复、检查更新等操作
- 设置页可配置监控参数、修复 Agent、通知方式和日志保留策略
- 支持基于 GitHub Release 的未签名自动更新

### 本地开发

直接启动开发流程：

```bash
./scripts/dev-run.sh
```

生成本地 Debug 包：

```bash
./scripts/package-local.sh
```

生成 Release 包：

```bash
./scripts/package.sh
```

产物位置：

- `build/Build/Products/<Configuration>/ClawKeep.app`
- `dist/ClawKeep-macos-<Configuration>-unsigned.zip`

### 配置文件

默认配置文件在：

```text
~/.claw-keep/config.toml
```

可以配置：

- Gateway 监听端口和检测超时
- 崩溃宽限期和最大修复次数
- 需要收集的日志路径
- 默认修复工具与自定义命令
- 修复提示词模板
- 飞书 / Bark / SMTP 通知
- ClawKeep 自身日志目录、级别和保留天数

参考示例见 [`config.example.toml`](config.example.toml)。

### 更新与发版

目前项目使用未签名的 GitHub Release 分发方式。

- App 支持手动检查更新
- App 会每天自动检查一次 GitHub Release
- 打 tag 时 GitHub Action 会发布 zip 和 `latest-macos.json`
- App 会下载新包、校验哈希，并通过外部 helper 替换旧版后自动重启

建议把 App 安装到可写目录，例如：

```text
~/Applications/ClawKeep.app
```

推荐发版流程：

```bash
git push origin <branch>
git tag v0.1.0
git push origin v0.1.0
```
