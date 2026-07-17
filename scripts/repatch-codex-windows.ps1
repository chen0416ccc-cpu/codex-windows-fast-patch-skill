[CmdletBinding()]
param(
  [string]$PatchScript,
  [string]$MarketplacePath = (Join-Path $env:USERPROFILE '.codex\marketplaces\openai-curated-local'),
  [switch]$DryRun,
  [switch]$NoLaunch,
  [switch]$SkipFastVerify,
  [switch]$SkipSdkCleanup,
  [switch]$KeepBuild,
  [switch]$SkipMarketplace,
  [switch]$SkipComputerUse,
  [switch]$RegisterMarketplaceOnly,
  [switch]$ForceRebuild,
  [string]$OutputRoot,
  [switch]$InstallModelInstructionsFile,
  [string]$ModelInstructionsSource,
  [string]$ModelInstructionsDestination = (Join-Path $env:USERPROFILE '.codex\prompts\system-prompt.md')
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-windows-fast-patch]'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($PatchScript)) {
  $PatchScript = Join-Path $ScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
}
$ComputerUseScript = Join-Path $ScriptRoot 'install-computer-use-local.ps1'
$ModelInstructionsScript = Join-Path $ScriptRoot 'install-model-instructions-file.ps1'
$script:ConfigBackupBeforeOverwrite = @{}

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Find-CodexCli {
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (Test-Path -LiteralPath $binRoot) {
    $hit = Get-ChildItem -LiteralPath $binRoot -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($hit) {
      return $hit.FullName
    }
  }

  $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source -notlike '*\WindowsApps\OpenAI.Codex_*\app\resources\codex.exe') {
    return $cmd.Source
  }

  return $null
}

function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$ErrorMessage
  )

  Write-Log "$FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ErrorMessage (exit code $LASTEXITCODE)"
  }
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Backup-ConfigBeforeOverwrite {
  param(
    [string]$ConfigPath,
    [string]$Reason = 'config-write'
  )

  if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return
  }

  $fullPath = [System.IO.Path]::GetFullPath($ConfigPath)
  if ($script:ConfigBackupBeforeOverwrite.ContainsKey($fullPath)) {
    return
  }

  $configDir = Split-Path -Parent $fullPath
  $backupRoot = Join-Path $configDir 'backups\config'
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

  $safeReason = ([string]$Reason -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeReason)) {
    $safeReason = 'config-write'
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $backupPath = Join-Path $backupRoot "config.toml.$stamp.$safeReason.bak"
  Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
  $script:ConfigBackupBeforeOverwrite[$fullPath] = $backupPath
  Write-Log "config.toml backup before overwrite: $backupPath"
}

function Set-TomlTable {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [hashtable]$Values
  )

  $content = ''
  if (Test-Path -LiteralPath $ConfigPath) {
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  }

  $lines = foreach ($key in ($Values.Keys | Sort-Object)) {
    $value = $Values[$key]
    if ($value -is [bool]) {
      "$key = $($value.ToString().ToLowerInvariant())"
    } else {
      $escaped = [string]$value -replace "'", "''"
      "$key = '$escaped'"
    }
  }
  $body = ($lines -join "`r`n") + "`r`n"
  $escapedHeader = [regex]::Escape($Header)
  $pattern = "(?ms)^$escapedHeader\s*\r?\n(?:(?!^\[).)*"
  $replacement = "$Header`r`n$body"

  if ([regex]::IsMatch($content, $pattern)) {
    $content = [regex]::Replace($content, $pattern, $replacement, 1)
  } else {
    if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) {
      $content += "`r`n"
    }
    if ($content.Length -gt 0 -and -not $content.EndsWith("`r`n`r`n")) {
      $content += "`r`n"
    }
    $content += $replacement
  }

  Backup-ConfigBeforeOverwrite $ConfigPath "set-$Header"
  Write-Utf8NoBom $ConfigPath $content
}

