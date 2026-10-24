[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [switch]$Clean,
  [string]$DataRoot = 'D:\CodexData\codex-windows-fast-patch',
  [string[]]$LegacyRunPath = @(),
  [string[]]$PurgeLegacyRunPath = @(),
  [string[]]$ObsoleteBuildRootPath = @(),
  [string]$VerifiedStatePath,
  [switch]$ExplicitTargetsOnly
)

$ErrorActionPreference = 'Stop'
$stateLibrary = Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1'
. $stateLibrary
$repairRunsName = 'model-experience-repair-runs'
$repairLogsName = 'model-experience-repair-logs'
$repairTempName = 'cwp-tmp'
$verifyScript = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'

function Assert-LocalDirectoryPath {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repair data must remain on D:\: $fullPath"
  }
  if ([IO.DriveInfo]::new('D:\').DriveType -ne [IO.DriveType]::Fixed) {
    throw 'D: is not a fixed local drive.'
  }
  $current = 'D:\'
  foreach ($part in $fullPath.Substring(3).Split('\')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $current = Join-Path $current $part
    if (-not (Test-Path -LiteralPath $current)) {
      throw "Repair data path does not exist: $current"
    }
    $item = Get-Item -LiteralPath $current -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Repair data path is not a normal local directory: $current"
    }
  }
  return $fullPath
}

