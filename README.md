<div align="center">

<img src="assets/readme-mark.png" width="104" height="104" alt="">

<h1>Codex Windows Fast Patch Skill</h1>

<p>让 AI 助手修复 Windows 版 Codex Desktop 更新后失效的模型列表、浏览器、电脑操控等功能。</p>

<p>
  <img src="https://img.shields.io/badge/Windows-0078D4?style=flat-square" alt="Windows">
  <img src="https://img.shields.io/badge/Agent%20Skills-2563EB?style=flat-square" alt="Agent Skills">
  <img src="https://img.shields.io/badge/PowerShell-475569?style=flat-square" alt="PowerShell">
</p>

<p><strong>中文</strong> &nbsp;/&nbsp; <a href="README.en.md">English</a></p>

<p>
  <a href="#能修复什么">能修复什么</a> &nbsp;·&nbsp;
  <a href="#安装">安装</a> &nbsp;·&nbsp;
  <a href="#使用">使用</a> &nbsp;·&nbsp;
  <a href="#更新">更新</a> &nbsp;·&nbsp;
  <a href="#哪些修复会重新安装-codex">重装说明</a> &nbsp;·&nbsp;
  <a href="#更多帮助">更多帮助</a>
</p>

</div>

这是社区维护的 **Agent Skill**，提供诊断流程与修复脚本，不是官方客户端，也不是适用于所有版本的一键安装器。

已适配 `26.1029.7803` 新布局，包含模型、Fast、Ultra 恢复；项目归属与归档错误使用独立显式入口。另提供 Sky `0.7.13` / `0.7.17` 的 Windows 10 截图补丁。安装后仍须核验实际运行版本、插件状态和所请求的截图验收；更新遗留的 MCP 路径按备份与运行时核对结果处理。

该布局的 `-OnlyModelExperience` 也支持定向诊断与修复，只调整模型可见性、Fast 和 Ultra，不顺带打开语言、浏览器或 Computer Use 门禁；已有完整桌面补丁会保留。Chrome 使用 `latest` 路径重新登记后，仅在指向同一当前文件且官方身份匹配时通过严格检查，不以内容相同的副本替代路径验证。

