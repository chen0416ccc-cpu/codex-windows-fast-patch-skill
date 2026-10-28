[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutputRoot,
  [Parameter(Mandatory = $true)][string]$TranscriptPath,
  [Parameter(Mandatory = $true)][string]$ExpectedUserSid,
  [Parameter(Mandatory = $true)][int]$ExpectedSessionId,
  [Parameter(Mandatory = $true)][string]$ExpectedPackageFullName,
  [switch]$ResumePreparedBuild,
  [string]$PreparedTranscriptPath,
  [string[]]$CustomModels = @('gpt-6-astra', 'gpt-6-sol', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'),
  [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$script:RepairRunRoot = 'D:\CodexData\codex-windows-fast-patch\model-experience-repair-runs'
$script:RepairLogRoot = 'D:\CodexData\codex-windows-fast-patch\model-experience-repair-logs'
. (Join-Path $PSScriptRoot 'lib\msix-safe-install.ps1')
. (Join-Path $PSScriptRoot 'lib\msix-payload.ps1')
. (Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1')
$patcher = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$script:TranscriptStarted = $false
$repairTempParent = 'D:\CodexData\cwp-tmp'
$script:RepairDeploymentState = $null
$script:RepairStatePath = $null
$script:RepairCheckpointFailed = $false

function Save-RepairCheckpoint {
  param([switch]$AfterDeployment)
  try {
    Write-RepairDeploymentState -Path $script:RepairStatePath -State $script:RepairDeploymentState
  } catch {
    if (-not $AfterDeployment) { throw }
    # State I/O must not turn a successful deployment into a rollback or a reported install failure.
    $script:RepairCheckpointFailed = $true
    Write-Log "warning: deployment checkpoint could not be saved; inspect the retained transcript: $($_.Exception.Message)"
  }
}

function New-RepairTemporaryRoot {
  $drive = [IO.DriveInfo]::new('D:\')
  if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'D: is not a fixed local drive.' }

  $parent = [IO.Path]::GetFullPath($repairTempParent)
  $current = 'D:\'
  foreach ($part in $parent.Substring(3).Split('\')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $current = Join-Path $current $part
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Repair temp path is not an ordinary directory: $current"
      }
    } else {
      New-Item -ItemType Directory -Path $current -ErrorAction Stop | Out-Null
    }
  }

  $leaf = 'r-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
  $path = Join-Path $parent $leaf
  New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
  $sentinelId = [guid]::NewGuid().ToString('N')
  $sentinelPath = Join-Path $path '.codex-model-experience-temp'
  [IO.File]::WriteAllText($sentinelPath, $sentinelId, [Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ Path = $path; SentinelId = $sentinelId }
}

function Remove-RepairTemporaryRoot {
  param([string]$Path, [string]$SentinelId)
  $fullPath = [IO.Path]::GetFullPath($Path)
  $parent = [IO.Path]::GetFullPath($repairTempParent).TrimEnd('\')
  if (-not $fullPath.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Parent $fullPath) -ine $parent) {
    throw "Repair temp cleanup path escaped its dedicated parent: $fullPath"
  }
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Repair temp cleanup target is not an ordinary directory: $fullPath"
  }
  $sentinelPath = Join-Path $fullPath '.codex-model-experience-temp'
  if ((Get-Content -LiteralPath $sentinelPath -Raw -ErrorAction Stop) -cne $SentinelId) {
    throw 'Repair temp cleanup sentinel does not match; artifacts were retained.'
  }
  Assert-NoReparsePointsRecursive -Path $fullPath
  Remove-DirectoryTreeRobust -Path $fullPath
}

function Assert-NoReparsePointsRecursive {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith('\\?\')) {
    $rootPath = $fullPath
  } elseif ($fullPath.StartsWith('\\')) {
    $rootPath = '\\?\UNC\' + $fullPath.Substring(2)
  } else {
    $rootPath = '\\?\' + $fullPath
  }

  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push($rootPath)
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $directoryAttributes = [IO.File]::GetAttributes($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    if (-not ($directoryAttributes -band [IO.FileAttributes]::Directory)) {
      throw "Recursive cleanup scan encountered a non-directory: $directory"
    }
    if ($directoryAttributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Recursive cleanup scan found a reparse point; artifacts were retained: $directory"
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
        $attributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Recursive cleanup scan found a reparse point; artifacts were retained: $entry"
      }
      if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Push($entry) }
    }
  }
}

function Remove-DirectoryTreeRobust {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath)) { return }
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Robust directory cleanup target is not an ordinary directory: $fullPath"
  }
  Assert-NoReparsePointsRecursive -Path $fullPath

  if ($fullPath.StartsWith('\\?\')) {
    $rootPath = $fullPath
  } elseif ($fullPath.StartsWith('\\')) {
    $rootPath = '\\?\UNC\' + $fullPath.Substring(2)
  } else {
    $rootPath = '\\?\' + $fullPath
  }

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
      throw "Robust cleanup found a reparse point; artifacts were retained: $directory"
    }
    if (-not ($attributes -band [IO.FileAttributes]::Directory)) {
      throw "Robust cleanup encountered a non-directory: $directory"
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
        throw "Robust cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($entryAttributes -band [IO.FileAttributes]::Directory) {
        $pending.Push($entry)
        continue
      }
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
  if (Test-Path -LiteralPath $fullPath) { throw "Robust cleanup did not remove: $fullPath" }
}

