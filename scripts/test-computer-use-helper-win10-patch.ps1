[CmdletBinding()]
param(
  [string]$HelperPath
)

$ErrorActionPreference = 'Stop'
$ExpectedSkyVersion = '0.6.6'
$ExpectedOriginalHash = 'BE488E66C38E12FA46850EE48C1F5E44ECDB0A3A64042E064E3A1A1DA286AC42'
$ExpectedPatchedHash = '34D6EB4F23630AD6E7211898AA7678472C9ED7ACFD972C78B7D9E575A1C5C640'
$Patcher = Join-Path $PSScriptRoot 'patch-computer-use-helper-win10.ps1'

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )
  if ([string]$Actual -cne [string]$Expected) {
    throw "$Message / expected=$Expected actual=$Actual"
  }
}

function Resolve-OriginalHelper {
  if (-not [string]::IsNullOrWhiteSpace($HelperPath)) {
    return [IO.Path]::GetFullPath($HelperPath)
  }

  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $runtimeHelper = Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        $candidate = Join-Path $_.FullName 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $ExpectedOriginalHash) {
          Get-Item -LiteralPath $candidate
        }
      } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($runtimeHelper) {
      return $runtimeHelper.FullName
    }
  }

  $backupRoot = Join-Path $env:USERPROFILE '.codex\backups\computer-use-helper'
  if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    $backup = Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'codex-computer-use.exe.original' -File -ErrorAction SilentlyContinue |
      Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $ExpectedOriginalHash } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($backup) {
      return $backup.FullName
    }
  }

  throw 'the exact @oai/sky 0.6.6 original helper is unavailable for this regression test'
}

function Get-Status {
  param(
    [string]$Path,
    [string]$CodexHome
  )
  return @(& $Patcher -HelperPath $Path -CodexHome $CodexHome) | Select-Object -Last 1
}

function Get-WindowsBuild {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  if ($os -and $os.BuildNumber) {
    return [int]$os.BuildNumber
  }
  return [Environment]::OSVersion.Version.Build
}

if (-not (Test-Path -LiteralPath $Patcher -PathType Leaf)) {
  throw "patcher is missing: $Patcher"
}

$sourceHelper = Resolve-OriginalHelper
Assert-Equal (Get-FileHash -LiteralPath $sourceHelper -Algorithm SHA256).Hash $ExpectedOriginalHash 'unexpected original helper hash'

$runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
$sourcePackagePath = $null
if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
  $sourcePackagePath = Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
      $candidate = Join-Path $_.FullName 'bin\node_modules\@oai\sky\package.json'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        try {
          $package = Get-Content -Raw -LiteralPath $candidate | ConvertFrom-Json
          if ([string]$package.version -ceq $ExpectedSkyVersion) {
            Get-Item -LiteralPath $candidate
          }
        } catch {
          # Ignore incomplete runtime package metadata and continue searching.
        }
      }
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    ForEach-Object FullName
}
if ([string]::IsNullOrWhiteSpace($sourcePackagePath)) {
  $sourceSkyRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $sourceHelper))
  $sourcePackagePath = Join-Path $sourceSkyRoot 'package.json'
}
if (-not (Test-Path -LiteralPath $sourcePackagePath -PathType Leaf)) {
  throw "source @oai/sky package.json is missing: $sourcePackagePath"
}
Assert-Equal ([string]((Get-Content -Raw -LiteralPath $sourcePackagePath | ConvertFrom-Json).version)) $ExpectedSkyVersion 'unexpected source @oai/sky version'

$tempBase = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($env:TEMP)) { [IO.Path]::GetTempPath() } else { $env:TEMP }))
$testRoot = Join-Path $tempBase ('codex-cua-win10-helper-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($tempBase.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "test root is outside TEMP: $resolvedTestRoot"
}

try {
  $skyRoot = Join-Path $resolvedTestRoot 'bin\node_modules\@oai\sky'
  $testHelper = Join-Path $skyRoot 'bin\windows\codex-computer-use.exe'
  $codexHome = Join-Path $resolvedTestRoot 'codex-home'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $testHelper) | Out-Null
  Copy-Item -LiteralPath $sourceHelper -Destination $testHelper -Force
  Copy-Item -LiteralPath $sourcePackagePath -Destination (Join-Path $skyRoot 'package.json') -Force

  $before = Get-Status $testHelper $codexHome
  Assert-Equal $before.State 'original-patchable' 'original state mismatch'
  Assert-Equal $before.Sha256 $ExpectedOriginalHash 'original status hash mismatch'

  $candidateHash = @(& $Patcher -HelperPath $testHelper -CodexHome $codexHome -ComputeCandidateHash) | Select-Object -Last 1
  Assert-Equal $candidateHash $ExpectedPatchedHash 'candidate hash mismatch'

  $windowsBuild = Get-WindowsBuild
  if ($windowsBuild -lt 22000) {
    & $Patcher -HelperPath $testHelper -CodexHome $codexHome -Install
    $afterInstall = Get-Status $testHelper $codexHome
    Assert-Equal $afterInstall.State 'patched' 'patched state mismatch'
    Assert-Equal $afterInstall.Sha256 $ExpectedPatchedHash 'patched hash mismatch'
    Assert-Equal (Get-FileHash -LiteralPath $afterInstall.BackupPath -Algorithm SHA256).Hash $ExpectedOriginalHash 'backup hash mismatch'

    & $Patcher -HelperPath $testHelper -CodexHome $codexHome -Install
    Assert-Equal (Get-FileHash -LiteralPath $testHelper -Algorithm SHA256).Hash $ExpectedPatchedHash 'idempotent install changed the helper'

    & $Patcher -HelperPath $testHelper -CodexHome $codexHome -Rollback
    Assert-Equal (Get-FileHash -LiteralPath $testHelper -Algorithm SHA256).Hash $ExpectedOriginalHash 'rollback hash mismatch'

    & $Patcher -HelperPath $testHelper -CodexHome $codexHome -Rollback
    Assert-Equal (Get-FileHash -LiteralPath $testHelper -Algorithm SHA256).Hash $ExpectedOriginalHash 'idempotent rollback changed the helper'
  } else {
    $platformGuardRejected = $false
    try {
      & $Patcher -HelperPath $testHelper -CodexHome $codexHome -Install
    } catch {
      $platformGuardRejected = $_.Exception.Message -eq "this profile is limited to Windows 10; detected build $windowsBuild"
    }
    Assert-Equal $platformGuardRejected $true 'Windows 11 fixture install bypassed the live platform guard'
    Assert-Equal (Get-FileHash -LiteralPath $testHelper -Algorithm SHA256).Hash $ExpectedOriginalHash 'platform guard changed the helper'
  }

  $unknownBytes = [IO.File]::ReadAllBytes($testHelper)
  $unknownBytes[0x47E01] = $unknownBytes[0x47E01] -bxor 1
  [IO.File]::WriteAllBytes($testHelper, $unknownBytes)
  $unknown = Get-Status $testHelper $codexHome
  Assert-Equal $unknown.State 'unsupported' 'unknown hash state mismatch'

  $unknownRejected = $false
  try {
    & $Patcher -HelperPath $testHelper -CodexHome $codexHome -Install
  } catch {
    $unknownRejected = $_.Exception.Message -like 'unsupported helper SHA-256:*'
  }
  Assert-Equal $unknownRejected $true 'unknown helper hash was not rejected'

  Write-Output 'ALL_TESTS_PASSED'
} finally {
  if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
