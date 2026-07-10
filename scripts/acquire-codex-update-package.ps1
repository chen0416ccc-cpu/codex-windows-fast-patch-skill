[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$EventPath,
  [string]$EventId,
  [string]$OutputPath,
  [string]$DownloadDirectory,
  [string]$ProductId = '9PLM9XGG6VKS',
  [string]$Source = 'msstore',
  [ValidateSet('x64', 'x86', 'arm64', 'neutral')]
  [string]$Architecture = 'x64',
  [string]$Proxy = $env:CODEX_GUARD_WINGET_PROXY,
  [string]$MirrorPackageUrl,
  [string]$MirrorLabel,
  [int]$TimeoutSeconds = 900,
  [switch]$NoDownload,
  [switch]$NoNotifications
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$mirrorSettings = Get-GuardMirrorFallbackSettings -State $state
if ([string]::IsNullOrWhiteSpace($MirrorPackageUrl)) {
  $MirrorPackageUrl = $mirrorSettings.PackageUrl
  $mirrorEnabled = [bool]$mirrorSettings.Enabled
} else {
  $mirrorEnabled = $true
}
if ([string]::IsNullOrWhiteSpace($MirrorLabel)) {
  $MirrorLabel = $mirrorSettings.Label
}
if ([string]::IsNullOrWhiteSpace($MirrorLabel) -and -not [string]::IsNullOrWhiteSpace($MirrorPackageUrl)) {
  $MirrorLabel = 'community_mirror'
}

$event = $null
if (-not [string]::IsNullOrWhiteSpace($EventPath)) {
  $event = Read-GuardJsonFile -Path $EventPath
}
$snapshot = if ($event -and $event.CurrentSnapshot) { $event.CurrentSnapshot } else { Get-GuardSnapshot }
if ([string]::IsNullOrWhiteSpace($EventId)) {
  $EventId = if ($event -and $event.EventId) { [string]$event.EventId } else { New-GuardUpdateActivityEventId -Snapshot $snapshot }
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $state.Paths.Logs ("update-source-acquire-$EventId.json")
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
  $DownloadDirectory = Join-Path $state.Paths.Downloads ("winget-$stamp-$EventId")
}
$DownloadDirectory = Assert-GuardPathUnderRoot -Path $DownloadDirectory -Root $state.Paths.Root -Label 'DownloadDirectory'
New-Item -ItemType Directory -Force -Path $DownloadDirectory | Out-Null

$logPath = Join-Path $DownloadDirectory 'acquire.log'
function Write-AcquireLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
  Add-Content -LiteralPath (Join-Path $state.Paths.Logs 'update-source-acquire.log') -Value $line -Encoding UTF8
}

function ConvertTo-AcquireCommandText {
  param(
    [Parameter(Mandatory = $true)][string]$WingetPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add((ConvertTo-GuardWindowsCommandArgument $WingetPath))
  foreach ($argument in $Arguments) {
    $parts.Add((ConvertTo-GuardWindowsCommandArgument $argument))
  }
  return ($parts.ToArray() -join ' ')
}

function ConvertTo-AcquireSafeText {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) {
    return $null
  }
  $builder = [System.Text.StringBuilder]::new()
  foreach ($char in $Text.ToCharArray()) {
    $code = [int][char]$char
    if ($code -in @(9, 10, 13) -or ($code -ge 32 -and $code -le 126)) {
      [void]$builder.Append($char)
    } else {
      [void]$builder.Append('?')
    }
    if ($builder.Length -ge 4000) {
      [void]$builder.Append('...<truncated>')
      break
    }
  }
  return $builder.ToString()
}

function ConvertTo-AcquireExitCodeHex {
  param([AllowNull()][object]$ExitCode)
  if ($null -eq $ExitCode -or [string]::IsNullOrWhiteSpace([string]$ExitCode)) {
    return $null
  }
  try {
    $value = [int64]$ExitCode
    if ($value -lt 0) {
      $value += 4294967296
    }
    return ('0x{0:X8}' -f ([uint32]$value))
  } catch {
    return $null
  }
}

function Get-AppxIdentityFromRoot {
  param([Parameter(Mandatory = $true)][string]$Root)
  $manifestPath = Join-Path $Root 'AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    return $null
  }
  try {
    [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
    return [pscustomobject]@{
      Name = [string]$manifest.Package.Identity.Name
      Version = [string]$manifest.Package.Identity.Version
      ProcessorArchitecture = [string]$manifest.Package.Identity.ProcessorArchitecture
      Publisher = [string]$manifest.Package.Identity.Publisher
      ManifestPath = $manifestPath
    }
  } catch {
    return $null
  }
}

