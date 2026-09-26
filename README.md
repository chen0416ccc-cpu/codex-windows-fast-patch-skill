<div align="center">

<img src="assets/readme-mark.svg" width="104" height="104" alt="">

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

> [!WARNING]
> **仅支持 Windows。部分修复包含重新安装 Codex 的步骤。** 期间应用会关闭，当前对话可能中断；安装完成后重新打开 Codex，回到原修复对话发送“继续”即可接着处理。具体见[重装说明](#哪些修复会重新安装-codex)。

## 能修复什么

| 问题 | 覆盖范围 |
| --- | --- |
| **模型与速度选项缺失** | Fast Mode、被隐藏的已有模型、Power 拖动条、Ultra 开关 |
| **界面与插件异常** | 语言重置、Goal 等入口消失、插件市场与安装按钮不可用 |
| **浏览器不可用** | 内置浏览器、Chrome 控制、自定义供应商下特定的登录依赖错误 |
| **电脑操控异常** | Computer Use / Any App、跨调用窗口操作、部分 Win10 截图故障 |
| **手机远控失效** | 入口、二维码、配对和版本过期问题，保留第三方 API 主使用方式 |
| **会话异常** | 新建对话 `inputSchema` 报错、切换供应商后历史消失、恢复后目录缺失 |
| **配置管理** | 配置、技能和市场的备份恢复 |
| **配置听话水** | 配置 skill 内置的系统提示词文件及 `model_instructions_file` |

手机远控和听话水配置（`model_instructions_file`）均为可选流程，不会随普通修复自动启用。

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
浏览器和电脑操控问题。保留我的配置与会话，完成后实际验证并清理临时文件。
```

**需要手机远控时单独提出：**

```text
使用 codex-windows-fast-patch 修复手机远控，
保留我的第三方 API 配置、原有登录和会话记录。
```

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

智能体修复前会检查仓库更新。通过 `git clone` 安装的副本也可以手动更新：

```powershell
git -C $SkillRoot pull --ff-only
```

这是更新修复工具，不是更新 Codex 客户端。有本地修改或分支冲突时先处理冲突，不要强行覆盖。通过插件或压缩包安装的非 Git 副本，需要从原安装渠道更新。

## 哪些修复会重新安装 Codex

是否重装取决于故障原因，不是每次使用 skill 都会重装：

| 修复内容 | 通常的处理方式 |
| --- | --- |
| Fast Mode、Power/Ultra、客户端过滤导致的模型不显示 | 修改客户端后重新安装 |
| 语言重置、Goal / 插件 / 浏览器 / Any App 的客户端入口异常 | 修改客户端后重新安装 |
| 手机远控的入口、配对或版本问题，新建对话 `inputSchema` 报错 | 需要修改客户端或原生程序时重新安装 |
| Chrome / Computer Use 的缓存、运行时路径、市场配置，以及已支持的 Chrome 登录依赖错误 | 通常只修本地环境，不重装 |
| 模型目录补全、历史会话可见性、缺失工作目录、备份与听话水配置、配对后的 API 地址 | 通常只改配置或数据，不重装 |

同样是“浏览器不能用”或“模型不显示”，也可能只是缓存或配置问题，以实际检查结果为准。

### 重装期间会发生什么

**可以直接在当前 Codex 对话里发起修复。** 需要安装时，由智能体安排独立安装进程接手，让安装在 Codex 窗口关闭后仍能继续。

1. 开始前，智能体应说明本次是否需要重装，先备份并保存修复进度；需要管理员权限时，按 Windows 提示授权。
2. 重装期间，Codex 窗口会退出，当前修复对话可能中断，应用会暂时无法使用。这是安装过程中的预期现象，不代表配置或会话记录被清空。
3. 安装完成后，若 Codex 没有自动打开，就手动打开它，回到**原来的修复对话**发送“继续”，让智能体检查安装结果、完成验收和清理，不必重新开一轮修复。

这里的“重装”采用保留用户数据的原位更新，不是先卸载再安装。**如果安装明确报错，或安装完成后仍打不开，就需要按失败处理并排查，不能当作正常等待。**

## 更多帮助

| 想了解什么 | 文档 |
| --- | --- |
| 完整执行流程、参数和备份操作 | [SKILL.md](SKILL.md)，供智能体与维护者按需查阅 |
| 模型、浏览器、插件或安装故障 | [常见问题排查](references/restriction-debug-cases.md) |
| 手机远控的授权、配对和 API 问题 | [手机远控排查](references/remote-control-debug-cases.md) |
| Win10 截图的适用版本与验证范围 | [Win10 截图兼容说明](references/win10-computer-use-screenshot-backend.md) |

仍有问题请[提交 issue](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/new)，附上 Windows / Codex 版本、问题现象和脱敏日志。不要上传 `auth.json`、API key、OAuth token 或浏览器资料；敏感信息处理见 [SECURITY.md](SECURITY.md)。

<p align="center">感谢 <a href="https://linux.do/">LinuxDo 社区</a> 的讨论与反馈。</p>
