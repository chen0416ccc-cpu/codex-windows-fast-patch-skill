$script:CodexDesktopGuardKnownMappings = @(
  [pscustomobject]@{
    PackageVersion = '26.623.9142.0'
    NativeCliVersion = '0.142.4'
    CodexSourceRef = 'rust-v0.142.4'
    AppServerVersion = '0.142.4'
    NativeSha256 = 'D6D96386EF54A2B523DE4DAB4C325400AD2817D9C66375BDB6924CAF882FA1FC'
  }
)

function Assert-GuardWindows {
  if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'Codex Desktop Guard is Windows-only.'
  }
}

function Get-GuardDefaultStateRoot {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is not set.'
  }
  return (Join-Path $env:USERPROFILE '.codex-fast-patch')
}

function Resolve-GuardFullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [System.IO.Path]::GetFullPath($Path)
}

function New-GuardDirectorySet {
  param([string]$StateRoot)
  if ([string]::IsNullOrWhiteSpace($StateRoot)) {
    $StateRoot = Get-GuardDefaultStateRoot
  }
  $root = Resolve-GuardFullPath $StateRoot
  return [pscustomobject]@{
    Root = $root
    Baselines = Join-Path $root 'baselines'
    Staging = Join-Path $root 'staging'
    Logs = Join-Path $root 'logs'
    Notifications = Join-Path $root 'notifications'
    Downloads = Join-Path $root 'downloads'
    Incoming = Join-Path $root 'incoming'
  }
}

function Initialize-GuardState {
  param([string]$StateRoot)
  $paths = New-GuardDirectorySet -StateRoot $StateRoot
  New-Item -ItemType Directory -Force -Path $paths.Root, $paths.Baselines, $paths.Staging, $paths.Logs, $paths.Notifications, $paths.Downloads, $paths.Incoming | Out-Null
  return [pscustomobject]@{
    Paths = $paths
    CreatedAt = (Get-Date).ToString('o')
  }
}

function Get-GuardConfigPath {
  param([Parameter(Mandatory = $true)][object]$State)
  return (Join-Path $State.Paths.Root 'guard-config.json')
}

function Read-GuardConfig {
  param([Parameter(Mandatory = $true)][object]$State)
  return (Read-GuardJsonFile -Path (Get-GuardConfigPath -State $State))
}

function Get-GuardMirrorFallbackSettings {
  param([Parameter(Mandatory = $true)][object]$State)
  $config = Read-GuardConfig -State $State
  $configUrl = [string](Resolve-GuardPropertyPath -Object $config -Path 'UpdateSources.MirrorPackageUrl')
  $configLabel = [string](Resolve-GuardPropertyPath -Object $config -Path 'UpdateSources.MirrorLabel')
  $enabledValue = Resolve-GuardPropertyPath -Object $config -Path 'UpdateSources.MirrorEnabled'

  $packageUrl = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_GUARD_MIRROR_PACKAGE_URL)) {
    [string]$env:CODEX_GUARD_MIRROR_PACKAGE_URL
  } else {
    $configUrl
  }
  $label = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_GUARD_MIRROR_LABEL)) {
    [string]$env:CODEX_GUARD_MIRROR_LABEL
  } elseif (-not [string]::IsNullOrWhiteSpace($configLabel)) {
    $configLabel
  } elseif (-not [string]::IsNullOrWhiteSpace($packageUrl)) {
    'community_mirror'
  } else {
    $null
  }

  $enabled = if ($null -ne $enabledValue) {
    [bool]$enabledValue
  } else {
    -not [string]::IsNullOrWhiteSpace($packageUrl)
  }

  return [pscustomobject]@{
    Enabled = $enabled
    PackageUrl = $packageUrl
    Label = $label
    ConfigPath = (Get-GuardConfigPath -State $State)
  }
}

function Write-GuardUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][string]$Content
  )
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, [string]$Content, $encoding)
}

