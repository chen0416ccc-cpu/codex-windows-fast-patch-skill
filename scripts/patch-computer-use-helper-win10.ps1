[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$HelperPath,
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [switch]$Install,
  [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-cua-win10-screenshot-helper]'

$PatchProfile = [ordered]@{
  Name = '@oai/sky 0.4.20 helper F2B2F56F / Windows 10 screenshot backend'
  ValidatedDesktopVersion = '26.707.12708.0'
  SkyVersion = '0.4.20'
  OriginalSha256 = 'F2B2F56FCD1699B0FA32DEC3214A56A1D36B937A2ECF58CC822AB4A904551E03'
  PatchedSha256 = '71A13CBC4BB333F0707D2311C99DBA54D8B24D1BBB9F7CE25C3B9386577FFDDA'
  Regions = @(
    [ordered]@{
      Name = 'optional-border-interface'
      Offset = 0x000BB5D1
      OriginalHex = '4889c689d3eb4f'
      PatchedHex = 'e97d0000009090'
    },
    [ordered]@{
      Name = 'frame-arrived-busy-return'
      Offset = 0x000BFA4F
      OriginalHex = '0f85c3340000'
      PatchedHex = '0f85a6340000'
    },
    [ordered]@{
      Name = 'frame-arrived-once-flag'
      Offset = 0x000BFA60
      OriginalHex = '740d'
      PatchedHex = 'eb0d'
    },
    [ordered]@{
      Name = 'mta-worker-wrapper'
      Offset = 0x0012C94E
      OriginalHex = ('cc' + (('00' * 174) -join ''))
      PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15610f00004885c074104889c1ff15330e000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff150b0c0000488b4c2428e82d30f9ffff15eb0b0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
    },
    [ordered]@{
      Name = 'frame-arrived-vtable'
      Offset = 0x0013C050
      OriginalHex = '0c060c4001000000'
      PatchedHex = '4ed5124001000000'
    }
  )
}

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Convert-HexToBytes {
  param([string]$Hex)

  if ([string]::IsNullOrWhiteSpace($Hex) -or ($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') {
    throw 'invalid hexadecimal byte string'
  }

  $bytes = New-Object byte[] ($Hex.Length / 2)
  for ($index = 0; $index -lt $bytes.Length; $index += 1) {
    $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
  }
  return $bytes
}

function Convert-BytesToHex {
  param([byte[]]$Bytes)
  return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Resolve-HelperPath {
  param([string]$RequestedPath)

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
      throw "Computer Use helper not found: $RequestedPath"
    }
    return (Resolve-Path -LiteralPath $RequestedPath).Path
  }

  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  $candidates = @()
  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $candidates = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $path = Join-Path $_.FullName 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        Get-Item -LiteralPath $path
      }
    } | Sort-Object LastWriteTime -Descending)
  }

  if ($candidates.Count -eq 0) {
    throw "no Computer Use helper found under $runtimeRoot"
  }

  return $candidates[0].FullName
}

function Get-SkyVersion {
  param([string]$ResolvedHelperPath)

  $skyRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ResolvedHelperPath))
  $packagePath = Join-Path $skyRoot 'package.json'
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    return 'unknown'
  }

  return [string]((Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json).version)
}

function Get-WindowsBuild {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  if ($os -and $os.BuildNumber) {
    return [int]$os.BuildNumber
  }
  return [Environment]::OSVersion.Version.Build
}

function Get-DesktopVersion {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($package -and $package.Version) {
    return [string]$package.Version
  }
  return 'unknown-desktop'
}

function Get-BackupPath {
  param(
    [string]$SkyVersion,
    [string]$OriginalHash,
    [string]$DesktopVersion
  )

  $profileDirectory = "$DesktopVersion-sky-$SkyVersion-$($OriginalHash.Substring(0, 8))"
  return Join-Path (Join-Path $CodexHome 'backups\computer-use-helper') "$profileDirectory\codex-computer-use.exe.original"
}

function Resolve-OriginalBackupPath {
  param([string]$PreferredPath)

  if (Test-Path -LiteralPath $PreferredPath -PathType Leaf) {
    return $PreferredPath
  }

  $backupRoot = Join-Path $CodexHome 'backups\computer-use-helper'
  if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    foreach ($candidate in @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'codex-computer-use.exe.original' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
      if ((Get-Sha256 $candidate.FullName) -eq $PatchProfile.OriginalSha256) {
        return $candidate.FullName
      }
    }
  }

  return $PreferredPath
}

function Assert-Regions {
  param(
    [byte[]]$FileBytes,
    [ValidateSet('Original', 'Patched')]
    [string]$State
  )

  foreach ($region in $PatchProfile.Regions) {
    $expectedHex = if ($State -eq 'Original') { $region.OriginalHex } else { $region.PatchedHex }
    $expected = Convert-HexToBytes $expectedHex
    if (($region.Offset + $expected.Length) -gt $FileBytes.Length) {
      throw "patch region is outside the helper: $($region.Name)"
    }

    $actual = New-Object byte[] $expected.Length
    [Array]::Copy($FileBytes, $region.Offset, $actual, 0, $actual.Length)
    if ((Convert-BytesToHex $actual) -ne $expectedHex.ToLowerInvariant()) {
      throw "helper bytes do not match the $State profile at $($region.Name) / 0x$('{0:X}' -f $region.Offset)"
    }
  }
}

