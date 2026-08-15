[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$patcher = Join-Path $scriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($patcher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
  throw "patcher has parse errors: $($parseErrors[0].Message)"
}

$requiredFunctions = @(
  'Normalize-AppPath',
  'Test-CodexAppPath',
  'Get-CodexAppVersion',
  'Find-CodexAppPath'
)
$definitions = foreach ($name in $requiredFunctions) {
  $definition = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true) | Select-Object -First 1
  if (-not $definition) {
    throw "patcher function is missing: $name"
  }
  $definition.Extent.Text
}
. ([scriptblock]::Create($definitions -join "`n"))

function Write-Log {
  param([string]$Message)
}

function Fail {
  param([string]$Message)
  throw $Message
}

$script:CurrentPackages = @()
$script:AllUserPackages = @()
$script:AllUsersQueryFails = $false
$script:RunningProcesses = @()

function Get-AppxPackage {
  [CmdletBinding()]
  param(
    [string]$Name,
    [switch]$AllUsers
  )
  if ($AllUsers) {
    if ($script:AllUsersQueryFails) {
      throw 'all-users query unavailable'
    }
    return $script:AllUserPackages
  }
  return $script:CurrentPackages
}

function Get-Process {
  [CmdletBinding()]
  param([string[]]$Name)
  return $script:RunningProcesses
}

function New-CodexPackageFixture {
  param(
    [Parameter(Mandatory = $true)][string]$WindowsAppsRoot,
    [Parameter(Mandatory = $true)][version]$Version,
    [bool]$Valid = $true
  )
  $packageRoot = Join-Path $WindowsAppsRoot "OpenAI.Codex_$($Version)_x64__2p2nqsd0c76g0"
  $app = Join-Path $packageRoot 'app'
  $resources = Join-Path $app 'resources'
  New-Item -ItemType Directory -Force -Path $resources | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $app 'Codex.exe'), 'fixture')
  [System.IO.File]::WriteAllText((Join-Path $resources 'app.asar'), 'fixture')
  if ($Valid) {
    [System.IO.File]::WriteAllText((Join-Path $resources 'rg.exe'), 'fixture')
  }
  return $packageRoot
}

function New-PackageRecord {
  param(
    [Parameter(Mandatory = $true)][version]$Version,
    [Parameter(Mandatory = $true)][string]$InstallLocation
  )
  return [pscustomobject]@{
    Version = $Version
    InstallLocation = $InstallLocation
  }
}

function Assert-PathEqual {
  param(
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $actualFull = [System.IO.Path]::GetFullPath($Actual).TrimEnd('\')
  $expectedFull = [System.IO.Path]::GetFullPath($Expected).TrimEnd('\')
  if (-not $actualFull.Equals($expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "assertion failed: $Message actual=$actualFull expected=$expectedFull"
  }
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixture = Join-Path $temp ('staged-package-selection-' + [guid]::NewGuid().ToString('N'))
$programFiles = Join-Path $fixture 'Program Files'
$windowsApps = Join-Path $programFiles 'WindowsApps'
New-Item -ItemType Directory -Force -Path $windowsApps | Out-Null

$previousProgramFiles = $env:ProgramFiles
try {
  $env:ProgramFiles = $programFiles
  $oldRoot = New-CodexPackageFixture -WindowsAppsRoot $windowsApps -Version '26.803.10989.0'
  $newRoot = New-CodexPackageFixture -WindowsAppsRoot $windowsApps -Version '26.810.4967.0'
  (Get-Item -LiteralPath $oldRoot).LastWriteTime = (Get-Date).AddMinutes(5)
  (Get-Item -LiteralPath $newRoot).LastWriteTime = (Get-Date).AddMinutes(-5)

  $script:CurrentPackages = @(New-PackageRecord -Version '26.803.10989.0' -InstallLocation $oldRoot)
  $script:AllUserPackages = @(
    New-PackageRecord -Version '26.803.10989.0' -InstallLocation $oldRoot
    New-PackageRecord -Version '26.810.4967.0' -InstallLocation $newRoot
  )
  $script:AllUsersQueryFails = $false
  $AppPath = $null
  Assert-PathEqual `
    -Actual (Find-CodexAppPath) `
    -Expected (Join-Path $newRoot 'app') `
    -Message 'a newer all-users Staged package wins over the older user package'

  $script:AllUsersQueryFails = $true
  Assert-PathEqual `
    -Actual (Find-CodexAppPath) `
    -Expected (Join-Path $newRoot 'app') `
    -Message 'WindowsApps fallback sorts by package version instead of directory timestamp'

  Remove-Item -LiteralPath (Join-Path $newRoot 'app\resources\rg.exe') -Force
  Assert-PathEqual `
    -Actual (Find-CodexAppPath) `
    -Expected (Join-Path $oldRoot 'app') `
    -Message 'an incomplete newer package is skipped'

  $AppPath = Join-Path $oldRoot 'app'
  Assert-PathEqual `
    -Actual (Find-CodexAppPath) `
    -Expected (Join-Path $oldRoot 'app') `
    -Message 'an explicit AppPath remains authoritative'
} finally {
  $env:ProgramFiles = $previousProgramFiles
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Staged package selection regression passed'