function Test-CodexPayloadRoot {
  param([Parameter(Mandatory = $true)][string]$Root)
  $identity = Get-AppxIdentityFromRoot -Root $Root
  if (-not $identity -or $identity.Name -ne 'OpenAI.Codex') {
    return $false
  }
  $codexExe = Join-Path $Root 'app\resources\codex.exe'
  $appAsar = Join-Path $Root 'app\resources\app.asar'
  $shellExe = Join-Path $Root 'app\Codex.exe'
  return (
    (Test-Path -LiteralPath $codexExe -PathType Leaf) -and
    (Test-Path -LiteralPath $appAsar -PathType Leaf) -and
    (Test-Path -LiteralPath $shellExe -PathType Leaf)
  )
}

function Normalize-ScopedPackagePaths {
  param([Parameter(Mandatory = $true)][string]$Root)
  $unpackedRoot = Join-Path $Root 'app\resources\app.asar.unpacked'
  if (-not (Test-Path -LiteralPath $unpackedRoot -PathType Container)) {
    return 0
  }
  $items = @(Get-ChildItem -LiteralPath $unpackedRoot -Recurse -Force -ErrorAction SilentlyContinue |
    Sort-Object { $_.FullName.Length } -Descending)
  $renameCount = 0
  foreach ($item in $items) {
    $decodedName = [System.Uri]::UnescapeDataString($item.Name)
    if ($decodedName -eq $item.Name) {
      continue
    }
    $targetPath = Join-Path (Split-Path -Parent $item.FullName) $decodedName
    if (Test-Path -LiteralPath $targetPath) {
      continue
    }
    Rename-Item -LiteralPath $item.FullName -NewName $decodedName
    $renameCount++
  }
  return $renameCount
}

function Expand-ZipPackage {
  param(
    [Parameter(Mandatory = $true)][string]$PackageFile,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][string]$Suffix
  )
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($PackageFile)
  $safeBase = ($baseName -replace '[^A-Za-z0-9._-]', '_')
  $hash = (Get-GuardSha256Text -Text $PackageFile).Substring(0, 8)
  $destination = Join-Path $DestinationRoot ("$safeBase-$Suffix-$hash")
  $destination = Assert-GuardPathUnderRoot -Path $destination -Root $state.Paths.Root -Label 'unpack destination'
  if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  [System.IO.Compression.ZipFile]::ExtractToDirectory($PackageFile, $destination)
  return $destination
}

