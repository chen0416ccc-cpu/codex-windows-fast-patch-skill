[CmdletBinding()]
param(
  [string]$OutputZip,
  [string]$SourceRoot,
  [string]$WorkRoot,
  [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows

$RequiredPayloadFiles = @(
  'AppxManifest.xml',
  'app\Codex.exe',
  'app\resources\codex.exe',
  'app\resources\app.asar'
)

function Write-SidecarLog {
  param([string]$Message)
  Write-Host ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Remove-SidecarDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$RequiredRoot
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  $resolved = Resolve-GuardFullPath $Path
  $root = (Resolve-GuardFullPath $RequiredRoot).TrimEnd('\')
  $comparison = [System.StringComparison]::OrdinalIgnoreCase
  if ($resolved.Equals($root, $comparison) -or -not $resolved.StartsWith($root + '\', $comparison)) {
    throw "refusing to recursively delete outside safe root: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Invoke-SidecarRobocopy {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy.exe $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed with exit code $LASTEXITCODE"
  }
}

function Get-SidecarRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $rootFull = (Resolve-GuardFullPath $Root).TrimEnd('\')
  $pathFull = Resolve-GuardFullPath $Path
  if ($pathFull.Length -le $rootFull.Length) {
    return ''
  }
  return $pathFull.Substring($rootFull.Length).TrimStart('\')
}

function Find-SidecarForbiddenUserState {
  param([Parameter(Mandatory = $true)][string]$Root)
  $forbiddenLeafNames = @(
    '.codex',
    'auth.json',
    'remote.json',
    'remote-control-oauth.json',
    'state_5.sqlite',
    'Cookies',
    'Login Data',
    'Web Data',
    'Network Persistent State'
  )
  $forbiddenSegments = @(
    '.codex',
    'User Data',
    'sessions',
    'archived_sessions'
  )
  $hits = New-Object System.Collections.Generic.List[object]
  Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $relative = Get-SidecarRelativePath -Root $Root -Path $_.FullName
    $segments = @($relative -split '[\\/]') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $leaf = $_.Name
    $matched = $null
    foreach ($segment in $segments) {
      if ($forbiddenSegments -contains $segment) {
        $matched = "segment:$segment"
        break
      }
    }
    if (-not $matched -and $forbiddenLeafNames -contains $leaf) {
      $matched = "leaf:$leaf"
    }
    if ($matched) {
      $hits.Add([pscustomobject]@{
        Path = $relative
        Match = $matched
        IsDirectory = [bool]$_.PSIsContainer
      })
    }
  }
  return @($hits.ToArray())
}

function Assert-SidecarNoForbiddenUserState {
  param([Parameter(Mandatory = $true)][string]$Root)
  $hits = @(Find-SidecarForbiddenUserState -Root $Root)
  if ($hits.Count -gt 0) {
    $sample = @($hits | Select-Object -First 8 | ForEach-Object { "$($_.Path) [$($_.Match)]" }) -join '; '
    throw "refusing to export payload because it appears to contain user state or credentials: $sample"
  }
}

function Get-SidecarPackageIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$PackageFullName,
    [string]$SignatureKind
  )
  $manifestPath = Join-Path $Root 'AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "AppxManifest.xml not found: $manifestPath"
  }
  [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
  $identityName = [string]$manifest.Package.Identity.Name
  $version = [string]$manifest.Package.Identity.Version
  $architecture = [string]$manifest.Package.Identity.ProcessorArchitecture
  $publisher = [string]$manifest.Package.Identity.Publisher
  if ($identityName -ne 'OpenAI.Codex') {
    throw "payload is not OpenAI.Codex: $identityName"
  }
  if ([string]::IsNullOrWhiteSpace($PackageFullName)) {
    $leaf = Split-Path -Leaf $Root
    $PackageFullName = if ($leaf -like 'OpenAI.Codex_*') { $leaf } else { "OpenAI.Codex_$version" + "_$architecture" + "__2p2nqsd0c76g0" }
  }
  return [pscustomobject]@{
    Name = $identityName
    PackageFullName = $PackageFullName
    Version = $version
    ProcessorArchitecture = $architecture
    Publisher = $publisher
    SignatureKind = $SignatureKind
  }
}

function Get-SidecarRelativeFingerprint {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )
  $path = Join-Path $Root $RelativePath
  $fingerprint = Get-GuardFileFingerprint -Path $path
  return [pscustomobject]@{
    RelativePath = $RelativePath
    Exists = $fingerprint.Exists
    Length = $fingerprint.Length
    LastWriteTimeUtc = $fingerprint.LastWriteTimeUtc
    Sha256 = $fingerprint.Sha256
  }
}

function Get-SidecarCodexCliVersion {
  param([Parameter(Mandatory = $true)][string]$CodexExe)
  $versionOutput = $null
  $version = $null
  $errorText = $null
  try {
    try {
      $capture = Invoke-GuardProcessCapture -FilePath $CodexExe -Arguments @('--version') -TimeoutSeconds 15
    } catch {
      $firstError = $_.Exception.Message
      $probeRoot = Join-Path $env:TEMP 'codex-sidecar-version-probe'
      $probeDir = Join-Path $probeRoot ([guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
      $probeExe = Join-Path $probeDir 'codex.exe'
      try {
        Copy-Item -LiteralPath $CodexExe -Destination $probeExe -Force
        $capture = Invoke-GuardProcessCapture -FilePath $probeExe -Arguments @('--version') -TimeoutSeconds 15
      } catch {
        throw "$firstError; fallback copy probe failed: $($_.Exception.Message)"
      } finally {
        Remove-Item -LiteralPath $probeExe -Force -ErrorAction SilentlyContinue
        Remove-SidecarDirectory -Path $probeDir -RequiredRoot $probeRoot
      }
    }
    $versionOutput = (($capture.Stdout, $capture.Stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    if ($capture.ExitCode -ne 0) {
      throw "codex.exe --version exited with $($capture.ExitCode): $($capture.Stderr)"
    }
    if ($versionOutput -match 'codex-cli\s+([0-9]+\.[0-9]+\.[0-9]+)') {
      $version = $Matches[1]
    } else {
      throw "could not parse codex-cli version from: $versionOutput"
    }
  } catch {
    $errorText = $_.Exception.Message
  }
  return [pscustomobject]@{
    VersionOutput = $versionOutput
    Version = $version
    Error = $errorText
  }
}

$package = $null
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $package -or [string]::IsNullOrWhiteSpace($package.InstallLocation)) {
    throw 'OpenAI.Codex package was not found.'
  }
  $SourceRoot = $package.InstallLocation
}
$SourceRoot = Resolve-GuardFullPath $SourceRoot
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
  throw "SourceRoot not found: $SourceRoot"
}

$identity = Get-SidecarPackageIdentity `
  -Root $SourceRoot `
  -PackageFullName $(if ($package) { $package.PackageFullName } else { $null }) `
  -SignatureKind $(if ($package) { [string]$package.SignatureKind } else { 'Unknown' })

foreach ($relative in $RequiredPayloadFiles) {
  $requiredPath = Join-Path $SourceRoot $relative
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "required payload file missing: $requiredPath"
  }
}

$repoRoot = Split-Path -Parent $ScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputZip)) {
  $outputDir = Join-Path $repoRoot 'artifacts\codex-payloads'
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  $safeVersion = ([string]$identity.Version) -replace '[^A-Za-z0-9._-]', '_'
  $safeArch = ([string]$identity.ProcessorArchitecture) -replace '[^A-Za-z0-9._-]', '_'
  $OutputZip = Join-Path $outputDir ("OpenAI.Codex_${safeVersion}_${safeArch}_payload.zip")
}
$OutputZip = Resolve-GuardFullPath $OutputZip
$outputParent = Split-Path -Parent $OutputZip
if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
  New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
}

$workParent = if ([string]::IsNullOrWhiteSpace($WorkRoot)) { Join-Path $env:TEMP 'codex-sidecar-export' } else { Resolve-GuardFullPath $WorkRoot }
New-Item -ItemType Directory -Force -Path $workParent | Out-Null
$workRoot = Join-Path $workParent ([guid]::NewGuid().ToString('N'))
$bundleRoot = Join-Path $workRoot 'sidecar-payload'
$packageRoot = Join-Path $bundleRoot 'package'
New-Item -ItemType Directory -Force -Path $bundleRoot | Out-Null

$scriptSucceeded = $false
try {
  Write-SidecarLog "exporting OpenAI.Codex payload from: $SourceRoot"
  Invoke-SidecarRobocopy -Source $SourceRoot -Destination $packageRoot
  Assert-SidecarNoForbiddenUserState -Root $packageRoot

  $codexCli = Get-SidecarCodexCliVersion -CodexExe (Join-Path $packageRoot 'app\resources\codex.exe')
  $requiredHashes = @($RequiredPayloadFiles | ForEach-Object { Get-SidecarRelativeFingerprint -Root $packageRoot -RelativePath $_ })
  $hashes = [pscustomObject]@{
    SchemaVersion = 1
    HashAlgorithm = 'SHA256'
    PackageDirectory = 'package'
    RequiredFiles = $requiredHashes
  }
  $manifest = [pscustomobject]@{
    SchemaVersion = 1
    Kind = 'CodexDesktopSidecarPayload'
    CreatedAt = (Get-Date).ToString('o')
    Package = $identity
    CodexCli = $codexCli
    PackageDirectory = 'package'
    RequiredFiles = $RequiredPayloadFiles
    HashesFile = 'hashes.json'
    Privacy = [pscustomobject]@{
      ContainsCodexUserState = $false
      ContainsAuthJson = $false
      ContainsSecrets = $false
      ContainsBrowserProfile = $false
    }
  }

  Write-GuardJsonFile -Path (Join-Path $bundleRoot 'codex-payload-manifest.json') -Value $manifest
  Write-GuardJsonFile -Path (Join-Path $bundleRoot 'hashes.json') -Value $hashes

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $OutputZip -PathType Leaf) {
    Remove-Item -LiteralPath $OutputZip -Force
  }
  Write-SidecarLog "creating sidecar payload zip: $OutputZip"
  [System.IO.Compression.ZipFile]::CreateFromDirectory($bundleRoot, $OutputZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)

  $zipInfo = Get-GuardFileFingerprint -Path $OutputZip
  $result = [pscustomobject]@{
    SchemaVersion = 1
    Status = 'exported'
    CreatedAt = (Get-Date).ToString('o')
    OutputZip = $OutputZip
    Package = $identity
    CodexCli = $codexCli
    Zip = $zipInfo
    WorkRoot = $workRoot
  }
  $scriptSucceeded = $true
  Write-SidecarLog "sidecar payload exported: $OutputZip"
  $result | ConvertTo-Json -Depth 8
} finally {
  if ($KeepWorkDir -or -not $scriptSucceeded) {
    Write-SidecarLog "keeping workdir: $workRoot"
  } else {
    Remove-SidecarDirectory -Path $workRoot -RequiredRoot $workParent
  }
}