function ConvertTo-ExtendedPath {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith('\\?\')) { return $fullPath }
  if ($fullPath.StartsWith('\\')) { return '\\?\UNC\' + $fullPath.Substring(2) }
  return '\\?\' + $fullPath
}

function Assert-NoReparsePointsRecursive {
  param([string]$Path)
  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push((ConvertTo-ExtendedPath $Path))
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $attributes = [IO.File]::GetAttributes($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    if (-not ($attributes -band [IO.FileAttributes]::Directory)) {
      throw "Cleanup scan encountered a non-directory: $directory"
    }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Cleanup found a reparse point; artifacts were retained: $directory"
    }
    try {
      $entries = [IO.Directory]::GetFileSystemEntries($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    foreach ($entry in $entries) {
      try {
        $entryAttributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($entryAttributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($entryAttributes -band [IO.FileAttributes]::Directory) {
        $pending.Push($entry)
      }
    }
  }
}

function Get-RepairTreeSnapshot {
  param([string]$Path)
  Assert-NoReparsePointsRecursive -Path $Path
  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push((ConvertTo-ExtendedPath $Path))
  [long]$fileCount = 0
  [long]$directoryCount = 0
  [long]$bytes = 0
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $entries = [IO.Directory]::GetFileSystemEntries($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    }
    foreach ($entry in $entries) {
      try {
        $attributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($attributes -band [IO.FileAttributes]::Directory) {
        $directoryCount++
        $pending.Push($entry)
      } else {
        $fileCount++
        $bytes += ([IO.FileInfo]::new($entry)).Length
      }
    }
  }
  return [pscustomobject]@{ Files = $fileCount; Directories = $directoryCount; Bytes = $bytes }
}

function Assert-LegacyRepairRunRoot {
  param(
    [string]$Path,
    [string]$ExpectedParent,
    [datetime]$Cutoff
  )
  $fullPath = [IO.Path]::GetFullPath($Path)
  $parent = [IO.Path]::GetFullPath((Split-Path -Parent $fullPath))
  if ($parent -ine [IO.Path]::GetFullPath($ExpectedParent)) {
    throw "Legacy repair path must be a direct child of $($ExpectedParent): $fullPath"
  }
  $name = Split-Path -Leaf $fullPath
  if ($name -notmatch '^upgrade-repair-\d{8}(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?$') {
    throw "Legacy repair path has an unexpected name: $name"
  }
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Legacy repair path is not an ordinary directory: $fullPath"
  }
  if ($item.LastWriteTime -ge $Cutoff) {
    throw "Legacy repair path is newer than the 24-hour cleanup boundary: $fullPath"
  }
  $statusPath = Join-Path $fullPath 'build-status.json'
  if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw "Legacy repair ownership marker is missing: $statusPath"
  }
  $statusItem = Get-Item -LiteralPath $statusPath -Force
  if ($statusItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Legacy repair ownership marker is a reparse point: $statusPath"
  }
  $status = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json -ErrorAction Stop
  if ($status.stage -cne 'failed' -or $status.installed -isnot [bool] -or $status.installed) {
    throw "Legacy cleanup requires a failed run explicitly marked installed=false: $statusPath"
  }
  return $fullPath
}

function Get-CurrentCodexPackageVersion {
  $versions = @()
  foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
    if ([string]$process.Path -match '(?i)\\WindowsApps\\OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_') {
      try { $versions += [version]$Matches[1] } catch { }
    }
  }
  if ($versions.Count -gt 0) {
    return ($versions | Sort-Object -Descending | Select-Object -First 1)
  }
  try {
    $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
    if ($package -and $package.Version) { return [version]$package.Version }
  } catch { }
  return $null
}

function Get-CurrentCodexDesktopProcess {
  param([Parameter(Mandatory = $true)][object]$Package)
  $expectedPath = Join-Path $Package.InstallLocation 'app\ChatGPT.exe'
  $process = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -ieq $expectedPath -and $_.MainWindowHandle -ne 0 } |
    Sort-Object StartTime -Descending |
    Select-Object -First 1
  if (-not $process) { throw "A visible Codex Desktop process from the registered package was not found: $expectedPath" }
  return $process
}

function Assert-ObsoleteBuildRoot {
  param(
    [string]$Path,
    [string]$ExpectedParent,
    [version]$CurrentCodexVersion,
    [datetime]$CurrentDesktopStartTime
  )
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ([IO.Path]::GetFullPath((Split-Path -Parent $fullPath)) -ine [IO.Path]::GetFullPath($ExpectedParent)) {
    throw ('Obsolete build root must be a direct child of {0}: {1}' -f $ExpectedParent, $fullPath)
  }
  if ((Split-Path -Leaf $fullPath) -notmatch '^nonphone-repair-\d{8}-\d{4,6}$') {
    throw "Obsolete build root has an unexpected name: $fullPath"
  }
  $root = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Obsolete build root is not an ordinary directory: $fullPath"
  }
  if ($root.LastWriteTime -ge $CurrentDesktopStartTime) {
    throw "Obsolete build root is not older than the current Desktop process: $fullPath"
  }
  $top = @(Get-ChildItem -LiteralPath $fullPath -Force)
  if ($top.Count -ne 1 -or -not $top[0].PSIsContainer -or $top[0].Name -notmatch '^OpenAI\.Codex_') {
    throw "Obsolete build root must contain exactly one Codex package directory: $fullPath"
  }
  $packageRoot = [IO.Path]::GetFullPath($top[0].FullName)
  $package = Join-Path $packageRoot 'package'
  $artifacts = Join-Path $packageRoot 'artifacts'
  $packageItem = Get-Item -LiteralPath $package -Force -ErrorAction Stop
  $artifactItem = Get-Item -LiteralPath $artifacts -Force -ErrorAction Stop
  if (-not $packageItem.PSIsContainer -or -not $artifactItem.PSIsContainer -or
      ($packageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      ($artifactItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Obsolete build root is missing ordinary package or artifacts directories: $fullPath"
  }
  $packageChildren = @(Get-ChildItem -LiteralPath $packageRoot -Force | Select-Object -ExpandProperty Name | Sort-Object)
  if (($packageChildren -join '|') -cne 'artifacts|package') {
    throw "Obsolete build root contains unexpected package-root entries: $fullPath"
  }
  $manifestPath = Join-Path $package 'AppxManifest.xml'
  $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
  if ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Build manifest is a reparse point: $manifestPath" }
  try {
    [xml]$manifest = [IO.File]::ReadAllText($manifestPath)
    $identity = $manifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if (-not $identity -or $identity.Name -cne 'OpenAI.Codex') { throw 'Unexpected package identity.' }
    $manifestVersion = [version]$identity.Version
  } catch {
    throw "Obsolete build manifest could not be verified: $manifestPath ($($_.Exception.Message))"
  }
  if ($top[0].Name -notmatch '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)(?:_|$)') {
    throw "Obsolete build package directory has no exact source version: $($top[0].Name)"
  }
  $sourceVersion = [version]$Matches[1]
  if ($sourceVersion.Revision -ge 65535) { throw "Obsolete build source version cannot be incremented: $sourceVersion" }
  $expectedTargetVersion = [version]::new($sourceVersion.Major, $sourceVersion.Minor, $sourceVersion.Build, $sourceVersion.Revision + 1)
  if ($sourceVersion -ge $CurrentCodexVersion -or $top[0].Name -notlike "OpenAI.Codex_${sourceVersion}*") {
    throw "Build package version is not proven obsolete: source=$sourceVersion current=$CurrentCodexVersion"
  }
  if ($manifestVersion -ne $expectedTargetVersion) {
    throw "Build manifest is not the exact next revision: expected=$expectedTargetVersion actual=$manifestVersion"
  }
  $msixFiles = @(Get-ChildItem -LiteralPath $artifacts -File -Force)
  if ($msixFiles.Count -ne 1 -or $msixFiles[0].Name -cne "OpenAI.Codex_${sourceVersion}_patched.msix") {
    throw "Obsolete build artifacts are not an exact single-version patch output: $artifacts"
  }
  $snapshot = Get-RepairTreeSnapshot -Path $fullPath
  return [pscustomobject]@{
    Path = $fullPath
    SourceVersion = $sourceVersion
    TargetVersion = $manifestVersion
    CurrentVersion = $CurrentCodexVersion
    Snapshot = $snapshot
    ManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
  }
}

function Get-VerifiedRepairRunCandidate {
  param([string]$StatePath, [string]$DataRoot, [string]$RunsRoot)
  $fullStatePath = [IO.Path]::GetFullPath($StatePath)
  $logsRoot = [IO.Path]::GetFullPath((Join-Path $DataRoot $repairLogsName))
  if ([IO.Path]::GetFullPath((Split-Path -Parent $fullStatePath)) -ine $logsRoot -or
      (Split-Path -Leaf $fullStatePath) -notmatch '\.transcript\.txt\.state\.json$') {
    throw "Verified state must be a direct child of the repair log root: $fullStatePath"
  }
  $state = Read-RepairDeploymentState $fullStatePath
  if (-not $state.acceptancePassed -or $state.stage -notin @('cleanup-pending', 'cleanup-failed') -or
      $state.cleanupStatus -notin @('pending', 'failed')) {
    throw 'Exact-run cleanup requires a recorded accepted repair with cleanup still pending.'
  }
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
    Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package -or $package.PackageFullName -cne $state.targetPackageFullName -or [string]$package.Status -ne 'Ok') {
    throw 'Exact-run cleanup requires the same healthy target package to remain registered.'
  }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($sid -cne $state.userSid) { throw 'Exact-run cleanup must run as the original repair user.' }
  $installer = $null
  try {
    $process = Get-Process -Id ([int]$state.installerPid) -ErrorAction Stop
    $installer = [pscustomobject]@{ Id = $process.Id; StartTime = $process.StartTime; SessionId = $process.SessionId }
  } catch {
    if (-not (Test-RepairProcessNotFoundError -ErrorRecord $_)) { throw "Installer state is unknown; cleanup is refused: $($_.Exception.Message)" }
  }
  $assessment = Get-RepairDeploymentAssessment -State $state -CurrentPackage $package -InstallerProcess $installer -CurrentUserSid $sid
  if ($assessment.Status -ne 'verified-cleanup-needed') { throw "Exact-run cleanup status is not eligible: $($assessment.Status)" }
  $outputRoot = [IO.Path]::GetFullPath([string]$state.outputRoot)
  if ([IO.Path]::GetFullPath((Split-Path -Parent $outputRoot)) -ine [IO.Path]::GetFullPath($RunsRoot) -or
      (Split-Path -Leaf $outputRoot) -notmatch '^\d{8}-\d{6}-[a-f0-9]{32}$') {
    throw "Accepted output root is outside the exact repair-runs directory: $outputRoot"
  }
  if (-not (Test-Path -LiteralPath $outputRoot)) {
    return [pscustomobject]@{ Path = $outputRoot; StatePath = $fullStatePath; State = $state; Missing = $true; Snapshot = $null; SentinelId = $null }
  }
  $sentinel = Join-Path $outputRoot '.codex-model-experience-repair'
  if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { throw "Accepted output ownership marker is missing: $sentinel" }
  $sentinelItem = Get-Item -LiteralPath $sentinel -Force
  if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Accepted output marker is a reparse point: $sentinel" }
  $sentinelId = [IO.File]::ReadAllText($sentinel).Trim()
  if ($sentinelId -notmatch '^[a-f0-9]{32}$') { throw "Accepted output marker is invalid: $sentinel" }
  return [pscustomobject]@{
    Path = $outputRoot
    StatePath = $fullStatePath
    State = $state
    Missing = $false
    Snapshot = (Get-RepairTreeSnapshot -Path $outputRoot)
    SentinelId = $sentinelId
  }
}

function Get-LegacyRecoveryVersion {
  param([string]$Root)
  $manifestPath = Join-Path $Root 'recovery-layout\AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
  $manifestItem = Get-Item -LiteralPath $manifestPath -Force
  if ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Legacy recovery manifest is a reparse point: $manifestPath"
  }
  try {
    [xml]$manifest = [IO.File]::ReadAllText($manifestPath)
    $identity = $manifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if (-not $identity -or $identity.Name -cne 'OpenAI.Codex' -or [string]::IsNullOrWhiteSpace($identity.Version)) {
      throw 'Package identity or version is missing.'
    }
    return [version]$identity.Version
  } catch {
    throw "Legacy recovery manifest could not be verified; artifacts were retained: $manifestPath ($($_.Exception.Message))"
  }
}