function Write-GuardLog {
  param(
    [Parameter(Mandatory = $true)][object]$State,
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$LogName = 'guard.log'
  )
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  if ($State -and $State.Paths -and $State.Paths.Logs) {
    $logPath = Join-Path $State.Paths.Logs $LogName
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
  }
}

function Write-GuardJsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value,
    [int]$Depth = 12
  )
  $json = $Value | ConvertTo-Json -Depth $Depth
  $tempPath = '{0}.{1}.tmp' -f $Path, $PID
  Write-GuardUtf8NoBom -Path $tempPath -Content ($json + "`r`n")
  Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Read-GuardJsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  $raw = Get-Content -Raw -LiteralPath $Path
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }
  return ($raw | ConvertFrom-Json)
}

function Add-GuardJsonLine {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value,
    [int]$Depth = 12
  )
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $line = $Value | ConvertTo-Json -Depth $Depth -Compress
  Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-GuardSha256Text {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-GuardObjectSignature {
  param([AllowNull()][object]$Value)
  $json = $Value | ConvertTo-Json -Depth 8 -Compress
  if ($null -eq $json) {
    $json = 'null'
  }
  return (Get-GuardSha256Text -Text ([string]$json)).Substring(0, 16)
}

function ConvertTo-GuardPowerShellArgument {
  param([AllowNull()][string]$Argument)
  if ($null -eq $Argument) {
    return "''"
  }
  return "'" + ([string]$Argument).Replace("'", "''") + "'"
}

function ConvertTo-GuardWindowsCommandArgument {
  param([AllowNull()][string]$Argument)
  if ($null -eq $Argument) {
    return '""'
  }
  return '"' + ([string]$Argument).Replace('"', '\"') + '"'
}

function Get-GuardFileFingerprint {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{
      Path = $Path
      Exists = $false
      Length = $null
      LastWriteTimeUtc = $null
      Sha256 = $null
    }
  }
  $item = Get-Item -LiteralPath $Path -ErrorAction Stop
  return [pscustomobject]@{
    Path = $item.FullName
    Exists = $true
    Length = $item.Length
    LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToUpperInvariant()
  }
}

function Invoke-GuardProcessCapture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 15
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $quotedArguments = New-Object System.Collections.Generic.List[string]
  foreach ($argument in $Arguments) {
    $value = [string]$argument
    if ($value -match '[\s"]') {
      $value = '"' + $value.Replace('\', '\\').Replace('"', '\"') + '"'
    }
    $quotedArguments.Add($value)
  }
  $psi.Arguments = ($quotedArguments -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try {
        $process.Kill()
      } catch {
      }
      try {
        [void]$process.WaitForExit(5000)
      } catch {
      }
      throw "process timed out: $FilePath"
    }
    [void]$stdoutTask.Wait(5000)
    [void]$stderrTask.Wait(5000)
    $stdout = if ($stdoutTask.IsCompleted) { [string]$stdoutTask.Result } else { '' }
    $stderr = if ($stderrTask.IsCompleted) { [string]$stderrTask.Result } else { '' }
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdout.Trim()
      Stderr = $stderr.Trim()
    }
  } finally {
    $process.Dispose()
  }
}

function Find-GuardLocalCodexCli {
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
    return $null
  }
  return Get-ChildItem -LiteralPath $binRoot -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
}

function Get-GuardLocalCodexCliInfo {
  $hit = Find-GuardLocalCodexCli
  if (-not $hit) {
    return [pscustomobject]@{
      Path = $null
      Exists = $false
      Length = $null
      LastWriteTimeUtc = $null
      Sha256 = $null
      VersionOutput = $null
      Version = $null
      VersionError = 'local copied CLI not found'
    }
  }
  $fingerprint = Get-GuardFileFingerprint -Path $hit.FullName
  $versionOutput = $null
  $version = $null
  $versionError = $null
  try {
    $capture = Invoke-GuardProcessCapture -FilePath $hit.FullName -Arguments @('--version') -TimeoutSeconds 15
    $versionOutput = (($capture.Stdout, $capture.Stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    if ($versionOutput -match 'codex-cli\s+([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)') {
      $version = $matches[1]
    } else {
      $versionError = "could not parse codex-cli version from: $versionOutput"
    }
  } catch {
    $versionError = $_.Exception.Message
  }
  return [pscustomobject]@{
    Path = $fingerprint.Path
    Exists = $fingerprint.Exists
    Length = $fingerprint.Length
    LastWriteTimeUtc = $fingerprint.LastWriteTimeUtc
    Sha256 = $fingerprint.Sha256
    VersionOutput = $versionOutput
    Version = $version
    VersionError = $versionError
  }
}

function Get-GuardCodexDesktopProcesses {
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'Codex.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath -like '*\WindowsApps\OpenAI.Codex_*' -and
        $_.ExecutablePath -like '*\app\Codex.exe'
      } |
      Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine)
  } catch {
    return @()
  }
}