function Set-TomlTableValue {
  param(
    [string]$ConfigPath,
    [string]$Header,
    [string]$Key,
    [object]$Value
  )

  $content = ''
  if (Test-Path -LiteralPath $ConfigPath) {
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false))
  }

  if ($Value -is [bool]) {
    $valueText = $Value.ToString().ToLowerInvariant()
  } else {
    $escaped = [string]$Value -replace "'", "''"
    $valueText = "'$escaped'"
  }
  $line = "$Key = $valueText"
  $escapedHeader = [regex]::Escape($Header)
  $escapedKey = [regex]::Escape($Key)
  $tablePattern = "(?ms)^$escapedHeader\s*\r?\n(?<body>(?:(?!^\[).)*)"

  if ([regex]::IsMatch($content, $tablePattern)) {
    $content = [regex]::Replace($content, $tablePattern, {
      param($match)
      $body = $match.Groups['body'].Value
      $keyPattern = "(?m)^\s*$escapedKey\s*=.*$"
      if ([regex]::IsMatch($body, $keyPattern)) {
        $body = [regex]::Replace($body, $keyPattern, $line, 1)
      } else {
        if ($body.Length -gt 0 -and -not $body.EndsWith("`n")) {
          $body += "`r`n"
        }
        $body += "$line`r`n"
      }
      return "$Header`r`n$body"
    }, 1)
  } else {
    if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) {
      $content += "`r`n"
    }
    if ($content.Length -gt 0 -and -not $content.EndsWith("`r`n`r`n")) {
      $content += "`r`n"
    }
    $content += "$Header`r`n$line`r`n"
  }

  Backup-ConfigBeforeOverwrite $ConfigPath "set-$Header-$Key"
  Write-Utf8NoBom $ConfigPath $content
}

function Test-TomlSyntax {
  param([string]$ConfigPath)

  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python not found; skipping tomllib syntax validation'
    return
  }

  $script = @'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
tomllib.loads(path.read_text(encoding="utf-8"))
'@
  $temp = Join-Path $env:TEMP ('codex-toml-validate-' + [guid]::NewGuid().ToString('N') + '.py')
  try {
    Write-Utf8NoBom $temp $script
    & $python.Source $temp $ConfigPath
    if ($LASTEXITCODE -ne 0) {
      throw "tomllib validation failed for $ConfigPath"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

function Repair-LocalMarketplaceManifestLayout {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $supportedManifest = Join-Path $Path '.agents\plugins\marketplace.json'
  $legacyManifest = Join-Path $Path 'marketplace.json'
  if ((Test-Path -LiteralPath $supportedManifest) -or -not (Test-Path -LiteralPath $legacyManifest)) {
    return
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $supportedManifest) | Out-Null
  Copy-Item -LiteralPath $legacyManifest -Destination $supportedManifest -Force
  Write-Log "repaired marketplace manifest layout: $supportedManifest"
}

function Repair-KnownLocalMarketplaceLayouts {
  param([string[]]$Paths)

  foreach ($candidate in ($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    Repair-LocalMarketplaceManifestLayout $candidate
  }
}

function Invoke-ComputerUseInstaller {
  param(
    [string]$Stage,
    [switch]$VerifyOnly
  )

  if (-not (Test-Path -LiteralPath $ComputerUseScript)) {
    throw "Computer Use installer not found: $ComputerUseScript"
  }

  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ComputerUseScript)
  $mode = 'install'
  if ($VerifyOnly) {
    $args += '-VerifyOnly'
    $mode = 'verify/repair'
  }

  Write-Log "Computer Use ${mode}: $Stage"
  Invoke-Checked 'powershell' $args "Computer Use $mode failed"
  $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = '1'
  Enable-ComputerUseFeature
}

function Enable-ComputerUseFeature {
  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  Set-TomlTableValue $configPath '[features]' 'computer_use' $true
  Set-TomlTableValue $configPath '[windows]' 'sandbox' 'unelevated'
  Test-TomlSyntax $configPath
  Write-Log 'local feature enabled: features.computer_use = true'
  Write-Log 'Windows sandbox mode set: windows.sandbox = unelevated'
}

function Invoke-ModelInstructionsInstaller {
  if (-not (Test-Path -LiteralPath $ModelInstructionsScript)) {
    throw "model instructions installer not found: $ModelInstructionsScript"
  }

  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ModelInstructionsScript)
  if (-not [string]::IsNullOrWhiteSpace($ModelInstructionsSource)) {
    $args += '-PromptSource'
    $args += $ModelInstructionsSource
  }
  if (-not [string]::IsNullOrWhiteSpace($ModelInstructionsDestination)) {
    $args += '-PromptDestination'
    $args += $ModelInstructionsDestination
  }

  Invoke-Checked 'powershell' $args 'model instructions file install failed'
}

function Register-LocalMarketplace {
  param([string]$Path)

  Repair-LocalMarketplaceManifestLayout $Path
  $manifest = Join-Path $Path '.agents\plugins\marketplace.json'
  if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Log "warning: local marketplace not found: $manifest"
    Write-Log 'warning: restore it from backup or re-extract it before registering marketplace'
    return
  }

  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
  $source = '\\?\' + $resolvedPath
  Set-TomlTable $configPath '[marketplaces.openai-curated-local]' @{
    last_updated = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = $source
    source_type = 'local'
  }
  Test-TomlSyntax $configPath
  Write-Log "local plugin marketplace configured: openai-curated-local -> $source"
}

