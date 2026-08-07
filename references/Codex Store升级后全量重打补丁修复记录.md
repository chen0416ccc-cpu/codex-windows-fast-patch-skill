# Codex Desktop Store 升级后全量补丁修复记录

> 最后复核：2026-08-07 20:19（Asia/Shanghai）
>
> 当前结论：Store 将 Codex Desktop 升级到 `26.803.5235.0`，并把包签名覆盖为 `SignatureKind=Store`。本轮已完成状态快照、技能自更新检查、本地 Computer Use 修复、全量 DryRun、外部 PowerShell 全量 MSIX 重打、签名、安装、重启和终态复验。当前包为 `Developer / Ok`，安装后 full DryRun 全部 `already-patched`，Fast Mode 线级抓包确认 `service_tier=priority`。
>
> 2026-08-05 的 `26.730.8199.0` 基线已被本轮取代。该轮关于“检查运行时路径、恢复掉失插件、不要用日志关键词判断补丁状态”的经验仍然有效。

## 当前基线

| 项目 | 当前值 |
| --- | --- |
| Desktop | `OpenAI.Codex 26.803.5235.0` |
| 包状态 | `SignatureKind=Developer` / `Status=Ok` |
| CLI | `codex-cli 0.147.0-alpha.6.5` |
| live `app.asar` SHA-256 | `5BCD375F3CFA0FD9CC06FFEFAA524007CA7C19560A3120F982B0DC80789F04B0` |
| live `resources/codex.exe` SHA-256 | `FB5C760E14CF8FE86E12E49E8A3E7F237AF06082D6B9FE1E411E463B7229C916` |
| Fast Patch Skill | upstream `5a484467c15df2055f9fc1828b349cde31160a1b`，自更新检查为 latest |
| Computer Use | 插件 `26.803.41515` / `@oai/sky 0.6.2`，未修改 helper |
| bundled Node 运行时 | `runtimes\cua_node\f1bf3cd3a5929acd` / Node `v24.14.0` |
| 活跃 Desktop 进程 | manifest 指向 `app\ChatGPT.exe`，安装后进程正常存活 |

Store 包在打补丁前的 live 基线为：

| 项目 | Store 原包 |
| --- | --- |
| 包 | `OpenAI.Codex 26.803.5235.0` / `SignatureKind=Store` |
| `app.asar` SHA-256 | `D79379444F689F36FF105E8E33A05966CD4901B85CAD989E9AC6EB0BAF879175` |
| `resources/codex.exe` SHA-256 | `FB5C760E14CF8FE86E12E49E8A3E7F237AF06082D6B9FE1E411E463B7229C916` |

`config.toml` 不使用整文件哈希作为基线，因为 Codex 会在启动时更新 Computer Use pipe 等运行态字段。本轮每次写配置前均保留了独立备份，并用 Python `tomllib` 验证语法。

## 审查发现与修复

- Store 升级确实覆盖了补丁。首次 full DryRun 在新包中重新命中并修改 Fast Mode request/UI、custom models、Ultra slider、locale i18n、browser-use、Computer Use 和 bundled marketplace copy；Power slider、Plugins 与 Goal 在当前构建中已开放或迁移，补丁器判定为 `already-patched`。
- 升级后的 `computer-use 26.803.41515` 缓存缺少 `.codex-plugin/plugin.json`。已执行 Computer Use Only 修复，重建稳定 marketplace/cache、更新 Chrome native-host，并切换到独立 CUA Node 运行时 `f1bf3cd3a5929acd`。
- 升级打掉了上一基线中已安装的 `sites@openai-bundled` 和 `deep-research@openai-bundled`。两者已重新安装并启用。
- 5 个 MCP 的 `command` 仍指向已不存在的旧 Node 运行时 `fb8898c05a62885e`：AdsPower、Burp、Chrome DevTools、JS Reverse、Ruishu。已在单独备份配置后精确迁移到 `f1bf3cd3a5929acd\bin\node.exe`，未修改入口脚本和其他 MCP 配置。
- `PATH` 中的 `codex.exe` 指向 WindowsApps 受保护路径，直接执行会返回 Access denied。本轮所有 CLI 验证均使用用户本地副本：

```text
C:\Users\zzf\AppData\Local\OpenAI\Codex\bin\cfac6bda2d141e07\codex.exe
```

- `openai-curated-local` 与 `openai-bundled` 均重新注册到稳定本地目录；配置中不存在指向 `.tmp\bundled-marketplaces` 的 marketplace source。
- MCP 源码未被本轮修改。Git 基线仍为 AdsPower `06dc59d`、Chrome DevTools `c5ebf9e`、IDA `f82e6e2`、JS Reverse `f45172a`、Ruishu `52f2d97`；IDA 的既有 overlay 差异和 Ruishu 的既有行尾差异原样保留。
- 本轮没有执行手机远控补丁，也没有安装可选 `model_instructions_file`。

## 验收结果

### Desktop 与补丁

| 检查项 | 结果 |
| --- | --- |
| MSIX 安装 | 外部 PowerShell 执行器退出码 `0`；包由 `Store` 恢复为 `Developer / Ok` |
| Fast Mode | 本地 HTTP/WebSocket 验证命中 `/v1/responses`，请求体 `service_tier=priority` |
| 安装后 full DryRun | Fast request/UI、custom models、Power/Ultra、i18n、Plugins/Goal、Browser、Computer Use、bundled marketplace copy 全部 `already-patched` |
| ASAR 直接证据 | live `app.asar` 含 `local-patched`、`enable_i18n`、`browser_use_availability_resolved` |
| 完整性 | live ASAR 哈希为本轮新值；native `codex.exe` 未改写 |
| 临时 SDK | `makeappx.exe`、`signtool.exe` 已清理，PATH 中均不可见 |

