[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$WorkRoot,

  [string]$CodexRepoUrl = 'https://github.com/openai/codex.git',
  [string]$CodexSourceRef,
  [string]$AppServerVersion,
  [string]$SourceRoot,
  [string]$CacheRoot,
  [string]$TempRoot,
  [string]$TargetRoot,
  [string]$RustToolchain = '1.95.0-x86_64-pc-windows-msvc',
  [string]$BuildTarget = 'x86_64-pc-windows-msvc',
  [string]$BuildProfile = 'dev-small',
  [switch]$SkipClone,
  [switch]$SkipPatch,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SkillRoot = Split-Path -Parent $ScriptRoot
$PatchPath = Join-Path $SkillRoot 'references\remote-control-native-replacement.patch'

function Write-Log {
  param([string]$Message)
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Fail {
  param([string]$Message)
  throw $Message
}

function Resolve-FullPath {
  param([string]$Path)
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-RequiredCommand {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    Fail "required command not found: $Name"
  }
  return $cmd.Source
}

function Import-MsvcBuildEnvironment {
  if ($BuildTarget -notlike '*windows-msvc') {
    return
  }
  $cl = Get-Command 'cl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  $link = Get-Command 'link.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cl -and $link) {
    Write-Log "MSVC build environment already available: $($cl.Source)"
    return
  }

  $vswhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  if ($vswhereCandidates.Count -eq 0) {
    Fail "MSVC Build Tools were not found. Install Visual Studio Build Tools 2022 with the C++ workload, then rerun this script. winget example: winget install --id Microsoft.VisualStudio.2022.BuildTools --source winget --override `"--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`""
  }

  $vswhere = $vswhereCandidates | Select-Object -First 1
  $installationPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($installationPath)) {
    Fail "Visual Studio Build Tools were found, but the C++ x64 tools are missing. Install the Microsoft.VisualStudio.Workload.VCTools workload, then rerun this script."
  }
  $vcvars = Join-Path $installationPath 'VC\Auxiliary\Build\vcvars64.bat'
  if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
    Fail "vcvars64.bat not found under Visual Studio installation: $vcvars"
  }

  Write-Log "loading MSVC build environment: $vcvars"
  $envLines = & cmd.exe /s /c "`"$vcvars`" >nul && set"
  if ($LASTEXITCODE -ne 0) {
    Fail "failed to load MSVC build environment from vcvars64.bat (exit code $LASTEXITCODE)"
  }
  foreach ($line in $envLines) {
    $idx = $line.IndexOf('=')
    if ($idx -le 0) {
      continue
    }
    [Environment]::SetEnvironmentVariable($line.Substring(0, $idx), $line.Substring($idx + 1), 'Process')
  }

  $cl = Get-Command 'cl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  $link = Get-Command 'link.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not ($cl -and $link)) {
    Fail "MSVC build environment did not provide cl.exe and link.exe after loading vcvars64.bat."
  }
  Write-Log "MSVC build environment loaded: $($cl.Source)"
}

function ConvertTo-NativeArgumentString {
  param([AllowNull()][string]$Argument)
  if ($null -eq $Argument) {
    return '""'
  }
  $arg = [string]$Argument
  if ($arg.Length -gt 0 -and $arg -notmatch '[\s"]') {
    return $arg
  }

  $result = New-Object System.Text.StringBuilder
  [void]$result.Append('"')
  $backslashes = 0
  foreach ($ch in $arg.ToCharArray()) {
    if ($ch -eq '\') {
      $backslashes++
      continue
    }
    if ($ch -eq '"') {
      [void]$result.Append(('\' * (($backslashes * 2) + 1)))
      [void]$result.Append('"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$result.Append(('\' * $backslashes))
      $backslashes = 0
    }
    [void]$result.Append($ch)
  }
  if ($backslashes -gt 0) {
    [void]$result.Append(('\' * ($backslashes * 2)))
  }
  [void]$result.Append('"')
  return $result.ToString()
}

function Join-NativeArgumentString {
  param([string[]]$Arguments)
  $quoted = New-Object System.Collections.Generic.List[string]
  foreach ($argument in $Arguments) {
    $quoted.Add((ConvertTo-NativeArgumentString -Argument $argument))
  }
  return ($quoted -join ' ')
}

function Invoke-NativeProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$WorkingDirectory,
    [switch]$CaptureOutput
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = Join-NativeArgumentString -Arguments $Arguments
  if ($WorkingDirectory) {
    $psi.WorkingDirectory = $WorkingDirectory
  }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi

  if ($CaptureOutput) {
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Output = (($stdout, $stderr | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join [Environment]::NewLine)
    }
  }

  $stdoutHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      Write-Host $eventArgs.Data
    }
  }
  $stderrHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      Write-Host $eventArgs.Data
    }
  }
  $process.add_OutputDataReceived($stdoutHandler)
  $process.add_ErrorDataReceived($stderrHandler)
  try {
    [void]$process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $process.WaitForExit()
    # WaitForExit() again flushes async event handlers on Windows PowerShell.
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Output = ''
    }
  } finally {
    $process.remove_OutputDataReceived($stdoutHandler)
    $process.remove_ErrorDataReceived($stderrHandler)
    $process.Dispose()
  }
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$ErrorMessage,
    [string]$WorkingDirectory
  )
  $prefix = if ($WorkingDirectory) { "[$WorkingDirectory] " } else { '' }
  Write-Log "$prefix$FilePath $($Arguments -join ' ')"
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    if ($WorkingDirectory) {
      Push-Location -LiteralPath $WorkingDirectory
      try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
          if ($null -ne $_) {
            Write-Host $_
          }
        }
        $exitCode = $LASTEXITCODE
      } finally {
        Pop-Location
      }
    } else {
      & $FilePath @Arguments 2>&1 | ForEach-Object {
        if ($null -ne $_) {
          Write-Host $_
        }
      }
      $exitCode = $LASTEXITCODE
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exitCode -ne 0) {
    Fail "$ErrorMessage (exit code $exitCode)"
  }
}