function Show-Status {
  $pkg = Get-InstalledCodexPackage
  if ($pkg) {
    Write-Log "package: $($pkg.PackageFullName)"
    Write-Log "signature: $($pkg.SignatureKind)"
    Write-Log "install location: $($pkg.InstallLocation)"
  } else {
    Write-Log 'warning: OpenAI.Codex package not found'
  }

  $makeappx = Get-Command makeappx.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  Write-Log "makeappx.exe: $(if ($makeappx) { $makeappx.Source } else { '<missing>' })"
  Write-Log "signtool.exe: $(if ($signtool) { $signtool.Source } else { '<missing>' })"

  $helper = Join-Path $env:USERPROFILE '.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  $userEnv = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE', 'User')
  Write-Log "computer-use helper: $(if (Test-Path -LiteralPath $helper) { $helper } else { '<missing>' })"
  Write-Log "computer-use user env: $(if ($userEnv) { $userEnv } else { '<missing>' })"
}

function Get-InstalledCodexPackage {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  return $package
}

function Test-CodexPatchInstallResult {
  param(
    [object]$SourcePackage,
    [object]$FinalPackage
  )

  if (-not $SourcePackage) {
    return [pscustomobject]@{
      Success = $false
      Retryable = $false
      Reason = 'source OpenAI.Codex package was not found'
    }
  }
  if (-not $FinalPackage) {
    return [pscustomobject]@{
      Success = $false
      Retryable = $false
      Reason = 'OpenAI.Codex package is missing after repair'
    }
  }

  $sourceVersion = [string]$SourcePackage.Version
  $finalVersion = [string]$FinalPackage.Version
  $signatureKind = [string]$FinalPackage.SignatureKind
  if ($finalVersion -ne $sourceVersion) {
    return [pscustomobject]@{
      Success = $false
      Retryable = $signatureKind -eq 'Store'
      Reason = "Codex package changed during repair: source=$sourceVersion final=$finalVersion signature=$signatureKind"
    }
  }
  if ($signatureKind -ne 'Developer') {
    return [pscustomobject]@{
      Success = $false
      Retryable = $signatureKind -eq 'Store'
      Reason = "Codex repair did not leave a Developer-signed package: version=$finalVersion signature=$signatureKind"
    }
  }

  return [pscustomobject]@{
    Success = $true
    Retryable = $false
    Reason = "version=$finalVersion signature=$signatureKind"
  }
}

if (-not $SkipMarketplace) {
  Repair-KnownLocalMarketplaceLayouts @(
    $MarketplacePath,
    (Join-Path $env:USERPROFILE '.codex\marketplaces\local-imagegen')
  )
  Register-LocalMarketplace $MarketplacePath
}

if (-not $SkipComputerUse) {
  if ($DryRun) {
    Invoke-ComputerUseInstaller -Stage 'preflight before MSIX dry run' -VerifyOnly
  } else {
    Invoke-ComputerUseInstaller -Stage 'preflight before MSIX patch'
  }
}

if ($InstallModelInstructionsFile) {
  Invoke-ModelInstructionsInstaller
}

if ($RegisterMarketplaceOnly) {
  Show-Status
  exit 0
}

if (-not (Test-Path -LiteralPath $PatchScript)) {
  throw "patch script not found: $PatchScript"
}