function Write-Log {
  param([string]$Message)
  Write-Host "[model-experience-repair] $Message"
}

function Test-FileContainsAsciiText {
  param([string]$Path, [string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { throw 'ASCII marker must not be empty.' }
  $pattern = [Text.Encoding]::ASCII.GetBytes($Text)
  $chunkSize = 65536
  $buffer = [byte[]]::new($chunkSize + $pattern.Length)
  $stream = [IO.File]::OpenRead($Path)
  try {
    $carry = 0
    while ($true) {
      $read = $stream.Read($buffer, $carry, $chunkSize)
      if ($read -eq 0) { return $false }
      $available = $carry + $read
      for ($start = 0; $start -le $available - $pattern.Length; $start++) {
        $matched = $true
        for ($offset = 0; $offset -lt $pattern.Length; $offset++) {
          if ($buffer[$start + $offset] -ne $pattern[$offset]) {
            $matched = $false
            break
          }
        }
        if ($matched) { return $true }
      }
      $carry = [Math]::Min($pattern.Length - 1, $available)
      if ($carry -gt 0) {
        [Array]::Copy($buffer, $available - $carry, $buffer, 0, $carry)
      }
    }
  } finally {
    $stream.Dispose()
  }
}

function Get-NodeReplTrustedPathsPatchResult {
  param([string]$Text)
  $matches = [regex]::Matches($Text, '(?m)^.*Node REPL trusted-paths patch result:\s*(?<result>[A-Za-z-]+)\s*$')
  if ($matches.Count -eq 0) { return $null }
  $results = @($matches | ForEach-Object { $_.Groups['result'].Value } | Select-Object -Unique)
  if ($results.Count -ne 1 -or $results[0] -notin @('patched', 'already-patched')) {
    throw "Node REPL trusted-paths patch report is missing or inconsistent: $($results -join ',')"
  }
  return $results[0]
}

function Get-CodexPackage {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $package -or -not (Test-Path -LiteralPath $package.InstallLocation -PathType Container)) {
    throw 'The current-user Codex MSIX package is unavailable.'
  }
  return $package
}

function Assert-OutputRootIsNewAndLocal {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
  if (-not $fullPath.StartsWith($script:RepairRunRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repair output must remain below $($script:RepairRunRoot): $fullPath"
  }
  if (Test-Path -LiteralPath $fullPath) {
    throw "Refusing to reuse existing repair output root: $fullPath"
  }
  $parentPath = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
    throw "Repair output parent must already exist: $parentPath"
  }
  $parent = Get-Item -LiteralPath $parentPath -Force
  for ($item = $parent; $null -ne $item; $item = $item.Parent) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Repair output path traverses a reparse point: $($item.FullName)"
    }
  }
  return $fullPath
}

function Assert-TranscriptPathIsSafe {
  param([string]$Path, [string]$RepairRoot)
  $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
  if (-not $fullPath.StartsWith($script:RepairLogRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repair transcript must remain below $($script:RepairLogRoot): $fullPath"
  }
  $parentPath = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
    throw "Transcript parent does not exist: $parentPath"
  }
  $parent = Get-Item -LiteralPath $parentPath -Force
  for ($item = $parent; $null -ne $item; $item = $item.Parent) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Transcript path traverses a reparse point: $($item.FullName)"
    }
  }
  if ($fullPath.StartsWith($RepairRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Transcript must remain outside the temporary repair output root.'
  }
  if (Test-Path -LiteralPath $fullPath) { throw "Refusing to overwrite transcript: $fullPath" }
  return $fullPath
}

