# Codex Windows Fast Patch Skill

语言：中文 | [English](README.en.md)

这是 `codex-windows-fast-patch` skill 的公开版本，用于指导智能体在 Windows 上恢复 Codex Desktop 升级后失效的本地补丁和能力开关。

## 主要功能

- 在 Codex Desktop 升级后重新应用 Windows MSIX 补丁。
- 修复 Fast Mode 无法使用，并在修复后验证请求是否真的带上 `service_tier=priority`。
- 注册和修复本地插件市场配置。
- 修复本地插件市场清单目录结构。
- 刷新 Windows Computer Use 兼容文件。
- 解除 Computer Control 页面里 `Any App` / `任意应用` 被组织或地区门控禁用的问题。
- 修复 Codex 移动版 / 连接页远程控制设置在未授权时跳转、报错或卡住退不出的问题。
- 在覆盖 `config.toml` 前自动生成一次时间戳备份，降低配置误写风险。
- 提供类似 ccswitch 的本机 Codex 状态备份管理：可备份、列出和恢复 `config.toml`、MCP 配置、skills 与 marketplaces。
- 每次正式使用前自动尝试从 GitHub 同步最新版，让本地 skill 尽量保持具备处理新问题的最新工作流；网络不可用时不会强制中断。

## 平台支持

当前只支持 Windows。

这个 skill 依赖 Windows Store / MSIX 包结构、PowerShell、`Get-AppxPackage`、`makeappx.exe`、`signtool.exe`、Windows 用户环境变量，以及 Windows Computer Use helper 路径。

不要在 macOS 上直接运行。macOS 需要单独的实现流程，例如处理 Codex `.app` 包、ASAR 解包和重打包、`codesign` 或 quarantine、shell 脚本，以及 macOS 自己的 Computer Use 可用性门控。

## 文件说明

- `SKILL.md`：Agent skill 主说明。
- `agents/openai.yaml`：agent 配置。
- `scripts/repatch-codex-windows.ps1`：工作流参考脚本。
- `scripts/patch_codex_fast_mode_windows_msix.ps1`：MSIX / ASAR 补丁参考实现。
- `scripts/install-computer-use-local.ps1`：Windows Computer Use 本地兼容文件安装和校验参考实现。
- `scripts/manage-codex-backups.ps1`：本机 Codex 配置、MCP、skills 和 marketplaces 的备份管理脚本。
- `scripts/update-skill-from-github.ps1`：使用前尽力同步 GitHub 最新版的自更新脚本。
- `references/restriction-debug-cases.md`：限制解除、Computer Use、移动入口和 CPA Fast Mode 的按需诊断案例。

## 安装

先克隆仓库，然后在仓库根目录打开 PowerShell，只复制 skill 需要的文件：

```powershell
$source = (Get-Location).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
  throw '请在 codex-windows-fast-patch-skill 仓库根目录运行此命令。'
}

$dest = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Copy-Item -Force -LiteralPath (Join-Path $source 'SKILL.md') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'agents') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'scripts') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'references') -Destination $dest
```

安装到 Codex 后，重启 Codex，让它重新加载 skill 元数据。

## 使用

安装后，让支持 Agent Skills 的智能体使用 `codex-windows-fast-patch` 工作流处理当前机器上的 Codex Desktop 问题。

这个 skill 支持自更新：智能体每次正式使用前都会先尝试从 GitHub 检查并同步最新版，不需要你反复回到 GitHub 手动拉取更新。这样本地 skill 可以尽量跟上最新出现的问题和对应工作流；如果网络不可用、GitHub 访问失败或下载失败，更新步骤会被跳过，智能体应继续使用当前本地版本处理问题。

这些脚本是参考实现和操作模板，不是跨所有机器都能直接运行的一键方案。实际处理时应先读取 `SKILL.md`，检查当前机器的 Codex 安装方式、MSIX 包路径、ASAR 内容、签名工具、插件目录和 Computer Use 文件状态，再决定执行、改写或只借鉴其中的步骤。

一个典型请求是：`使用 codex-windows-fast-patch 这个 skill，检查并修复这台 Windows 机器上的 Codex Desktop Fast Mode、插件市场和 Computer Use 可用性问题。`

## 备份管理

修复脚本在写入 `config.toml` 前会自动把旧文件备份到 `.codex\backups\config\`。如果要手动备份或迁移本机 Codex 的关键状态，可以使用独立备份脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

列出现有备份：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action List
```

从某个备份恢复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Restore -BackupPath "<backup path>"
```

默认备份自定义 skills、marketplaces、`config.toml`、解析出的 `mcp_servers.json` 和 `chrome-native-hosts.json`，并排除 `.git`、`node_modules`、构建产物和虚拟环境等容易变大的目录。需要完整离线依赖副本时再加 `-IncludeDependencyDirs`；插件缓存和 `.tmp\bundled-marketplaces` 也可能较大，需要时再加 `-IncludePluginCache` 或 `-IncludeTmpBundledMarketplaces`。

## CPA 上游配置

如果 Codex 请求的上游是 CPA，仅在本地把请求改成 `service_tier=priority` 还不够。还需要在 CPA 的覆盖规则中，对承接 Codex 的模型强制覆盖参数：`service_tier`、类型为字符串、值为 `priority`，这样上游才会真正按 Fast / Priority 路径处理。

图中的模型名只是示例，实际应按 CPA 中当前承接 Codex 的模型填写。

![CPA 覆盖规则示例](assets/cpa-override-rule.svg)

## 致谢

感谢 [LinuxDo community](https://linux.do/) 中相关讨论和反馈对这个工作流的启发。
