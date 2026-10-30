<div align="center">

<img src="assets/readme-mark.png" width="104" height="104" alt="">

<h1>Codex Windows Fast Patch Skill</h1>

<p>Let an AI assistant repair model lists, browser access, computer control, and other features that stop working after Windows Codex Desktop updates.</p>

<p>
  <img src="https://img.shields.io/badge/Windows-0078D4?style=flat-square" alt="Windows">
  <img src="https://img.shields.io/badge/Agent%20Skills-2563EB?style=flat-square" alt="Agent Skills">
  <img src="https://img.shields.io/badge/PowerShell-475569?style=flat-square" alt="PowerShell">
</p>

<p><a href="README.md">中文</a> &nbsp;/&nbsp; <strong>English</strong></p>

<p>
  <a href="#what-it-repairs">Features</a> &nbsp;·&nbsp;
  <a href="#install">Install</a> &nbsp;·&nbsp;
  <a href="#use">Use</a> &nbsp;·&nbsp;
  <a href="#update">Update</a> &nbsp;·&nbsp;
  <a href="#which-repairs-reinstall-codex">Reinstallation</a> &nbsp;·&nbsp;
  <a href="#more-help">More help</a>
</p>

</div>

This community-maintained **Agent Skill** contains diagnostic workflows and repair scripts. It is not an official client or a universal one-click installer.