function Assert-PreparedOutputRoot {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
  $root = $script:RepairRunRoot.TrimEnd('\')
  if ((Split-Path -Parent $fullPath) -ine $root) {
    throw "Prepared output must be a direct child of ${root}: $fullPath"
  }
  $directory = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Prepared output is not an ordinary directory: $fullPath"
  }
  for ($item = $directory.Parent; $null -ne $item; $item = $item.Parent) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Prepared output path traverses a reparse point: $($item.FullName)"
    }
  }
  $sentinel = Join-Path $fullPath '.codex-model-experience-repair'
  if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { throw 'Prepared output sentinel is missing.' }
  $sentinelItem = Get-Item -LiteralPath $sentinel -Force
  if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Prepared output sentinel is a reparse point.' }
  $sentinelId = [IO.File]::ReadAllText($sentinel).Trim()
  if ($sentinelId -notmatch '^[a-f0-9]{32}$') { throw 'Prepared output sentinel is malformed.' }
  $allowedEntries = @('.codex-model-experience-repair', 'patched-build', 'recovery-package', 'codex-original-content-recovery.msix')
  $unexpected = @(Get-ChildItem -LiteralPath $fullPath -Force | Where-Object { $_.Name -notin $allowedEntries })
  if ($unexpected.Count -gt 0) { throw "Prepared output contains unexpected entries: $($unexpected.Name -join ', ')" }
  $buildRoot = Join-Path $fullPath 'patched-build'
  $buildItem = Get-Item -LiteralPath $buildRoot -Force -ErrorAction Stop
  if (-not $buildItem.PSIsContainer -or ($buildItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Prepared build directory is missing or is a reparse point.'
  }
  foreach ($partialPath in @((Join-Path $fullPath 'recovery-package'), (Join-Path $fullPath 'codex-original-content-recovery.msix'))) {
    if (-not (Test-Path -LiteralPath $partialPath)) { continue }
    $partial = Get-Item -LiteralPath $partialPath -Force
    if (($partial.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($partial.FullName -like '*recovery-package' -and -not $partial.PSIsContainer) -or
        ($partial.FullName -like '*codex-original-content-recovery.msix' -and $partial.PSIsContainer)) {
      throw "Prepared recovery artifact has an unexpected type or is a reparse point: $partialPath"
    }
  }
  return [pscustomobject]@{ Path = $fullPath; SentinelPath = $sentinel; SentinelId = $sentinelId }
}

function Read-PreparedPatchTranscript {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
  $root = $script:RepairLogRoot.TrimEnd('\')
  if ((Split-Path -Parent $fullPath) -ine $root) { throw "Prepared transcript must be directly under ${root}." }
  $file = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Prepared transcript is not an ordinary file.'
  }
  $text = [IO.File]::ReadAllText($fullPath)
  $expectedCertificateStop = $text -match 'failed: A current-user code-signing certificate for the package publisher was not found:'
  $expectedTrustedPathGuardStop = $text -match 'failed: The installed app\.asar lost its external trust-path contract, but the current patch run did not repair it\.'
  if (-not ($expectedCertificateStop -or $expectedTrustedPathGuardStop)) {
    throw 'Prepared transcript does not record a recognized pre-deployment stop.'
  }
  return $text
}

function Get-PreparedTemporaryWorkspace {
  param([string]$TranscriptText)
  $matches = [regex]::Matches($TranscriptText, '(?m)^\[model-experience-repair\] short-path temporary workspace: (?<path>D:\\CodexData\\cwp-tmp\\r-[a-f0-9]{12})\s*$')
  $paths = @($matches | ForEach-Object { $_.Groups['path'].Value } | Select-Object -Unique)
  if ($paths.Count -ne 1) { throw 'Prepared transcript must identify exactly one short-path temporary workspace.' }
  $fullPath = [IO.Path]::GetFullPath($paths[0])
  if ((Split-Path -Parent $fullPath) -ine [IO.Path]::GetFullPath($repairTempParent).TrimEnd('\')) {
    throw 'Prepared temporary workspace is outside its dedicated parent.'
  }
  $directory = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Prepared temporary workspace is not an ordinary directory.'
  }
  for ($item = $directory.Parent; $null -ne $item; $item = $item.Parent) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Prepared temporary workspace traverses a reparse point: $($item.FullName)"
    }
  }
  $sentinelPath = Join-Path $fullPath '.codex-model-experience-temp'
  $sentinelItem = Get-Item -LiteralPath $sentinelPath -Force -ErrorAction Stop
  if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Prepared temporary workspace sentinel is a reparse point.' }
  $sentinelId = [IO.File]::ReadAllText($sentinelPath).Trim()
  if ($sentinelId -notmatch '^[a-f0-9]{32}$') { throw 'Prepared temporary workspace sentinel is malformed.' }
  return [pscustomobject]@{ Path = $fullPath; SentinelId = $sentinelId }
}

function Remove-PreparedRecoveryArtifacts {
  param([string]$OutputRoot, [string]$SentinelId)
  $root = [IO.Path]::GetFullPath($OutputRoot)
  $sentinel = Join-Path $root '.codex-model-experience-repair'
  if ([IO.File]::ReadAllText($sentinel).Trim() -cne $SentinelId) {
    throw 'Prepared output sentinel changed before recovery artifacts were refreshed.'
  }
  $recoveryRoot = Join-Path $root 'recovery-package'
  if (Test-Path -LiteralPath $recoveryRoot) {
    $directory = Get-Item -LiteralPath $recoveryRoot -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Prepared recovery package is not an ordinary directory.'
    }
    Assert-NoReparsePointsRecursive -Path $recoveryRoot
    Remove-DirectoryTreeRobust -Path $recoveryRoot
  }
  $recoveryMsix = Join-Path $root 'codex-original-content-recovery.msix'
  if (Test-Path -LiteralPath $recoveryMsix) {
    $file = Get-Item -LiteralPath $recoveryMsix -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Prepared recovery MSIX is not an ordinary file.'
    }
    Remove-Item -LiteralPath $recoveryMsix -Force -ErrorAction Stop
  }
}

