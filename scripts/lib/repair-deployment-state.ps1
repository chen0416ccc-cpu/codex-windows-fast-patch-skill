function Resolve-RepairPhysicalPath {
  param([Parameter(Mandatory)][string]$Path)
  if (-not ('RepairPhysicalPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class RepairPhysicalPath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetFinalPathNameByHandle(IntPtr handle, StringBuilder path, uint size, uint flags);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string Resolve(string path) {
    var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
    if(handle==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
    try {
      var buffer=new StringBuilder(32768);
      uint size=GetFinalPathNameByHandle(handle,buffer,(uint)buffer.Capacity,0);
      if(size==0 || size>=buffer.Capacity) throw new System.ComponentModel.Win32Exception();
      string result=buffer.ToString();
      if(result.StartsWith(@"\\?\UNC\")) return @"\\"+result.Substring(8);
      return result.StartsWith(@"\\?\") ? result.Substring(4) : result;
    } finally { CloseHandle(handle); }
  }
}
'@
  }
  return [RepairPhysicalPath]::Resolve($Path)
}

function ConvertTo-RepairUtcDateTime {
  param([Parameter(Mandatory = $true)][object]$Value)
  # ConvertFrom-Json in recent PowerShell converts ISO timestamps to DateTime.
  # Coercing those back to strings loses sub-second process identity precision.
  if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
  if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
  return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Test-RepairProcessNotFoundError {
  param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
  return ($ErrorRecord.FullyQualifiedErrorId -like 'NoProcessFoundForId*' -or
    $ErrorRecord.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*')
}

function Assert-RepairStatePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath -notmatch '^[A-Za-z]:\\' -or $fullPath.Substring(3).Contains(':') -or
      ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($fullPath))).DriveType -ne [IO.DriveType]::Fixed) {
    throw 'Repair state must be an ordinary file on a fixed local drive.'
  }
  $current = Split-Path -Parent $fullPath
  while ($current) {
    $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Repair state parent is not an ordinary directory: $current"
    }
    $current = Split-Path -Parent $current
  }
  if (Test-Path -LiteralPath $fullPath) {
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Repair state is not an ordinary file: $fullPath"
    }
  }
  return $fullPath
}

function Assert-RepairDeploymentState {
  param([Parameter(Mandatory = $true)][object]$State)
  $fields = if ($State -is [System.Collections.IDictionary]) { @($State.Keys) } else { @($State.PSObject.Properties.Name) }
  foreach ($field in @('schemaVersion', 'stage', 'sourcePackageFullName', 'sourceVersion',
      'targetPackageFullName', 'targetVersion', 'installerPid', 'installerStartedUtc',
      'userSid', 'sessionId', 'acceptancePassed', 'cleanupStatus', 'transcriptPath', 'outputRoot', 'updatedUtc')) {
    if ($field -notin $fields) { throw "Repair state is missing field: $field" }
  }
  if ($State.schemaVersion -ne 1 -or $State.acceptancePassed -isnot [bool] -or
      $State.stage -notin @('preparing', 'deploying', 'verifying', 'recovering', 'failed',
        'cleanup-pending', 'cleanup-failed', 'verified-complete') -or
      [int]$State.installerPid -le 0 -or [int]$State.sessionId -lt 0 -or
      [string]::IsNullOrWhiteSpace($State.userSid) -or
      [string]::IsNullOrWhiteSpace($State.sourcePackageFullName) -or
      [string]::IsNullOrWhiteSpace($State.targetPackageFullName) -or
      [version]$State.targetVersion -le [version]$State.sourceVersion) {
    throw 'Repair state has an unsupported schema or invalid identity, phase or acceptance flag.'
  }
  $null = ConvertTo-RepairUtcDateTime $State.installerStartedUtc
  $null = ConvertTo-RepairUtcDateTime $State.updatedUtc
  if ($State.acceptancePassed -and
      ($State.verifiedPackageFullName -cne $State.targetPackageFullName -or -not $State.verifiedUtc -or
       $State.stage -notin @('cleanup-pending', 'cleanup-failed', 'verified-complete'))) {
    throw 'Repair acceptance is not bound to the intended target and a completed validation phase.'
  }
  if ($State.acceptancePassed) {
    $null = ConvertTo-RepairUtcDateTime $State.verifiedUtc
  }
}

