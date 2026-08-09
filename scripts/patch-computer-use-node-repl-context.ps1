[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$HelperTransportPath,
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [switch]$Install,
  [switch]$Rollback,
  [switch]$Json,
  [switch]$ComputeCandidateHash
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-cua-node-repl-context]'
$PatchMarker = 'computer_use_node_repl_request_context_patch'
$PatchProfile = [ordered]@{
  Name = '@oai/sky 0.6.2 helper transport / node_repl request context'
  SkyVersion = '0.6.2'
  OriginalSha256 = '6423BA834F18139D55CDAC2290C91CD9B24B568332B07CDDD2A7EDA043702B7C'
  PatchedSha256 = '3600AC240CD6CB7029F1E489DF990CAE22D72177350B8084412DF1F3FA5BB60A'
}

$ImportAnchor = 'import{spawnSync as n,spawn as s}from"node:child_process";'
$ImportReplacement = 'import{AsyncLocalStorage as ComputerUseAsyncLocalStorage}from"node:async_hooks";/* ' + $PatchMarker + ' */' + $ImportAnchor
$RequestRecordAnchor = 'e(this,E,"f").set(a,{child:i,codexTurnMetadata:r,createElicitation:l,method:n,params:s,resolve:t,reject:o,timeout:u,turnScope:d}),i.stdin.write'
$RequestRecordReplacement = 'e(this,E,"f").set(a,{child:i,codexTurnMetadata:r,createElicitation:l,method:n,params:s,resolve:t,reject:o,runInRequestContext:ComputerUseAsyncLocalStorage.snapshot(),timeout:u,turnScope:d}),i.stdin.write'
$ApprovalAnchor = 'if(null!=s)return void e(this,f,"m",T).call(this,n,s);'
$ApprovalReplacement = 'if(null!=s)return void n.runInRequestContext((()=>e(this,f,"m",T).call(this,n,s)));'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Get-Sha256FromBytes {
  param([byte[]]$Bytes)

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace '-', '')
  } finally {
    $sha256.Dispose()
  }
}

function Get-Sha256 {
  param([string]$Path)
  return Get-Sha256FromBytes ([IO.File]::ReadAllBytes($Path))
}

function Get-Utf8Bytes {
  param([string]$Content)
  return [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
}

function Get-OccurrenceCount {
  param(
    [string]$Content,
    [string]$Needle
  )

  $count = 0
  $index = 0
  while ($true) {
    $index = $Content.IndexOf($Needle, $index, [StringComparison]::Ordinal)
    if ($index -lt 0) {
      return $count
    }
    $count += 1
    $index += $Needle.Length
  }
}

function Get-PatchedContent {
  param([string]$Content)

  if ($Content.Contains($PatchMarker)) {
    throw 'helper transport already contains the node_repl request-context patch marker'
  }

  foreach ($anchor in @($ImportAnchor, $RequestRecordAnchor, $ApprovalAnchor)) {
    $count = Get-OccurrenceCount $Content $anchor
    if ($count -ne 1) {
      throw "helper transport anchor count is $count instead of 1: $anchor"
    }
  }

  $patched = $Content.Replace($ImportAnchor, $ImportReplacement)
  $patched = $patched.Replace($RequestRecordAnchor, $RequestRecordReplacement)
  $patched = $patched.Replace($ApprovalAnchor, $ApprovalReplacement)
  return $patched
}

function Resolve-HelperTransportPath {
  param([string]$RequestedPath)

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
      throw "Computer Use helper transport not found: $RequestedPath"
    }
    return [IO.Path]::GetFullPath($RequestedPath)
  }

  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  $candidates = @()
  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $candidates = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $path = Join-Path $_.FullName 'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
      $packagePath = Join-Path $_.FullName 'bin\node_modules\@oai\sky\package.json'
      if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        [pscustomobject]@{
          Path = $path
          PackageLastWriteTime = (Get-Item -LiteralPath $packagePath).LastWriteTime
        }
      }
    } | Sort-Object PackageLastWriteTime -Descending)
  }

  if ($candidates.Count -eq 0) {
    throw "no Computer Use helper transport found under $runtimeRoot"
  }
  return [IO.Path]::GetFullPath($candidates[0].Path)
}

