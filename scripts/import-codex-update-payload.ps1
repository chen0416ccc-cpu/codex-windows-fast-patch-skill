[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$PayloadZip,
  [string]$PayloadRoot,
  [switch]$NoPrepare,
  [switch]$PrepareDryRun,
  [switch]$PrepareNoBuild,
  [switch]$NoNotifications,
  [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot

$RequiredPayloadFiles = @(
  'AppxManifest.xml',
  'app\Codex.exe',
  'app\resources\codex.exe',
  'app\resources\app.asar'
)

function Write-ImportLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath (Join-Path $state.Paths.Logs 'sidecar-import.log') -Value $line -Encoding UTF8
}

function Remove-ImportDirectory {
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

function Invoke-ImportRobocopy {
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

function Get-ImportRelativePath {
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

function Find-ImportForbiddenUserState {
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
    $relative = Get-ImportRelativePath -Root $Root -Path $_.FullName
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

function Assert-ImportNoForbiddenUserState {
  param([Parameter(Mandatory = $true)][string]$Root)
  $hits = @(Find-ImportForbiddenUserState -Root $Root)
  if ($hits.Count -gt 0) {
    $sample = @($hits | Select-Object -First 8 | ForEach-Object { "$($_.Path) [$($_.Match)]" }) -join '; '
    throw "refusing to import payload because it appears to contain user state or credentials: $sample"
  }
}

function Get-ImportPackageIdentity {
  param([Parameter(Mandatory = $true)][string]$Root)
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
  $leaf = Split-Path -Leaf $Root
  $packageFullName = if ($leaf -like 'OpenAI.Codex_*') { $leaf } else { "OpenAI.Codex_$version" + "_$architecture" + "__2p2nqsd0c76g0" }
  return [pscustomobject]@{
    Name = $identityName
    PackageFullName = $packageFullName
    Version = $version
    ProcessorArchitecture = $architecture
    Publisher = $publisher
    ManifestPath = $manifestPath
  }
}

function Get-ImportRelativeFingerprint {
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

function Assert-ImportPayloadRoot {
  param([Parameter(Mandatory = $true)][string]$Root)
  foreach ($relative in $RequiredPayloadFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "required payload file missing: $path"
    }
  }
  return Get-ImportPackageIdentity -Root $Root
}

function Assert-ImportHashes {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)]$Hashes
  )
  if (-not $Hashes.RequiredFiles) {
    throw 'sidecar hashes.json does not contain RequiredFiles.'
  }
  foreach ($entry in @($Hashes.RequiredFiles)) {
    $relative = [string]$entry.RelativePath
    if ([string]::IsNullOrWhiteSpace($relative)) {
      throw 'sidecar hashes.json contains a RequiredFiles entry without RelativePath.'
    }
    $actual = Get-ImportRelativeFingerprint -Root $Root -RelativePath $relative
    if (-not $actual.Exists) {
      throw "hashed payload file is missing: $relative"
    }
    if ([string]::IsNullOrWhiteSpace($entry.Sha256)) {
      throw "sidecar hashes.json does not contain SHA256 for: $relative"
    }
    if ($actual.Sha256.ToUpperInvariant() -ne ([string]$entry.Sha256).ToUpperInvariant()) {
      throw "payload hash mismatch for $relative; expected=$($entry.Sha256) actual=$($actual.Sha256)"
    }
  }
}

function Get-ImportCodexCliVersion {
  param([Parameter(Mandatory = $true)][string]$CodexExe)
  $versionOutput = $null
  $version = $null
  $errorText = $null
  try {
    try {
      $capture = Invoke-GuardProcessCapture -FilePath $CodexExe -Arguments @('--version') -TimeoutSeconds 15
    } catch {
      $firstError = $_.Exception.Message
      $probeRoot = Join-Path $env:TEMP 'codex-sidecar-import-version-probe'
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
        Remove-ImportDirectory -Path $probeDir -RequiredRoot $probeRoot
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

function Find-ImportPackageRoot {
  param([Parameter(Mandatory = $true)][string]$ExtractRoot)
  if (Test-Path -LiteralPath (Join-Path $ExtractRoot 'AppxManifest.xml') -PathType Leaf) {
    return $ExtractRoot
  }
  $preferred = Join-Path $ExtractRoot 'package'
  if (Test-Path -LiteralPath (Join-Path $preferred 'AppxManifest.xml') -PathType Leaf) {
    return $preferred
  }
  $hit = Get-ChildItem -LiteralPath $ExtractRoot -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'AppxManifest.xml') -PathType Leaf } |
    Select-Object -First 1
  if (-not $hit) {
    throw "could not find package root under extracted sidecar payload: $ExtractRoot"
  }
  return $hit.FullName
}

function Read-ImportSidecarMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$PackageRoot
  )
  $manifestPath = Join-Path $Root 'codex-payload-manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $manifestPath = Join-Path $PackageRoot 'codex-payload-manifest.json'
  }
  $hashesPath = Join-Path $Root 'hashes.json'
  if (-not (Test-Path -LiteralPath $hashesPath -PathType Leaf)) {
    $hashesPath = Join-Path $PackageRoot 'hashes.json'
  }
  $manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Read-GuardJsonFile -Path $manifestPath } else { $null }
  $hashes = if (Test-Path -LiteralPath $hashesPath -PathType Leaf) { Read-GuardJsonFile -Path $hashesPath } else { $null }
  return [pscustomobject]@{
    ManifestPath = if ($manifest) { $manifestPath } else { $null }
    Manifest = $manifest
    HashesPath = if ($hashes) { $hashesPath } else { $null }
    Hashes = $hashes
  }
}