function Expand-DownloadedPackageFile {
  param(
    [Parameter(Mandatory = $true)][string]$PackageFile,
    [Parameter(Mandatory = $true)][string]$UnpackRoot
  )
  $roots = New-Object System.Collections.Generic.List[object]
  $extension = [System.IO.Path]::GetExtension($PackageFile).ToLowerInvariant()
  $containerLabel = if ($extension -in @('.msixbundle', '.appxbundle')) { 'bundle' } else { 'package' }
  Write-AcquireLog "unpacking $($containerLabel): $PackageFile"
  $containerRoot = Expand-ZipPackage -PackageFile $PackageFile -DestinationRoot (Join-Path $DownloadDirectory 'archives') -Suffix $containerLabel
  if (Test-CodexPayloadRoot -Root $containerRoot) {
    $renamed = Normalize-ScopedPackagePaths -Root $containerRoot
    if ($renamed -gt 0) {
      Write-AcquireLog "normalized $renamed scoped package path(s) under: $containerRoot"
    }
    $roots.Add($containerRoot)
    Write-AcquireLog "usable Codex payload unpacked: $containerRoot"
  }

  $innerPackages = @(Get-ChildItem -LiteralPath $containerRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { [System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant() -in @('.msix', '.appx') })
  foreach ($inner in $innerPackages) {
    try {
      $payloadRoot = Expand-ZipPackage -PackageFile $inner.FullName -DestinationRoot $UnpackRoot -Suffix 'payload'
      if (Test-CodexPayloadRoot -Root $payloadRoot) {
        $renamed = Normalize-ScopedPackagePaths -Root $payloadRoot
        if ($renamed -gt 0) {
          Write-AcquireLog "normalized $renamed scoped package path(s) under: $payloadRoot"
        }
        $roots.Add($payloadRoot)
        Write-AcquireLog "usable Codex payload unpacked: $payloadRoot"
      } else {
        Write-AcquireLog "skipping non-Codex or incomplete inner package: $($inner.FullName)"
      }
    } catch {
      Write-AcquireLog "warning: could not unpack inner package $($inner.FullName): $($_.Exception.Message)"
    }
  }

  if ($roots.Count -eq 0) {
    Write-AcquireLog "downloaded package did not produce a complete OpenAI.Codex payload: $PackageFile"
  }
  return @($roots.ToArray())
}

function Get-AcquirePackageFiles {
  return @(
    Get-ChildItem -LiteralPath $DownloadDirectory -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { [System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant() -in @('.msix', '.appx', '.msixbundle', '.appxbundle') } |
      Sort-Object Length -Descending
  )
}

function Add-PayloadRootsFromPackageFile {
  param(
    [Parameter(Mandatory = $true)][string]$PackageFile,
    [Parameter(Mandatory = $true)][string]$UnpackRoot,
    [Parameter(Mandatory = $true)][string]$SourceLabel
  )
  foreach ($root in @(Expand-DownloadedPackageFile -PackageFile $PackageFile -UnpackRoot $UnpackRoot)) {
    $identity = Get-AppxIdentityFromRoot -Root $root
    $payloadRoots.Add([pscustomobject]@{
      Path = $root
      Identity = $identity
      Source = $SourceLabel
    })
  }
}

function Get-MirrorDownloadExtension {
  param([AllowNull()][string]$Url)
  $normalized = if ([string]::IsNullOrWhiteSpace($Url)) { '' } else { $Url.ToLowerInvariant() }
  if ($normalized -match '\.msixbundle(?:$|\?)' -or $normalized -match '\.appxbundle(?:$|\?)') {
    return '.msixbundle'
  }
  if ($normalized -match '\.appx(?:$|\?)') {
    return '.appx'
  }
  return '.msix'
}

function Invoke-MirrorPackageDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $mirrorRoot = Join-Path $DownloadDirectory 'mirror'
  New-Item -ItemType Directory -Force -Path $mirrorRoot | Out-Null
  $extension = Get-MirrorDownloadExtension -Url $Url
  $targetPath = Join-Path $mirrorRoot ("codex-desktop-mirror-latest$extension")
  if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    Remove-Item -LiteralPath $targetPath -Force
  }
  $previousProtocols = [System.Net.ServicePointManager]::SecurityProtocol
  try {
    [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocols -bor [System.Net.SecurityProtocolType]::Tls12
    Write-AcquireLog "downloading Codex package from mirror '$Label': $Url"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curl) {
      $curlArgs = @(
        '--silent',
        '--show-error',
        '--location',
        '--fail',
        '--retry', '4',
        '--retry-all-errors',
        '--retry-delay', '5',
        '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; CodexDesktopGuard)',
        '--output', $targetPath,
        $Url
      )
      $capture = Invoke-GuardProcessCapture -FilePath $curl.Source -Arguments $curlArgs -TimeoutSeconds $TimeoutSeconds
      if ($capture.ExitCode -ne 0) {
        throw "curl mirror download failed with exit code $($capture.ExitCode): $($capture.Stderr)"
      }
    } else {
      Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $targetPath -MaximumRedirection 5 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; CodexDesktopGuard)' -ErrorAction Stop | Out-Null
    }
    Write-AcquireLog "mirror download complete: $targetPath"
    return $targetPath
  } finally {
    [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocols
  }
}

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$wingetArgs = @(
  'download',
  '--id', $ProductId,
  '--source', $Source,
  '--exact',
  '--architecture', $Architecture,
  '--download-directory', $DownloadDirectory,
  '--accept-source-agreements',
  '--accept-package-agreements',
  '--skip-license',
  '--disable-interactivity',
  '--verbose-logs'
)
if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
  $wingetArgs += @('--proxy', $Proxy)
}

$capture = $null
$downloadAttempted = $false
$commandText = if ($winget) { ConvertTo-AcquireCommandText -WingetPath $winget.Source -Arguments $wingetArgs } else { $null }
$errors = New-Object System.Collections.Generic.List[object]