function Test-GuardInvokedFromCodexDesktop {
  $currentPid = $PID
  $seen = @{}
  for ($i = 0; $i -lt 24; $i++) {
    if ($seen.ContainsKey([string]$currentPid)) {
      return $false
    }
    $seen[[string]$currentPid] = $true
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $currentPid" -ErrorAction SilentlyContinue
    if (-not $process) {
      return $false
    }
    if ($process.ExecutablePath -and $process.ExecutablePath -like '*\WindowsApps\OpenAI.Codex_*') {
      return $true
    }
    if (-not $process.ParentProcessId -or $process.ParentProcessId -eq 0) {
      return $false
    }
    $currentPid = [int]$process.ParentProcessId
  }
  return $false
}

function Get-GuardSnapshot {
  Assert-GuardWindows
  $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1

  $packageInfo = $null
  $resources = [pscustomobject]@{
    CodexExe = Get-GuardFileFingerprint -Path $null
    AppAsar = Get-GuardFileFingerprint -Path $null
  }
  if ($pkg -and $pkg.InstallLocation) {
    $codexExe = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'
    $appAsar = Join-Path $pkg.InstallLocation 'app\resources\app.asar'
    $packageInfo = [pscustomobject]@{
      Name = $pkg.Name
      PackageFullName = $pkg.PackageFullName
      Version = $pkg.Version.ToString()
      SignatureKind = [string]$pkg.SignatureKind
      InstallLocation = $pkg.InstallLocation
    }
    $resources = [pscustomobject]@{
      CodexExe = Get-GuardFileFingerprint -Path $codexExe
      AppAsar = Get-GuardFileFingerprint -Path $appAsar
    }
  }

  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  return [pscustomobject]@{
    SchemaVersion = 1
    CreatedAt = (Get-Date).ToString('o')
    Package = $packageInfo
    Resources = $resources
    LocalCli = Get-GuardLocalCodexCliInfo
    CodexConfigToml = Get-GuardFileFingerprint -Path $configPath
    UpdateSignals = Get-GuardUpdateSignals
  }
}

function Get-GuardCodexWindowsAppsDirectories {
  $root = 'C:\Program Files\WindowsApps'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    return @()
  }
  try {
    return @(Get-ChildItem -LiteralPath $root -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue |
      Sort-Object Name |
      Select-Object Name, FullName, @{Name = 'LastWriteTimeUtc'; Expression = { $_.LastWriteTimeUtc.ToString('o') } }, @{Name = 'CreationTimeUtc'; Expression = { $_.CreationTimeUtc.ToString('o') } })
  } catch {
    return @()
  }
}

function Get-GuardRecentCodexAppxEvents {
  $events = New-Object System.Collections.Generic.List[object]
  $logs = @('Microsoft-Windows-AppXDeploymentServer/Operational', 'Microsoft-Windows-AppXDeployment/Operational')
  foreach ($log in $logs) {
    try {
      Get-WinEvent -LogName $log -MaxEvents 120 -ErrorAction SilentlyContinue |
        Where-Object {
          $_.TimeCreated -gt (Get-Date).AddHours(-6) -and
          $_.Message -match 'OpenAI\.Codex|OpenAI Codex|Codex'
        } |
        ForEach-Object {
          $message = [string]$_.Message
          $message = ($message -replace "`r?`n", ' ').Trim()
          if ($message.Length -gt 280) {
            $message = $message.Substring(0, 280)
          }
          $events.Add([pscustomobject]@{
            LogName = $log
            TimeCreated = $_.TimeCreated.ToString('o')
            Id = $_.Id
            Level = $_.LevelDisplayName
            MessageExcerpt = $message
          })
        }
    } catch {
    }
  }
  return @($events | Sort-Object TimeCreated, Id)
}