function Copy-ImportPayloadManifest {
  param(
    [AllowNull()][object]$SidecarManifest,
    [Parameter(Mandatory = $true)][object]$Identity,
    [Parameter(Mandatory = $true)][object]$CodexCli
  )
  if ($SidecarManifest) {
    $payloadManifest = $SidecarManifest | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    if ($payloadManifest.PSObject.Properties['PackageDirectory']) {
      $payloadManifest.PackageDirectory = '.'
    } else {
      $payloadManifest | Add-Member -NotePropertyName 'PackageDirectory' -NotePropertyValue '.'
    }
    if ($payloadManifest.PSObject.Properties['ImportedAt']) {
      $payloadManifest.ImportedAt = (Get-Date).ToString('o')
    } else {
      $payloadManifest | Add-Member -NotePropertyName 'ImportedAt' -NotePropertyValue (Get-Date).ToString('o')
    }
    return $payloadManifest
  }
  return [pscustomobject]@{
    SchemaVersion = 1
    Kind = 'CodexDesktopSidecarPayload'
    CreatedAt = (Get-Date).ToString('o')
    Package = $Identity
    CodexCli = $CodexCli
    PackageDirectory = '.'
    RequiredFiles = $RequiredPayloadFiles
    HashesFile = 'hashes.json'
    Privacy = [pscustomobject]@{
      ContainsCodexUserState = $false
      ContainsAuthJson = $false
      ContainsSecrets = $false
      ContainsBrowserProfile = $false
    }
  }
}

