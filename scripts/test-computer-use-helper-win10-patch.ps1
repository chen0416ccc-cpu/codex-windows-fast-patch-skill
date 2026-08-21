[CmdletBinding()]
param(
  [string]$HelperPath,
  # Profile labels, not raw @oai/sky versions: one sky version can ship more than one
  # helper binary across Desktop builds, so each label pins its own hash pair.
  [ValidateSet('0.6.6', '0.6.11', '0.6.11-7A95D14E', '0.6.16', '0.6.16-BEB498C2', '0.6.17-29D5E113', '0.6.17-DB8F4486')]
  [string]$SkyVersion = '0.6.16'
)

$ErrorActionPreference = 'Stop'
$Profiles = @{
  '0.6.6' = [ordered]@{
    SkyVersion = '0.6.6'
    OriginalHash = 'BE488E66C38E12FA46850EE48C1F5E44ECDB0A3A64042E064E3A1A1DA286AC42'
    PatchedHash = '34D6EB4F23630AD6E7211898AA7678472C9ED7ACFD972C78B7D9E575A1C5C640'
  }
  '0.6.11' = [ordered]@{
    SkyVersion = '0.6.11'
    OriginalHash = 'DE07F17A7206588687A8F722E4EBFC5A4FB1BD87F91DF2C60BB5C777C6D5CDCD'
    PatchedHash = '40530E628C91EF510F81A02FD3394C18E0D322C3D68D4A0277F0B0C56A2D43CC'
  }
  '0.6.11-7A95D14E' = [ordered]@{
    SkyVersion = '0.6.11'
    OriginalHash = '7A95D14EBF992955D8AB8E6C57A75545ED7D18E864B0F5C1B9FE7F47685BD897'
    PatchedHash = 'E84A4ECB473CF9D3B4B65BB27A298DE6602AD8A1A11B21EE0BA7BC9209FE4DA9'
  }
  '0.6.16' = [ordered]@{
    SkyVersion = '0.6.16'
    OriginalHash = 'E40BE6145157885F0E155A4247DF3B64BD5D3455A04E276503B0E2821B3EA39E'
    PatchedHash = 'F35CA6D89959EDEFB4DF46A5ECC6202091AB3C63E885E6CD6CF9824D92B66EB7'
  }
  '0.6.16-BEB498C2' = [ordered]@{
    SkyVersion = '0.6.16-202608171739-pr-1311460-c66628846294'
    OriginalHash = 'BEB498C287889D807DCCB0E1FAD8A39ED9BE6BDF084D10313B5D52BA26C1E370'
    PatchedHash = 'AF7D14EE6E2B850E06798EC14117D29F1C839DB5C135A7F515DE37074DB66A23'
  }
  '0.6.17-29D5E113' = [ordered]@{
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalHash = '29D5E113A5D24A1DD3F3CCA4245CE5AE82A56E88AF5AFCD8E0AE4CC2E5C94992'
    PatchedHash = 'DC83663FBF8DEF6749296B84EAE66054D2C07530CC42A87CA4503ECF86AD3767'
  }
  '0.6.17-DB8F4486' = [ordered]@{
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalHash = 'DB8F4486D527C91B80266FAF77FDC38266B1D3960EFBBA35D0A6AAB4CAAF6AEE'
    PatchedHash = '6495168DC16A35CDC33230E6512D64E660B56D13E99FE239426D228B9F86E157'
  }
}
$ProfileLabel = $SkyVersion
$ExpectedSkyVersion = $Profiles[$ProfileLabel].SkyVersion
$ExpectedOriginalHash = $Profiles[$ProfileLabel].OriginalHash
$ExpectedPatchedHash = $Profiles[$ProfileLabel].PatchedHash
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

function Get-CodexPackageInstallLocations {
  $locations = New-Object System.Collections.Generic.List[string]
  foreach ($scope in @($false, $true)) {
    try {
      $packages = if ($scope) {
        Get-AppxPackage -Name 'OpenAI.Codex' -AllUsers -ErrorAction Stop
      } else {
        Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop
      }
    } catch {
      continue
    }
    foreach ($package in ($packages | Sort-Object { [version]$_.Version } -Descending)) {
      if (-not [string]::IsNullOrWhiteSpace($package.InstallLocation) -and -not $locations.Contains($package.InstallLocation)) {
        $locations.Add($package.InstallLocation)
      }
    }
  }
  return $locations
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

  # A freshly published Desktop build ships its helper inside the installed package and the
  # user-local runtime only appears after the app has been launched once, so fall back to the
  # bundled copy. Read-only, and every candidate is still hash-pinned to the profile.
  foreach ($installLocation in (Get-CodexPackageInstallLocations)) {
    $candidate = Join-Path $installLocation 'app\resources\cua_node\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
        (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $ExpectedOriginalHash) {
      return $candidate
    }
  }

  throw "the exact original helper for profile $ProfileLabel (@oai/sky $ExpectedSkyVersion) is unavailable for this regression test"
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
$hasSourcePackage = Test-Path -LiteralPath $sourcePackagePath -PathType Leaf
if ($hasSourcePackage) {
  Assert-Equal ([string]((Get-Content -Raw -LiteralPath $sourcePackagePath | ConvertFrom-Json).version)) $ExpectedSkyVersion 'unexpected source @oai/sky version'
}

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
  $testPackagePath = Join-Path $skyRoot 'package.json'
  if ($hasSourcePackage) {
    Copy-Item -LiteralPath $sourcePackagePath -Destination $testPackagePath -Force
  } else {
    [IO.File]::WriteAllText($testPackagePath, ('{"version":"' + $ExpectedSkyVersion + '"}'), [Text.UTF8Encoding]::new($false))
  }

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