function Find-SdkTool {
  param([string]$Name)
  $roots = @(
    (Join-Path $env:TEMP 'codex-windows-sdk-buildtools'),
    (Join-Path $env:USERPROFILE '.nuget\packages\microsoft.windows.sdk.buildtools'),
    (Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Windows Kits\10\bin'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  foreach ($root in $roots) {
    $tool = Get-ChildItem -LiteralPath $root -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($tool) { return $tool.FullName }
  }
  throw "Windows SDK tool not found after patch preparation: $Name"
}

function Copy-RecoveryPackageLayout {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )
  New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
  & robocopy.exe $SourceRoot $DestinationRoot /E /COPY:DAT /DCOPY:DAT /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -gt 7) {
    throw "Recovery package copy failed with robocopy exit code $LASTEXITCODE"
  }
  foreach ($relativePath in @('AppxSignature.p7x', 'AppxBlockMap.xml', 'AppxMetadata\CodeIntegrity.cat')) {
    $path = Join-Path $DestinationRoot $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      Remove-Item -LiteralPath $path -Force
    }
  }
  $sourceAsar = Join-Path $SourceRoot 'app\resources\app.asar'
  $recoveryAsar = Join-Path $DestinationRoot 'app\resources\app.asar'
  if (-not (Test-Path -LiteralPath $recoveryAsar -PathType Leaf) -or
      (Get-FileHash -LiteralPath $sourceAsar -Algorithm SHA256).Hash -cne
      (Get-FileHash -LiteralPath $recoveryAsar -Algorithm SHA256).Hash) {
    throw 'The recovery package does not preserve the original app.asar bytes.'
  }
}

function Test-CodeSigningCertificate {
  param([object]$Certificate)
  $codeSigningOid = '1.3.6.1.5.5.7.3.3'
  foreach ($usage in @($Certificate.EnhancedKeyUsageList)) {
    $objectId = [string]$usage.ObjectId
    if ([string]::IsNullOrWhiteSpace($objectId)) { $objectId = [string]$usage.ObjectId.Value }
    if ($objectId -eq $codeSigningOid) { return $true }
  }
  return $false
}

function Get-CodeSigningCertificate {
  param([string]$Publisher)
  $certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
      $_.Subject -ceq $Publisher -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
      (Test-CodeSigningCertificate $_)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
  if (-not $certificate) {
    throw "A current-user code-signing certificate for the package publisher was not found: $Publisher"
  }
  Write-Log "recovery signing certificate verified: $($certificate.Thumbprint)"
  return $certificate
}

function Get-CodexCli {
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  $cli = Get-ChildItem -LiteralPath $binRoot -Recurse -Filter codex.exe -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $cli) { throw "A user-local Codex CLI was not found under $binRoot" }
  return $cli.FullName
}

function Test-ModelListFastTiers {
  param([string]$CliPath)
  $node = Get-Command node.exe -ErrorAction Stop | Select-Object -First 1
  $probe = @'
const { spawn } = require("child_process");
const nl = String.fromCharCode(10);
const child = spawn(process.argv[2], ["app-server", "--stdio"], { stdio: ["pipe", "pipe", "ignore"] });
let buffer = "";
let nextId = 1;
const pending = new Map();
child.stdout.on("data", chunk => {
  buffer += chunk.toString();
  for (;;) {
    const newline = buffer.indexOf(nl);
    if (newline < 0) break;
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    try {
      const message = JSON.parse(line);
      if (message.id !== undefined && pending.has(message.id)) {
        const settle = pending.get(message.id);
        pending.delete(message.id);
        message.error ? settle.reject(new Error(message.error.message)) : settle.resolve(message.result);
      }
    } catch {}
  }
});
function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(method + " timed out")), 20000);
    pending.set(id, {
      resolve: value => { clearTimeout(timer); resolve(value); },
      reject: error => { clearTimeout(timer); reject(error); }
    });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + nl);
  });
}
(async () => {
  try {
    await request("initialize", {
      clientInfo: { name: "model-experience-repair-check", version: "1.0.0" },
      capabilities: { experimentalApi: true }
    });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "initialized", params: {} }) + nl);
    const response = await request("model/list", { includeHidden: true, limit: 200 });
    const models = response.data || response.models || [];
    const selected = models.find(model => model.isDefault);
    const defaultTiers = selected?.serviceTiers?.map(tier => tier.id) || [];
    if (!selected || !defaultTiers.includes("priority")) {
      throw new Error("default model does not expose the Fast service tier");
    }
    const ultrafastModels = models
      .filter(model => (model.serviceTiers || []).some(tier => tier.id === "ultrafast"))
      .map(model => model.id);
    process.stdout.write(JSON.stringify({ model: selected.id, serviceTiers: defaultTiers, ultrafastModels }));
  } catch (error) {
    process.stderr.write(String(error?.message || error));
    process.exitCode = 1;
  } finally {
    child.kill();
  }
})();
'@
  $errorPath = Join-Path $OutputRoot 'model-list.stderr.log'
  # Windows PowerShell 5.1 strips embedded double quotes from native -e args.
  # A file preserves the exact JavaScript bytes and keeps CLI paths separate.
  $probePath = Join-Path $OutputRoot ('model-list-probe-' + [guid]::NewGuid().ToString('N') + '.cjs')
  [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $result = @(& $node.Source $probePath $CliPath 2> $errorPath)
    $probeExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    [IO.File]::Delete($probePath)
  }
  if ($probeExitCode -ne 0) {
    $detail = if (Test-Path -LiteralPath $errorPath) { Get-Content -LiteralPath $errorPath -Raw } else { 'no diagnostic output' }
    throw "app-server model/list verification failed: $detail"
  }
  $json = ($result -join '').Trim()
  $parsed = $json | ConvertFrom-Json
  if (-not $parsed.model -or @($parsed.serviceTiers) -notcontains 'priority') {
    throw "Unexpected model/list verification response: $json"
  }
  Write-Log "model/list verified: model=$($parsed.model) tiers=$($parsed.serviceTiers -join ',')"
  if (@($parsed.ultrafastModels).Count -gt 0) {
    Write-Log "models with provider-advertised ultrafast tier: $($parsed.ultrafastModels -join ',')"
  } else {
    Write-Log 'the active provider advertises no ultrafast-capable model; the patch will not invent unsupported model tiers'
  }
  return $parsed
}