function New-RepairDeploymentState {
  param(
    [Parameter(Mandatory = $true)][object]$SourcePackage,
    [Parameter(Mandatory = $true)][object]$InstallerProcess,
    [Parameter(Mandatory = $true)][string]$UserSid,
    [Parameter(Mandatory = $true)][int]$SessionId,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [Parameter(Mandatory = $true)][string]$TranscriptPath
  )
  $sourceVersion = [version]$SourcePackage.Version
  if ($sourceVersion.Revision -lt 0 -or $sourceVersion.Revision -ge 65535) {
    throw "Cannot increment repair target revision: $sourceVersion"
  }
  $targetVersion = [version]::new($sourceVersion.Major, $sourceVersion.Minor, $sourceVersion.Build, $sourceVersion.Revision + 1)
  $sourceName = [string]$SourcePackage.PackageFullName
  $versionToken = "_${sourceVersion}_"
  if (-not $sourceName.Contains($versionToken)) { throw 'Source package full name does not contain its version.' }
  $now = [DateTime]::UtcNow.ToString('o')
  return [ordered]@{
    schemaVersion = 1
    stage = 'preparing'
    startedUtc = $now
    updatedUtc = $now
    sourcePackageFullName = $sourceName
    sourceVersion = [string]$sourceVersion
    targetPackageFullName = $sourceName.Replace($versionToken, "_${targetVersion}_")
    targetVersion = [string]$targetVersion
    recoveryPackageFullName = $null
    installerPid = [int]$InstallerProcess.Id
    installerStartedUtc = $InstallerProcess.StartTime.ToUniversalTime().ToString('o')
    userSid = $UserSid
    sessionId = $SessionId
    transcriptPath = $TranscriptPath
    outputRoot = $OutputRoot
    acceptancePassed = $false
    verifiedPackageFullName = $null
    verifiedUtc = $null
    cleanupStatus = 'not-started'
  }
}