> [!WARNING]
> **仅支持 Windows。部分修复包含重新安装 Codex 的步骤。** 期间应用会关闭，当前对话可能中断；安装完成后重新打开 Codex，回到原修复对话发送“继续”即可接着处理。具体见[重装说明](#哪些修复会重新安装-codex)。

## 能修复什么

`26.1029.7803` 启动卡在 Statsig 初始化时，完整桌面补丁将 Windows 登录后请求的总等待限制为 5 秒，SDK 网络回退等待限制为 2 秒，并保留缓存及后台刷新。日志新增渲染进程退出原因与退出码；这项诊断不等于已经修复原生渲染崩溃。见[启动等待与重载诊断](references/windows-startup-stability.md)。

工具报 `failed to spawn code-mode host` 时，可运行 `scripts/install-computer-use-local.ps1 -OnlyExecutorRuntime`，加 `-StrictVerifyOnly` 只检查。它核对当前包的完整文件哈希、恢复缺失的配套程序，并备份后迁移固定旧缓存目录的 `CODEX_CLI_PATH`。修复后重启 Codex，核对实际 app-server 路径和真实工具调用。

一键修复已包含 CUA 浏览器代理恢复：已继承有效的 `HTTP_PROXY` 和 `HTTPS_PROXY` 时保留运行时原件；否则从 Windows 显式 HTTP 系统代理生成受管理的本地 runtime 补丁，保留原件备份，代理改变后可重新应用。修改后需重启 Codex，并分别验证 Chrome 与内置浏览器。仅修复此项可运行 `scripts/install-computer-use-local.ps1 -OnlyRuntimeProxy`；加 `-StrictVerifyOnly` 只检查。暂不支持把 PAC、带认证或非 HTTP 代理用作回退。

| 问题 | 覆盖范围 |
| --- | --- |
| **模型与速度选项缺失** | Fast Mode、被隐藏的已有模型、Power 拖动条、Ultra 开关 |
| **界面与插件异常** | 语言重置、Goal 等入口消失、插件市场与安装按钮不可用、客户端过滤隐藏的 Image-guided Assets |
| **浏览器不可用** | 内置浏览器、Chrome 控制、自定义供应商下特定的登录依赖错误 |
| **电脑操控异常** | Computer Use / Any App、跨调用窗口操作、部分 Win10 截图故障 |
| **手机远控失效** | 入口、二维码、配对和版本过期问题，保留第三方 API 主使用方式 |
| **会话异常** | 新建对话 `inputSchema` 报错、切换供应商后历史消失、恢复后目录缺失、重启后项目归属丢失、已有归档列表仍显示加载失败 |
| **配置管理** | 配置、技能和市场的备份恢复 |
| **配置听话水** | 配置 skill 内置的系统提示词文件及 `model_instructions_file` |

手机远控和听话水配置（`model_instructions_file`）均为可选流程，不会随普通修复自动启用。

新版 26.1027 若仅“设置中缺少手机远控入口或点击无反应”，可先运行手机脚本的
`-OnlySettingsEntry -DryRun`。该模式只修入口显示和路由，保留认证与权限检查，
不包含新版隔离登录或原生连接适配，不能视为扫码连接已修复。详情见[手机远控排查](references/remote-control-debug-cases.md)。
同版本另有精确绑定的 [0.166 原生隔离远控适配](references/remote-control-native-local-261027.md)，
已完成该版本组合的用户手机连接验收，包含系统代理与清理边界说明；不自动套用旧版完整修复流程，
也不把用户确认当作已独立采集手机消息回环或实际模型请求地址。

补丁是否适用取决于当前版本和文件内容，不能把旧补丁强套到未知版本。模型仍需由你的供应商提供，本项目不提供模型 API 或额度。会话恢复以本地历史数据仍在为前提；修复缺失目录不会找回被删除的项目文件。

## 安装

准备好 Windows 版 Codex Desktop、Git，以及支持 Agent Skills 的 AI 助手。在 PowerShell 中执行：

```powershell
$SkillRoot = "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"
git clone https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git $SkillRoot
```

这一步只安装 skill，不会重装 Codex。完成后重启使用它的 AI 助手，让其加载技能。

Claude Code 可将目标改为 `$env:USERPROFILE\.claude\skills\codex-windows-fast-patch`；其他客户端使用各自的 skills 目录。后续命令中的 `$SkillRoot` 都应指向你的实际安装位置。已经安装过的副本直接按下文更新，不要重复克隆。

## 使用

**安装后，直接向 AI 助手描述问题，例如：**

```text
使用 codex-windows-fast-patch，检查并修复 Codex 更新后的模型列表、
浏览器和电脑操控问题。保留我的配置与会话，完成后做后台核验并清理临时文件。
```

默认采用后台只读验收，不自动打开计算器等测试应用，不切换原生窗口焦点或发送鼠标键盘输入。运行时、插件、窗口枚举等检查会分别报告；真实截图和原生输入测试仅在你明确要求或同意后执行，未执行时会如实注明。

### 更新后统一检查与恢复

项目现在包含统一入口，不需要从某次聊天复制临时脚本：

```powershell
& "$SkillRoot\scripts\codex-after-update.ps1"
& "$SkillRoot\scripts\codex-after-update.ps1" -CheckApp
& "$SkillRoot\scripts\codex-after-update.ps1" -RepairPlugins -RepairApp
```

第一条只检查当前包的安装事务、实时模型目录和插件/运行时；没有当前包的验收记录时，会明确返回 `app-check-needed`，不会因为插件正常就宣称应用补丁正常。第二条还会对当前包运行完整补丁试运行，逐项检查语言、插件、浏览器/电脑控制、Fast 和 Ultra 路径，并清理本次临时副本；可用 `-CheckRoot 'D:\CodexChecks'` 指定空间充足的临时目录。第三条显式修复插件，并在试运行确认需要且兼容时调用带回退保护的完整非手机安装器，会请求正常 UAC 并重启 Codex。已安装但未验收的事务只续做验收；安装器运行中或状态不明时不会再启动一个。

模型白名单默认从当前提供方的 `model/list` 获取可见模型和用户选中的默认模型，保留各模型原有 reasoning/service tiers，避免更新修复回退到旧的写死列表。也可显式传 `-CustomModels @('your-model-a','your-model-b')`；这只控制已有目录项的可见性，不会创造模型或速度能力。恢复启动器默认也使用实时目录；读取失败会停止并给出诊断，而不悄悄使用旧列表。

输出包含机器可读 JSON 状态。可加 `-ReportPath '<新的报告路径>.json'` 保存报告（不会覆盖已有文件）；`-WhatIf` 允许诊断，但不修复插件、不启动安装器、不保存报告。完整包诊断需要临时磁盘空间，不修改已安装应用。工具不会安装定时任务、自动监控或后台自动重启。商店仍可覆盖包内补丁；本入口用于在更新后发现并恢复兼容的已知路径，未知结构会报告不支持并停止安装，不能保证所有未来版本都自动兼容。详细状态与边界见[更新后验证](references/post-update-verification.md)。

外部浏览器扩展验收支持 Chrome 或 Edge。仅在 Edge 安装扩展时，会通过官方诊断检查 Edge 自己的配置目录，无需再往 Chrome 安装扩展，也不会把两个浏览器的用户目录互相映射。实际网页访问仍需分别核验。

**需要手机远控时单独提出：**

```text
使用 codex-windows-fast-patch 修复手机远控，
保留我的第三方 API 配置、原有登录和会话记录。
```

### 项目归属与归档加载

对于已核验的 `26.1027.6604` 和 `26.1029.7803` 文件组合，`-OnlyProjectArchiveState` 只修复全局状态备份恢复、Windows 本地项目关联持久保存，以及归档列表已有内容时残留的错误提示。先运行 `scripts/patch_codex_fast_mode_windows_msix.ps1 -OnlyProjectArchiveState -DryRun`。此模式需要重新打包并原地更新；新版 `26.1029.7803` 全量修复也包含这些代码修复，未知文件哈希会停止。已有归属恢复须先核对数据库、全局状态及备份，按证据修复，不从工作目录批量猜测归属。步骤及验收见[项目与归档状态修复](references/project-archive-state.md)。

### 配置听话水

“听话水”就是本 skill 内置的系统提示词。把下面这句话发送给智能体：

```text
帮我进行听话水相关的配置
```

智能体会使用 [`assets/system-prompt.md`](assets/system-prompt.md)，配置系统提示词文件，并在 `config.toml` 中设置 `model_instructions_file`。完成后按提示开启新会话或重启 Codex，使配置生效。

<details>
<summary><strong>Chrome 是否需要额外登录？</strong></summary>

对于明确配置 `requires_openai_auth=false` 的供应商，支持修复特定版本的 `Codex auth token is unavailable` 错误，且保持代理请求头开启、不借用手机授权。这不是所有登录问题的通用绕过，具体条件见[Chrome 兼容说明](references/restriction-debug-cases.md#chrome-custom-provider-request-header-authentication-dependency)。

</details>

## 更新

每次更新打补丁前，先拉取并审查自己的远端 `main` 与上游 `main`，对比本机技能和已有 PR；远端已覆盖的修复直接复用，只补充有实际证据支持的缺失修复或优化。通过 `git clone` 安装的副本可在审查后快进更新：

```powershell
git -C $SkillRoot fetch origin
git -C $SkillRoot fetch upstream
git -C $SkillRoot pull --ff-only
```

先核实 `origin` 是自己的 fork、`upstream` 是原仓库；没有该 remote 时按[远端审查与发布流程](references/remote-review-and-publication.md)配置。非 Git 安装副本也要通过持久源码 checkout 对比，保留本机 overlay，不能跳过远端审查。

这是更新修复工具，不是更新 Codex 客户端。必要增量验证后必须提交、推送自己的 `main` 并创建或更新上游 PR，在修复记录中写明 commit、base/head 和 PR URL。已有有效提交/PR 则复用，避免空提交和重复 PR；网络或认证阻塞须明确记录。

## 哪些修复会重新安装 Codex

是否重装取决于故障原因，不是每次使用 skill 都会重装：

| 修复内容 | 通常的处理方式 |
| --- | --- |
| Fast Mode、Power/Ultra、客户端过滤导致的模型不显示 | 修改客户端后重新安装 |
| 语言重置、Goal / 插件 / 浏览器 / Any App 的客户端入口异常 | 修改客户端后重新安装 |
| 手机远控的入口、配对或版本问题，新建对话 `inputSchema` 报错 | 需要修改客户端或原生程序时重新安装 |
| 重启后项目归属丢失、归档列表已显示仍提示加载失败 | 核对并恢复归属数据，修补受支持客户端后原地更新 |
| Chrome / Computer Use 的缓存、运行时路径、市场配置，以及已支持的 Chrome 登录依赖错误 | 通常只修本地环境，不重装 |
| 模型目录补全、历史会话可见性、缺失工作目录、备份与听话水配置、配对后的 API 地址 | 通常只改配置或数据，不重装 |

同样是“浏览器不能用”或“模型不显示”，也可能只是缓存或配置问题，以实际检查结果为准。

### 重装期间会发生什么

**可以直接在当前 Codex 对话里发起修复。** 需要安装时，由智能体安排独立安装进程接手，让安装在 Codex 窗口关闭后仍能继续。

1. 开始前，智能体应说明本次是否需要重装，先备份并保存修复进度；需要管理员权限时，按 Windows 提示授权。
2. 重装期间，Codex 窗口会退出，当前修复对话可能中断，应用会暂时无法使用。这是安装过程中的预期现象，不代表配置或会话记录被清空。
3. 安装完成后，若 Codex 没有自动打开，就手动打开它，回到**原来的修复对话**发送“继续”，让智能体检查安装结果、完成验收和清理，不必重新开一轮修复。

这里的“重装”采用保留用户数据的原位更新，不是先卸载再安装。**如果安装明确报错，或安装完成后仍打不开，就需要按失败处理并排查，不能当作正常等待。**

可恢复安装器会在日志旁保留独立的状态文件，记录源版本、目标版本、安装进程、验收和清理结果。重启后可用 `scripts/get-model-experience-repair-status.ps1 -StatePath <状态文件路径>` 只读查询；如果又更新了 Codex，应先确认新版本是否已替代旧修复，避免重复安装。详细步骤和配置变更核对见[更新后续接与验收](references/post-update-verification.md)。

ASAR 解包和打包优先复用 npm 缓存中可运行的本地工具，不依赖 npm 的在线索引或离线索引元数据；仅在没有可用工具时沿用 npx/pnpm 获取方式。已选定工具执行失败时直接停止，不通过重新下载掩盖归档错误。正式打包在复制应用目录之前检查 Windows SDK 工具，避免完成耗时补丁后才发现缺少打包依赖；现有有效 SDK 缓存可复用。

## 更多帮助

| 想了解什么 | 文档 |
| --- | --- |
| 完整执行流程、参数和备份操作 | [SKILL.md](SKILL.md)，供智能体与维护者按需查阅 |
| 模型、浏览器、插件或安装故障 | [常见问题排查](references/restriction-debug-cases.md) |
| 重启后项目归属与归档错误提示 | [项目与归档状态修复](references/project-archive-state.md) |
| dots 新入口缺失、账号与云端访问条件 | [dots 只读诊断](references/dots-diagnostics.md)，不包含云端资格解锁 |
| 手机远控的授权、配对和 API 问题 | [手机远控排查](references/remote-control-debug-cases.md) |
| Win10 截图的适用版本与验证范围 | [Win10 截图兼容说明](references/win10-computer-use-screenshot-backend.md) |
| 本机是 Win11，如何分析和验证 Win10 截图问题 | [Win10 客体与独立验证工具](references/win10-validation-on-win11.md) |

仍有问题请[提交 issue](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/new)，附上 Windows / Codex 版本、问题现象和脱敏日志。不要上传 `auth.json`、API key、OAuth token 或浏览器资料；敏感信息处理见 [SECURITY.md](SECURITY.md)。

<p align="center">感谢 <a href="https://linux.do/">LinuxDo 社区</a> 的讨论与反馈。</p>