function Get-GuardCodexBitsTransfers {
  try {
    $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop)
  } catch {
    try {
      $jobs = @(Get-BitsTransfer -ErrorAction Stop)
    } catch {
      return [pscustomobject]@{
        Error = $_.Exception.Message
        Jobs = @()
      }
    }
  }

  $matches = @($jobs | Where-Object {
    ([string]$_.DisplayName -match 'OpenAI|Codex') -or
    ([string]$_.Description -match 'OpenAI|Codex')
  } | Select-Object DisplayName, Description, JobState, OwnerAccount, BytesTransferred, BytesTotal, @{Name = 'CreationTime'; Expression = { if ($_.CreationTime) { $_.CreationTime.ToString('o') } else { $null } } }, @{Name = 'ModificationTime'; Expression = { if ($_.ModificationTime) { $_.ModificationTime.ToString('o') } else { $null } } })

  return [pscustomobject]@{
    Error = $null
    Jobs = $matches
  }
}

function Get-GuardStoreUpdateProcesses {
  $names = @(
    'WinStore.App',
    'StoreExperienceHost',
    'Microsoft.StorePurchaseApp',
    'AppInstaller',
    'BackgroundTransferHost'
  )
  return @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $names -contains $_.ProcessName } |
    Select-Object Id, ProcessName, Path, @{Name = 'StartTime'; Expression = { try { $_.StartTime.ToString('o') } catch { $null } } } |
    Sort-Object ProcessName, Id)
}