function Write-RepairDeploymentState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$State
  )
  $fullPath = Assert-RepairStatePath $Path
  $State.updatedUtc = [DateTime]::UtcNow.ToString('o')
  $json = $State | ConvertTo-Json -Depth 5
  Assert-RepairDeploymentState ($json | ConvertFrom-Json)
  $temporaryPath = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  $created = $false
  try {
    $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $created = $true
    try {
      $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally { $stream.Dispose() }
    $null = Assert-RepairStatePath $fullPath
    if ([IO.File]::Exists($fullPath)) {
      # PowerShell 5.1 converts $null to an empty string for a string parameter.
      [IO.File]::Replace($temporaryPath, $fullPath, [NullString]::Value)
    } else {
      [IO.File]::Move($temporaryPath, $fullPath)
    }
  } finally {
    if ($created -and [IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
  }
}

function Set-RepairAcceptanceCheckpoint {
  param(
    [Parameter(Mandatory = $true)][object]$State,
    [Parameter(Mandatory = $true)][string]$CurrentPackageFullName,
    [Parameter(Mandatory = $true)][bool]$InstallerExited,
    [Parameter(Mandatory = $true)][bool]$DesktopLaunchPassed,
    [Parameter(Mandatory = $true)][bool]$FastWirePassed,
    [Parameter(Mandatory = $true)][object]$ModelList,
    [Parameter(Mandatory = $true)][bool]$StrictVerificationPassed
  )
  if ($State.acceptancePassed -or $State.stage -notin @('deploying', 'verifying')) {
    throw 'Post-deployment acceptance can only complete a pending deployment checkpoint.'
  }
  if ($CurrentPackageFullName -cne $State.targetPackageFullName) {
    throw 'Post-deployment acceptance requires the exact currently registered target package.'
  }
  if (-not $InstallerExited -or -not $DesktopLaunchPassed -or -not $FastWirePassed -or -not $StrictVerificationPassed) {
    throw 'Post-deployment acceptance evidence is incomplete.'
  }
  if (-not $ModelList.model -or @($ModelList.serviceTiers) -notcontains 'priority') {
    throw 'Post-deployment model/list evidence does not expose the Fast tier for the default model.'
  }

  $State.acceptancePassed = $true
  $State.verifiedPackageFullName = $CurrentPackageFullName
  $State.verifiedUtc = [DateTime]::UtcNow.ToString('o')
  $State.stage = 'cleanup-pending'
  $State.cleanupStatus = 'pending'
}

function Read-RepairDeploymentState {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = Assert-RepairStatePath $Path
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if ($item.Length -gt 65536) { throw 'Repair state exceeds the 64 KiB limit.' }
  $state = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
  Assert-RepairDeploymentState $state
  return $state
}

function Get-RepairDeploymentAssessment {
  param(
    [Parameter(Mandatory = $true)][object]$State,
    [AllowNull()][object]$CurrentPackage,
    [AllowNull()][object]$InstallerProcess,
    [Parameter(Mandatory = $true)][string]$CurrentUserSid,
    [switch]$InstallerProbeFailed
  )
  Assert-RepairDeploymentState $State
  $running = $false
  if ($InstallerProcess -and -not $InstallerProbeFailed) {
    $expectedStart = ConvertTo-RepairUtcDateTime $State.installerStartedUtc
    $running = [int]$InstallerProcess.Id -eq [int]$State.installerPid -and
      [int]$InstallerProcess.SessionId -eq [int]$State.sessionId -and
      $InstallerProcess.StartTime.ToUniversalTime().Ticks -eq $expectedStart.Ticks
  }
  $currentName = if ($CurrentPackage) { [string]$CurrentPackage.PackageFullName } else { $null }
  if ($CurrentUserSid -cne $State.userSid) { $status = 'different-user' }
  elseif ($InstallerProbeFailed) { $status = 'installer-status-unknown'; $running = $null }
  elseif ($running) { $status = 'installer-running' }
  elseif (-not $CurrentPackage) { $status = 'package-missing' }
  elseif ($currentName -ceq $State.targetPackageFullName) {
    if (-not $State.acceptancePassed) { $status = 'installed-needs-verification' }
    elseif ($State.cleanupStatus -in @('removed', 'retained-requested')) { $status = 'verified-complete' }
    else { $status = 'verified-cleanup-needed' }
  } elseif ($State.recoveryPackageFullName -and $currentName -ceq $State.recoveryPackageFullName) {
    $status = 'recovered-original-content'
  } elseif ([version]$CurrentPackage.Version -gt [version]$State.targetVersion -and
      $currentName -ceq ([string]$State.targetPackageFullName).Replace("_$($State.targetVersion)_", "_$($CurrentPackage.Version)_")) {
    $status = 'superseded'
  } elseif ($currentName -ceq $State.sourcePackageFullName) {
    $status = if ($State.stage -eq 'failed') { 'failed-original-retained' } else { 'interrupted-not-installed' }
  } else { $status = 'package-changed' }
  return [pscustomobject][ordered]@{
    Status = $status
    Stage = $State.stage
    AcceptancePassed = $status -in @('verified-complete', 'verified-cleanup-needed')
    RecordedAcceptancePassed = $State.acceptancePassed
    CleanupStatus = $State.cleanupStatus
    InstallerRunning = $running
    InstallerPid = $State.installerPid
    InstallerStartedUtc = $State.installerStartedUtc
    SourcePackageFullName = $State.sourcePackageFullName
    TargetPackageFullName = $State.targetPackageFullName
    CurrentPackageFullName = $currentName
    TranscriptPath = $State.transcriptPath
    OutputRoot = $State.outputRoot
    UpdatedUtc = $State.updatedUtc
  }
}