$patchArgs = @()
if ($DryRun) {
  $patchArgs += '-DryRun'
  $patchArgs += '-ForceRebuild'
} else {
  $patchArgs += '-InstallPrerequisites'
  $patchArgs += '-Install'
  $patchArgs += '-ForceRebuild'
  if (-not $NoLaunch) {
    $patchArgs += '-Launch'
  }
  if (-not $SkipSdkCleanup) {
    $patchArgs += '-CleanupWindowsSdkAfterInstall'
  }
  if (-not $KeepBuild) {
    $patchArgs += '-CleanupAfter'
  }
  if (-not $SkipFastVerify) {
    $patchArgs += '-VerifyFastModeRequest'
  }
}
if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
  $patchArgs += '-OutputRoot'
  $patchArgs += $OutputRoot
}

$maxPatchAttempts = if ($DryRun) { 1 } else { 2 }
$successfulSourcePackage = $null
for ($patchAttempt = 1; $patchAttempt -le $maxPatchAttempts; $patchAttempt++) {
  $sourcePackage = Get-InstalledCodexPackage
  if (-not $sourcePackage) {
    throw 'OpenAI.Codex package is not installed; cannot start MSIX repair'
  }
  Write-Log "patch attempt $patchAttempt/$maxPatchAttempts source package: $($sourcePackage.PackageFullName) signature=$($sourcePackage.SignatureKind)"

  try {
    Invoke-Checked 'powershell' (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PatchScript) + $patchArgs) 'Codex MSIX patch failed'
  } catch {
    $patchError = $_
    if (-not $DryRun) {
      $failedPackage = Get-InstalledCodexPackage
      $failedInstallResult = Test-CodexPatchInstallResult $sourcePackage $failedPackage
      $storeReplacementDetected = (
        $failedPackage -and
        [string]$failedPackage.SignatureKind -eq 'Store' -and
        (
          [string]$failedPackage.Version -ne [string]$sourcePackage.Version -or
          [string]$sourcePackage.SignatureKind -ne 'Store'
        )
      )
      if ($storeReplacementDetected -and $patchAttempt -lt $maxPatchAttempts) {
        Write-Log "warning: patch subprocess failed while $($failedInstallResult.Reason)"
        Write-Log 'warning: Store update or package replacement detected during repair; retrying once against the current package'
        continue
      }
    }
    throw $patchError
  }

  if (-not $SkipMarketplace) {
    Register-LocalMarketplace $MarketplacePath
  }

  if (-not $SkipComputerUse) {
    if ($DryRun) {
      Invoke-ComputerUseInstaller -Stage 'post-dry-run final verification' -VerifyOnly
    } else {
      Invoke-ComputerUseInstaller -Stage 'post-patch refresh after Codex startup'
      Invoke-ComputerUseInstaller -Stage 'post-patch final verification' -VerifyOnly
    }
  }

  if ($DryRun) {
    $successfulSourcePackage = $sourcePackage
    break
  }

  $finalPackage = Get-InstalledCodexPackage
  $installResult = Test-CodexPatchInstallResult $sourcePackage $finalPackage
  if ($installResult.Success) {
    Write-Log "patch install verification ok: $($installResult.Reason)"
    $successfulSourcePackage = $sourcePackage
    break
  }

  if ($installResult.Retryable -and $patchAttempt -lt $maxPatchAttempts) {
    Write-Log "warning: $($installResult.Reason)"
    Write-Log 'warning: Store update or package replacement detected during repair; retrying once against the current package'
    continue
  }

  throw $installResult.Reason
}

if (-not $successfulSourcePackage) {
  throw 'Codex MSIX repair did not complete successfully'
}

if ($InstallModelInstructionsFile) {
  Invoke-Checked 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ModelInstructionsScript, '-PromptDestination', $ModelInstructionsDestination, '-VerifyOnly') 'model instructions file verification failed'
}

if (-not $DryRun) {
  $finalPackage = Get-InstalledCodexPackage
  $finalInstallResult = Test-CodexPatchInstallResult $successfulSourcePackage $finalPackage
  if (-not $finalInstallResult.Success) {
    throw "final Codex package verification failed: $($finalInstallResult.Reason)"
  }
}

Show-Status