$hasZip = -not [string]::IsNullOrWhiteSpace($PayloadZip)
$hasRoot = -not [string]::IsNullOrWhiteSpace($PayloadRoot)
if ($hasZip -eq $hasRoot) {
  throw 'Supply exactly one of -PayloadZip or -PayloadRoot.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$workRoot = Join-Path $state.Paths.Downloads ("sidecar-import-$stamp-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$sourcePayloadRoot = $null
$sidecarManifest = $null
$sidecarHashes = $null
$sidecarManifestPath = $null
$sidecarHashesPath = $null
$scriptSucceeded = $false

try {
  if ($hasZip) {
    $PayloadZip = Resolve-GuardFullPath $PayloadZip
    if (-not (Test-Path -LiteralPath $PayloadZip -PathType Leaf)) {
      throw "PayloadZip not found: $PayloadZip"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractRoot = Join-Path $workRoot 'extract'
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Write-ImportLog "extracting sidecar payload zip: $PayloadZip"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($PayloadZip, $extractRoot)
    Assert-ImportNoForbiddenUserState -Root $extractRoot
    $sidecarManifestPath = Join-Path $extractRoot 'codex-payload-manifest.json'
    $sidecarHashesPath = Join-Path $extractRoot 'hashes.json'
    if (-not (Test-Path -LiteralPath $sidecarManifestPath -PathType Leaf)) {
      throw "sidecar zip is missing codex-payload-manifest.json: $PayloadZip"
    }
    if (-not (Test-Path -LiteralPath $sidecarHashesPath -PathType Leaf)) {
      throw "sidecar zip is missing hashes.json: $PayloadZip"
    }
    $sidecarManifest = Read-GuardJsonFile -Path $sidecarManifestPath
    $sidecarHashes = Read-GuardJsonFile -Path $sidecarHashesPath
    if (-not $sidecarManifest -or $sidecarManifest.Kind -ne 'CodexDesktopSidecarPayload') {
      throw 'sidecar manifest kind is not CodexDesktopSidecarPayload.'
    }
    $sourcePayloadRoot = Find-ImportPackageRoot -ExtractRoot $extractRoot
    Assert-ImportHashes -Root $sourcePayloadRoot -Hashes $sidecarHashes
  } else {
    $payloadInputRoot = Resolve-GuardFullPath $PayloadRoot
    if (-not (Test-Path -LiteralPath $payloadInputRoot -PathType Container)) {
      throw "PayloadRoot not found: $payloadInputRoot"
    }
    Assert-ImportNoForbiddenUserState -Root $payloadInputRoot
    $sourcePayloadRoot = Find-ImportPackageRoot -ExtractRoot $payloadInputRoot
    $sidecarMetadata = Read-ImportSidecarMetadata -Root $payloadInputRoot -PackageRoot $sourcePayloadRoot
    $sidecarManifestPath = $sidecarMetadata.ManifestPath
    $sidecarManifest = $sidecarMetadata.Manifest
    $sidecarHashesPath = $sidecarMetadata.HashesPath
    $sidecarHashes = $sidecarMetadata.Hashes
    if ($sidecarManifest -and $sidecarManifest.Kind -ne 'CodexDesktopSidecarPayload') {
      throw 'sidecar manifest kind is not CodexDesktopSidecarPayload.'
    }
    if ($sidecarHashes) {
      Assert-ImportHashes -Root $sourcePayloadRoot -Hashes $sidecarHashes
    }
  }

  $identity = Assert-ImportPayloadRoot -Root $sourcePayloadRoot
  Assert-ImportNoForbiddenUserState -Root $sourcePayloadRoot
  $requiredHashes = @($RequiredPayloadFiles | ForEach-Object { Get-ImportRelativeFingerprint -Root $sourcePayloadRoot -RelativePath $_ })
  $codexCli = Get-ImportCodexCliVersion -CodexExe (Join-Path $sourcePayloadRoot 'app\resources\codex.exe')
  $shortHash = (($requiredHashes | Where-Object { $_.RelativePath -eq 'app\resources\codex.exe' } | Select-Object -First 1).Sha256).Substring(0, 12)
  $safeVersion = ([string]$identity.Version) -replace '[^A-Za-z0-9._-]', '_'
  $incomingRoot = Join-Path $state.Paths.Incoming ("$stamp-$safeVersion-$shortHash")
  $incomingRoot = Assert-GuardPathUnderRoot -Path $incomingRoot -Root $state.Paths.Root -Label 'incoming payload root'

  Write-ImportLog "copying sidecar payload into incoming: $incomingRoot"
  Invoke-ImportRobocopy -Source $sourcePayloadRoot -Destination $incomingRoot

  $hashes = [pscustomobject]@{
    SchemaVersion = 1
    HashAlgorithm = 'SHA256'
    PackageDirectory = '.'
    RequiredFiles = $requiredHashes
  }
  $payloadManifest = Copy-ImportPayloadManifest -SidecarManifest $sidecarManifest -Identity $identity -CodexCli $codexCli
  Write-GuardJsonFile -Path (Join-Path $incomingRoot 'codex-payload-manifest.json') -Value $payloadManifest
  Write-GuardJsonFile -Path (Join-Path $incomingRoot 'hashes.json') -Value $hashes

  $importManifestPath = Join-Path $incomingRoot 'codex-payload-import.json'
  $importManifest = [pscustomobject]@{
    SchemaVersion = 1
    Kind = 'CodexDesktopSidecarImport'
    Status = 'imported'
    CreatedAt = (Get-Date).ToString('o')
    StateRoot = $state.Paths.Root
    PayloadZip = if ($hasZip) { $PayloadZip } else { $null }
    SourcePayloadRoot = $sourcePayloadRoot
    IncomingPayloadRoot = $incomingRoot
    Package = $identity
    CodexCli = $codexCli
    Hashes = $hashes
    PrepareRequested = (-not [bool]$NoPrepare)
    PrepareExitCode = $null
    PrepareStatus = $null
    PrepareManifest = $null
    PrepareLog = $null
  }
  Write-GuardJsonFile -Path $importManifestPath -Value $importManifest
  Write-GuardJsonFile -Path (Join-Path $state.Paths.Logs "sidecar-import-$stamp.json") -Value $importManifest

  $notification = @(
    "Codex Desktop Guard imported a sidecar Codex Desktop payload.",
    "Payload: $incomingRoot",
    "Package: $($identity.PackageFullName)",
    "Version: $($identity.Version)",
    "codex-cli: $($codexCli.Version)",
    "",
    "The guard has not installed anything."
  ) -join "`r`n"
  if (-not $NoNotifications) {
    Write-GuardNotification -State $state -Name "UPDATE_SOURCE_READY-$stamp.txt" -Content $notification | Out-Null
    Write-GuardNotification -State $state -Name 'UPDATE_SOURCE_READY.txt' -Content $notification | Out-Null
  }

  if (-not $NoPrepare) {
    $prepareScript = Join-Path $ScriptRoot 'prepare-patched-update.ps1'
    if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
      throw "prepare script not found: $prepareScript"
    }
    $prepareLog = Join-Path $incomingRoot 'prepare-patched-update-from-import.log'
    $prepareStartedUtc = (Get-Date).ToUniversalTime()
    $prepareArgs = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $prepareScript,
      '-StateRoot',
      $state.Paths.Root,
      '-PayloadRoot',
      $incomingRoot
    )
    if ($PrepareDryRun) {
      $prepareArgs += '-DryRun'
    }
    if ($PrepareNoBuild) {
      $prepareArgs += '-NoBuild'
    }
    Write-ImportLog "triggering patched-update prepare for imported payload: $incomingRoot"
    & powershell @prepareArgs *>&1 | Tee-Object -FilePath $prepareLog
    $prepareExitCode = $LASTEXITCODE
    $prepareManifestPath = Get-ChildItem -LiteralPath $state.Paths.Staging -Recurse -Filter 'manifest.json' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTimeUtc -ge $prepareStartedUtc.AddSeconds(-2) } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1 -ExpandProperty FullName
    $prepareManifest = if ($prepareManifestPath) { Read-GuardJsonFile -Path $prepareManifestPath } else { $null }
    $importManifest.Status = if ($prepareExitCode -eq 0) { 'imported_prepare_complete' } else { 'imported_prepare_failed' }
    $importManifest.PrepareExitCode = $prepareExitCode
    $importManifest.PrepareManifest = $prepareManifestPath
    $importManifest.PrepareStatus = if ($prepareManifest) { [string]$prepareManifest.Status } else { $null }
    $importManifest.PrepareLog = $prepareLog
    Write-GuardJsonFile -Path $importManifestPath -Value $importManifest
    Write-GuardJsonFile -Path (Join-Path $state.Paths.Logs "sidecar-import-$stamp.json") -Value $importManifest
    if ($prepareExitCode -ne 0) {
      throw "prepare-patched-update failed with exit code $prepareExitCode"
    }
  }

  $scriptSucceeded = $true
  $importManifest | ConvertTo-Json -Depth 12
} finally {
  if ($KeepWorkDir -or -not $scriptSucceeded) {
    Write-ImportLog "keeping workdir: $workRoot"
  } else {
    Remove-ImportDirectory -Path $workRoot -RequiredRoot $state.Paths.Downloads
  }
}
