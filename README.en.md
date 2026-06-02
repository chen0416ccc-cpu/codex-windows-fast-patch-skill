# Codex Windows Fast Patch Skill

Language: [中文](README.md) | English

This is the public version of the `codex-windows-fast-patch` skill. It guides agents through restoring local Codex Desktop patches and feature gates after Windows Store upgrades.

## Features

- Reapply the Windows MSIX patch after Codex Desktop upgrades.
- Repair unavailable Fast Mode first, then verify that repaired requests really send `service_tier=priority`.
- Register and repair local plugin marketplace configuration.
- Repair local plugin marketplace manifest layout.
- Refresh Windows Computer Use compatibility files.
- Unlock the Computer Control `Any App` gate when the UI reports organization or region unavailability.
- Keep the Codex Mobile / Connections remote-control setup flow from redirecting, error-looping, or becoming hard to close when remote-control auth is missing.
- Create a timestamped backup before overwriting `config.toml`, reducing the risk of accidental config loss.
- Provide ccswitch-style local Codex state backup management for `config.toml`, MCP configuration, skills, and marketplaces.
- Before each substantive use, automatically try syncing the latest workflow from GitHub so the local skill stays ready for newly discovered issues; network failures do not block the repair.

## Platform Support

This skill supports Windows only.

It depends on the Windows Store / MSIX package layout, PowerShell, `Get-AppxPackage`, `makeappx.exe`, `signtool.exe`, Windows user environment variables, and Windows Computer Use helper paths.

Do not run it on macOS. A macOS version needs a separate workflow for the Codex `.app` bundle, ASAR extraction and repacking, `codesign` or quarantine handling, shell scripts, and macOS-specific Computer Use availability gates.

## Files

- `SKILL.md`: Agent skill entrypoint.
- `agents/openai.yaml`: Agent configuration.
- `scripts/repatch-codex-windows.ps1`: Workflow reference script.
- `scripts/patch_codex_fast_mode_windows_msix.ps1`: MSIX / ASAR patch reference implementation.
- `scripts/install-computer-use-local.ps1`: Windows Computer Use local compatibility reference implementation.
- `scripts/manage-codex-backups.ps1`: Backup manager for local Codex config, MCP, skills, and marketplaces.
- `scripts/update-skill-from-github.ps1`: Best-effort self-update script that syncs the latest GitHub version before use.
- `references/restriction-debug-cases.md`: On-demand cases for restriction gates, Computer Use, mobile entry failures, and CPA Fast Mode.

## Install

Clone this repository, open PowerShell in the repository root, then copy only the skill files:

```powershell
$source = (Get-Location).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
  throw 'Run this command from the codex-windows-fast-patch-skill repository root.'
}

$dest = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Copy-Item -Force -LiteralPath (Join-Path $source 'SKILL.md') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'agents') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'scripts') -Destination $dest
Copy-Item -Recurse -Force -LiteralPath (Join-Path $source 'references') -Destination $dest
```

After installing into Codex, restart Codex so it reloads skill metadata.

## Usage

After installation, ask an agent that supports Agent Skills to use the `codex-windows-fast-patch` workflow for the Codex Desktop issue on the current machine.

This skill supports self-updating: before each substantive use, the agent first tries to check GitHub and sync the latest version, so you do not need to repeatedly return to GitHub and pull updates manually. This keeps the local skill as close as possible to the latest known workflow for newly discovered issues; if the network is unavailable, GitHub cannot be reached, or the download fails, that update step is skipped and the agent should continue with the currently installed local version.

The scripts are reference implementations and operational templates, not a one-command fix that is guaranteed to work on every machine. A real run should first read `SKILL.md`, inspect the current Codex installation method, MSIX package path, ASAR contents, signing tools, plugin directories, and Computer Use file state, then decide whether to execute, adapt, or only borrow steps from the scripts.

Example request: `Use the codex-windows-fast-patch skill to inspect and repair Codex Desktop Fast Mode, plugin marketplace, and Computer Use availability on this Windows machine.`

## Backup Management

Repair scripts automatically back up the previous `config.toml` into `.codex\backups\config\` before writing it. To manually back up or migrate important local Codex state, use the standalone backup manager:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Backup
```

List existing backups:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action List
```

Restore from a backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\manage-codex-backups.ps1" -Action Restore -BackupPath "<backup path>"
```

By default, the backup includes custom skills, marketplaces, `config.toml`, extracted `mcp_servers.json`, and `chrome-native-hosts.json`, while excluding easy-to-grow directories such as `.git`, `node_modules`, build outputs, and virtual environments. Use `-IncludeDependencyDirs` only when an exact offline dependency copy is needed; plugin cache and `.tmp\bundled-marketplaces` can also be large, so include them only when needed with `-IncludePluginCache` or `-IncludeTmpBundledMarketplaces`.

## CPA Upstream Configuration

If Codex requests go through CPA upstream, changing the local request to `service_tier=priority` is not enough by itself. Add a CPA override rule for the models that handle Codex requests and force the parameter `service_tier` to string value `priority`, so the upstream actually uses the Fast / Priority path.

The model names in the image are examples. Use the real Codex-facing model names configured in CPA.

![CPA override rule example](assets/cpa-override-rule.svg)

## Acknowledgements

Thanks to the [LinuxDo community](https://linux.do/) for the discussions and feedback around this workflow.