function Get-GuardDoctorUpdateStatus {
  $cli = Get-GuardLocalCodexCliInfo
  if (-not $cli.Exists -or [string]::IsNullOrWhiteSpace($cli.Path)) {
    return [pscustomobject]@{
      Available = $false
      Error = 'local copied CLI not found'
      CodexVersion = $null
      UpdateStatus = $null
      UpdateSummary = $null
      StartupUpdateCheck = $null
      LatestVersion = $null
      LatestVersionStatus = $null
      LatestVersionProbe = $null
      UpdateAction = $null
      VersionCache = $null
      Signature = Get-GuardObjectSignature 'local copied CLI not found'
    }
  }

  try {
    $capture = Invoke-GuardProcessCapture -FilePath $cli.Path -Arguments @('doctor', '--json', '--summary') -TimeoutSeconds 90
    if ([string]::IsNullOrWhiteSpace($capture.Stdout)) {
      if ($capture.ExitCode -ne 0) {
        throw "doctor --json exited with $($capture.ExitCode): $($capture.Stderr)"
      }
      throw 'doctor --json returned empty stdout'
    }
    $report = $capture.Stdout | ConvertFrom-Json
    $updates = $report.checks.'updates.status'
    $details = if ($updates) { $updates.details } else { $null }
    $probe = if ($details -and $details.PSObject.Properties['latest version probe']) { [string]$details.'latest version probe' } else { $null }
    $latestVersion = if ($details -and $details.PSObject.Properties['latest version']) { [string]$details.'latest version' } else { $null }
    $latestVersionStatus = if ($details -and $details.PSObject.Properties['latest version status']) { [string]$details.'latest version status' } else { $null }
    $startup = if ($details -and $details.PSObject.Properties['check for update on startup']) { [string]$details.'check for update on startup' } else { $null }
    $action = if ($details -and $details.PSObject.Properties['update action']) { [string]$details.'update action' } else { $null }
    $cache = if ($details -and $details.PSObject.Properties['version cache']) { $details.'version cache' } else { $null }
    $summary = if ($updates) { [string]$updates.summary } else { $null }
    $status = if ($updates) { [string]$updates.status } else { $null }
    $available = $false
    if ($status -and $status -notin @('ok', '')) {
      $available = $true
    }
    if ($summary -match 'available|update|newer|latest' -or $probe -match 'available|newer|latest|403|error|failed' -or $latestVersionStatus -match 'available|newer|latest') {
      $available = $true
    }
    $payload = [pscustomobject]@{
      CodexVersion = [string]$report.codexVersion
      UpdateStatus = $status
      UpdateSummary = $summary
      StartupUpdateCheck = $startup
      LatestVersion = $latestVersion
      LatestVersionStatus = $latestVersionStatus
      LatestVersionProbe = $probe
      UpdateAction = $action
      VersionCache = $cache
    }
    $exitError = $null
    if ($capture.ExitCode -ne 0) {
      $exitError = "doctor --json exited with $($capture.ExitCode): $($capture.Stderr)"
    }
    return [pscustomobject]@{
      Available = [bool]$available
      Error = $exitError
      CodexVersion = $payload.CodexVersion
      UpdateStatus = $payload.UpdateStatus
      UpdateSummary = $payload.UpdateSummary
      StartupUpdateCheck = $payload.StartupUpdateCheck
      LatestVersion = $payload.LatestVersion
      LatestVersionStatus = $payload.LatestVersionStatus
      LatestVersionProbe = $payload.LatestVersionProbe
      UpdateAction = $payload.UpdateAction
      VersionCache = $payload.VersionCache
      Signature = Get-GuardObjectSignature $payload
    }
  } catch {
    $payload = [pscustomobject]@{
      Error = $_.Exception.Message
      CodexVersion = $cli.Version
    }
    return [pscustomobject]@{
      Available = $true
      Error = $_.Exception.Message
      CodexVersion = $cli.Version
      UpdateStatus = 'unknown'
      UpdateSummary = 'codex doctor update check failed'
      StartupUpdateCheck = $null
      LatestVersion = $null
      LatestVersionStatus = $null
      LatestVersionProbe = $null
      UpdateAction = $null
      VersionCache = $null
      Signature = Get-GuardObjectSignature $payload
    }
  }
}

function Get-GuardUpdateSignals {
  $dirs = @(Get-GuardCodexWindowsAppsDirectories)
  $events = @(Get-GuardRecentCodexAppxEvents)
  $bits = Get-GuardCodexBitsTransfers
  $processes = @(Get-GuardStoreUpdateProcesses)
  $doctor = Get-GuardDoctorUpdateStatus
  $doctorActivitySignature = Get-GuardObjectSignature ([pscustomobject]@{
    CodexVersion = $doctor.CodexVersion
    HasDoctorUpdateActivity = [bool]$doctor.Available
  })
  $hasCodexUpdateActivity = ($dirs.Count -gt 1) -or ($events.Count -gt 0) -or ($bits.Jobs.Count -gt 0) -or $doctor.Available
  return [pscustomobject]@{
    HasCodexUpdateActivity = [bool]$hasCodexUpdateActivity
    CodexWindowsAppsDirectoryCount = $dirs.Count
    CodexWindowsAppsDirectorySignature = Get-GuardObjectSignature $dirs
    CodexWindowsAppsDirectories = $dirs
    RecentCodexAppxEventCount = $events.Count
    RecentCodexAppxEventSignature = Get-GuardObjectSignature $events
    RecentCodexAppxEvents = $events
    BitsCodexTransferCount = $bits.Jobs.Count
    BitsCodexTransferSignature = Get-GuardObjectSignature $bits
    BitsCodexTransfers = $bits.Jobs
    BitsError = $bits.Error
    StoreUpdateProcessCount = $processes.Count
    StoreUpdateProcessSignature = Get-GuardObjectSignature $processes
    StoreUpdateProcesses = $processes
    DoctorCodexVersion = $doctor.CodexVersion
    DoctorUpdateStatus = $doctor.UpdateStatus
    DoctorUpdateSummary = $doctor.UpdateSummary
    DoctorStartupUpdateCheck = $doctor.StartupUpdateCheck
    DoctorLatestVersion = $doctor.LatestVersion
    DoctorLatestVersionStatus = $doctor.LatestVersionStatus
    DoctorLatestVersionProbe = $doctor.LatestVersionProbe
    DoctorUpdateAction = $doctor.UpdateAction
    DoctorVersionCache = $doctor.VersionCache
    DoctorUpdateError = $doctor.Error
    DoctorUpdateDetailSignature = $doctor.Signature
    DoctorUpdateSignature = $doctorActivitySignature
  }
}