function Get-LegacyGeneratedArtifactDirectories {
  param(
    [string]$Path,
    [version]$CurrentCodexVersion
  )
  $generatedNames = @('build', 'tmp', 'transactional')
  $recoveryPath = Join-Path $Path 'recovery-layout'
  if (Test-Path -LiteralPath $recoveryPath -PathType Container) {
    $recoveryVersion = Get-LegacyRecoveryVersion -Root $Path
    if ($CurrentCodexVersion -and $recoveryVersion -and $CurrentCodexVersion -gt $recoveryVersion) {
      $generatedNames += 'recovery-layout'
    } elseif ($recoveryVersion) {
      Write-Host ("Preserving recovery-layout: current Codex version '{0}' does not prove recovery version '{1}' obsolete." -f $CurrentCodexVersion, $recoveryVersion)
    }
  }
  $result = @()
  foreach ($name in $generatedNames) {
    $directory = Join-Path $Path $name
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
    $item = Get-Item -LiteralPath $directory -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Legacy generated directory is a reparse point; artifacts were retained: $directory"
    }
    $snapshot = Get-RepairTreeSnapshot -Path $directory
    $result += [pscustomobject]@{ Name = $name; Path = [IO.Path]::GetFullPath($directory); Snapshot = $snapshot; Bytes = $snapshot.Bytes }
  }
  return $result
}