Write-AcquireLog "Codex update package acquire started; event: $EventId; directory: $DownloadDirectory"
if ($NoDownload) {
  Write-AcquireLog 'NoDownload set; winget download skipped'
} elseif (-not $winget) {
  $errors.Add([pscustomobject]@{
    Source = 'winget'
    Error = 'winget.exe not found'
  })
  Write-AcquireLog 'winget.exe not found'
} else {
  $downloadAttempted = $true
  Write-AcquireLog "running: $commandText"
  try {
    $capture = Invoke-GuardProcessCapture -FilePath $winget.Source -Arguments $wingetArgs -TimeoutSeconds $TimeoutSeconds
    $safeStdout = ConvertTo-AcquireSafeText $capture.Stdout
    $safeStderr = ConvertTo-AcquireSafeText $capture.Stderr
    Write-AcquireLog "winget exit code: $($capture.ExitCode)"
    if (-not [string]::IsNullOrWhiteSpace($safeStdout)) {
      Write-AcquireLog "winget stdout: $safeStdout"
    }
    if (-not [string]::IsNullOrWhiteSpace($safeStderr)) {
      Write-AcquireLog "winget stderr: $safeStderr"
    }
    if ($capture.ExitCode -ne 0) {
      $errors.Add([pscustomobject]@{
        Source = 'winget'
        ExitCode = $capture.ExitCode
        Stdout = $safeStdout
        Stderr = $safeStderr
      })
    }
  } catch {
    $errors.Add([pscustomobject]@{
      Source = 'winget'
      Error = $_.Exception.Message
    })
    Write-AcquireLog "winget failed: $($_.Exception.Message)"
  }
}

$packageFiles = @(Get-AcquirePackageFiles)
$unpackRoot = Join-Path $DownloadDirectory 'payloads'
New-Item -ItemType Directory -Force -Path $unpackRoot | Out-Null
$payloadRoots = New-Object System.Collections.Generic.List[object]
$mirrorAttempted = $false
$mirrorDownloadedFile = $null
foreach ($packageFile in $packageFiles) {
  try {
    Add-PayloadRootsFromPackageFile -PackageFile $packageFile.FullName -UnpackRoot $unpackRoot -SourceLabel 'winget_download'
  } catch {
    $errors.Add([pscustomobject]@{
      Source = 'unpack'
      Path = $packageFile.FullName
      Error = $_.Exception.Message
    })
    Write-AcquireLog "warning: failed to unpack $($packageFile.FullName): $($_.Exception.Message)"
  }
}

if ($payloadRoots.Count -eq 0 -and -not $NoDownload -and $mirrorEnabled -and -not [string]::IsNullOrWhiteSpace($MirrorPackageUrl)) {
  $mirrorAttempted = $true
  try {
    $mirrorDownloadedFile = Invoke-MirrorPackageDownload -Url $MirrorPackageUrl -Label $MirrorLabel
    $packageFiles = @(Get-AcquirePackageFiles)
    Add-PayloadRootsFromPackageFile -PackageFile $mirrorDownloadedFile -UnpackRoot $unpackRoot -SourceLabel $MirrorLabel
  } catch {
    $errors.Add([pscustomobject]@{
      Source = if ([string]::IsNullOrWhiteSpace($MirrorLabel)) { 'community_mirror' } else { $MirrorLabel }
      Url = $MirrorPackageUrl
      Error = $_.Exception.Message
    })
    Write-AcquireLog "mirror download failed: $($_.Exception.Message)"
  }
}

$detectedExitCodeHex = if ($capture) { ConvertTo-AcquireExitCodeHex -ExitCode $capture.ExitCode } else { $null }
$detectedErrorCode = $null
$combinedWingetText = if ($capture) { [string]::Concat([string]$capture.Stdout, "`n", [string]$capture.Stderr) } else { '' }
if ($combinedWingetText -match '0x[0-9A-Fa-f]{8}') {
  $detectedErrorCode = $Matches[0].ToUpperInvariant()
} elseif ($detectedExitCodeHex) {
  $detectedErrorCode = $detectedExitCodeHex
}

$status = if ($payloadRoots.Count -gt 0) {
  'update_source_ready'
} else {
  'needs_update_source'
}
$reason = if ($payloadRoots.Count -gt 0) {
  if ($mirrorDownloadedFile) { 'mirror_payload_unpacked' } else { 'downloaded_payload_unpacked' }
} elseif ($NoDownload) {
  'download_disabled'
} elseif (-not $winget) {
  'winget_missing'
} elseif ($mirrorAttempted) {
  'mirror_download_failed_or_no_payload'
} elseif ($detectedErrorCode -eq '0x8A150076') {
  'store_offline_authorization_required'
} elseif ($downloadAttempted) {
  'winget_download_failed_or_no_payload'
} else {
  'no_update_source'
}

