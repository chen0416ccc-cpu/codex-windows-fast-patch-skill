[CmdletBinding()]
param(
  [string]$HelperPath,
  # Profile labels, not raw @oai/sky versions: one sky version can ship more than one
  # helper binary across Desktop builds, so each label pins its own hash pair.
  [ValidateSet('0.4.20-F2B2F56F', '0.5.2-2C4CAC16', '0.6.6', '0.6.11', '0.6.11-7A95D14E', '0.6.16', '0.6.16-BEB498C2', '0.6.17-29D5E113', '0.6.17-DB8F4486', '0.6.17-4250FF66', '0.6.17-4319D3A2', '0.6.17-D967386B', '0.6.23-8423CA8C', '0.6.24-DE3696C0', '0.6.24-4DB7B670', '0.6.24-9BAB6E1B')]
  [string]$SkyVersion = '0.6.16'
)

$ErrorActionPreference = 'Stop'
$Profiles = @{
  '0.4.20-F2B2F56F' = [ordered]@{
    SkyVersion = '0.4.20'
    OriginalHash = 'F2B2F56FCD1699B0FA32DEC3214A56A1D36B937A2ECF58CC822AB4A904551E03'
    PatchedHash = '71A13CBC4BB333F0707D2311C99DBA54D8B24D1BBB9F7CE25C3B9386577FFDDA'
  }
  '0.5.2-2C4CAC16' = [ordered]@{
    SkyVersion = '0.5.2'
    OriginalHash = '2C4CAC168200520C2752058177EA9FE7D1CCF9A26B7287DDDFF669D41CA9AF16'
    PatchedHash = 'D816B14A80370697380BA702863DA9528AA5B73ED34C2B189ACE2BF9E103BEFF'
  }
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
  '0.6.17-4250FF66' = [ordered]@{
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalHash = '4250FF66B8EE598931DBE782E1CC76133FBE7650CCE225C4FC232155F7054350'
    PatchedHash = 'F4408E2C59F037D8B96ADAF3DE48846DB2921A9F007BC3CCAE34C1407A609ACC'
  }
  '0.6.17-4319D3A2' = [ordered]@{
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalHash = '4319D3A23F6B21370205425203BD46E76E7F3BB7EA5AC263851DCC5B8727AAE5'
    PatchedHash = '338D32A33BB7C034FEBCA79D23EF2337BCCE1CC9741784C1C11CE64F3A508368'
  }
  '0.6.17-D967386B' = [ordered]@{
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalHash = 'D967386B8943355017B7CFC1044A6F39AF41A38A3731088C4191123CE7F86018'
    PatchedHash = 'B43B12A8A23BE7CED3CCB64C56CC6885A483DBD482891116AB78C35CC3ACFB30'
  }
  '0.6.23-8423CA8C' = [ordered]@{
    SkyVersion = '0.6.23-202608251207-pr-1350514-1bc5ee2d44ce'
    OriginalHash = '8423CA8C5B75BD2ADCDC0E0BB0242A8F5422D16E12505753E84728D4A112458F'
    PatchedHash = 'E7C020B3451F6F2EF300D725A6B2AFC45A223A07C87D6D053B93BF3B28F0B661'
  }
  '0.6.24-DE3696C0' = [ordered]@{
    SkyVersion = '0.6.24-premerge-pr-1369830-395ab116910c'
    OriginalHash = 'DE3696C0E35CB4A00A77F284779E03FBED6B46D9EE00CA261D2B467064A3D149'
    PatchedHash = '1AB5261A714BDD10BCE038319A4668E366B679691A746B569731ED994FAC80E3'
  }
  # Same sky version string as DE3696C0, different binary: keyed on hash, not version.
  '0.6.24-4DB7B670' = [ordered]@{
    SkyVersion = '0.6.24-premerge-pr-1369830-395ab116910c'
    OriginalHash = '4DB7B6709F5B6DB2AE6DF60A1BDE026CF8A3582EEB616AF6B6529150E11B5CE1'
    PatchedHash = '986AA8DC4F6B2DC0A9551617120AF82915EC42C9F745BDE5F474EEB44A6ACCBD'
  }
  # Third binary on the same sky version string, shipped by Desktop 26.825.5331.0.
  '0.6.24-9BAB6E1B' = [ordered]@{
    SkyVersion = '0.6.24-premerge-pr-1369830-395ab116910c'
    OriginalHash = '9BAB6E1B59D31D97530F2F6681DAEF76E39C7AD0836147C6E0B55A9B47A33EBF'
    PatchedHash = 'B86B1FCB9EBD7184526AF49D40333FDA02F774FA62E0E9A3528BA5F87EB68AB7'
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
  $unknownBytes[$unknownBytes.Length - 1] = $unknownBytes[$unknownBytes.Length - 1] -bxor 1
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
