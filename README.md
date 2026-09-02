# Codex Windows Fast Patch Skill

语言：中文 | [English](README.en.md)

这是 `codex-windows-fast-patch` skill 的公开版本，用于让支持 Agent Skills 的智能体修复 Windows 版 Codex Desktop 更新后常见的功能失效问题。

## 主要功能

如果你的 Windows Codex Desktop 更新后出现下面这些问题，可以让 agent 使用这个 skill：

- 修复 Fast Mode、gpt-5.6-sol、gpt-5.6-terra、gpt-5.6-luna 模型不显示，蓝紫色 Power 拖动条消失，以及自定义提供商下 Ultra 开关变灰不可点的问题。
- 修复 Codex 重启后界面语言又变回英文的问题。
- 修复插件入口、插件安装按钮、插件市场列表不可用的问题。
- 修复内置浏览器、浏览器面板、Chrome / browser_use 不可用的问题。
- 修复 Computer Use / 电脑操控 / Any App 不可用的问题。
- 修复 Computer Use 能列出窗口、但后续独立调用因持久 helper 的应用审批回调丢失 `node_repl` 执行上下文而报错的问题；只对文档列出的精确 `@oai/sky` 源文件哈希应用补丁。
- 修复特定 Win10 CUA helper 在截图时因 `SetIsBorderRequired` 返回 `0x80004002`，以及绕过后 `FrameArrived` 同步等待死锁的问题；仅支持文档列出的精确 helper 哈希。
- 修复手机远控入口不显示、二维码一直转圈、跳 ChatGPT 登录、点允许后失败、手机提示 Codex 版本过期等问题。(第三方api登录态下使用原生手机远控功能)
- 修复 Goal 入口、部分设置入口、功能按钮在更新后消失或变灰的问题。
- 修复切换 `model_provider` / API 配置后，旧会话仍在本地但官方侧边栏不显示的问题；如果恢复后的会话能显示但继续时报“当前工作目录缺失”，可按 rollout 原始 `cwd` 创建缺失空目录。
- 修复本地插件市场配置损坏、`codex plugin list` 报错的问题。
- 安全清理已移除 marketplace/plugin 在 `config.toml` 中遗留的精确插件表和 hook state；默认只读，只有 marketplace 未配置且限定缓存位置无插件证据时才允许写入。
- 可选备份和恢复本机 Codex 配置、技能、插件市场等关键状态。
- 支持每次开始修复前自动将skills更新到最新版本
- 破限只需：帮我配置破限相关文件和config.toml中的相关配置

## 平台支持

当前只支持 Windows。

这个 skill 依赖 Windows Store / MSIX 包结构、PowerShell、`Get-AppxPackage`、`makeappx.exe`、`signtool.exe`、Windows 用户环境变量，以及 Windows Computer Use helper 路径。

不要在 macOS 上直接运行。macOS 需要单独的实现流程，例如处理 Codex `.app` 包、ASAR 解包和重打包、`codesign` 或 quarantine、shell 脚本，以及 macOS 自己的 Computer Use 可用性门控。

## 文件说明