$result = [pscustomobject]@{
  SchemaVersion = 1
  Status = $status
  Reason = $reason
  EventId = $EventId
  CreatedAt = (Get-Date).ToString('o')
  StateRoot = $state.Paths.Root
  EventPath = $EventPath
  ProductId = $ProductId
  Source = $Source
  Architecture = $Architecture
  Proxy = $Proxy
  MirrorEnabled = $mirrorEnabled
  MirrorPackageUrl = $MirrorPackageUrl
  MirrorLabel = $MirrorLabel
  MirrorAttempted = $mirrorAttempted
  MirrorDownloadedFile = $mirrorDownloadedFile
  DownloadDirectory = $DownloadDirectory
  LogPath = $logPath
  Command = $commandText
  Winget = if ($winget) { $winget.Source } else { $null }
  WingetExitCode = if ($capture) { $capture.ExitCode } else { $null }
  WingetExitCodeHex = $detectedExitCodeHex
  DetectedErrorCode = $detectedErrorCode
  WingetStdout = if ($capture) { ConvertTo-AcquireSafeText $capture.Stdout } else { $null }
  WingetStderr = if ($capture) { ConvertTo-AcquireSafeText $capture.Stderr } else { $null }
  DownloadedFiles = @($packageFiles | ForEach-Object { Get-GuardFileFingerprint -Path $_.FullName })
  UnpackedPayloadRoots = @($payloadRoots.ToArray())
  Errors = @($errors.ToArray())
  OutputPath = $OutputPath
}
Write-GuardJsonFile -Path $OutputPath -Value $result

if ($reason -ne 'store_offline_authorization_required') {
  Remove-Item -LiteralPath (Join-Path $state.Paths.Notifications "STORE_OFFLINE_AUTHORIZATION_REQUIRED-$EventId.txt") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $state.Paths.Notifications 'STORE_OFFLINE_AUTHORIZATION_REQUIRED.txt') -Force -ErrorAction SilentlyContinue
}

if (-not $NoNotifications) {
  if ($status -eq 'update_source_ready') {
    $sourceLine = if ($mirrorDownloadedFile) { "Source: $MirrorLabel ($MirrorPackageUrl)" } else { "Source: Microsoft Store / winget" }
    $text = @(
      "Codex Desktop Guard acquired a Codex update package.",
      "Event: $EventId",
      $sourceLine,
      "ProductId: $ProductId",
      "Payload roots:",
      (($payloadRoots | ForEach-Object { "  $($_.Path)" }) -join "`r`n"),
      "",
      "The guard has not installed anything. The patched-update prepare step can now build a repaired package from this payload."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "UPDATE_SOURCE_READY-$EventId.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'UPDATE_SOURCE_READY.txt' -Content $text | Out-Null
  } else {
    $guidance = if ($reason -eq 'store_offline_authorization_required') {
      @(
        "Microsoft Store offline distribution requires Microsoft Entra ID authorization on this machine.",
        "Use a clean Windows / VM / another user environment to install official Codex Desktop through Microsoft Store, then export a sidecar payload zip and import it here.",
        "This is not a DNS-only problem, and the guard did not install or stop Codex Desktop."
      )
    } elseif ($mirrorAttempted) {
      @(
        "The configured community mirror did not produce a usable payload on this run.",
        "Check mirror availability or update guard-config.json with another official-package mirror URL.",
        "You can also place an unpacked OpenAI.Codex payload under:",
        $state.Paths.Incoming
      )
    } else {
      @(
        "If this machine needs a proxy for Microsoft Store offline packages, set CODEX_GUARD_WINGET_PROXY or rerun the command with winget --proxy.",
        "If you have explicitly configured a community mirror in guard-config.json, the guard can retry with that source on the next run.",
        "You can also place an unpacked OpenAI.Codex payload under:",
        $state.Paths.Incoming
      )
    }
    $text = @(
      "Codex Desktop Guard tried to acquire the Codex Desktop update package but could not produce a usable payload.",
      "Event: $EventId",
      "Status: $status",
      "Reason: $reason",
      "ProductId: $ProductId",
      "Mirror enabled: $mirrorEnabled",
      "Mirror source: $MirrorPackageUrl",
      "Detected error: $detectedErrorCode",
      "Command:",
      $commandText,
      "",
      ($guidance -join "`r`n"),
      "",
      "No patch was applied and no Desktop process was stopped."
    ) -join "`r`n"
    Write-GuardNotification -State $state -Name "NEEDS_UPDATE_SOURCE-$EventId.txt" -Content $text | Out-Null
    Write-GuardNotification -State $state -Name 'NEEDS_UPDATE_SOURCE.txt' -Content $text | Out-Null
    if ($reason -eq 'store_offline_authorization_required') {
      Write-GuardNotification -State $state -Name "STORE_OFFLINE_AUTHORIZATION_REQUIRED-$EventId.txt" -Content $text | Out-Null
      Write-GuardNotification -State $state -Name 'STORE_OFFLINE_AUTHORIZATION_REQUIRED.txt' -Content $text | Out-Null
    }
  }
}

$result | ConvertTo-Json -Depth 12