function Resolve-GuardPropertyPath {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $current = $Object
  foreach ($part in $Path.Split('.')) {
    if ($null -eq $current) {
      return $null
    }
    $property = $current.PSObject.Properties[$part]
    if (-not $property) {
      return $null
    }
    $current = $property.Value
  }
  return $current
}

function Compare-GuardSnapshots {
  param(
    [AllowNull()][object]$Baseline,
    [Parameter(Mandatory = $true)][object]$Current
  )
  if ($null -eq $Baseline) {
    return @()
  }
  $fields = @(
    @{ Name = 'package_full_name'; Path = 'Package.PackageFullName' },
    @{ Name = 'package_version'; Path = 'Package.Version' },
    @{ Name = 'package_signature_kind'; Path = 'Package.SignatureKind' },
    @{ Name = 'install_location'; Path = 'Package.InstallLocation' },
    @{ Name = 'resources_codex_exe_sha256'; Path = 'Resources.CodexExe.Sha256' },
    @{ Name = 'resources_codex_exe_length'; Path = 'Resources.CodexExe.Length' },
    @{ Name = 'resources_app_asar_sha256'; Path = 'Resources.AppAsar.Sha256' },
    @{ Name = 'resources_app_asar_length'; Path = 'Resources.AppAsar.Length' },
    @{ Name = 'local_cli_path'; Path = 'LocalCli.Path' },
    @{ Name = 'local_cli_sha256'; Path = 'LocalCli.Sha256' },
    @{ Name = 'local_cli_version'; Path = 'LocalCli.Version' },
    @{ Name = 'codex_config_toml_sha256'; Path = 'CodexConfigToml.Sha256' },
    @{ Name = 'codex_config_toml_length'; Path = 'CodexConfigToml.Length' },
    @{ Name = 'codex_windowsapps_dir_signature'; Path = 'UpdateSignals.CodexWindowsAppsDirectorySignature' },
    @{ Name = 'appx_codex_event_signature'; Path = 'UpdateSignals.RecentCodexAppxEventSignature' },
    @{ Name = 'bits_codex_transfer_signature'; Path = 'UpdateSignals.BitsCodexTransferSignature' },
    @{ Name = 'doctor_update_signature'; Path = 'UpdateSignals.DoctorUpdateSignature' }
  )
  $changes = New-Object System.Collections.Generic.List[object]
  foreach ($field in $fields) {
    $before = Resolve-GuardPropertyPath -Object $Baseline -Path $field.Path
    $after = Resolve-GuardPropertyPath -Object $Current -Path $field.Path
    if ([string]$before -ne [string]$after) {
      $changes.Add([pscustomobject]@{
        Name = $field.Name
        Path = $field.Path
        Before = $before
        After = $after
      })
    }
  }
  return $changes.ToArray()
}

function New-GuardEventId {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
    [Parameter(Mandatory = $true)][object]$Snapshot
  )
  $payload = [pscustomobject]@{
    Changes = $Changes
    PackageFullName = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.PackageFullName'
    CodexExeSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Resources.CodexExe.Sha256'
    AppAsarSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Resources.AppAsar.Sha256'
    LocalCliSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Sha256'
    ConfigSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'CodexConfigToml.Sha256'
  }
  $json = $payload | ConvertTo-Json -Depth 12 -Compress
  return (Get-GuardSha256Text -Text $json).Substring(0, 16)
}