- `SKILL.md`：Agent skill 主说明。
- `agents/openai.yaml`：Agent UI 元数据。
- `scripts/repatch-codex-windows.ps1`：主工作流参考脚本。
- `scripts/patch_codex_fast_mode_windows_msix.ps1`：Fast Mode、插件、浏览器、Computer Use 等 MSIX / ASAR 补丁参考实现。
- `scripts/patch-dynamic-tools-windows-msix.ps1`：用于修复 Desktop `dynamicTools` schema 漂移导致新建对话 / thread start 报 `missing field inputSchema` 的 targeted MSIX / ASAR 脚本。
- `scripts/patch-dynamic-tools-schema.cjs`：dynamicTools MSIX 脚本使用的 Electron bundle patcher。
- `scripts/patch-remote-control-windows-msix.ps1`：手机远控 MSIX / ASAR 补丁和 marker 校验参考实现。
- `scripts/patch-remote-control-asar.cjs`：手机远控 Electron bundle patcher。
- `scripts/build-remote-control-native-replacement.ps1`：当 native app-server 因 API-key 主认证拒绝手机远控时，在指定工作目录下构建 patched `app\resources\codex.exe` replacement。默认从安装包副本自动识别原生版本；内置映射包括在 Desktop `26.715.2305.0` 上完成精确 tag 构建、安装和手机端到端实测的 `0.145.0-alpha.18`，在 Desktop `26.707.3748.0` 上完成同类验证的 `0.144.0-alpha.4`，以及仅通过 patch-apply 验证的历史 `0.142.4`。其他版本必须提供严格匹配的 `-CodexSourceRef`、`-AppServerVersion` 和已验证的 `-PatchPathOverride`。
- `scripts/install-computer-use-local.ps1`：Windows Computer Use 与 Chrome 本地运行时安装和校验参考实现；兼容旧式 `latest + plugin-local node_modules` 和新版“版本缓存 + `%LOCALAPPDATA%` 独立 cua_node runtime”布局，并同步 Chrome 外层 native-host manifest、`extension-host-config.json` 与两份 schema-2 app-server 状态文件。
- `scripts/patch-computer-use-node-repl-context.ps1`：为精确支持哈希的 `@oai/sky 0.6.2` helper transport 修复跨 `node_repl` 调用的应用审批上下文，提供只读识别、安装、完整哈希校验和回滚。
- `scripts/patch-computer-use-helper-win10.ps1`：为精确支持哈希的 `@oai/sky 0.4.20`、`0.5.2`、`0.6.6`、`0.6.11`、`0.6.16` 和 `0.6.17` helper 提供只读识别、安装和回滚；`26.707.12708.0`、`26.721.4979.0`、`26.803.10989.0`、`26.810.6296.0`、`26.810.7004.0`、`26.814.5167.0`、`26.814.5517.0`、`26.818.2872.0` 与 `26.818.3698.0` 是各自的端到端验证基线，不是版本门槛。同一个 `0.6.16` 系列在两个 Desktop 版本上是不同的 helper 二进制；两个 `0.6.17` helper 甚至上报完全相同的版本字符串，仅整文件哈希不同，因此 profile 只能按完整哈希选取，绝不能按版本前缀。最新 `0.6.17` 基线包含八帧全唯一静态截图、二十帧全唯一动态截图和预热后资源稳定性验证。
- `scripts/sync-codex-provider-history.ps1`：同步本地会话 provider 元数据，让切换 `model_provider` 后消失的会话重新出现在官方列表中；也可用 `-RepairMissingCwdDirs` 修复恢复后会话无法继续的缺失 `cwd` 目录。默认不改 `config.toml`，也不改 workspace/project roots。
- `scripts/cleanup-orphaned-plugin-config.ps1`：只针对显式 `plugin@marketplace` ID 分类并清理孤立 `config.toml` 插件/hook 表；默认只读，写入前检查 marketplace 和限定磁盘位置，写入时创建 SHA-256 校验备份。
- `scripts/install-model-instructions-file.ps1`：可选安装内置 `model_instructions_file` 提示词资源。
- `scripts/manage-codex-backups.ps1`：本地 Codex 配置、MCP、skills 和 marketplaces 的备份管理脚本。
- `assets/system-prompt.md`：仅在用户明确要求可选提示词配置时使用的内置提示词资源。
- `references/restriction-debug-cases.md`：限制解除、Chrome/browser_use、Computer Use 和 Fast Mode 的按需诊断案例。
- `references/win10-computer-use-screenshot-backend.md`：Win10 原生截图 helper 的 `0x80004002`、`FrameArrived` 死锁、补丁边界和验收证据。
- `references/remote-control-debug-cases.md`：手机远控配对、隔离授权、native app-server 网络、版本过期状态和配对后 API 地址诊断案例。
- `references/remote-control-native-replacement.patch`：手机远控 native app-server replacement 使用的 Rust 源码参考补丁。
- `references/remote-control-native-replacement-0.145.0-alpha.18.patch`：已在 Desktop `26.715.2305.0` 上完成构建、安装和手机端到端实测的 `rust-v0.145.0-alpha.18` 专用 Rust 源码补丁。
- `references/remote-control-native-replacement-0.142.4.patch`：历史 `rust-v0.142.4` 专用、仅通过 clean patch-apply 验证的 Rust 源码补丁；不得描述为完整编译或端到端验证。

## 安装

skill 目录就是这个仓库的一份克隆，直接 `git clone` 到你的智能体的 skills 目录即可。目标路径取决于你用的 harness，skill 本身不关心装在哪个 harness 下面：

```powershell
# Codex
git clone https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"

# Claude Code
git clone https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git "$env:USERPROFILE\.claude\skills\codex-windows-fast-patch"
```