function Test-GitPatchCheck {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$PatchFile,
    [switch]$Reverse
  )
  $arguments = @('-C', $RepositoryRoot, 'apply')
  if ($Reverse) {
    $arguments += '--reverse'
  }
  $arguments += @('--check', $PatchFile)
  return Invoke-NativeProcess -FilePath $GitPath -Arguments $arguments -CaptureOutput
}

function Test-GitWorktreeDirty {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot
  )
  $status = Invoke-NativeProcess -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'status', '--porcelain') -CaptureOutput
  if ($status.ExitCode -ne 0) {
    Fail "failed to inspect Codex source git status (exit code $($status.ExitCode))"
  }
  return (-not [string]::IsNullOrWhiteSpace($status.Output))
}

function Checkout-CodexSourceRef {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [string]$SourceRef
  )

  $ref = $SourceRef.Trim()
  if ([string]::IsNullOrWhiteSpace($ref)) {
    return
  }

  $reverseCheck = Test-GitPatchCheck -GitPath $GitPath -RepositoryRoot $RepositoryRoot -PatchFile $PatchPath -Reverse
  if ($reverseCheck.ExitCode -eq 0) {
    Write-Log "native patch already applied; leaving existing source ref unchanged"
    return
  }

  if (Test-GitWorktreeDirty -GitPath $GitPath -RepositoryRoot $RepositoryRoot) {
    Fail "SourceRoot has uncommitted changes; cannot safely check out Codex source ref '$ref'. Use a clean SourceRoot or a new WorkRoot."
  }

  Write-Log "checking out Codex source ref: $ref"
  Invoke-Checked -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'fetch', '--depth', '1', 'origin', $ref) -ErrorMessage "failed to fetch Codex source ref '$ref'"
  Invoke-Checked -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'checkout', '--detach', 'FETCH_HEAD') -ErrorMessage "failed to check out Codex source ref '$ref'"
}

