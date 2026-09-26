# Codex Windows Fast Patch Skill

[中文](README.md) | English

Let an AI assistant repair model lists, browser access, computer control, and other features that stop working after Windows Codex Desktop updates.

This community-maintained **Agent Skill** contains diagnostic workflows and repair scripts. It is not an official client or a universal one-click installer.

> **Windows only.** If a repair needs to close, repackage, or update Codex Desktop, run it from the Codex extension in VS Code or an independent external PowerShell session. Do not let the Desktop session being repaired update itself. Read-only checks and local configuration or plugin-cache repairs can usually run in the current session.

## What it repairs

| Problem | Coverage |
| --- | --- |
| Missing models or speed controls | Fast Mode, hidden existing model entries, the Power slider, and the Ultra toggle |
| UI or plugin issues | Language resets, missing Goal entries, unavailable marketplaces or install buttons |
| Unavailable browser access | In-app browser, Chrome control, and specific authentication-dependency errors with custom providers |
| Computer-control failures | Computer Use / Any App, cross-call window operations, and some Windows 10 screenshot failures |
| Broken phone remote control | Missing entry points, QR codes, pairing, or expired-version errors while retaining third-party API use |
| Conversation failures | New-chat `inputSchema` errors, history hidden after provider changes, and missing working directories after recovery |
| Configuration management | Configuration, skill, and marketplace backup/restore, plus custom model instructions |

Phone remote control and custom model instructions (`model_instructions_file`) are optional workflows, not enabled automatically by an ordinary repair.

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

Describe the problem to your AI assistant, for example:

```text
Use codex-windows-fast-patch to inspect and repair the model-list,
browser, and computer-control issues after my Codex update. Preserve my
configuration and conversations, verify real operations, and clean up temporary files.
```

Request phone remote control separately:

```text
Use codex-windows-fast-patch to repair phone remote control while keeping
my third-party API configuration, existing login, and conversation history.
```

**Does Chrome require another login?** For a provider explicitly configured with `requires_openai_auth=false`, the skill can repair the `Codex auth token is unavailable` error on specifically supported versions, keeping agent request headers enabled without borrowing phone credentials. This is not a general bypass for authentication failures. See the [Chrome compatibility conditions](references/restriction-debug-cases.md#chrome-custom-provider-request-header-authentication-dependency).

### Check without making changes

This command checks the local Chrome / Computer Use environment without applying repairs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SkillRoot\scripts\install-computer-use-local.ps1" -StrictVerifyOnly
```

`-VerifyOnly` can apply repairs and is **not read-only**. To check the availability of all bundled plugins, see [local runtime verification](SKILL.md#computer-use-only). Available plugins do not all need to be installed.

## Update

The agent checks for repository updates before repairs. You can also update a Git-cloned installation manually:

```powershell
git -C $SkillRoot pull --ff-only
```

This updates the repair tool, not Codex Desktop. Resolve local changes or branch conflicts without force-overwriting them. Non-Git copies installed through a plugin or archive need updating through their original installation channel.

## Before running a repair

- **Back up before changing anything.** Preserve conversations, authentication, and user settings; do not bulk-enable unrelated plugins. Desktop state normally lives in `$env:USERPROFILE\.codex`. Do not set a global `CODEX_HOME` or move that state into an isolated CLI home. See [backup and restore](SKILL.md#backup-management).
- **Update in place, without uninstalling first.** Run the relevant `-DryRun`, check package signature, identity, and deployment permissions, then install a higher-version update. Packages containing system services require normal UAC administrator approval.
- **Prepare recovery before deployment.** Separately prepare a validly signed recovery MSIX containing the original program files at a version higher than the update. Ordinary installation entrypoints do not generate it automatically. See the [safe deployment workflow](SKILL.md#external-executor-for-desktop-restarting-repairs).
- **Verify real operations.** Depending on the repair, interact with the browser, capture a window, or send a message from the phone. A successful script exit or read-only check does not establish that every feature was tested.
- **Clean up after acceptance.** Remove extraction directories, installed patch-package artifacts, temporary SDKs, and task-local caches. Keep the installed app, active runtimes, necessary logs, and explicit backups. Prefer a non-system drive for large artifacts.

## More help

| Looking for | Documentation |
| --- | --- |
| Complete workflows, parameters, and backup commands | [SKILL.md](SKILL.md), the on-demand guide for agents and maintainers |
| Model, browser, plugin, or installation troubleshooting | [Troubleshooting cases](references/restriction-debug-cases.md) |
| Phone authorization, pairing, and API issues | [Phone remote-control troubleshooting](references/remote-control-debug-cases.md) |
| Supported Windows 10 screenshot profiles and validation scope | [Windows 10 screenshot compatibility](references/win10-computer-use-screenshot-backend.md) |

Still stuck? [Open an issue](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/issues/new) with your Windows and Codex versions, symptoms, and redacted logs. Do not upload `auth.json`, API keys, OAuth tokens, or browser profiles. See [SECURITY.md](SECURITY.md) for handling sensitive material.

Thanks to the [LinuxDo community](https://linux.do/) for discussions and feedback.