function Remove-DirectoryTreeRobust {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Cleanup target is not an ordinary directory: $fullPath"
  }
  Assert-NoReparsePointsRecursive -Path $fullPath
  $rootPath = ConvertTo-ExtendedPath $fullPath
  $pending = [Collections.Generic.Stack[string]]::new()
  $directories = [Collections.Generic.List[string]]::new()
  $pending.Push($rootPath)
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $attributes = [IO.File]::GetAttributes($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Cleanup found a reparse point; artifacts were retained: $directory"
    }
    if (-not ($attributes -band [IO.FileAttributes]::Directory)) {
      throw "Cleanup encountered a non-directory: $directory"
    }
    $directories.Add($directory)
    try {
      $entries = [IO.Directory]::GetFileSystemEntries($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    foreach ($entry in $entries) {
      try {
        $entryAttributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($entryAttributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($entryAttributes -band [IO.FileAttributes]::Directory) {
        $pending.Push($entry)
      } else {
        try {
          [IO.File]::SetAttributes($entry, [IO.FileAttributes]::Normal)
          [IO.File]::Delete($entry)
        } catch [IO.DirectoryNotFoundException] {
          continue
        } catch [IO.FileNotFoundException] {
          continue
        }
      }
    }
  }
  for ($index = $directories.Count - 1; $index -ge 0; $index--) {
    $directory = $directories[$index]
    try {
      [IO.File]::SetAttributes($directory, [IO.FileAttributes]::Directory)
      [IO.Directory]::Delete($directory, $false)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
  }
  if (Test-Path -LiteralPath $fullPath) {
    throw "Cleanup did not remove: $fullPath"
  }
}

function Test-ActiveRepairProcess {
  param([string]$Path)
  $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  foreach ($process in $processes) {
    if ($process.ProcessId -eq $PID -or [string]::IsNullOrWhiteSpace($process.CommandLine)) { continue }
    if ($process.CommandLine.IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      return $process
    }
  }
  return $null
}

$dataRootFull = Assert-LocalDirectoryPath -Path $DataRoot
$runsRoot = Join-Path $dataRootFull $repairRunsName
if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
  if ($LegacyRunPath.Count -eq 0 -and $PurgeLegacyRunPath.Count -eq 0 -and
      $ObsoleteBuildRootPath.Count -eq 0 -and -not $VerifiedStatePath) {
    Write-Output "No repair run directory exists: $runsRoot"
    exit 0
  }
  $runsRootFull = $null
} else {
  $runsRootFull = Assert-LocalDirectoryPath -Path $runsRoot
}
$cutoff = (Get-Date).AddHours(-24)
$candidates = @()
$runDirectories = @()
if ($runsRootFull -and -not $ExplicitTargetsOnly) {
  $runDirectories = @(Get-ChildItem -LiteralPath $runsRootFull -Directory -Force)
}
foreach ($directory in $runDirectories) {
  if ($directory.Name -notmatch '^\d{8}-\d{6}-[a-f0-9]{32}$') { continue }
  if ($directory.LastWriteTime -ge $cutoff) { continue }
  if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Repair output is a reparse point: $($directory.FullName)"
  }
  $fullPath = [IO.Path]::GetFullPath($directory.FullName)
  if ((Split-Path -Parent $fullPath) -ine $runsRootFull.TrimEnd('\')) {
    throw "Repair output is not a direct child of the run root: $fullPath"
  }
  $sentinel = Join-Path $fullPath '.codex-model-experience-repair'
  if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { continue }
  $sentinelItem = Get-Item -LiteralPath $sentinel -Force
  if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Repair output ownership marker is a reparse point: $sentinel"
  }
  $sentinelId = [IO.File]::ReadAllText($sentinel).Trim()
  if ($sentinelId -notmatch '^[a-f0-9]{32}$') { continue }
  $snapshot = Get-RepairTreeSnapshot -Path $fullPath
  $candidates += [pscustomobject]@{
    Path = $fullPath
    SentinelId = $sentinelId
    SentinelName = '.codex-model-experience-repair'
    LastWriteTime = $directory.LastWriteTime
    Snapshot = $snapshot
  }
}

$repairTempRoot = Join-Path (Split-Path -Parent $dataRootFull) $repairTempName
if (-not $ExplicitTargetsOnly -and (Test-Path -LiteralPath $repairTempRoot -PathType Container)) {
  $repairTempRootFull = Assert-LocalDirectoryPath -Path $repairTempRoot
  foreach ($directory in Get-ChildItem -LiteralPath $repairTempRootFull -Directory -Force) {
    if ($directory.Name -notmatch '^r-[a-f0-9]{12}$' -or $directory.LastWriteTime -ge $cutoff) { continue }
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Repair temp workspace is a reparse point: $($directory.FullName)"
    }
    $fullPath = [IO.Path]::GetFullPath($directory.FullName)
    if ((Split-Path -Parent $fullPath) -ine $repairTempRootFull.TrimEnd('\')) {
      throw "Repair temp workspace is not a direct child of its root: $fullPath"
    }
    $sentinel = Join-Path $fullPath '.codex-model-experience-temp'
    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { continue }
    $sentinelItem = Get-Item -LiteralPath $sentinel -Force
    if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Repair temp ownership marker is a reparse point: $sentinel"
    }
    $sentinelId = [IO.File]::ReadAllText($sentinel).Trim()
    if ($sentinelId -notmatch '^[a-f0-9]{32}$') { continue }
    $snapshot = Get-RepairTreeSnapshot -Path $fullPath
    $candidates += [pscustomobject]@{
      Path = $fullPath
      SentinelId = $sentinelId
      SentinelName = '.codex-model-experience-temp'
      LastWriteTime = $directory.LastWriteTime
      Snapshot = $snapshot
    }
  }
}