其它支持 Agent Skills 的智能体同理，把目标目录换成它自己的 skills 根就行。完整历史只占约 800 KB，比工作树本身还小。

装完重启智能体，让它重新加载 skill 元数据。

如果你的 harness 用插件或 marketplace 机制安装 skill，那份副本不是 git 工作树，自更新不可用，其余功能不受影响。

## 使用

安装后，让支持 Agent Skills 的智能体使用 `codex-windows-fast-patch` 工作流处理当前机器上的 Codex Desktop 问题。

这个 skill 的更新就是 `git pull`。智能体正式开工前先做一次极轻的检查：`git fetch` 加 `git rev-list --count 'HEAD..@{u}'`（PowerShell 里 `@{u}` 必须加单引号，否则会被解析成 hashtable），计数为 0 就直接跳过，非 0 才看 `git log` 决定是否拉取。补丁步骤失败时（helper profile 缺失、pattern 不再命中、Desktop 版本不认识）会再检查一次，因为这正是上游可能已经修好的情况。

本地改动不会被抹掉。上游改的文件和你改的文件不重叠时，`git pull --ff-only` 会正常快进并保留你的改动；重叠时 git 会拒绝拉取、点名冲突文件，并把你的改动完整留在磁盘上，用 `git stash` 拉取后再 `git stash pop` 处理（如果改的正是同几行，`stash pop` 会留下冲突标记，需要手动解决）；已经本地 commit 则分支分叉，`--ff-only` 拒绝，用 `git pull --rebase` 把本地提交重放到更新之上。你自己加的 helper profile 和修复护栏因此是安全的。想换更新源就 `git remote set-url origin <你的 fork>`，想回退就 `git checkout <旧提交>`。网络不通时更新会被跳过，智能体继续用当前本地版本处理问题，并在结论里说明未能更新。

这些脚本是参考实现和操作模板，不是跨所有机器都能直接运行的一键方案。实际处理时应先读取 `SKILL.md`，检查当前机器的 Codex 安装方式、MSIX 包路径、ASAR 内容、签名工具、插件目录、Computer Use 文件状态和远控相关日志，再决定执行、改写或只借鉴其中步骤。

## 使用建议

有些修复会重装 Codex Desktop。重装时当前 Codex Desktop 会被关闭，所以不要让正在使用的这个 Codex Desktop 会话自己重装自己，否则很容易出现“修到一半会话被卸载/中断”的情况。

可以直接让当前 Codex Desktop 会话修复的问题：

- Computer Use 提示插件不可用、`native pipe unavailable`、`missing-helper-path`、重启后又失效。
- Computer Use 的 `list_windows` 成功，但下一次 `get_window_state` / `activate_window` 报 `node_repl exec context not found`；先做精确源文件哈希识别，未知哈希停止。
- Computer Use 能列出窗口但 Win10 截图报 `SetIsBorderRequired ... 0x80004002`；此类只能对精确支持哈希运行 helper patcher，未知哈希停止。
- Chrome / browser_use 的 helper 路径、缓存、native-host 文件损坏。
- 插件市场配置损坏、`codex plugin list` 报 marketplace manifest 错误。
- 本地 marketplace 缺 `.agents\plugins\marketplace.json`。
- 已移除的个人插件仍残留 `[plugins."...@marketplace"]` 或对应 `[hooks.state."...:..."]`，而 marketplace 已不再配置且限定缓存位置无插件目录或 descriptor。先运行只读分类，再显式加 `-Install`。
- 切换 `model_provider` / API 配置后，本地旧会话消失但 `sessions`、`archived_sessions` 或 `state_5.sqlite` 仍有数据。此类先用 provider history sync，不需要重装 MSIX。
- 旧会话已经恢复显示，但继续对话时报“当前工作目录缺失”或 `invalid codex request`。此类先用 provider history sync 的 dry-run 看 `missing rollout cwd dirs before`，确认后用 `-RepairMissingCwdDirs` 创建 rollout 记录的原始缺失目录。
- 只需要备份/恢复 Codex 配置，或安装可选的自定义提示词配置。
- 手机远控已经能配对，但手机发来的对话请求到了错误的模型 API 地址。这类属于配对后的配置诊断，先查实际请求 URL 和当前配置，再依据证据修改。

建议使用另一个 agent、外部 PowerShell、VS Code/Antigravity 里的 Codex 扩展，或其它不会被 Codex Desktop 重装影响的环境来修复的问题：