### 插件、Computer Use 与 Chrome

| 检查项 | 结果 |
| --- | --- |
| Computer Use StrictVerify | `StrictVerifyOnly -VerifyAllBundledPluginsAvailable` 通过 |
| CUA 运行时 | `runtime import ok`，`list_windows` 返回数组；终态复核为 6 个窗口 |
| 插件 | 5 个 primary-runtime + 7 个 bundled 全部 `installed, enabled` |
| bundled 版本 | Computer Use/Browser/Chrome `26.803.41515`；Sites `0.1.34`；LaTeX `0.2.4`；Deep Research `0.1.1`；Visualize `1.0.20` |
| 配置 | `features.computer_use=true`、`windows.sandbox='unelevated'`，TOML 语法通过 |
| 用户环境变量 | `CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1` |
| Chrome native host | 指向 `chrome\26.803.41515\extension-host\windows\x64\extension-host.exe`，文件存在且路径不含 `.tmp` |
| Chrome `latest` | junction 指向稳定版本目录 `chrome\26.803.41515` |
| Chrome 9222 smoke | Chrome `149.0.7827.201`；CDP 实测 `https://example.com/`、标题 `Example Domain`、1 个 `h1`、正文 `Example Domain`，测试标签已关闭 |
| Windows sandbox | `codex sandbox C:\Windows\System32\cmd.exe /c echo CODEX_SANDBOX_OK` 通过 |
| Skills | 75 个用户 Skills、6 个系统 Skills |

### MCP

7 个 MCP 均启用，`command` 与本地入口文件全部存在。使用 MCP stdio 协议 `2024-11-05` 实测 `initialize + tools/list`：

| MCP | 初始化 | tools |
| --- | --- | ---: |
| AdsPower | 通过 | 47 |
| Chrome DevTools | 通过 | 29 |
| JS Reverse | 通过 | 24 |
| Ruishu | 通过 | 3 |
| IDA Pro | 通过 | 3 |
| Node REPL | 通过 | 3 |
| Burp | 通过 | 未列出 |

Burp 的 `tools/list` 返回 `Tools not loaded. Is Burp running?`，原因是外部 Burp 未监听 `127.0.0.1:9877`。这与上一基线一致，属于既有非阻断项。

## 回滚与审计

本轮保留回滚点，不执行上一轮的“删除所有备份”清理策略：

| 用途 | 路径 |
| --- | --- |
| 本轮完整状态快照 | `C:\Users\zzf\.codex\backups\portable-state\20260807-194750` |
| marketplace/config 自动备份 | `C:\Users\zzf\.codex\backups\config\config.toml.20260807-195452-011.set--marketplaces.openai-curated-local.bak` |
| bundled marketplace 自动备份 | `C:\Users\zzf\.codex\backups\config\config.toml.20260807-195758-002.set--marketplaces.openai-bundled.bak` |
| MCP Node 路径修复前配置 | `C:\Users\zzf\.codex\backups\config\config.toml.20260807-200716-774.mcp-node-runtime.bak` |
| Chrome native-host 备份 | `C:\Users\zzf\AppData\Local\OpenAI\extension\com.openai.codexextension.json.20260807-194948-281.bak` |
| 安装与 MCP 审计日志 | `D:\CodexPatchLogs\20260807-26.803.5235` |

大型 MSIX staging、生成的 patched MSIX 和临时 Windows SDK 已删除。`D:\CodexPatchWork` 下仅剩 3 个空的运行级父目录，不含构建文件。2026-08-03 的历史 portable-state、MCP source 和 config 回滚点仍保留。

## 下次 Store 升级

1. 运行 Fast Patch Skill 自更新检查，确认补丁器已覆盖新 Store 构建。
2. 创建 portable-state 快照，再记录版本、签名、live ASAR/native 哈希和当前插件安装状态。
3. 先运行 `StrictVerifyOnly -VerifyAllBundledPluginsAvailable`。若只存在 marketplace/cache/native-host/runtime 问题，先走 Computer Use Only 修复。
4. 对新 Store 包执行 full DryRun；仅当 package gate 确实被覆盖且所有目标可匹配时，才从外部 PowerShell 执行全量 MSIX 重打。
5. 安装后再次执行 full DryRun，要求每个目标为 `already-patched`，并用 wire capture 验证 `service_tier=priority`。
6. 逐个核对 5 个 primary-runtime 和 7 个 bundled 插件；升级可能再次移除 `sites`、`deep-research` 等可选插件。
7. 不要假设旧 bundled Node 目录仍存在。逐个检查 7 个 MCP 的 `command`、入口文件，并真实执行 `initialize + tools/list`。
8. 复核 Computer Use、sandbox、Chrome 9222、native-host、stable cache junction 和 `config.toml` TOML 语法。

### 已确认的注意事项

- full DryRun 应直接调用补丁脚本并同时传 `-CleanupAfter`，避免留下约 2 GB 的复制包；wrapper 的 `-DryRun` 当前不会自动传该参数。
- 不要直接运行 WindowsApps 内的 `resources\codex.exe`。优先使用 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`，或让补丁器使用工作包副本。
- 不要用关键词搜索 `.codex\logs_2.sqlite` 判断补丁状态。当前任务自身的提示词和工具调用也会进入日志，`local-patched`、`already-patched` 等字符串会产生假阳性。应使用 live ASAR 直接证据、补丁器 DryRun 结果和真实功能 smoke。
- helper 哈希未知时保持原版。只有复现特定截图故障并完成对应版本分析后，才增加 helper patch profile。