function Test-ComputerUseStrictVerification {
  $strictScript = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
  if (-not (Test-Path -LiteralPath $strictScript -PathType Leaf)) {
    throw "Computer Use strict verifier was not found: $strictScript"
  }
  $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  # A new package revision changes resourcesPath and the native-host identity.
  # Refresh against the installed target before the separate read-only pass.
  foreach ($pass in @('refresh', 'strict')) {
    $stdoutPath = Join-Path $OutputRoot "computer-use-$pass.stdout.log"
    $stderrPath = Join-Path $OutputRoot "computer-use-$pass.stderr.log"
    $mode = if ($pass -eq 'refresh') { '-VerifyOnly' } else { '-StrictVerifyOnly' }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', $strictScript,
      $mode, '-VerifyAllBundledPluginsAvailable')
    $process = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    foreach ($line in @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)) { Write-Log "$pass CUA: $line" }
    if (Test-Path -LiteralPath $stderrPath) {
      foreach ($line in @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)) { Write-Log "$pass CUA stderr: $line" }
    }
    if ($process.ExitCode -ne 0) {
      throw "Computer Use $mode failed with exit code $($process.ExitCode)."
    }
  }
  Write-Log 'Computer Use StrictVerifyOnly passed without native screenshot or input.'
}

function Start-AndValidateCodex {
  param(
    [object]$Package,
    [version]$PatchedVersion,
    [string]$CliPath
  )
  $manifest = Get-AppxPackageManifest -Package $Package
  $application = @($manifest.Package.Applications.Application) | Select-Object -First 1
  if (-not $application) { throw 'The installed Codex package has no application entry.' }
  $appUserModelId = "$($Package.PackageFamilyName)!$($application.Id)"
  $executable = Join-Path $Package.InstallLocation ([string]$application.Executable).Replace('/', '\')
  $processName = [IO.Path]::GetFileNameWithoutExtension($executable)
  Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$appUserModelId"
  $deadline = (Get-Date).AddSeconds(45)
  $process = $null
  while (-not $process -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $process = Get-Process -Name $processName -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path.Equals($executable, [StringComparison]::OrdinalIgnoreCase) } |
      Select-Object -First 1
  }
  if (-not $process) { throw "Codex did not start from the installed package path: $executable" }
  Start-Sleep -Seconds 4
  $process.Refresh()
  if ($process.HasExited) { throw 'Codex exited immediately after the package update.' }
  Write-Log "Codex process start verified: pid=$($process.Id) version=$($Package.Version)"
  if ([version]$Package.Version -eq $PatchedVersion) {
    $null = Test-ModelListFastTiers -CliPath $CliPath
    Test-ComputerUseStrictVerification
  }
}

