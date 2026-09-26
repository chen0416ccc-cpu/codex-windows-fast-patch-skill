# Codex Windows Fast Patch Skill

中文 | [English](README.en.md)

让 AI 助手修复 Windows 版 Codex Desktop 更新后失效的模型列表、浏览器、电脑操控等功能。

这是社区维护的 **Agent Skill**，提供诊断流程与修复脚本，不是官方客户端，也不是适用于所有版本的一键安装器。

> **仅支持 Windows。** 如果修复需要关闭、重打包或更新 Codex Desktop，请从 VS Code 的 Codex 扩展或独立外部 PowerShell 执行，不要让正在修复的 Desktop 会话更新自己。仅检查或修复本地配置、插件缓存时，通常可以留在当前会话。

## 能修复什么

| 问题 | 覆盖范围 |
| --- | --- |
| 模型与速度选项缺失 | Fast Mode、被隐藏的已有模型、Power 拖动条、Ultra 开关 |
| 界面与插件异常 | 语言重置、Goal 等入口消失、插件市场与安装按钮不可用 |
| 浏览器不可用 | 内置浏览器、Chrome 控制、自定义供应商下特定的登录依赖错误 |
| 电脑操控异常 | Computer Use / Any App、跨调用窗口操作、部分 Win10 截图故障 |
| 手机远控失效 | 入口、二维码、配对和版本过期问题，保留第三方 API 主使用方式 |
| 会话异常 | 新建对话 `inputSchema` 报错、切换供应商后历史消失、恢复后目录缺失 |
| 配置管理 | 配置、技能和市场的备份恢复，自定义模型指令 |

手机远控和自定义模型指令（`model_instructions_file`）均为可选流程，不会随普通修复自动启用。

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

安装后，直接向 AI 助手描述问题，例如：

```text
使用 codex-windows-fast-patch，检查并修复 Codex 更新后的模型列表、
浏览器和电脑操控问题。保留我的配置与会话，完成后实际验证并清理临时文件。
```

需要手机远控时单独提出：

```text
使用 codex-windows-fast-patch 修复手机远控，
保留我的第三方 API 配置、原有登录和会话记录。
```

**Chrome 是否需要额外登录？** 对于明确配置 `requires_openai_auth=false` 的供应商，支持修复特定版本的 `Codex auth token is unavailable` 错误，且保持代理请求头开启、不借用手机授权。这不是所有登录问题的通用绕过，具体条件见[Chrome 兼容说明](references/restriction-debug-cases.md#chrome-custom-provider-request-header-authentication-dependency)。

### 只检查，不修改

以下命令只检查 Chrome / Computer Use 的本地环境，不执行修复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\install-computer-use-local.ps1" -StrictVerifyOnly
```

注意：`-VerifyOnly` 会执行部分修复，**不等于只读**。需要检查全部随包插件可用性时，参阅[本地运行时检查](SKILL.md#computer-use-only)，不要把“可用”误当作“应全部安装”。

## 更新

智能体修复前会检查仓库更新。通过 `git clone` 安装的副本也可以手动更新：

```powershell
git -C $SkillRoot pull --ff-only
```

这是更新修复工具，不是更新 Codex 客户端。有本地修改或分支冲突时先处理冲突，不要强行覆盖。通过插件或压缩包安装的非 Git 副本，需要从原安装渠道更新。

## 使用前须知

- **先备份，再修改。** 保留会话、认证和用户设置，不批量启用无关插件。默认状态目录是 `$env:USERPROFILE\.codex`，不要设置全局 `CODEX_HOME` 或把它搬进隔离 CLI 目录。手动操作见[备份与恢复](SKILL.md#backup-management)。
- **更新不先卸载。** 客户端补丁先通过 `-DryRun`，再检查签名、身份和安装权限，使用递增版本的原位更新。含系统服务的包需要正常 UAC 管理员授权。
- **部署前准备恢复包。** 另行准备含原程序内容、签名有效且版本高于更新包的恢复 MSIX；普通安装入口不会自动生成它。详见[安全部署流程](SKILL.md#external-executor-for-desktop-restarting-repairs)。
- **真实操作才算验收。** 按修复范围实际操作浏览器、截图窗口或从手机发送消息。脚本退出成功、只读检查通过，不代表所有功能都已实测。
- **验收后清理。** 删除解包目录、已安装补丁的安装产物、临时 SDK 和任务缓存；保留在用程序、运行时、必要日志和明确备份。大文件优先放在非系统盘。

## 更多帮助

| 想了解什么 | 文档 |
| --- | --- |
| 完整执行流程、参数和备份操作 | [SKILL.md](SKILL.md)，供智能体与维护者按需查阅 |
| 模型、浏览器、插件或安装故障 | [常见问题排查](references/restriction-debug-cases.md) |
| 手机远控的授权、配对和 API 问题 | [手机远控排查](references/remote-control-debug-cases.md) |
| Win10 截图的适用版本与验证范围 | [Win10 截图兼容说明](references/win10-computer-use-screenshot-backend.md) |

仍有问题请[提交 issue](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/new)，附上 Windows / Codex 版本、问题现象和脱敏日志。不要上传 `auth.json`、API key、OAuth token 或浏览器资料；敏感信息处理见 [SECURITY.md](SECURITY.md)。

感谢 [LinuxDo 社区](https://linux.do/) 的讨论与反馈。