> [!WARNING]
> **Windows only. Some repairs include reinstalling Codex.** The app will close and the current conversation may be interrupted. After installation, reopen Codex, return to the original repair conversation, and send "continue" to resume. See the [reinstallation details](#which-repairs-reinstall-codex).

## What it repairs

| Problem | Coverage |
| --- | --- |
| **Missing models or speed controls** | Fast Mode, hidden existing model entries, the Power slider, and the Ultra toggle |
| **UI or plugin issues** | Language resets, missing Goal entries, unavailable marketplaces or install buttons, and client-filtered Image-guided Assets |
| **Unavailable browser access** | In-app browser, Chrome control, and specific authentication-dependency errors with custom providers |
| **Computer-control failures** | Computer Use / Any App, cross-call window operations, and some Windows 10 screenshot failures |
| **Broken phone remote control** | Missing entry points, QR codes, pairing, or expired-version errors while retaining third-party API use |
| **Conversation failures** | New-chat `inputSchema` errors, history hidden after provider changes, and missing working directories after recovery |
| **Configuration management** | Configuration, skill, and marketplace backup/restore |
| **Configure Tinghuashui (听话水)** | Configure the skill's bundled system-prompt file and `model_instructions_file` |

Phone remote control and Tinghuashui configuration (`model_instructions_file`) are optional workflows, not enabled automatically by an ordinary repair.

Compatibility depends on the installed version and file contents; do not apply an old patch to an unknown version. Your provider must actually supply the requested models; this project provides no model API or quota. History recovery requires the local history data to still exist, and recreating a missing directory does not recover deleted project files.

## Install

You need Windows Codex Desktop, Git, and an AI assistant that supports Agent Skills. Run in PowerShell:

```powershell
$SkillRoot = "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch"
git clone https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill.git $SkillRoot
```

This installs only the skill; it does not reinstall Codex. Restart the AI assistant afterwards so it loads the skill.

For Claude Code, change the destination to `$env:USERPROFILE\.claude\skills\codex-windows-fast-patch`; other clients use their own skills directories. In the commands below, `$SkillRoot` must point to your actual installation. If already installed, use the update instructions instead of cloning again.

## Use

**Describe the problem to your AI assistant, for example:**

```text
Use codex-windows-fast-patch to inspect and repair the model-list,
browser, and computer-control issues after my Codex update. Preserve my
configuration and conversations, run background verification, and clean up temporary files.
```

Verification defaults to background read-only checks. It does not automatically open Calculator or another test app, change native-window focus, or inject mouse/keyboard input. Runtime, plugin, and window-enumeration results are reported separately. Live native screenshot/input tests run only when explicitly requested or authorized, and untested operations are identified as such.

External-browser extension verification accepts Chrome or Edge. For an Edge-only installation, the official diagnostic checks Edge's own profile root; installing the extension in Chrome or mapping one browser's user directory to another is unnecessary. Actual page access still requires separate verification.

**Request phone remote control separately:**

```text
Use codex-windows-fast-patch to repair phone remote control while keeping
my third-party API configuration, existing login, and conversation history.
```

### Check and recover after an update

The repository includes a reusable entry point instead of a script copied from a repair chat:

```powershell
& "$SkillRoot\scripts\codex-after-update.ps1"
& "$SkillRoot\scripts\codex-after-update.ps1" -CheckApp
& "$SkillRoot\scripts\codex-after-update.ps1" -RepairPlugins -RepairApp
```

The first command checks the current package transaction, live model catalog and plugin/runtime contracts. A package without its own accepted checkpoint returns `app-check-needed`; passing plugin checks does not establish that app patches survived. `-CheckApp` also runs the full package dry run, checking locale, plugins, browser/Computer Use, Fast and Ultra paths, then removes its temporary package copy. Use `-CheckRoot 'D:\CodexChecks'` to select a temporary directory with enough free space.

The third command explicitly repairs plugins and dispatches the recoverable full non-phone installer only when a compatible dry run establishes missing patches. Deployment requests normal UAC and restarts Desktop. A pending installed target resumes acceptance instead of redeploying; running or unknown installer state blocks another launch.

Model visibility overrides default to the active provider's visible `model/list` entries plus its selected default, preserving the catalog's reasoning/service tiers. Supply `-CustomModels @('your-model-a','your-model-b')` to override this list; it never creates model or speed capabilities. The recoverable launcher also resolves live defaults and stops on probe failure instead of silently falling back to an old hard-coded list.

The entry point emits a JSON status. `-ReportPath '<new-report-path>.json'` saves it without overwriting existing files. `-WhatIf` permits diagnostics, but does not repair plugins, dispatch an installer or save a report. Full bundle inspection uses temporary disk space and does not modify the installed application. No scheduled task, monitor or automatic restart is registered. Store updates can still replace patched files; this workflow detects and restores supported paths after an update, and rejects unknown layouts before installation. It cannot guarantee compatibility with arbitrary future releases. See [post-update verification](references/post-update-verification.md).

### Configure Tinghuashui (听话水)

"听话水" (Tinghuashui) is this project's name for its bundled system prompt. Send this request to your agent:

```text
帮我进行听话水相关的配置
```

The agent uses [`assets/system-prompt.md`](assets/system-prompt.md), configures the system-prompt file, and sets `model_instructions_file` in `config.toml`. Afterwards, follow its instructions to start a new session or restart Codex so the configuration takes effect.

<details>
<summary><strong>Does Chrome require another login?</strong></summary>

For a provider explicitly configured with `requires_openai_auth=false`, the skill can repair the `Codex auth token is unavailable` error on specifically supported versions, keeping agent request headers enabled without borrowing phone credentials. This is not a general bypass for authentication failures. See the [Chrome compatibility conditions](references/restriction-debug-cases.md#chrome-custom-provider-request-header-authentication-dependency).

</details>

## Update

Before every update or patch, fetch and review both your fork's `main` and upstream `main`, then compare the installed skill and existing PRs. Reuse remote fixes and add only missing fixes or optimizations supported by actual evidence. A Git-cloned installation can fast-forward after review:

```powershell
git -C $SkillRoot fetch origin
git -C $SkillRoot fetch upstream
git -C $SkillRoot pull --ff-only
```

Verify that `origin` is your fork and `upstream` is the original repository; configure a missing remote using the [remote review and publication workflow](references/remote-review-and-publication.md). Non-Git installations must also compare through a persistent source checkout while preserving their local overlay.

This updates the repair tool, not Codex Desktop. Validate necessary increments, commit them, push your `main`, and create or update an upstream PR. Record the commit, base/head and PR URL. Reuse effective commits/PRs without empty commits or duplicate PRs, and explicitly record network or authentication blocks.

## Which repairs reinstall Codex

Reinstallation depends on the cause of the problem, not simply on using this skill:

| Repair | Typical approach |
| --- | --- |
| Fast Mode, Power/Ultra, or models hidden by client-side filtering | Patch the client and reinstall |
| Language resets or broken client-side Goal / plugin / browser / Any App entry points | Patch the client and reinstall |
| Phone entry, pairing, or version issues; new-chat `inputSchema` errors | Reinstall when the client or native program needs changes |
| Chrome / Computer Use caches, runtime paths, marketplace configuration, or supported Chrome authentication-dependency errors | Usually repair the local environment without reinstalling |
| Model-catalog entries, history visibility, missing working directories, backups, Tinghuashui configuration, or post-pairing API addresses | Usually change configuration or data without reinstalling |

The same visible symptom, such as an unavailable browser or a missing model, may come from configuration or cache problems. Let the diagnosis determine the repair.

### What happens during reinstallation

**You can initiate the repair in your current Codex conversation.** When installation is needed, the agent arranges an independent installer so deployment can continue after the Codex window closes.

1. Before starting, the agent should explain whether reinstallation is needed, back up state, and save repair progress. Approve the Windows administrator prompt when required.
2. During reinstallation, the Codex window closes, the repair conversation may be interrupted, and the app is temporarily unavailable. This is an expected installation interruption, not a sign that configuration or conversation history has been erased.
3. Once installation finishes, open Codex if it has not reopened automatically. Return to the **original repair conversation** and send "continue" so the agent can check the installation, complete acceptance, and clean up. There is no need to start a new repair from scratch.

Here, "reinstallation" is an in-place update that preserves user data, not an uninstall followed by an install. **A reported installation error, or an app that still cannot start after installation finishes, is a failure to investigate, not normal waiting.**

The recoverable installer retains a separate state file beside its log, recording the source, target, installer process, acceptance and cleanup results. After a restart, inspect it read-only with `scripts/get-model-experience-repair-status.ps1 -StatePath <state-file>`. If Codex updates again, check whether the newer package supersedes the old repair before deploying anything twice. See [post-update resume and verification](references/post-update-verification.md), including configuration-change auditing.

ASAR extraction and packing first reuse a working CLI already installed in the npm cache, without requiring online registry access or cached registry metadata. Only when no usable tool is present does the existing npx/pnpm acquisition path run. A selected tool failure stops the operation rather than retrying a download and hiding an archive error. Non-dry-run builds resolve Windows SDK tools before copying the application tree, so missing packaging dependencies fail before expensive patch work; existing valid SDK caches remain reusable.

## More help

| Looking for | Documentation |
| --- | --- |
| Complete workflows, parameters, and backup commands | [SKILL.md](SKILL.md), the on-demand guide for agents and maintainers |
| Model, browser, plugin, or installation troubleshooting | [Troubleshooting cases](references/restriction-debug-cases.md) |
| Missing dots entry, account and cloud access requirements | [Read-only dots diagnostics](references/dots-diagnostics.md); does not unlock cloud eligibility |
| Phone authorization, pairing, and API issues | [Phone remote-control troubleshooting](references/remote-control-debug-cases.md) |
| Supported Windows 10 screenshot profiles and validation scope | [Windows 10 screenshot compatibility](references/win10-computer-use-screenshot-backend.md) |
| Investigating Windows 10 capture from a Windows 11 host | [Windows 10 guest and isolated diagnostic](references/win10-validation-on-win11.md) |

Still stuck? [Open an issue](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/new) with your Windows and Codex versions, symptoms, and redacted logs. Do not upload `auth.json`, API keys, OAuth tokens, or browser profiles. See [SECURITY.md](SECURITY.md) for handling sensitive material.

<p align="center">Thanks to the <a href="https://linux.do/">LinuxDo community</a> for discussions and feedback.</p>