function Resolve-SkyRoot {
  param([string]$ResolvedTransportPath)

  $directory = Split-Path -Parent $ResolvedTransportPath
  for ($depth = 0; $depth -lt 14; $depth += 1) {
    $packagePath = Join-Path $directory 'package.json'
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
      $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
      if ([string]$package.name -eq '@oai/sky') {
        return [IO.Path]::GetFullPath($directory)
      }
    }
    $parent = Split-Path -Parent $directory
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $directory) {
      break
    }
    $directory = $parent
  }
  throw "unable to locate @oai/sky package root for $ResolvedTransportPath"
}

function Get-BackupPath {
  param(
    [string]$SkyVersion,
    [string]$OriginalHash
  )

  $directory = "sky-$SkyVersion-$($OriginalHash.Substring(0, 8))"
  return Join-Path (Join-Path $CodexHome 'backups\computer-use-node-repl-context') "$directory\helper_transport.js.original"
}

function Get-Status {
  param([string]$ResolvedTransportPath)

  $skyRoot = Resolve-SkyRoot $ResolvedTransportPath
  $package = Get-Content -Raw -LiteralPath (Join-Path $skyRoot 'package.json') | ConvertFrom-Json
  $skyVersion = [string]$package.version
  $content = [IO.File]::ReadAllText($ResolvedTransportPath)
  $hash = Get-Sha256 $ResolvedTransportPath
  $backupPath = Get-BackupPath $skyVersion $PatchProfile.OriginalSha256
  $backupHash = if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
    Get-Sha256 $backupPath
  } else {
    $null
  }
  $state = if ($hash -eq $PatchProfile.OriginalSha256) {
    'original-patchable'
  } elseif ($hash -eq $PatchProfile.PatchedSha256) {
    if ($backupHash -eq $PatchProfile.OriginalSha256) {
      'patched'
    } elseif ($null -eq $backupHash) {
      'patched-backup-missing'
    } else {
      'patched-backup-invalid'
    }
  } elseif ($content.Contains($PatchMarker)) {
    'unsupported-modified'
  } else {
    'unsupported'
  }

  $candidateHash = $null
  if ($state -eq 'original-patchable') {
    $candidateHash = Get-Sha256FromBytes (Get-Utf8Bytes (Get-PatchedContent $content))
  }

  return [pscustomobject]@{
    Profile = $PatchProfile.Name
    HelperTransportPath = $ResolvedTransportPath
    SkyRoot = $skyRoot
    SkyVersion = $skyVersion
    State = $state
    Sha256 = $hash
    CandidateSha256 = $candidateHash
    BackupPath = $backupPath
    BackupSha256 = $backupHash
  }
}

function Write-Status {
  param([pscustomobject]$Status)

  if ($Json) {
    $Status | ConvertTo-Json -Compress
  } else {
    $Status
  }
}

if ($Install -and $Rollback) {
  throw 'choose either -Install or -Rollback'
}

$resolvedTransportPath = Resolve-HelperTransportPath $HelperTransportPath
$status = Get-Status $resolvedTransportPath

if ($ComputeCandidateHash) {
  if ($status.State -ne 'original-patchable') {
    throw "candidate hash requires the exact original helper transport; state=$($status.State)"
  }
  $status.CandidateSha256
  return
}

if (-not $Install -and -not $Rollback) {
  Write-Status $status
  return
}