$resolvedOutputRoot = $null
$preparedPatchText = $null
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$oldNpmConfigCache = $env:npm_config_cache
$tempRoot = $null
$tempSentinelId = $null
$failure = $null
try {
  $requestedOutputRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputRoot))
  $transcriptFullPath = Assert-TranscriptPathIsSafe -Path $TranscriptPath -RepairRoot $requestedOutputRoot
  Start-Transcript -Path $transcriptFullPath -NoClobber | Out-Null
  $script:TranscriptStarted = $true

  if ($ResumePreparedBuild) {
    if (-not $PreparedTranscriptPath) { throw 'PreparedTranscriptPath is required when resuming a prepared build.' }
    $preparedState = Assert-PreparedOutputRoot $OutputRoot
    $resolvedOutputRoot = $preparedState.Path
    $sentinel = $preparedState.SentinelPath
    $sentinelId = $preparedState.SentinelId
    $preparedPatchText = Read-PreparedPatchTranscript $PreparedTranscriptPath
    $tempWorkspace = Get-PreparedTemporaryWorkspace $preparedPatchText
    $tempRoot = $tempWorkspace.Path
    $tempSentinelId = $tempWorkspace.SentinelId
  } else {
    if ($PreparedTranscriptPath) { throw 'PreparedTranscriptPath is only valid with ResumePreparedBuild.' }
    $resolvedOutputRoot = Assert-OutputRootIsNewAndLocal $OutputRoot
  }

  foreach ($scope in @('Process', 'User', 'Machine')) {
    if ([Environment]::GetEnvironmentVariable('CODEX_HOME', $scope)) {
      throw "CODEX_HOME is set at $scope scope; refusing to repair an isolated CLI home."
    }
  }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $identitySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
  if ($identitySid -cne $ExpectedUserSid -or $sessionId -ne $ExpectedSessionId) {
    throw "Elevated installer identity/session does not match the requesting Desktop session: sid=$identitySid session=$sessionId"
  }
  $package = Get-CodexPackage
  if ($package.PackageFullName -cne $ExpectedPackageFullName) {
    throw "Codex package changed before deployment: expected=$ExpectedPackageFullName actual=$($package.PackageFullName)"
  }
  if (-not (Test-MsixAdministrator)) { throw 'This package requires an elevated installer; UAC elevation was not established.' }
  Assert-MsixExternalExecutor $package
  Write-Log "installer identity verified: $identity"
  Write-Log "source package verified: $($package.PackageFullName)"
  $script:RepairStatePath = $transcriptFullPath + '.state.json'
  if (Test-Path -LiteralPath $script:RepairStatePath) { throw 'Deployment state already exists; refusing to overwrite another attempt.' }
  $script:RepairDeploymentState = New-RepairDeploymentState -SourcePackage $package -InstallerProcess (Get-Process -Id $PID) `
    -UserSid $identitySid -SessionId $sessionId -OutputRoot $resolvedOutputRoot -TranscriptPath $transcriptFullPath
  Save-RepairCheckpoint
  Write-Log "deployment state: $script:RepairStatePath"

  if (-not $ResumePreparedBuild) {
    New-Item -ItemType Directory -Force -Path $resolvedOutputRoot | Out-Null
    $sentinel = Join-Path $resolvedOutputRoot '.codex-model-experience-repair'
    $sentinelId = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($sentinel, $sentinelId, [Text.UTF8Encoding]::new($false))
    $tempWorkspace = New-RepairTemporaryRoot
    $tempRoot = $tempWorkspace.Path
    $tempSentinelId = $tempWorkspace.SentinelId
    Write-Log "short-path temporary workspace: $tempRoot"
  } else {
    Write-Log "resuming prepared build from: $resolvedOutputRoot"
    Write-Log "verified short-path temporary workspace: $tempRoot"
  }
  $env:TEMP = $tempRoot
  $env:TMP = $tempRoot
  $env:npm_config_cache = Join-Path $tempRoot 'npm-cache'

  $patchOutput = Join-Path $resolvedOutputRoot 'patched-build'
  $patchParameters = @{
    AppPath = Join-Path $package.InstallLocation 'app'
    InstallPrerequisites = $true
    # The recovery package is built after patching; keep makeappx and signtool available.
    CleanupWindowsSdkAfterInstall = $false
    VerifyFastModeRequest = $true
    OutputRoot = $patchOutput
    AsarWorkRoot = $tempRoot
    CustomModels = $CustomModels
  }
  if ($ResumePreparedBuild) {
    $patchText = $preparedPatchText
  } else {
    $patchLog = @(& $patcher @patchParameters 2>&1)
    $patchExit = $LASTEXITCODE
    foreach ($line in $patchLog) { Write-Log "patcher: $line" }
    if ($patchExit -ne 0) { throw "Full non-phone package preparation failed with exit code $patchExit" }
    $patchTranscriptText = Get-Content -LiteralPath $transcriptFullPath -Raw -ErrorAction Stop
    $patchText = ($patchLog -join [Environment]::NewLine) + [Environment]::NewLine + $patchTranscriptText
  }
  foreach ($feature in @(
    'fast-mode patch result:',
    'fast-mode UI patch result:',
    'custom models patch result:',
    'Power slider patch result:',
    'browser-use gate patch result:',
    'computer-use gate patch result:',
    'Node REPL trusted-paths patch result:',
    'Node REPL proxy environment patch result:',
    'Windows CUA surface patch result:'
  )) {
    if ($patchText -notmatch [regex]::Escape($feature)) {
      throw "Full non-phone patch report is missing a result for: $feature"
    }
  }
  $trustedPathsResult = Get-NodeReplTrustedPathsPatchResult $patchText
  if (-not $trustedPathsResult) {
    throw 'Full non-phone patch report has no recognized Node REPL trusted-path result.'
  }

  $packageShortId = Split-Path -Leaf $package.InstallLocation | ForEach-Object { $_ -replace '_x64__.*$', '' }
  $artifactDir = Join-Path (Join-Path $patchOutput $packageShortId) 'artifacts'
  $patchedCandidates = @(Get-ChildItem -LiteralPath $artifactDir -Filter '*_patched.msix' -File)
  if ($patchedCandidates.Count -ne 1) {
    throw "Expected one patched MSIX in $artifactDir; found $($patchedCandidates.Count)"
  }
  $patchedMsix = $patchedCandidates[0].FullName
  $stagedAsar = Join-Path (Join-Path (Join-Path (Join-Path $patchOutput $packageShortId) 'package') 'app\resources') 'app.asar'
  if (-not (Test-Path -LiteralPath $stagedAsar -PathType Leaf) -or
      -not (Test-FileContainsAsciiText -Path $stagedAsar -Text 'CODEX_NODE_REPL_TRUSTED_PATHS_V1')) {
    throw "The staged app.asar does not contain the external trust-path contract marker: $stagedAsar"
  }
  Write-Log "staged app.asar trusted-path contract verified: patcher=$trustedPathsResult"
  if ($ResumePreparedBuild) {
    $expectedPreparedStop = ($patchText -match 'failed: A current-user code-signing certificate for the package publisher was not found:') -or
      ($patchText -match 'failed: The installed app\.asar lost its external trust-path contract, but the current patch run did not repair it\.')
    if (-not $expectedPreparedStop -or
        $patchText -notmatch [regex]::Escape("patched MSIX: $patchedMsix") -or
        $patchText -notmatch 'Package creation succeeded\.' -or
        $patchText -notmatch 'Successfully signed: .+_patched\.msix' -or
        $patchText -notmatch 'fast verification: request wire service_tier=priority' -or
        $trustedPathsResult -notin @('patched', 'already-patched')) {
      throw 'Prepared transcript does not prove a signed, Fast-verified package stopped at a recognized pre-deployment guard.'
    }
  }
  $patchedInfo = Get-MsixManifestInfo $patchedMsix
  $sourceVersion = [version]$package.Version
  $expectedPatchedVersion = [version]::new($sourceVersion.Major, $sourceVersion.Minor, $sourceVersion.Build, $sourceVersion.Revision + 1)
  if ($patchedInfo.Version -ne $expectedPatchedVersion) {
    throw "Unexpected patched package version: expected=$expectedPatchedVersion actual=$($patchedInfo.Version)"
  }
  $patchedPayload = Test-MsixPayload -Path $patchedMsix
  Write-Log "patched package payload verified: version=$($patchedInfo.Version) files=$($patchedPayload.Files) blocks=$($patchedPayload.Blocks)"

  $recoveryRoot = Join-Path $resolvedOutputRoot 'recovery-package'
  if ($ResumePreparedBuild) {
    Remove-PreparedRecoveryArtifacts -OutputRoot $resolvedOutputRoot -SentinelId $sentinelId
  }
  Copy-RecoveryPackageLayout -SourceRoot $package.InstallLocation -DestinationRoot $recoveryRoot
  $recoveryManifest = Join-Path $recoveryRoot 'AppxManifest.xml'
  $recoveryVersion = Set-MsixUpdateVersion -ManifestPath $recoveryManifest -MinimumVersion $patchedInfo.Version
  if ($recoveryVersion -le $patchedInfo.Version) { throw 'Recovery package version must exceed the patched package version.' }
  $recoveryMsix = Join-Path $resolvedOutputRoot 'codex-original-content-recovery.msix'
  $makeAppx = Find-SdkTool 'makeappx.exe'
  $signTool = Find-SdkTool 'signtool.exe'
  & $makeAppx pack /d $recoveryRoot /p $recoveryMsix /o
  if ($LASTEXITCODE -ne 0) { throw "Recovery package packing failed with exit code $LASTEXITCODE" }
  $publisher = (Get-MsixManifestInfo $patchedMsix).Publisher
  $certificate = Get-CodeSigningCertificate $publisher
  & $signTool sign /fd SHA256 /sha1 $certificate.Thumbprint $recoveryMsix
  if ($LASTEXITCODE -ne 0) { throw "Recovery package signing failed with exit code $LASTEXITCODE" }
  $recoveryPayload = Test-MsixPayload -Path $recoveryMsix
  $recoveryInfo = Get-MsixManifestInfo $recoveryMsix
  $recoverySignature = Get-AuthenticodeSignature -LiteralPath $recoveryMsix
  if ($recoveryInfo.Version -ne $recoveryVersion -or $recoveryInfo.Publisher -cne $publisher -or
      $recoverySignature.Status -ne 'Valid' -or $recoverySignature.SignerCertificate.Subject -cne $publisher) {
    throw 'Recovery package identity, revision, or signature validation failed.'
  }
  Write-Log "original-content recovery package verified: version=$($recoveryInfo.Version) files=$($recoveryPayload.Files) blocks=$($recoveryPayload.Blocks)"

  $null = Test-MsixDeploymentPreflight -MsixPath $patchedMsix -PackageName 'OpenAI.Codex'
  $null = Test-MsixDeploymentPreflight -MsixPath $recoveryMsix -PackageName 'OpenAI.Codex'
  Write-Log 'both package deployment preflights passed before application shutdown'

  $cliPath = Get-CodexCli
  $script:RepairDeploymentState.recoveryPackageFullName = ([string]$package.PackageFullName).Replace("_$($package.Version)_", "_${recoveryVersion}_")
  $script:RepairDeploymentState.stage = 'deploying'
  # Fail closed here: the next call can shut down Desktop.
  Save-RepairCheckpoint
  $validateInstalled = {
    param($installed)
    $script:RepairDeploymentState.stage = if ($installed.PackageFullName -ceq $script:RepairDeploymentState.targetPackageFullName) { 'verifying' } else { 'recovering' }
    Save-RepairCheckpoint -AfterDeployment
    Start-AndValidateCodex -Package $installed -PatchedVersion $patchedInfo.Version -CliPath $cliPath
  }
  $outcome = Invoke-RecoverableMsixInstall -MsixPath $patchedMsix -RecoveryMsixPath $recoveryMsix -ValidateInstalledPackage $validateInstalled -PackageName 'OpenAI.Codex'
  if (-not $outcome.Success) {
    if ($outcome.Recovered) {
      throw "The patched package failed launch/model-list acceptance; original-content recovery is installed at version $($outcome.Package.Version). Details: $($outcome.Error)"
    }
    throw "The patched package failed; the previous registration remains active. Details: $($outcome.Error)"
  }

  Write-Log "transactional repair passed: version=$($outcome.Package.Version); original-content recovery was retained until launch and model/list checks passed"
  $script:RepairDeploymentState.acceptancePassed = $true
  $script:RepairDeploymentState.verifiedPackageFullName = $outcome.Package.PackageFullName
  $script:RepairDeploymentState.verifiedUtc = [DateTime]::UtcNow.ToString('o')
  $script:RepairDeploymentState.stage = 'cleanup-pending'
  $script:RepairDeploymentState.cleanupStatus = if ($KeepArtifacts) { 'retained-requested' } else { 'pending' }
  Save-RepairCheckpoint -AfterDeployment
  if (-not $KeepArtifacts -and -not $script:RepairCheckpointFailed) {
    Remove-RepairTemporaryRoot -Path $tempRoot -SentinelId $tempSentinelId
    Write-Log 'verified short-path temporary workspace removed after successful acceptance'
    $rootItem = Get-Item -LiteralPath $resolvedOutputRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-Content -LiteralPath $sentinel -Raw) -cne $sentinelId) {
      throw 'Output cleanup sentinel or directory identity check failed; artifacts were retained.'
    }
    Remove-DirectoryTreeRobust -Path $resolvedOutputRoot
    Write-Log 'verified temporary build and recovery packages were removed after successful acceptance'
    $script:RepairDeploymentState.cleanupStatus = 'removed'
  } elseif ($script:RepairCheckpointFailed) {
    $script:RepairDeploymentState.cleanupStatus = 'retained-checkpoint-error'
    Write-Log 'warning: accepted repair artifacts retained because a deployment checkpoint could not be saved'
  }
  $script:RepairDeploymentState.stage = 'verified-complete'
  Save-RepairCheckpoint -AfterDeployment
} catch {
  if ($script:RepairDeploymentState -and $script:RepairDeploymentState.acceptancePassed) {
    $script:RepairDeploymentState.stage = 'cleanup-failed'
    $script:RepairDeploymentState.cleanupStatus = 'failed'
    Write-Log "warning: repair acceptance passed; cleanup incomplete: $($_.Exception.Message)"
  } else {
    $failure = $_
    if ($script:RepairDeploymentState) { $script:RepairDeploymentState.stage = 'failed' }
    Write-Log "failed: $($_.Exception.Message)"
  }
  if ($script:RepairDeploymentState) { Save-RepairCheckpoint -AfterDeployment }
  if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
    Write-Log "temporary workspace retained for diagnosis: $tempRoot"
  }
} finally {
  $env:TEMP = $oldTemp
  $env:TMP = $oldTmp
  $env:npm_config_cache = $oldNpmConfigCache
  if ($script:TranscriptStarted) {
    Stop-Transcript | Out-Null
  }
}

if ($failure) { exit 1 }