function Set-CargoWorkspacePackageVersion {
  param(
    [Parameter(Mandatory = $true)][string]$CargoManifestPath,
    [string]$Version
  )

  if ([string]::IsNullOrWhiteSpace($Version)) {
    return
  }
  $versionValue = $Version.Trim()
  if ($versionValue -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {
    Fail "invalid AppServerVersion: $versionValue"
  }

  $text = Get-Content -Raw -LiteralPath $CargoManifestPath
  $match = [regex]::Match($text, '(?ms)(^\[workspace\.package\]\s*?\r?\n)(.*?)(?=^\[|\z)')
  if (-not $match.Success) {
    Fail "Cargo workspace package section not found: $CargoManifestPath"
  }

  $section = $match.Groups[2].Value
  if ($section -notmatch '(?m)^version\s*=') {
    Fail "Cargo workspace package version not found: $CargoManifestPath"
  }

  $newSection = [regex]::Replace($section, '(?m)^version\s*=\s*"[^"]*"', "version = `"$versionValue`"", 1)
  $newText = $text.Substring(0, $match.Groups[2].Index) + $newSection + $text.Substring($match.Groups[2].Index + $match.Groups[2].Length)
  if ($newText -ne $text) {
    Set-Content -LiteralPath $CargoManifestPath -Value $newText -NoNewline
    Write-Log "set Cargo workspace package version for remote-control app-server: $versionValue"
  }
}

function Test-PathUnderRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $fullPath = Resolve-FullPath $Path
  $fullRoot = (Resolve-FullPath $Root).TrimEnd('\')
  $comparison = [StringComparison]::OrdinalIgnoreCase
  if ($fullPath.Equals($fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + '\', $comparison)) {
    return
  }
  Fail "$Label must stay under WorkRoot. $Label=$fullPath WorkRoot=$fullRoot"
}

function Find-Bytes {
  param(
    [Parameter(Mandatory = $true)][byte[]]$Haystack,
    [Parameter(Mandatory = $true)][byte[]]$Needle
  )
  if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) {
    return $false
  }
  $limit = $Haystack.Length - $Needle.Length
  for ($i = 0; $i -le $limit; $i++) {
    if ($Haystack[$i] -ne $Needle[0]) {
      continue
    }
    $matched = $true
    for ($j = 1; $j -lt $Needle.Length; $j++) {
      if ($Haystack[$i + $j] -ne $Needle[$j]) {
        $matched = $false
        break
      }
    }
    if ($matched) {
      return $true
    }
  }
  return $false
}

function Test-BinaryMarkers {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Markers
  )
  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Fail "replacement codex.exe not found: $FilePath"
  }
  $bytes = [System.IO.File]::ReadAllBytes($FilePath)
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($marker in $Markers) {
    $needle = [System.Text.Encoding]::UTF8.GetBytes($marker)
    if (-not (Find-Bytes -Haystack $bytes -Needle $needle)) {
      $missing.Add($marker)
    }
  }
  if ($missing.Count -gt 0) {
    Fail "replacement codex.exe is missing native remote-control markers: $($missing -join ', ')"
  }
  Write-Log "replacement codex.exe marker check passed: $($Markers.Count)"
}

$WorkRoot = Resolve-FullPath $WorkRoot
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  $SourceRoot = Join-Path $WorkRoot 's'
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
  $CacheRoot = Join-Path $WorkRoot 'c'
}
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $TempRoot = Join-Path $WorkRoot 't'
}
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot = Join-Path $WorkRoot 'o'
}

$SourceRoot = Resolve-FullPath $SourceRoot
$CacheRoot = Resolve-FullPath $CacheRoot
$TempRoot = Resolve-FullPath $TempRoot
$TargetRoot = Resolve-FullPath $TargetRoot

foreach ($item in @(
  @{ Path = $SourceRoot; Label = 'SourceRoot' },
  @{ Path = $CacheRoot; Label = 'CacheRoot' },
  @{ Path = $TempRoot; Label = 'TempRoot' },
  @{ Path = $TargetRoot; Label = 'TargetRoot' }
)) {
  Test-PathUnderRoot -Path $item.Path -Root $WorkRoot -Label $item.Label
}

if (-not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
  Fail "native patch reference not found: $PatchPath"
}

New-Item -ItemType Directory -Force -Path $WorkRoot, $CacheRoot, $TempRoot, $TargetRoot | Out-Null

$git = Get-RequiredCommand 'git'
$cargo = Get-RequiredCommand 'cargo'
Import-MsvcBuildEnvironment

if (-not $SkipClone) {
  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    $parent = Split-Path -Parent $SourceRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Invoke-Checked -FilePath $git -Arguments @(
      'clone',
      '--filter=blob:none',
      '--depth',
      '1',
      $CodexRepoUrl,
      $SourceRoot
    ) -ErrorMessage 'failed to clone Codex source'
  } else {
    Write-Log "using existing source tree: $SourceRoot"
  }
} elseif (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
  Fail "SkipClone was set but SourceRoot does not exist: $SourceRoot"
}

$gitDir = Join-Path $SourceRoot '.git'
if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
  Fail "SourceRoot is not a git checkout: $SourceRoot"
}

if (-not [string]::IsNullOrWhiteSpace($CodexSourceRef)) {
  Checkout-CodexSourceRef -GitPath $git -RepositoryRoot $SourceRoot -SourceRef $CodexSourceRef
}

if (-not $SkipPatch) {
  $reverseCheck = Test-GitPatchCheck -GitPath $git -RepositoryRoot $SourceRoot -PatchFile $PatchPath -Reverse
  if ($reverseCheck.ExitCode -eq 0) {
    Write-Log "native patch already applied"
  } else {
    $applyCheck = Test-GitPatchCheck -GitPath $git -RepositoryRoot $SourceRoot -PatchFile $PatchPath
    if ($applyCheck.ExitCode -ne 0) {
      if (-not [string]::IsNullOrWhiteSpace($applyCheck.Output)) {
        Write-Host $applyCheck.Output
      }
      Fail "native patch does not apply cleanly (exit code $($applyCheck.ExitCode))"
    }
    Invoke-Checked -FilePath $git -Arguments @('-C', $SourceRoot, 'apply', $PatchPath) -ErrorMessage 'failed to apply native patch'
  }
}

$CargoWorkspaceRoot = Join-Path $SourceRoot 'codex-rs'
$CargoManifestPath = Join-Path $CargoWorkspaceRoot 'Cargo.toml'
if (-not (Test-Path -LiteralPath $CargoManifestPath -PathType Leaf)) {
  Fail "Cargo.toml not found at expected Codex Rust workspace path: $CargoManifestPath"
}
Set-CargoWorkspacePackageVersion -CargoManifestPath $CargoManifestPath -Version $AppServerVersion

$env:CARGO_HOME = Join-Path $CacheRoot 'c'
$env:RUSTUP_HOME = Join-Path $CacheRoot 'r'
$env:TEMP = $TempRoot
$env:TMP = $TempRoot
$env:CARGO_TARGET_DIR = $TargetRoot
$env:CARGO_BUILD_JOBS = '1'

Write-Log "CARGO_HOME=$env:CARGO_HOME"
Write-Log "RUSTUP_HOME=$env:RUSTUP_HOME"
Write-Log "TEMP=$env:TEMP"
Write-Log "CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR"

if (-not $SkipBuild) {
  Invoke-Checked -FilePath $cargo -Arguments @(
    "+$RustToolchain",
    'build',
    '--profile',
    $BuildProfile,
    '-p',
    'codex-cli',
    '--target',
    $BuildTarget
  ) -ErrorMessage 'failed to build patched native Codex app-server binary' -WorkingDirectory $CargoWorkspaceRoot
}

$builtExe = Join-Path $TargetRoot "$BuildTarget\$BuildProfile\codex.exe"
$markers = @(
  'remote_control_app_server_isolated_oauth_used',
  'remote_control_native_remote_json_first',
  'remote_control_websocket_proxy_attempt',
  'remote_control_websocket_proxy_connected',
  'remote-control-oauth.json',
  'remote.json',
  'codex.remote_control.enroll'
)
Test-BinaryMarkers -FilePath $builtExe -Markers $markers

Write-Log "replacement native binary ready: $builtExe"
[pscustomobject]@{
  ReplacementResourceCodexExe = $builtExe
  WorkRoot = $WorkRoot
  SourceRoot = $SourceRoot
  CacheRoot = $CacheRoot
  TargetRoot = $TargetRoot
  TempRoot = $TempRoot
} | ConvertTo-Json