$legacyCandidates = @()
$purgeLegacyCandidates = @()
$obsoleteBuildCandidates = @()
$verifiedCandidates = @()
$legacyParent = Assert-LocalDirectoryPath -Path (Split-Path -Parent $dataRootFull)
$currentCodexVersion = Get-CurrentCodexPackageVersion
if ($LegacyRunPath.Count -gt 0) {
  foreach ($requestedPath in $LegacyRunPath) {
    $legacyFullPath = Assert-LegacyRepairRunRoot -Path $requestedPath -ExpectedParent $legacyParent -Cutoff $cutoff
    $legacyFullPath = Assert-LocalDirectoryPath -Path $legacyFullPath
    $generated = @(Get-LegacyGeneratedArtifactDirectories -Path $legacyFullPath -CurrentCodexVersion $currentCodexVersion)
    if ($generated.Count -eq 0) {
      Write-Output "No known generated legacy directories remain: $legacyFullPath"
      continue
    }
    $legacyBytes = [long](($generated | Measure-Object -Property Bytes -Sum).Sum)
    $statusPath = Join-Path $legacyFullPath 'build-status.json'
    $statusHash = (Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash
    $legacyCandidates += [pscustomobject]@{
      Path = $legacyFullPath
      CurrentCodexVersion = $currentCodexVersion
      Generated = $generated
      Bytes = $legacyBytes
      StatusHash = $statusHash
    }
  }
}

foreach ($requestedPath in $PurgeLegacyRunPath) {
  $legacyFullPath = Assert-LegacyRepairRunRoot -Path $requestedPath -ExpectedParent $legacyParent -Cutoff $cutoff
  $statusPath = Join-Path $legacyFullPath 'build-status.json'
  $purgeLegacyCandidates += [pscustomobject]@{
    Path = $legacyFullPath
    StatusHash = (Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash
    Snapshot = Get-RepairTreeSnapshot -Path $legacyFullPath
  }
}

foreach ($requestedPath in $ObsoleteBuildRootPath) {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
    Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package -or [string]$package.Status -ne 'Ok') { throw 'A healthy current Codex package is required for obsolete-build cleanup.' }
  $desktopProcess = Get-CurrentCodexDesktopProcess -Package $package
  $obsoleteBuildCandidates += Assert-ObsoleteBuildRoot -Path $requestedPath -ExpectedParent $legacyParent `
    -CurrentCodexVersion ([version]$package.Version) -CurrentDesktopStartTime $desktopProcess.StartTime
}

if ($VerifiedStatePath) {
  if (-not $runsRootFull) { throw 'Verified run cleanup requires the model-experience-repair-runs directory.' }
  $verifiedCandidates += Get-VerifiedRepairRunCandidate -StatePath $VerifiedStatePath -DataRoot $dataRootFull -RunsRoot $runsRootFull
}

if ($candidates.Count -eq 0 -and $legacyCandidates.Count -eq 0 -and $purgeLegacyCandidates.Count -eq 0 -and
    $obsoleteBuildCandidates.Count -eq 0 -and $verifiedCandidates.Count -eq 0) {
  Write-Output 'No marked repair runs or explicitly selected obsolete artifacts are eligible for cleanup.'
  exit 0
}
foreach ($candidate in $candidates) {
  Write-Output ('Candidate: {0} size={1:N2} GiB files={2} modified={3:yyyy-MM-dd HH:mm:ss}' -f $candidate.Path, ($candidate.Snapshot.Bytes / 1GB), $candidate.Snapshot.Files, $candidate.LastWriteTime)
}
foreach ($candidate in $legacyCandidates) {
  Write-Output ('Legacy candidate: {0} generated-size={1:N2} GiB current-Codex={2}' -f $candidate.Path, ($candidate.Bytes / 1GB), $candidate.CurrentCodexVersion)
  foreach ($directory in $candidate.Generated) {
    Write-Output ('  {0} size={1:N2} GiB files={2}' -f $directory.Name, ($directory.Snapshot.Bytes / 1GB), $directory.Snapshot.Files)
  }
}
foreach ($candidate in $purgeLegacyCandidates) {
  Write-Output ('Explicit failed-run purge candidate: {0} size={1:N2} GiB files={2}; backups and evidence are included.' -f
    $candidate.Path, ($candidate.Snapshot.Bytes / 1GB), $candidate.Snapshot.Files)
}
foreach ($candidate in $obsoleteBuildCandidates) {
  Write-Output ('Obsolete package build candidate: {0} Codex {1} < current {2}; size={3:N2} GiB files={4}' -f
    $candidate.Path, $candidate.SourceVersion, $candidate.CurrentVersion,
    ($candidate.Snapshot.Bytes / 1GB), $candidate.Snapshot.Files)
}
foreach ($candidate in $verifiedCandidates) {
  if ($candidate.Missing) {
    Write-Output ('Accepted run already absent; checkpoint can be finalized: {0}' -f $candidate.Path)
  } else {
    Write-Output ('Accepted run cleanup candidate: {0} size={1:N2} GiB files={2}' -f
      $candidate.Path, ($candidate.Snapshot.Bytes / 1GB), $candidate.Snapshot.Files)
  }
}

if (-not $Clean) {
  Write-Output 'Dry run only. Pass -Clean to remove the listed exact repair artifacts.'
  exit 0
}

$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf) -or -not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
  throw 'Strict verification prerequisites are missing; repair artifacts were retained.'
}
$freeBefore = [IO.DriveInfo]::new('D:\').AvailableFreeSpace
$verifyArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifyScript, '-StrictVerifyOnly', '-VerifyAllBundledPluginsAvailable')
$verifyOutput = @(& $powershellExe @verifyArguments 2>&1)
$verifyExitCode = $LASTEXITCODE
foreach ($line in $verifyOutput) { Write-Host ([string]$line) }
if ($verifyExitCode -ne 0) {
  throw "Strict installed-package verification failed with exit code $verifyExitCode; repair artifacts were retained."
}

foreach ($candidate in $candidates) {
  $activeProcess = Test-ActiveRepairProcess -Path $candidate.Path
  if ($activeProcess) {
    throw "An active process references this repair run; artifacts were retained: pid=$($activeProcess.ProcessId) path=$($candidate.Path)"
  }
  $currentSentinel = Join-Path $candidate.Path $candidate.SentinelName
  if ([IO.File]::ReadAllText($currentSentinel).Trim() -cne $candidate.SentinelId) {
    throw "Repair output ownership marker changed; artifacts were retained: $($candidate.Path)"
  }
  if ($PSCmdlet.ShouldProcess($candidate.Path, 'Remove verified obsolete Codex repair build')) {
    Remove-DirectoryTreeRobust -Path $candidate.Path
  }
}

foreach ($candidate in $legacyCandidates) {
  $activeProcess = Test-ActiveRepairProcess -Path $candidate.Path
  if ($activeProcess) {
    throw "An active process references this legacy repair run; artifacts were retained: pid=$($activeProcess.ProcessId) path=$($candidate.Path)"
  }
  $statusPath = Join-Path $candidate.Path 'build-status.json'
  if ((Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash -cne $candidate.StatusHash) {
    throw "Legacy repair ownership marker changed; artifacts were retained: $($candidate.Path)"
  }
  $currentVersion = Get-CurrentCodexPackageVersion
  $currentGenerated = @(Get-LegacyGeneratedArtifactDirectories -Path $candidate.Path -CurrentCodexVersion $currentVersion)
  $expectedNames = @($candidate.Generated | ForEach-Object { $_.Name }) -join '|'
  $actualNames = @($currentGenerated | ForEach-Object { $_.Name }) -join '|'
  if ($actualNames -cne $expectedNames) {
    throw "Legacy generated-artifact set changed; artifacts were retained: $($candidate.Path)"
  }
  for ($index = 0; $index -lt $candidate.Generated.Count; $index++) {
    $expected = $candidate.Generated[$index]
    $actual = $currentGenerated[$index]
    if ($actual.Snapshot.Files -ne $expected.Snapshot.Files -or
        $actual.Snapshot.Directories -ne $expected.Snapshot.Directories -or
        $actual.Snapshot.Bytes -ne $expected.Snapshot.Bytes) {
      throw "Legacy generated artifact changed after inventory; artifacts were retained: $($expected.Path)"
    }
    if ($PSCmdlet.ShouldProcess($expected.Path, 'Remove verified obsolete legacy Codex build artifact')) {
      Remove-DirectoryTreeRobust -Path $expected.Path
    }
  }
}

foreach ($candidate in $purgeLegacyCandidates) {
  $activeProcess = Test-ActiveRepairProcess -Path $candidate.Path
  if ($activeProcess) {
    throw "An active process references this failed legacy run; artifacts were retained: pid=$($activeProcess.ProcessId) path=$($candidate.Path)"
  }
  $statusPath = Join-Path $candidate.Path 'build-status.json'
  if ((Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash -cne $candidate.StatusHash) {
    throw "Legacy run record changed after inventory; the complete run was retained: $($candidate.Path)"
  }
  $currentStatus = Assert-LegacyRepairRunRoot -Path $candidate.Path -ExpectedParent $legacyParent -Cutoff (Get-Date).AddHours(-24)
  $currentSnapshot = Get-RepairTreeSnapshot -Path $currentStatus
  if ($currentSnapshot.Files -ne $candidate.Snapshot.Files -or
      $currentSnapshot.Directories -ne $candidate.Snapshot.Directories -or
      $currentSnapshot.Bytes -ne $candidate.Snapshot.Bytes) {
    throw "Legacy run contents changed after inventory; the complete run was retained: $($candidate.Path)"
  }
  if ($PSCmdlet.ShouldProcess($candidate.Path, 'Remove explicitly selected failed Codex repair run, including its backups and evidence')) {
    Remove-DirectoryTreeRobust -Path $candidate.Path
  }
}

foreach ($candidate in $obsoleteBuildCandidates) {
  $activeProcess = Test-ActiveRepairProcess -Path $candidate.Path
  if ($activeProcess) {
    throw "An active process references this obsolete package build; artifacts were retained: pid=$($activeProcess.ProcessId) path=$($candidate.Path)"
  }
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
    Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package -or [string]$package.Status -ne 'Ok') { throw 'Current Codex package became unavailable; obsolete build was retained.' }
  $desktopProcess = Get-CurrentCodexDesktopProcess -Package $package
  $actual = Assert-ObsoleteBuildRoot -Path $candidate.Path -ExpectedParent $legacyParent `
    -CurrentCodexVersion ([version]$package.Version) -CurrentDesktopStartTime $desktopProcess.StartTime
  if ($actual.SourceVersion -ne $candidate.SourceVersion -or
      $actual.ManifestHash -cne $candidate.ManifestHash -or
      $actual.Snapshot.Files -ne $candidate.Snapshot.Files -or
      $actual.Snapshot.Directories -ne $candidate.Snapshot.Directories -or
      $actual.Snapshot.Bytes -ne $candidate.Snapshot.Bytes) {
    throw "Obsolete build changed after inventory; artifacts were retained: $($candidate.Path)"
  }
  if ($PSCmdlet.ShouldProcess($candidate.Path, 'Remove explicitly selected obsolete Codex package build')) {
    Remove-DirectoryTreeRobust -Path $candidate.Path
  }
}

foreach ($candidate in $verifiedCandidates) {
  $activeProcess = Test-ActiveRepairProcess -Path $candidate.Path
  if ($activeProcess) {
    throw "An active process references this accepted repair run; artifacts were retained: pid=$($activeProcess.ProcessId) path=$($candidate.Path)"
  }
  $current = Get-VerifiedRepairRunCandidate -StatePath $candidate.StatePath -DataRoot $dataRootFull -RunsRoot $runsRootFull
  if ($current.Path -cne $candidate.Path -or $current.State.targetPackageFullName -cne $candidate.State.targetPackageFullName -or
      $current.State.verifiedUtc -cne $candidate.State.verifiedUtc) {
    throw "Accepted repair state changed after inventory; artifacts were retained: $($candidate.Path)"
  }
  if ($candidate.Missing -ne $current.Missing) {
    throw "Accepted repair output presence changed after inventory: $($candidate.Path)"
  }
  if (-not $candidate.Missing -and ($current.Snapshot.Files -ne $candidate.Snapshot.Files -or
      $current.Snapshot.Directories -ne $candidate.Snapshot.Directories -or
      $current.Snapshot.Bytes -ne $candidate.Snapshot.Bytes -or $current.SentinelId -cne $candidate.SentinelId)) {
    throw "Accepted repair output changed after inventory; artifacts were retained: $($candidate.Path)"
  }
  if ($PSCmdlet.ShouldProcess($candidate.Path, 'Remove the exact accepted Codex repair build and recovery package')) {
    if (-not $candidate.Missing) { Remove-DirectoryTreeRobust -Path $candidate.Path }
    $state = Read-RepairDeploymentState $candidate.StatePath
    if (-not $state.acceptancePassed -or $state.targetPackageFullName -cne $candidate.State.targetPackageFullName -or
        $state.verifiedUtc -cne $candidate.State.verifiedUtc) {
      throw 'Accepted repair checkpoint changed during cleanup; the remaining state was retained.'
    }
    $state.cleanupStatus = 'removed'
    $state.stage = 'verified-complete'
    Write-RepairDeploymentState -Path $candidate.StatePath -State $state
  }
}

$remaining = @($candidates | Where-Object { Test-Path -LiteralPath $_.Path })
$legacyRemaining = @()
foreach ($candidate in $legacyCandidates) {
  foreach ($directory in $candidate.Generated) {
    if (Test-Path -LiteralPath $directory.Path) { $legacyRemaining += $directory.Path }
  }
}
$purgeLegacyRemaining = @($purgeLegacyCandidates | Where-Object { Test-Path -LiteralPath $_.Path })
$obsoleteBuildRemaining = @($obsoleteBuildCandidates | Where-Object { Test-Path -LiteralPath $_.Path })
$verifiedRemaining = @($verifiedCandidates | Where-Object { Test-Path -LiteralPath $_.Path })
if (($remaining.Count + $legacyRemaining.Count + $purgeLegacyRemaining.Count +
    $obsoleteBuildRemaining.Count + $verifiedRemaining.Count) -gt 0) {
  $remainingPaths = @($remaining | ForEach-Object { $_.Path }) + $legacyRemaining +
    @($purgeLegacyRemaining | ForEach-Object { $_.Path }) + @($obsoleteBuildRemaining | ForEach-Object { $_.Path }) +
    @($verifiedRemaining | ForEach-Object { $_.Path })
  Write-Output ('Cleanup not applied to: ' + ($remainingPaths -join ', '))
  exit 0
}
$freeAfter = [IO.DriveInfo]::new('D:\').AvailableFreeSpace
$spaceChange = ($freeAfter - $freeBefore) / 1GB
Write-Output ('CLEANUP_PASSED verified-runs={0} obsolete-builds={1} failed-runs-purged={2} generated-legacy-artifacts={3} released={4:N2} GiB; non-selected backups and evidence were retained.' -f
  $verifiedCandidates.Count, $obsoleteBuildCandidates.Count, $purgeLegacyCandidates.Count, $legacyCandidates.Count, $spaceChange)