- Fast Mode / Priority 模式不显示、不生效。
- Codex 重启后语言变回英文。
- 插件入口、插件安装按钮、Goal 入口、Computer Control 的 `Any App` 变灰或消失。
- 内置浏览器、浏览器面板、Chrome / browser_use 被桌面端门控隐藏或禁用。
- bundled runtime marketplace 反复丢失 `sites`，或 Desktop 日志里的 `pluginNames` 不含 `sites` 且出现 `not_in_bundled_marketplace_plugin_names` / `sites@openai-bundled`。
- 手机远控入口不显示、二维码一直转圈、跳 ChatGPT 登录、点允许后失败、手机提示 Codex 版本过期。
- 任何需要运行完整 repatch、重新打包 MSIX、安装 Developer 签名包、替换 `app.asar` 或替换 `resources\codex.exe` 的修复。

简单判断规则：如果修复会停止、卸载、重装或重新启动 Codex Desktop，就用另一个 agent 或外部 PowerShell 来跑；如果只是修本地配置、插件缓存、marketplace、备份或验证，一般可以让当前 Codex Desktop 会话直接处理。

## 用 VS Code Codex 扩展作为外部执行器

在 Windows 上，如果修复会停止、卸载、重装、重新打包 MSIX、替换 `app.asar`、替换 `resources\codex.exe` 或重启 Codex Desktop，推荐从 VS Code 里的 Codex 扩展、外部 PowerShell，或其它不会被 Desktop 重启影响的 agent 环境执行。

执行目标始终是 Codex Desktop 的状态目录：默认是 `$env:USERPROFILE\.codex`。不要把隔离 CLI wrapper 当成 Desktop 执行环境；如果某个 wrapper 会把 `CODEX_HOME` 设为 `$env:USERPROFILE\.codex-cli` 或其它隔离目录，那只是 CLI 状态，不是 Desktop 的插件、市场、MCP、远控或登录状态。

外部执行器开始前先确认没有全局 `CODEX_HOME`。不要把 `.codex` 复制或迁移到 `.codex-cli`，不要提交或展示 `auth.json`、API key、OAuth token、MCP 凭据、浏览器资料或其它本地凭据。建议顺序是：先用 `scripts\manage-codex-backups.ps1 -Action Backup` 备份 Desktop 状态，再做只读检查和日志判断；需要 MSIX / ASAR 修复时先跑对应脚本的 `-DryRun`，只有 dry run 找到并验证目标后再运行安装路径，例如 `repatch-codex-windows.ps1` 或 targeted `*-windows-msix.ps1 -Install -Launch -InstallPrerequisites`。Store 刚下载的新包可能只对 SYSTEM 处于 Staged；补丁器会选择当前用户或 SYSTEM-Staged 的 `-AllUsers` 注册，并仅在该查询不可用时回退 WindowsApps 目录。继续前核对 `selected Codex app` 日志，只有需要强制指定来源时才传 `-AppPath`。

手机远控安装路径会在缺少 `makeappx.exe` / `signtool.exe` 时从 NuGet 下载 Windows SDK BuildTools，并把缓存放在 `-OutputRoot\.remote-control-temp`，不会在已指定 D 盘输出根时回落到 `%TEMP%`。默认不强制使用本地代理；如果机器必须走代理，再显式传 `-BuildToolsProxy "http://127.0.0.1:10808"` 或设置 `CODEX_WINDOWS_SDK_BUILDTOOLS_PROXY`。日志不会打印代理 URI 或凭据。如果遇到 `curl download failed with exit code 7`，先确认是否传了一个未监听的本地代理。

原生 replacement 构建也应把 `-WorkRoot` 放在用户指定的大容量非系统盘，并优先使用短根路径。`26.715.2305.0 / 0.145.0-alpha.18` 的实测中，过长的 D 盘路径会让 Cargo 的 Git 依赖 checkout 因 Windows path-too-long 失败；缩短为类似 `D:\CodexData\rc145` 的根路径后构建成功。PowerShell 5.1 下 SDK NuGet 包使用已校验的 `tar.exe` 解包，并兼容库与头文件分离的实际 `c\um\x64`、`c\ucrt\x64`、`c\Include\<version>` 和 `c\bin\<version>\x64` 布局。

一个典型请求是：

```text
使用 codex-windows-fast-patch 这个 skill，检查并修复这台 Windows 机器上的 Codex Desktop Fast Mode、语言/locale、Chrome browser_use、插件市场和 Computer Use 可用性问题。
```

手机远控请求示例：