if ($Install) {
  if ($status.State -eq 'patched') {
    Write-Log "already patched: $resolvedTransportPath"
    return
  }
  if ($status.State -like 'patched-backup-*') {
    throw "patched helper transport does not have the verified original backup: state=$($status.State) path=$($status.BackupPath)"
  }
  if ($status.State -ne 'original-patchable') {
    throw "unsupported helper transport SHA-256: $($status.Sha256)"
  }
  if ($status.SkyVersion -ne $PatchProfile.SkyVersion) {
    throw "this profile requires @oai/sky $($PatchProfile.SkyVersion); detected $($status.SkyVersion)"
  }

  $originalContent = [IO.File]::ReadAllText($resolvedTransportPath)
  $patchedContent = Get-PatchedContent $originalContent
  $patchedBytes = Get-Utf8Bytes $patchedContent
  $patchedHash = Get-Sha256FromBytes $patchedBytes
  if ($patchedHash -ne $PatchProfile.PatchedSha256) {
    throw "patched helper transport hash mismatch: $patchedHash"
  }

  $tempRoot = if ([string]::IsNullOrWhiteSpace($env:TEMP)) { [IO.Path]::GetTempPath() } else { $env:TEMP }
  $tempPath = Join-Path $tempRoot ('codex-cua-node-repl-context-' + [guid]::NewGuid().ToString('N') + '.js')
  try {
    [IO.File]::WriteAllBytes($tempPath, $patchedBytes)
    $skyBinRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $status.SkyRoot))
    $nodePath = Join-Path $skyBinRoot 'node.exe'
    if (Test-Path -LiteralPath $nodePath -PathType Leaf) {
      & $nodePath --check $tempPath
      if ($LASTEXITCODE -ne 0) {
        throw "node --check failed for patched helper transport: $tempPath"
      }
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedTransportPath, 'Install the hash-guarded node_repl request-context patch')) {
      return
    }

    if (Test-Path -LiteralPath $status.BackupPath -PathType Leaf) {
      $backupHash = Get-Sha256 $status.BackupPath
      if ($backupHash -ne $PatchProfile.OriginalSha256) {
        throw "existing helper transport backup has an unexpected SHA-256: $($status.BackupPath) / $backupHash"
      }
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $status.BackupPath) | Out-Null
      Copy-Item -LiteralPath $resolvedTransportPath -Destination $status.BackupPath -Force
      if ((Get-Sha256 $status.BackupPath) -ne $PatchProfile.OriginalSha256) {
        throw "helper transport backup verification failed: $($status.BackupPath)"
      }
      Write-Log "original backup: $($status.BackupPath)"
    }

    Copy-Item -LiteralPath $tempPath -Destination $resolvedTransportPath -Force
    if ((Get-Sha256 $resolvedTransportPath) -ne $PatchProfile.PatchedSha256) {
      throw "installed helper transport verification failed: $resolvedTransportPath"
    }
    Write-Log "installed and verified: $resolvedTransportPath"
    Write-Log 'reset the current node_repl JavaScript kernel before retesting Computer Use'
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue -WhatIf:$false
  }
  return
}

if ($status.State -eq 'original-patchable') {
  Write-Log "already rolled back: $resolvedTransportPath"
  return
}
if ($status.State -ne 'patched') {
  throw "cannot roll back unsupported helper transport SHA-256: $($status.Sha256)"
}
if (-not (Test-Path -LiteralPath $status.BackupPath -PathType Leaf)) {
  throw "original helper transport backup not found: $($status.BackupPath)"
}
if ((Get-Sha256 $status.BackupPath) -ne $PatchProfile.OriginalSha256) {
  throw "original helper transport backup hash mismatch: $($status.BackupPath)"
}

if ($PSCmdlet.ShouldProcess($resolvedTransportPath, 'Restore the original Computer Use helper transport')) {
  Copy-Item -LiteralPath $status.BackupPath -Destination $resolvedTransportPath -Force
  if ((Get-Sha256 $resolvedTransportPath) -ne $PatchProfile.OriginalSha256) {
    throw "rollback verification failed: $resolvedTransportPath"
  }
  Write-Log "rolled back and verified: $resolvedTransportPath"
}
