function Get-RepairFixedDrives {
  foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    try {
      if ($drive.DriveType -eq [IO.DriveType]::Fixed -and $drive.IsReady) {
        [pscustomobject]@{ Root = $drive.RootDirectory.FullName; AvailableFreeSpace = $drive.AvailableFreeSpace }
      }
    } catch { continue }
  }
}

function Select-RepairStorageDrive {
  param([object[]]$Drives = @(Get-RepairFixedDrives))
  $selected = $Drives | Where-Object { $_.Root -match '^[A-Za-z]:\\$' -and $_.AvailableFreeSpace -gt 0 } |
    Sort-Object @{ Expression = { [long]$_.AvailableFreeSpace }; Descending = $true }, Root | Select-Object -First 1
  if (-not $selected) { throw 'No ready fixed local drive has available space for repair artifacts.' }
  return $selected.Root
}

function Assert-RepairLocalDirectory {
  param([Parameter(Mandatory = $true)][string]$Path, [switch]$Create, [switch]$AllowMissing)
  $expanded = [Environment]::ExpandEnvironmentVariables($Path).Replace('/', '\')
  if ($expanded -notmatch '^[A-Za-z]:\\' -or $expanded.Substring(3) -match '[:*?"<>|\x00-\x1f]') {
    throw "Repair data requires an absolute path on a fixed local drive: $Path"
  }
  foreach ($part in $expanded.Substring(3).Split('\')) {
    if ($part -match '[. ]$') { throw "Repair data path contains an ambiguous directory name: $Path" }
  }
  $fullPath = [IO.Path]::GetFullPath($expanded)
  if ($fullPath.Length -gt 3) { $fullPath = $fullPath.TrimEnd('\') }
  $driveRoot = [IO.Path]::GetPathRoot($fullPath)
  $drive = [IO.DriveInfo]::new($driveRoot)
  if ($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady) {
    throw "Repair data drive is not a ready fixed local drive: $driveRoot"
  }
  $current = $driveRoot
  foreach ($part in $fullPath.Substring(3).Split('\')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $current = Join-Path $current $part
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Repair data path is not an ordinary local directory: $current"
      }
    } elseif ($Create) {
      New-Item -ItemType Directory -Path $current -ErrorAction Stop | Out-Null
    } elseif (-not $AllowMissing) {
      throw "Repair data directory does not exist: $current"
    }
  }
  return $fullPath
}

function Get-RepairStorageLayout {
  param([string]$DataRoot)
  if (-not $DataRoot) { $DataRoot = $env:CODEX_WINDOWS_REPAIR_DATA_ROOT }
  if (-not $DataRoot) { $DataRoot = Join-Path (Select-RepairStorageDrive) 'CodexData\codex-windows-fast-patch' }
  $root = Assert-RepairLocalDirectory -Path $DataRoot -AllowMissing
  if ($root.Length -le 3) { throw 'Repair data root must be a dedicated directory, not a drive root.' }
  $driveRoot = [IO.Path]::GetPathRoot($root)
  return [pscustomobject]@{
    DataRoot = $root
    RunRoot = Join-Path $root 'model-experience-repair-runs'
    LogRoot = Join-Path $root 'model-experience-repair-logs'
    # Keep ASAR paths short even when an explicit data root is deeply nested.
    TemporaryRoot = Join-Path $driveRoot 'CodexData\cwp-tmp'
    DriveRoot = $driveRoot
  }
}

function Get-RepairDataRootFromRunPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $run = [IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $run
  if ((Split-Path -Leaf $parent) -ine 'model-experience-repair-runs' -or
      (Split-Path -Leaf $run) -notmatch '^\d{8}-\d{6}-[a-f0-9]{32}$') {
    throw "Repair output must be a named direct child of model-experience-repair-runs: $run"
  }
  return (Get-RepairStorageLayout -DataRoot (Split-Path -Parent $parent)).DataRoot
}

function Get-RepairDataRootFromStatePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $statePath = [IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $statePath
  if ((Split-Path -Leaf $parent) -ine 'model-experience-repair-logs' -or
      (Split-Path -Leaf $statePath) -notmatch '\.transcript\.txt\.state\.json$') {
    throw "Repair checkpoint must be a direct child of model-experience-repair-logs: $statePath"
  }
  return (Get-RepairStorageLayout -DataRoot (Split-Path -Parent $parent)).DataRoot
}

function Get-RepairKnownDataRoots {
  param([string]$DataRoot)
  $roots = @()
  if ($DataRoot) { $roots += (Get-RepairStorageLayout -DataRoot $DataRoot).DataRoot }
  if ($env:CODEX_WINDOWS_REPAIR_DATA_ROOT) {
    $roots += (Get-RepairStorageLayout -DataRoot $env:CODEX_WINDOWS_REPAIR_DATA_ROOT).DataRoot
  }
  foreach ($drive in Get-RepairFixedDrives) {
    $roots += Join-Path $drive.Root 'CodexData\codex-windows-fast-patch'
  }
  # Discovery never creates directories or chooses a new drive for an old run.
  foreach ($root in @($roots | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $root) { Assert-RepairLocalDirectory -Path $root }
  }
}