```text
使用 codex-windows-fast-patch 这个 skill，修复 Windows Codex Desktop 手机远控，同时保留我的第三方 API 主使用方式和现有会话记录。
```

孤立插件配置先只读检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\cleanup-orphaned-plugin-config.ps1" -PluginId "obsolete-helper@personal"
```

只有输出确认 marketplace 未配置且限定磁盘位置无插件证据时，才执行清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\cleanup-orphaned-plugin-config.ps1" -PluginId "obsolete-helper@personal" -Install
```

## 预期验证

- 补丁日志中的 `selected Codex app` 与 `source package` 指向预期的最高版本；如果 Store 新包只对 SYSTEM 为 Staged，也不能静默回退到旧用户包。
- 补丁日志包含 `fast-mode UI patch result`、`locale i18n patch result` 和 `browser-use gate patch result`，结果为 `patched` 或 `already-patched`。
- Fast Mode 本地线缆验证能在 `/v1/responses` 的 HTTP 请求体或 WebSocket 帧里捕获 `service_tier=priority`；如果 `codex exec` 未发出请求，验证器会回退到 app-server，并额外确认 `thread/start serviceTier=priority`。
- 如果本次修复包含浏览器和 Computer Use，`codex plugin list` 应显示 `browser`、`chrome`、`computer-use` 为 `installed, enabled`；`sites`、`latex`、`deep-research`、`visualize` 等无关可选插件必须保留用户原有状态。给主 wrapper 加 `-VerifyAllBundledPluginsAvailable` 会在正常修复/DryRun 流程中附加 availability 断言，校验稳定镜像与当前安装包的 descriptor 名称和版本一致，并校验 CLI JSON 报告相同版本；断言本身不联网下载、不执行 `plugin add`、不启用可选插件，但 wrapper 的其它修复步骤仍可能写入状态。完全只读时直接运行 `install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable`。该断言以安装包自带的 `app\resources\plugins\openai-bundled` 清单为基准，所以当账号侧 feature flag 让 Desktop 物化的 descriptor 少于安装包时，它会以 `stable bundled marketplace descriptor set does not match the installed package` 失败。第三方 provider 或 API key 账号出现这种情况属于预期，不是修复目标：例如 Desktop `26.825.6671.0` 安装包带 10 个 descriptor，而账号只能物化 8 个，缺的 `unified-computer-use`（依赖 `browserUseTinysky`，且在 Windows 上恒返回空并标记 `hidden`）与 `user-writing`（依赖 `userWriting` 与 ChatGPT 账号用户设置）都无法在这类账号下取得。此时改用「按本次修复实际需要的插件名」验收，并在报告里写明缺口与原因。
- 如果修复 `node_repl exec context not found`，`StrictVerifyOnly` 应报告已验证的 helper-transport 补丁哈希；随后必须在启动 helper 的调用之后，用至少两个新的独立调用激活并截图同一个稳定窗口，并检查图片内容确实属于目标窗口。只有 `list_windows`、截图计数或 PNG 文件不算验收。
- 如果修复是在外部 PowerShell、VS Code 等环境里执行、没有 Desktop 的 `node_repl` 内核，可以改用当前 `cua_node` 运行时自带的 `node.exe` 起多个独立短进程来做 Computer Use 真实验收：先在 `globalThis.nodeRepl` 仍为 `undefined` 时 import 官方 sky 入口并访问一次导出，再注入 `{ config: {}, createElicitation }` 应答 helper 的审批请求，然后用 `activate_window({ window: { app, id } })` 和 `get_window_state({ window, include_screenshot: true, include_text: true })` 取图（图片在 `screenshots[].url` 的 data URL 里，常见媒体类型是 `image/jpeg`，sky 没有单独的 screenshot 方法）。报告里要写明这条替代路径没有走 Desktop 内真实审批 UI。Chrome/浏览器的 smoke test 无法这样替代——`browser-client.mjs` 硬性要求 `globalThis.nodeRepl.rpc`，只有 Desktop 的 Node REPL 提供这条受信通道；自己写一个 `rpc` 也没用，它背后没有真实 browser service，而且 `sky.js` 是按同一个属性选传输路径的，一旦定义 `rpc`，Computer Use 也会从本地 helper 客户端切到这条假通道，把刚验过的能力弄坏——此时只能报到「门已开且配置/清单/缓存/注册表已校验」，并明说标签页读取没跑。
- Desktop 日志应保留当前安装包的 bundled descriptor 名称，并且不应通过 `not_in_bundled_marketplace_plugin_names` 删除用户原本已安装的插件；descriptor 存在不等于插件已安装。
- 如果本次修复包含浏览器能力，Desktop 日志里 `browser_use_availability_resolved` 显示 `available=true` 和 `reason=local-patched`。
- 如果修复 Win10 截图 helper，patcher 应报告已验证 patched SHA-256；Explorer 首帧/连续帧、任务管理器动态帧、文字读取、窗口枚举和预热后资源稳定性都应通过。
- 如果需要 Chrome 控制，`codex plugin list` 显示 `chrome@openai-bundled` 为 `installed, enabled`；native messaging host manifest 的路径和注册表值指向当前稳定缓存；`allowed_origins` 与缓存 `scripts\extension-ids.json` 顶层 ID 精确一致；`extension-host-config.json` 包含与当前安装包匹配的本地 `codex.exe` 以及同一当前运行时的 `node.exe` / `node_repl.exe`；`%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json` 与 `%USERPROFILE%\.codex\chrome-native-hosts-v2.json` 都包含当前版本、官方哈希身份和全部现存路径。稳定 marketplace 与版本化缓存中的 `browser-client.mjs` 必须和安装包 SHA-256 完全一致；信任校验既支持旧版 `app.asar` 哈希列表、`NODE_REPL_TRUSTED_SERVICES` 与 `browserServicePath` 服务契约，也支持完整的 `26.814` native-host 路径契约。如果稳定缓存通过 junction 位于 `CODEX_HOME` 之外，用户级和 Desktop 生成后的 `NODE_REPL_TRUSTED_CODE_PATHS` 都必须包含解析后的物理 marketplace/cache 根，installed ASAR 必须包含 `CODEX_NODE_REPL_TRUSTED_PATHS_V1`。`setupBrowserRuntime()` 成功且 `agent.browsers.get("chrome")` 返回真实 Chrome 扩展后端。随后真实 smoke test 应能读到受控标签页标题，例如 `Example Domain`。Chrome 未运行时，无需再次征得用户授权，直接自动启动后验证 `https://example.com/`、`Example Domain` 标题和唯一且文本匹配的 `h1`。
- 如果修复手机远控，连接页应显示手机/移动设备设置路径，二维码应出现，手机扫码不再提示 Codex 版本过期；按 WindowsApps native PID/路径关联的日志应出现 `remote_control_websocket_proxy_connected` 和 `Connected` 且没有重复 `os error 10060`，手机发送消息能到达 Desktop。部分 native 版本会静默处理 Ping/Pong，因此不得把帧日志文字当作唯一成功条件。
- 如果修复会话消失，`sync-codex-provider-history.ps1` 应显示 App/legacy SQLite 和 readable rollout 的 provider 已对齐到当前 `model_provider`，`config.toml sha256 unchanged`，官方侧边栏能看到历史会话，并且不会新增空项目分组。如果修的是“恢复后无法继续”，`missing rollout cwd dirs after` 应为 0 或只剩已审查跳过的路径，受影响会话重启后能发送新消息。
- 如果清理孤立插件配置，日志应先报告只读分类或明确拒绝原因；`-Install` 成功时必须报告备份 SHA-256、TOML 校验通过、无 UTF-8 BOM、精确插件/hook 表已不存在，且相似 ID 与无关表仍保留。

## 备份管理

修复脚本在写入 `config.toml` 前会自动把旧文件备份到 `.codex\backups\config\`。如果要手动备份或迁移本地 Codex 的关键状态，可以使用独立备份脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\manage-codex-backups.ps1" -Action Backup
```

列出现有备份：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\manage-codex-backups.ps1" -Action List
```

从某个备份恢复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\manage-codex-backups.ps1" -Action Restore -BackupPath "<backup path>"
```

默认备份自定义 skills、marketplaces、`config.toml`、解析出的 `mcp_servers.json` 和 `chrome-native-hosts.json`，并排除 `.git`、`node_modules`、构建产物和虚拟环境等容易变大的目录。需要完整离线依赖副本时再加 `-IncludeDependencyDirs`；插件缓存和 `.tmp\bundled-marketplaces` 也可能较大，需要时再加 `-IncludePluginCache` 或 `-IncludeTmpBundledMarketplaces`。

## 致谢

感谢 [LinuxDo community](https://linux.do/) 中相关讨论和反馈对这个工作流的启发。