function New-GuardUpdateActivityEventId {
  param([Parameter(Mandatory = $true)][object]$Snapshot)
  $payload = [pscustomobject]@{
    Kind = 'update_activity'
    PackageFullName = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.PackageFullName'
    PackageVersion = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.Version'
    CodexExeSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Resources.CodexExe.Sha256'
    AppAsarSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Resources.AppAsar.Sha256'
    LocalCliSha256 = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Sha256'
    LocalCliVersion = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Version'
    DoctorUpdateSignature = Resolve-GuardPropertyPath -Object $Snapshot -Path 'UpdateSignals.DoctorUpdateSignature'
    HasCodexUpdateActivity = Resolve-GuardPropertyPath -Object $Snapshot -Path 'UpdateSignals.HasCodexUpdateActivity'
  }
  $json = $payload | ConvertTo-Json -Depth 12 -Compress
  return (Get-GuardSha256Text -Text $json).Substring(0, 16)
}

function Resolve-GuardKnownVersionMapping {
  param([Parameter(Mandatory = $true)][object]$Snapshot)
  $reasons = New-Object System.Collections.Generic.List[string]
  $packageVersion = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.Version'
  $packageFullName = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.PackageFullName'
  $nativeVersion = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Version'
  $nativeVersionError = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.VersionError'
  $liveNativeSha = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Resources.CodexExe.Sha256'
  $localNativeSha = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Sha256'

  if ([string]::IsNullOrWhiteSpace($packageVersion) -or [string]::IsNullOrWhiteSpace($packageFullName)) {
    $reasons.Add('OpenAI.Codex package was not found.')
  }

  $mapping = $script:CodexDesktopGuardKnownMappings |
    Where-Object { $_.PackageVersion -eq [string]$packageVersion } |
    Select-Object -First 1
  if (-not $mapping) {
    $reasons.Add("No safe version mapping is known for package version '$packageVersion'.")
  } else {
    if ([string]::IsNullOrWhiteSpace($nativeVersion)) {
      if ([string]::IsNullOrWhiteSpace($nativeVersionError)) {
        $reasons.Add('Could not determine local copied codex-cli version.')
      } else {
        $reasons.Add("Could not determine local copied codex-cli version: $nativeVersionError")
      }
    } elseif ($nativeVersion -ne $mapping.NativeCliVersion) {
      $reasons.Add("Local copied codex-cli version '$nativeVersion' does not match expected '$($mapping.NativeCliVersion)'.")
    }

    $expectedSha = $mapping.NativeSha256.ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($liveNativeSha)) {
      $reasons.Add('Live resources\codex.exe hash is unavailable.')
    } elseif ($liveNativeSha.ToUpperInvariant() -ne $expectedSha) {
      $reasons.Add("Live resources\codex.exe hash '$liveNativeSha' does not match expected '$expectedSha'.")
    }

    if ([string]::IsNullOrWhiteSpace($localNativeSha)) {
      $reasons.Add('Local copied codex.exe hash is unavailable.')
    } elseif ($localNativeSha.ToUpperInvariant() -ne $expectedSha) {
      $reasons.Add("Local copied codex.exe hash '$localNativeSha' does not match expected '$expectedSha'.")
    }
  }

  return [pscustomobject]@{
    Safe = ($reasons.Count -eq 0)
    Mapping = $mapping
    Reasons = @($reasons)
    PackageVersion = $packageVersion
    PackageFullName = $packageFullName
    NativeCliVersion = $nativeVersion
    LiveNativeSha256 = $liveNativeSha
    LocalNativeSha256 = $localNativeSha
  }
}