function Set-PatchedRegions {
  param([byte[]]$FileBytes)

  foreach ($region in $PatchProfile.Regions) {
    $replacement = Convert-HexToBytes $region.PatchedHex
    [Array]::Copy($replacement, 0, $FileBytes, $region.Offset, $replacement.Length)
  }
}

function Stop-RunningHelper {
  param([string]$ResolvedHelperPath)

  $processes = @(Get-Process -Name 'codex-computer-use' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.Equals($ResolvedHelperPath, [System.StringComparison]::OrdinalIgnoreCase)
  })

  if ($processes.Count -gt 0) {
    Write-Log "stopping helper processes: $($processes.Id -join ', ')"
    $processes | Stop-Process -Force
  }
}

if ($Install -and $Rollback) {
  throw 'choose either -Install or -Rollback'
}

$resolvedHelperPath = Resolve-HelperPath $HelperPath
$skyVersion = Get-SkyVersion $resolvedHelperPath
$windowsBuild = Get-WindowsBuild
$desktopVersion = Get-DesktopVersion
$currentHash = Get-Sha256 $resolvedHelperPath
$preferredBackupPath = Get-BackupPath $skyVersion $PatchProfile.OriginalSha256 $desktopVersion
$state = if ($currentHash -eq $PatchProfile.OriginalSha256) {
  'original-patchable'
} elseif ($currentHash -eq $PatchProfile.PatchedSha256) {
  'patched'
} else {
  'unsupported'
}
$backupPath = if ($state -eq 'patched') {
  Resolve-OriginalBackupPath $preferredBackupPath
} else {
  $preferredBackupPath
}

if (-not $Install -and -not $Rollback) {
  [pscustomobject]@{
    Profile = $PatchProfile.Name
    HelperPath = $resolvedHelperPath
    CurrentDesktopVersion = $desktopVersion
    EndToEndValidatedDesktopVersion = $PatchProfile.ValidatedDesktopVersion
    SkyVersion = $skyVersion
    WindowsBuild = $windowsBuild
    State = $state
    Sha256 = $currentHash
    BackupPath = $backupPath
  }
  return
}

if ($Install) {
  if ($state -eq 'patched') {
    Assert-Regions ([IO.File]::ReadAllBytes($resolvedHelperPath)) 'Patched'
    Write-Log "already patched: $resolvedHelperPath"
    return
  }
  if ($state -ne 'original-patchable') {
    throw "unsupported helper SHA-256: $currentHash"
  }
  if ($windowsBuild -ge 22000) {
    throw "this profile is limited to Windows 10; detected build $windowsBuild"
  }
  if ($skyVersion -ne $PatchProfile.SkyVersion) {
    throw "this profile requires @oai/sky $($PatchProfile.SkyVersion); detected $skyVersion"
  }

  $bytes = [IO.File]::ReadAllBytes($resolvedHelperPath)
  Assert-Regions $bytes 'Original'
  Set-PatchedRegions $bytes

  $tempPath = "$resolvedHelperPath.win10-screenshot-$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllBytes($tempPath, $bytes)
    $tempHash = Get-Sha256 $tempPath
    if ($tempHash -ne $PatchProfile.PatchedSha256) {
      throw "patched helper hash mismatch: $tempHash"
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedHelperPath, 'Install the hash-guarded Windows 10 screenshot backend patch')) {
      return
    }

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
      $backupHash = Get-Sha256 $backupPath
      if ($backupHash -ne $PatchProfile.OriginalSha256) {
        throw "existing helper backup has an unexpected SHA-256: $backupPath / $backupHash"
      }
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
      Copy-Item -LiteralPath $resolvedHelperPath -Destination $backupPath -Force
      if ((Get-Sha256 $backupPath) -ne $PatchProfile.OriginalSha256) {
        throw "helper backup verification failed: $backupPath"
      }
      Write-Log "original helper backup: $backupPath"
    }

    Stop-RunningHelper $resolvedHelperPath
    Copy-Item -LiteralPath $tempPath -Destination $resolvedHelperPath -Force
    if ((Get-Sha256 $resolvedHelperPath) -ne $PatchProfile.PatchedSha256) {
      throw "installed helper verification failed: $resolvedHelperPath"
    }
    Write-Log "installed and verified: $resolvedHelperPath"
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
  return
}

if ($state -eq 'original-patchable') {
  Write-Log "already rolled back: $resolvedHelperPath"
  return
}
if ($state -ne 'patched') {
  throw "cannot roll back unsupported helper SHA-256: $currentHash"
}
if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
  throw "original helper backup not found: $backupPath"
}
if ((Get-Sha256 $backupPath) -ne $PatchProfile.OriginalSha256) {
  throw "original helper backup hash mismatch: $backupPath"
}

if ($PSCmdlet.ShouldProcess($resolvedHelperPath, 'Restore the original Computer Use helper')) {
  Stop-RunningHelper $resolvedHelperPath
  Copy-Item -LiteralPath $backupPath -Destination $resolvedHelperPath -Force
  if ((Get-Sha256 $resolvedHelperPath) -ne $PatchProfile.OriginalSha256) {
    throw "rollback verification failed: $resolvedHelperPath"
  }
  Write-Log "rolled back and verified: $resolvedHelperPath"
}