function Resolve-GuardPayloadVersionMapping {
  param(
    [Parameter(Mandatory = $true)][object]$Snapshot,
    [switch]$AllowInferred
  )
  $known = Resolve-GuardKnownVersionMapping -Snapshot $Snapshot
  if ($known.Safe -or -not $AllowInferred) {
    return $known
  }

  $reasons = New-Object System.Collections.Generic.List[string]
  $packageVersion = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.Version'
  $packageFullName = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Package.PackageFullName'
  $nativeVersion = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Version'
  $nativeVersionError = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.VersionError'
  $liveNativeSha = Resolve-GuardPropertyPath -Object $Snapshot -Path 'Resources.CodexExe.Sha256'
  $localNativeSha = Resolve-GuardPropertyPath -Object $Snapshot -Path 'LocalCli.Sha256'

  if ([string]::IsNullOrWhiteSpace($packageVersion) -or [string]::IsNullOrWhiteSpace($packageFullName)) {
    $reasons.Add('OpenAI.Codex payload package identity was not found.')
  }
  if ([string]::IsNullOrWhiteSpace($nativeVersion)) {
    if ([string]::IsNullOrWhiteSpace($nativeVersionError)) {
      $reasons.Add('Could not determine payload codex-cli version.')
    } else {
      $reasons.Add("Could not determine payload codex-cli version: $nativeVersionError")
    }
  } elseif ($nativeVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    $reasons.Add("Payload codex-cli version '$nativeVersion' is not a supported semantic version.")
  }
  if ([string]::IsNullOrWhiteSpace($liveNativeSha)) {
    $reasons.Add('Payload resources\codex.exe hash is unavailable.')
  }
  if ([string]::IsNullOrWhiteSpace($localNativeSha)) {
    $reasons.Add('Payload local codex.exe hash is unavailable.')
  } elseif (-not [string]::IsNullOrWhiteSpace($liveNativeSha) -and $localNativeSha.ToUpperInvariant() -ne $liveNativeSha.ToUpperInvariant()) {
    $reasons.Add("Payload local codex.exe hash '$localNativeSha' does not match payload resources\codex.exe hash '$liveNativeSha'.")
  }

  $mapping = $null
  if ($reasons.Count -eq 0) {
    $mapping = [pscustomobject]@{
      PackageVersion = [string]$packageVersion
      NativeCliVersion = [string]$nativeVersion
      CodexSourceRef = "rust-v$nativeVersion"
      AppServerVersion = [string]$nativeVersion
      NativeSha256 = [string]$liveNativeSha
      MappingSource = 'inferred_from_payload_codex_cli_version'
    }
  } else {
    foreach ($reason in @($known.Reasons)) {
      if (-not [string]::IsNullOrWhiteSpace($reason)) {
        $reasons.Add($reason)
      }
    }
  }

  return [pscustomobject]@{
    Safe = ($reasons.Count -eq 0)
    Mapping = $mapping
    Reasons = @($reasons)
    PackageVersion = $packageVersion
    PackageFullName = $packageFullName
    NativeCliVersion = $nativeVersion
    LiveNativeSha256 = $liveNativeSha
    LocalNativeSha256 = $localNativeSha
    Inferred = ($null -ne $mapping)
  }
}

function Write-GuardNotification {
  param(
    [Parameter(Mandatory = $true)][object]$State,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Content,
    [switch]$NotifyMsg
  )
  $path = Join-Path $State.Paths.Notifications $Name
  Write-GuardUtf8NoBom -Path $path -Content $Content
  if ($NotifyMsg) {
    $msg = Get-Command msg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($msg) {
      try {
        & $msg.Source $env:USERNAME $Content | Out-Null
      } catch {
      }
    }
  }
  return $path
}

function Assert-GuardPathUnderRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Label = 'path'
  )
  $fullPath = Resolve-GuardFullPath $Path
  $fullRoot = (Resolve-GuardFullPath $Root).TrimEnd('\')
  $comparison = [System.StringComparison]::OrdinalIgnoreCase
  if ($fullPath.Equals($fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + '\', $comparison)) {
    return $fullPath
  }
  throw "$Label is outside the expected root: $fullPath"
}

function Get-GuardScriptRoot {
  if ($PSScriptRoot) {
    return $PSScriptRoot
  }
  return Split-Path -Parent $MyInvocation.MyCommand.Path
}
