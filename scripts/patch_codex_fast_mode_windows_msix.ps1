param(
  [string]$AppPath,
  [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\codex-msix-repack'),
  [switch]$InstallPrerequisites,
  [switch]$Install,
  [switch]$Launch,
  [switch]$NoLaunch,
  [switch]$ForceRebuild,
  [switch]$KeepWorkDir,
  [switch]$CleanupAfter,
  [switch]$CleanupWindowsSdkAfterInstall,
  [switch]$AddLocalPluginMarketplace,
  [string]$LocalPluginMarketplaceSource = (Join-Path $env:USERPROFILE '.codex\.tmp\plugins'),
  [string]$LocalPluginMarketplaceName = 'openai-curated-local',
  [string[]]$CustomModels = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'),
  [switch]$VerifyFastModeRequest,
  [switch]$OnlyBundledMarketplaceCopy,
  [Alias('OnlyCustomModels')]
  [switch]$OnlyModelExperience,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-msix-patch-win]'
$OutputRootWasExplicit = $PSBoundParameters.ContainsKey('OutputRoot')
$WindowsSdkBuildToolsPackageId = 'microsoft.windows.sdk.buildtools'
$WindowsSdkBuildToolsVersion = '10.0.26100.7705'
$WindowsSdkInstallTimeoutSeconds = 300
$script:InstalledWindowsSdkViaNuGet = $false
$script:InstalledWindowsSdkViaWinget = $false

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Fail {
  param([string]$Message)
  throw "$LogPrefix error: $Message"
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RequiredCommand {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    Fail "required command not found: $Name"
  }
  return $cmd
}

function Normalize-AppPath {
  param([string]$Candidate)
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    return $null
  }
  $resolved = Resolve-Path -LiteralPath $Candidate -ErrorAction SilentlyContinue
  if ($resolved) {
    $Candidate = $resolved.ProviderPath
  }
  if ((Split-Path -Leaf $Candidate) -ne 'app') {
    $nested = Join-Path $Candidate 'app'
    if (Test-Path -LiteralPath $nested -PathType Container) {
      $Candidate = $nested
    }
  }
  return $Candidate
}

function Test-CodexAppPath {
  param([string]$Candidate)
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    return $false
  }
  $app = Normalize-AppPath $Candidate
  return (
    (Test-Path -LiteralPath $app -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $app 'Codex.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $app 'resources\app.asar') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $app 'resources\rg.exe') -PathType Leaf)
  )
}

function Find-CodexAppPath {
  if ($AppPath) {
    $manual = Normalize-AppPath $AppPath
    if (-not (Test-CodexAppPath $manual)) {
      Fail "-AppPath is not a Codex app directory: $AppPath"
    }
    return $manual
  }

  $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if ($pkg -and $pkg.InstallLocation) {
    $candidate = Join-Path $pkg.InstallLocation 'app'
    if (Test-CodexAppPath $candidate) {
      return (Normalize-AppPath $candidate)
    }
  }

  $running = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\Codex.exe' } |
    Sort-Object StartTime -Descending |
    Select-Object -First 1
  if ($running) {
    $candidate = Split-Path -Parent $running.Path
    if (Test-CodexAppPath $candidate) {
      return (Normalize-AppPath $candidate)
    }
  }

  $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
  $dirs = Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'OpenAI.Codex_*_x64__*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  foreach ($dir in $dirs) {
    $candidate = Join-Path $dir.FullName 'app'
    if (Test-CodexAppPath $candidate) {
      return (Normalize-AppPath $candidate)
    }
  }

  Fail 'could not find Windows Store/MSIX Codex app. Pass -AppPath explicitly.'
}

function Resolve-OutputRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Candidate,
    [bool]$WasExplicit
  )
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    Fail 'OutputRoot is empty'
  }

  $expanded = [Environment]::ExpandEnvironmentVariables($Candidate)
  $fullPath = [System.IO.Path]::GetFullPath($expanded)

  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
  if ($item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    $targets = @($item.Target) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $target = $targets | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace($target) -and -not (Test-Path -LiteralPath $target)) {
      try {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-Log "recreated missing OutputRoot reparse target: $fullPath -> $target"
      } catch {
        if ($WasExplicit) {
          Fail "OutputRoot is a broken reparse point and its target could not be recreated: $fullPath -> $target ($($_.Exception.Message))"
        }
        $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'codex-msix-repack'
        Write-Log "warning: default OutputRoot is a broken reparse point and could not be repaired: $fullPath -> $target"
        Write-Log "warning: falling back to temporary OutputRoot: $fallback"
        $fullPath = [System.IO.Path]::GetFullPath($fallback)
      }
    }
  }

  New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
  return (Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).ProviderPath
}

function Get-PackageRoot {
  param([string]$App)
  return (Split-Path -Parent $App)
}

function Get-PackageShortId {
  param([string]$PackageRoot)
  $name = Split-Path -Leaf $PackageRoot
  if ($name -match '^(OpenAI\.Codex_[^_]+)_') {
    return $matches[1]
  }
  return $name
}

function Find-WindowsSdkTool {
  param([string]$ToolName)
  $nugetTempRoot = Join-Path $env:TEMP 'codex-windows-sdk-buildtools'
  $nugetUserRoot = Join-Path $env:USERPROFILE ".nuget\packages\$WindowsSdkBuildToolsPackageId"
  $roots = @(
    $nugetTempRoot,
    $nugetUserRoot,
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  foreach ($root in $roots) {
    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $ToolName -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($hit) {
      return $hit.FullName
    }
  }
  return $null
}

function Stop-ProcessTree {
  param([int]$ProcessId)
  $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
  foreach ($child in $children) {
    Stop-ProcessTree -ProcessId ([int]$child.ProcessId)
  }
  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Invoke-ProcessWithTimeout {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [int]$TimeoutSeconds,
    [string]$Description
  )

  Write-Log "$Description (timeout ${TimeoutSeconds}s)"
  $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-ProcessTree -ProcessId $process.Id
    Fail "$Description timed out after ${TimeoutSeconds}s"
  }
  if ($process.ExitCode -ne 0) {
    Fail "$Description failed with exit code $($process.ExitCode)"
  }
}

function Remove-DirectoryRobust {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$RequiredRoot,
    [switch]$BestEffort
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
  if (-not [string]::IsNullOrWhiteSpace($RequiredRoot)) {
    if (-not (Test-Path -LiteralPath $RequiredRoot)) {
      Fail "safe deletion root does not exist: $RequiredRoot"
    }
    $root = (Resolve-Path -LiteralPath $RequiredRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($resolved.Equals($root, $comparison) -or -not $resolved.StartsWith($root + '\', $comparison)) {
      Fail "refusing to recursively delete outside safe root: $resolved"
    }
  }

  $emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-empty-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
  try {
    & robocopy.exe $emptyDir $resolved /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
      Write-Log "warning: robocopy empty mirror cleanup failed with exit code $LASTEXITCODE for $resolved"
    }
  } finally {
    Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $resolved) {
    try {
      [System.IO.Directory]::Delete($resolved, $true)
    } catch {
      $message = "failed to remove directory: $resolved ($($_.Exception.Message))"
      if ($BestEffort) {
        Write-Log "warning: $message"
      } else {
        Fail $message
      }
    }
  }
}

function Install-WindowsSdkBuildToolsViaNuGet {
  $cacheRoot = Join-Path $env:TEMP 'codex-windows-sdk-buildtools'
  $packageRoot = Join-Path $cacheRoot $WindowsSdkBuildToolsVersion
  $x64Root = Join-Path $packageRoot 'bin'
  if ((Find-WindowsSdkTool 'makeappx.exe') -and (Find-WindowsSdkTool 'signtool.exe')) {
    return
  }

  if (Test-Path -LiteralPath $packageRoot) {
    Remove-DirectoryRobust -Path $packageRoot -RequiredRoot $cacheRoot
  }
  New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

  $packageId = $WindowsSdkBuildToolsPackageId.ToLowerInvariant()
  $nupkg = Join-Path $cacheRoot "$packageId.$WindowsSdkBuildToolsVersion.nupkg"
  $zip = Join-Path $cacheRoot "$packageId.$WindowsSdkBuildToolsVersion.zip"
  $url = "https://api.nuget.org/v3-flatcontainer/$packageId/$WindowsSdkBuildToolsVersion/$packageId.$WindowsSdkBuildToolsVersion.nupkg"

  Write-Log "downloading Windows SDK BuildTools from NuGet: $WindowsSdkBuildToolsVersion"
  $oldProgress = $ProgressPreference
  try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -TimeoutSec 120
  } finally {
    $ProgressPreference = $oldProgress
  }

  Copy-Item -LiteralPath $nupkg -Destination $zip -Force
  Expand-Archive -LiteralPath $zip -DestinationPath $packageRoot -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

  $makeappx = Get-ChildItem -LiteralPath $x64Root -Recurse -Filter 'makeappx.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Select-Object -First 1
  $signtool = Get-ChildItem -LiteralPath $x64Root -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Select-Object -First 1

  if (-not $makeappx -or -not $signtool) {
    Fail "NuGet Windows SDK BuildTools did not provide required x64 MSIX tools: $packageRoot"
  }
  $script:InstalledWindowsSdkViaNuGet = $true
  Write-Log "using NuGet Windows SDK BuildTools: $packageRoot"
}

function Install-WindowsSdkPrerequisites {
  try {
    Install-WindowsSdkBuildToolsViaNuGet
    if ((Find-WindowsSdkTool 'makeappx.exe') -and (Find-WindowsSdkTool 'signtool.exe')) {
      return
    }
  } catch {
    Write-Log "warning: NuGet Windows SDK BuildTools install failed: $($_.Exception.Message)"
  }

  Write-Log 'installing Windows SDK via winget fallback'
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $winget) {
    Fail 'winget.exe not found and NuGet Windows SDK BuildTools install failed; install Windows SDK manually or install App Installer first'
  }
  Invoke-ProcessWithTimeout `
    -FilePath $winget.Source `
    -ArgumentList @('install', '--id', 'Microsoft.WindowsSDK.10.0.26100', '-e', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements') `
    -TimeoutSeconds $WindowsSdkInstallTimeoutSeconds `
    -Description 'winget Windows SDK install'
  $script:InstalledWindowsSdkViaWinget = $true
}

function Require-WindowsSdkTool {
  param([string]$ToolName)
  $tool = Find-WindowsSdkTool $ToolName
  if (-not $tool -and $InstallPrerequisites) {
    Install-WindowsSdkPrerequisites
    $tool = Find-WindowsSdkTool $ToolName
  }
  if (-not $tool) {
    Fail "$ToolName not found. Re-run with -InstallPrerequisites or install Windows SDK manually."
  }
  return [string]$tool
}

function Copy-FileDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
  try {
    $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
  try {
    $sourceItem = Get-Item -LiteralPath $Source -Force
    [System.IO.File]::SetLastWriteTimeUtc($Destination, $sourceItem.LastWriteTimeUtc)
  } catch {
    Write-Log "warning: could not preserve timestamp for $Destination`: $($_.Exception.Message)"
  }
}

function Copy-DirectoryDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Fail "source directory not found: $Source"
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    $target = Join-Path $Destination $item.Name
    if ($item.PSIsContainer -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
      Copy-DirectoryDataOnly -Source $item.FullName -Destination $target
    } elseif ($item.PSIsContainer) {
      Write-Log "warning: copying reparse directory as an empty directory: $($item.FullName)"
      New-Item -ItemType Directory -Force -Path $target | Out-Null
    } else {
      Copy-FileDataOnly -Source $item.FullName -Destination $target
    }
  }
}

function Copy-PackageLayout {
  param(
    [string]$SourcePackageRoot,
    [string]$WorkPackageRoot
  )
  if ((Test-Path -LiteralPath $WorkPackageRoot) -and $ForceRebuild) {
    Remove-DirectoryRobust -Path $WorkPackageRoot -RequiredRoot (Split-Path -Parent $WorkPackageRoot)
  }
  if (-not (Test-Path -LiteralPath $WorkPackageRoot)) {
    New-Item -ItemType Directory -Force -Path $WorkPackageRoot | Out-Null
    Write-Log "copying package layout to: $WorkPackageRoot"
    $asarPath = Join-Path $WorkPackageRoot 'app\resources\app.asar'
    $robocopyFailed = $false
    & robocopy.exe $SourcePackageRoot $WorkPackageRoot /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
      Write-Log "warning: robocopy failed with exit code $LASTEXITCODE; retrying package copy with data-only stream copy"
      $robocopyFailed = $true
    }
    if ($robocopyFailed -or -not (Test-Path -LiteralPath $asarPath -PathType Leaf)) {
      if (Test-Path -LiteralPath $WorkPackageRoot) {
        Remove-DirectoryRobust -Path $WorkPackageRoot -RequiredRoot (Split-Path -Parent $WorkPackageRoot)
      }
      New-Item -ItemType Directory -Force -Path $WorkPackageRoot | Out-Null
      Copy-DirectoryDataOnly -Source $SourcePackageRoot -Destination $WorkPackageRoot
    }
    if (-not (Test-Path -LiteralPath $asarPath -PathType Leaf)) {
      Fail "package copy did not produce app.asar: $asarPath"
    }
  } else {
    Write-Log "using existing work package layout: $WorkPackageRoot"
  }
}

function Remove-OldPackageArtifacts {
  param([string]$WorkPackageRoot)
  foreach ($rel in @('AppxSignature.p7x', 'AppxBlockMap.xml', 'AppxMetadata\CodeIntegrity.cat')) {
    $path = Join-Path $WorkPackageRoot $rel
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }
}

function Invoke-CommandChecked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$FailureMessage
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    Fail "$FailureMessage (exit code $LASTEXITCODE)"
  }
}

function Invoke-NpxAsar {
  param(
    [string]$Action,
    [string]$Source,
    [string]$Target
  )
  $npx = (Get-RequiredCommand 'npx').Source
  & $npx --yes asar $Action $Source $Target
  if ($LASTEXITCODE -ne 0) {
    Fail "npx asar $Action failed with exit code $LASTEXITCODE"
  }
}

function Invoke-RgList {
  param(
    [string]$RgPath,
    [string]$Pattern,
    [string]$Directory
  )
  $output = & $RgPath -l --hidden --glob '*.js' $Pattern $Directory 2>$null
  if ($LASTEXITCODE -gt 1) {
    Fail "rg failed for pattern: $Pattern"
  }
  return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Write-PatcherFiles {
  param([string]$WorkDir)

  $fastPatcherPath = Join-Path $WorkDir 'PatchFastMode.cjs'
  $fastUiPatcherPath = Join-Path $WorkDir 'PatchFastModeUi.cjs'
  $customModelsPatcherPath = Join-Path $WorkDir 'PatchCustomModels.cjs'
  $powerSliderPatcherPath = Join-Path $WorkDir 'PatchPowerSlider.cjs'
  $ultraFullAccessPatcherPath = Join-Path $WorkDir 'PatchUltraFullAccess.cjs'
  $localePatcherPath = Join-Path $WorkDir 'PatchLocaleI18n.cjs'
  $pluginsPatcherPath = Join-Path $WorkDir 'PatchPlugins.cjs'
  $goalPatcherPath = Join-Path $WorkDir 'PatchGoal.cjs'
  $computerUsePatcherPath = Join-Path $WorkDir 'PatchComputerUseGates.cjs'
  $browserUsePatcherPath = Join-Path $WorkDir 'PatchBrowserUseGates.cjs'
  $bundledMarketplaceCopyPatcherPath = Join-Path $WorkDir 'PatchBundledMarketplaceCopy.cjs'

  Set-Content -LiteralPath $fastPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');

const legacyPatchedRe = /function L\(e\)\{let (\w+)=v\(x\),(\w+)=e\?\.hostId\?\?\1,\{data:(\w+)\}=d\(E,\2\);return \3\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const currentDirectPatchedRe = /featureRequirements\?\.fast_mode===!1;return!\w+\}/;
const currentAsyncPatchedRe = /async function \w+\(\w+,\w+\)\{let \w+=await \w+\(\w+,\w+\);return\(await \w+\.query\.fetch\(\w+,\{authMethod:\w+,hostId:\w+\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const currentCachedAsyncPatchedRe = /return [^;]+\.query\.setData\([\s\S]*?\),\w+\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const legacyOriginalRe = /function L\(e\)\{let (\w+)=v\(x\),(\w+)=e\?\.hostId\?\?\1,(\w+)=O\(\2\),\{data:(\w+)\}=d\(E,\2\);return!\(\3\?\.authMethod!==`chatgpt`\|\|\4\?\.requirements\?\.featureRequirements\?\.fast_mode===!1\)\}/;
const currentDirectOriginalRe = /function (\w+)\(e\)\{let (\w+)=([^,;]+),(\w+)=e\?\.hostId\?\?\2,(\w+)=(\w+\(\4\)),\{data:(\w+)\}=(\w+\(\w+,\4\)),(\w+)=\7\?\.requirements\?\.featureRequirements\?\.fast_mode===!1;return!\(\5\?\.authMethod!==`chatgpt`\|\|\9\)\}/;
const currentAsyncOriginalRe = /async function (\w+)\((\w+),(\w+)\)\{let (\w+)=await ([A-Za-z_$][\w$]*)\(\2,\3\);return \4===`chatgpt`\?\(await \2\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:\4,hostId:\3\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1:!1\}/;
const currentSplitConditionRe = /if\((\w+)\?\.authMethod!==`chatgpt`\|\|(\w+)\)\{/;

if (legacyPatchedRe.test(text) || currentAsyncPatchedRe.test(text) || currentCachedAsyncPatchedRe.test(text) || (currentDirectPatchedRe.test(text) && !legacyOriginalRe.test(text) && !currentDirectOriginalRe.test(text) && !currentSplitConditionRe.test(text))) {
  process.stdout.write('already-patched');
  process.exit(0);
}

let next = text;
let patched = false;
const legacyMatch = next.match(legacyOriginalRe);
if (legacyMatch) {
  const [, rootVar, hostVar, , dataVar] = legacyMatch;
  next = next.replace(legacyOriginalRe, `function L(e){let ${rootVar}=v(x),${hostVar}=e?.hostId??${rootVar},{data:${dataVar}}=d(E,${hostVar});return ${dataVar}?.requirements?.featureRequirements?.fast_mode!==!1}`);
  patched = true;
}

if (!patched) {
  const currentMatch = next.match(currentDirectOriginalRe);
  if (currentMatch) {
    const [, fn, rootVar, rootExpr, hostVar, , , dataVar, dataCall, disabledVar] = currentMatch;
    next = next.replace(currentDirectOriginalRe, `function ${fn}(e){let ${rootVar}=${rootExpr},${hostVar}=e?.hostId??${rootVar},{data:${dataVar}}=${dataCall},${disabledVar}=${dataVar}?.requirements?.featureRequirements?.fast_mode===!1;return!${disabledVar}}`);
    patched = true;
  }

  const currentAsyncMatch = next.match(currentAsyncOriginalRe);
  if (currentAsyncMatch) {
    const [, fn, hostManagerVar, hostIdVar, authMethodVar, authMethodFn, queryVar] = currentAsyncMatch;
    next = next.replace(currentAsyncOriginalRe, `async function ${fn}(${hostManagerVar},${hostIdVar}){let ${authMethodVar}=await ${authMethodFn}(${hostManagerVar},${hostIdVar});return(await ${hostManagerVar}.query.fetch(${queryVar},{authMethod:${authMethodVar},hostId:${hostIdVar}})).requirements?.featureRequirements?.fast_mode!==!1}`);
    patched = true;
  }

  if (/canUseFastMode:!1/.test(next)) {
    const splitNext = next.replace(currentSplitConditionRe, 'if($2){');
    if (splitNext === next) {
      process.stderr.write('split-gate-target-not-found\n');
      process.exit(2);
    }
    next = splitNext;
    patched = true;
  }
}

if (!patched) {
  process.stderr.write('patch-target-not-found\n');
  process.exit(2);
}
fs.writeFileSync(file, next);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $fastUiPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');

const constantPatchedRe = /let\{data:\w+,isPending:\w+\}=[^;]+,(\w+)=!1,(\w+)=!0,\w+;[\s\S]*?\{isServiceTierAllowed:\2,isLoading:\1\}/;
if (constantPatchedRe.test(text)) {
  process.stdout.write('already-patched');
  process.exit(0);
}

const patchedRe = /let\{data:\w+,isPending:(\w+)\}=[A-Za-z_$][\w$]*\([^)]+\),(\w+)=!!\w+\?\.isLoading\|\|\1,(\w+)=!\2&&\w+!=null&&\w+\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1/;
if (patchedRe.test(text)) {
  process.stdout.write('already-patched');
  process.exit(0);
}

const uiGateRe = /let\{data:(\w+),isPending:(\w+)\}=([A-Za-z_$][\w$]*\([^)]+\)),(\w+)=!!(\w+)\?\.isLoading\|\|(\w+)&&\2,(\w+)=\6&&!\4&&\1!=null&&\1\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1/;
const match = text.match(uiGateRe);
if (!match) {
  process.stderr.write('fast-ui-patch-target-not-found\n');
  process.exit(2);
}

const [, dataVar, pendingVar, queryCall, loadingVar, authStateVar, chatgptOnlyVar, allowedVar] = match;
const replacement = `let{data:${dataVar},isPending:${pendingVar}}=${queryCall},${loadingVar}=!!${authStateVar}?.isLoading||${pendingVar},${allowedVar}=!${loadingVar}&&${dataVar}!=null&&${dataVar}?.requirements?.featureRequirements?.fast_mode!==!1`;
fs.writeFileSync(file, text.replace(uiGateRe, replacement));
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $customModelsPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const models = [...new Set(process.argv.slice(3).filter(Boolean))];
if (models.length === 0) {
  process.stderr.write('custom-model-list-empty\n');
  process.exit(2);
}

const marker = 'CODEX_CUSTOM_MODELS_V1';
const text = fs.readFileSync(file, 'utf8');
if (text.includes(marker) && models.every((model) => text.includes(model))) {
  process.stdout.write('already-patched');
  process.exit(0);
}

const visibilityRe = /if\(([$A-Za-z_][$\w]*)\?([$A-Za-z_][$\w]*)\.has\(([$A-Za-z_][$\w]*)\.model\):!\3\.hidden\)\{/;
const match = text.match(visibilityRe);
if (!match) {
  process.stderr.write('custom-model-visibility-target-not-found\n');
  process.exit(2);
}

const forced = JSON.stringify(models);
const replacement = `if(/*${marker}*/${forced}.includes(${match[3]}.model)||(${match[1]}?${match[2]}.has(${match[3]}.model):!${match[3]}.hidden)){`;
const next = text.replace(visibilityRe, replacement);
if (!next.includes(marker) || !models.every((model) => next.includes(model))) {
  process.stderr.write('custom-model-patch-verification-failed\n');
  process.exit(2);
}
fs.writeFileSync(file, next);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $powerSliderPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const marker = 'CODEX_POWER_SLIDER_V1';
const text = fs.readFileSync(file, 'utf8');

if (text.includes(marker)) {
  process.stdout.write('already-patched');
  process.exit(0);
}

if (!text.includes('harborEnabled:') && (text.includes('composer.modelPicker.power') || /model-picker-power-slider-impl/i.test(file))) {
  process.stdout.write('already-patched');
  process.exit(0);
}

const gateRe = /function ([$A-Za-z_][$\w]*)\(\{harborEnabled:([$A-Za-z_][$\w]*),isElectron:([$A-Za-z_][$\w]*),isEverydayWorkMode:([$A-Za-z_][$\w]*)\}\)\{return \4\|\|\3&&\2\}/;
const match = text.match(gateRe);
if (!match) {
  process.stderr.write('power-slider-harbor-gate-target-not-found\n');
  process.exit(2);
}

const [, fn, harborEnabled, isElectron, isEverydayWorkMode] = match;
const replacement = `function ${fn}({harborEnabled:${harborEnabled},isElectron:${isElectron},isEverydayWorkMode:${isEverydayWorkMode}}){return ${isEverydayWorkMode}||${isElectron}/*${marker}*/}`;
const next = text.replace(gateRe, replacement);
if (!next.includes(marker)) {
  process.stderr.write('power-slider-patch-verification-failed\n');
  process.exit(2);
}
fs.writeFileSync(file, next);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $ultraFullAccessPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const composerFile = process.argv[2];
const permissionsFile = process.argv[3];
const modelSettingsFile = process.argv[4];
const marker = 'CODEX_ULTRA_FULL_ACCESS_V1';
const composerMarker = 'CODEX_ULTRA_FULL_ACCESS_V1_COMPOSER';
const permissionMarker = 'CODEX_ULTRA_FULL_ACCESS_V1_PERMISSION';
const modelReadMarker = 'CODEX_ULTRA_FULL_ACCESS_V1_MODEL_READ';
const modelSetMarker = 'CODEX_ULTRA_FULL_ACCESS_V1_MODEL_SET';

if (!composerFile || !permissionsFile || !modelSettingsFile) {
  process.stderr.write('ultra-full-access-targets-missing\n');
  process.exit(2);
}

let composer = fs.readFileSync(composerFile, 'utf8');
let permissions = fs.readFileSync(permissionsFile, 'utf8');
let modelSettings = fs.readFileSync(modelSettingsFile, 'utf8');
const composerPatched = composer.includes(composerMarker) || composer.includes(marker);
const permissionsPatched = permissions.includes(permissionMarker) || (permissionsFile !== composerFile && permissions.includes(marker));
const modelReadPatched = modelSettings.includes(modelReadMarker);
const modelSetPatched = modelSettings.includes(modelSetMarker);

if (composerPatched && permissionsPatched && modelReadPatched && modelSetPatched) {
  process.stdout.write('already-patched');
  process.exit(0);
}

if (!composerPatched) {
  if (!composer.includes('ultraFullAccessConfirm.title') || !(composer.includes('ultraFullAccessConfirm.useUltra') || composer.includes('onContinueWithFullAccess:'))) {
    process.stderr.write('ultra-full-access-dialog-anchor-not-found\n');
    process.exit(2);
  }
  const dialogGateRe = /if\(!([$A-Za-z_][$\w]*)\|\|([$A-Za-z_][$\w]*)!==`ultra`(?:\|\|[$A-Za-z_][$\w]*\.reasoningEffort===`ultra`)?\)return/;
  const dialogMatch = composer.match(dialogGateRe);
  if (!dialogMatch) {
    process.stderr.write('ultra-full-access-dialog-gate-not-found\n');
    process.exit(2);
  }
  composer = composer.replace(dialogGateRe, `if(!${dialogMatch[1]}||${dialogMatch[2]}!==\`ultra\`||${dialogMatch[1]}/*${composerMarker}*/)return`);
}

if (!permissionsPatched) {
  if (permissionsFile === composerFile) {
    permissions = composer;
  }
  const fallbackGateRe = /([$A-Za-z_][$\w]*)=!([$A-Za-z_][$\w]*)&&([$A-Za-z_][$\w]*)\.reasoningEffort===`ultra`&&([$A-Za-z_][$\w]*)===`full-access`&&\(([$A-Za-z_][$\w]*)==null\|\|\5\.startsWith\(`:`\)\),([$A-Za-z_][$\w]*)=\1\?([$A-Za-z_][$\w]*)\(\):null/;
  const fallbackMatch = permissions.match(fallbackGateRe);
  if (fallbackMatch) {
    permissions = permissions.replace(fallbackGateRe, `${fallbackMatch[1]}=!1/*${permissionMarker}*/,${fallbackMatch[6]}=null`);
  } else if (permissions.includes('onContinueWithFullAccess:') && permissions.includes('ultraFullAccessConfirm.title')) {
    permissions = permissions.replace('onContinueWithFullAccess:', `/*${permissionMarker}*/onContinueWithFullAccess:`);
  } else {
    process.stderr.write('ultra-full-access-permission-fallback-not-found\n');
    process.exit(2);
  }
  if (permissionsFile === composerFile) {
    composer = permissions;
  }
}

if (!modelReadPatched) {
  const modelReadRe = /([$A-Za-z_][$\w]*)=([$A-Za-z_][$\w]*)\?\.model_reasoning_effort===`ultra`\?null:\2\?\.model_reasoning_effort\?\?null/;
  const modelReadMatch = modelSettings.match(modelReadRe);
  if (!modelReadMatch) {
    process.stderr.write('ultra-full-access-model-read-fallback-not-found\n');
    process.exit(2);
  }
  modelSettings = modelSettings.replace(modelReadRe, `${modelReadMatch[1]}=${modelReadMatch[2]}?.model_reasoning_effort??null/*${modelReadMarker}*/`);
}

if (!modelSetPatched) {
  const modelSetRe = /if\(([$A-Za-z_][$\w]*)\[0\]===(?:`default`|"default")&&([$A-Za-z_][$\w]*)===`ultra`\)\{/;
  if (!modelSetRe.test(modelSettings)) {
    process.stderr.write('ultra-full-access-model-set-fallback-not-found\n');
    process.exit(2);
  }
  modelSettings = modelSettings.replace(modelSetRe, `if(!1/*${modelSetMarker}*/){`);
}

if (!(composer.includes(composerMarker) || composer.includes(marker)) || !(permissions.includes(permissionMarker) || (permissionsFile !== composerFile && permissions.includes(marker))) || !modelSettings.includes(modelReadMarker) || !modelSettings.includes(modelSetMarker)) {
  process.stderr.write('ultra-full-access-patch-verification-failed\n');
  process.exit(2);
}

fs.writeFileSync(composerFile, composer);
fs.writeFileSync(permissionsFile, permissions);
fs.writeFileSync(modelSettingsFile, modelSettings);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $localePatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');

if (!text.includes('enable_i18n') && text.includes('locale_source')) {
  process.stdout.write('already-patched');
  process.exit(0);
}

let next = text.replace(/(\w+=)\w+\?\.get\(`enable_i18n`,!1\)/, '$1!0');
if (next === text) {
  process.stderr.write('locale-i18n-patch-target-not-found\n');
  process.exit(2);
}

fs.writeFileSync(file, next);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $pluginsPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [sidebarFile, skillsFile, detailFile, pageAuthFile] = process.argv.slice(2);
let changed = false;

function hasFile(file) {
  return typeof file === 'string' && file.length > 0 && file !== '__none__' && fs.existsSync(file);
}

function rewriteFile(label, file, patchedRe, originalRe, replacement) {
  const text = fs.readFileSync(file, 'utf8');
  if (patchedRe.test(text)) return;
  const next = text.replace(originalRe, replacement);
  if (next === text) {
    process.stderr.write(`${label}-target-not-found\n`);
    process.exit(2);
  }
  fs.writeFileSync(file, next);
  changed = true;
}

function patchOldPluginGates() {
  rewriteFile(
    'plugin-sidebar-gate',
    sidebarFile,
    /\{authMethod:(\w+)\}=([A-Za-z_$][\w$]*)\(\),(\w+)=([A-Za-z_$][\w$]*)\(`533078438`\),(\w+)=!1,(\w+)=e&&\3&&\5,(\w+)=([A-Za-z_$][\w$]*)\(\{hostId:([A-Za-z_$][\w$]*)\}\),(\w+)=e&&\7&&!\5,/,
    /\{authMethod:(\w+)\}=([A-Za-z_$][\w$]*)\(\),(\w+)=([A-Za-z_$][\w$]*)\(`533078438`\),(\w+)=([A-Za-z_$][\w$]*)\(\1\),(\w+)=e&&\3&&\5,(\w+)=([A-Za-z_$][\w$]*)\(\{hostId:([A-Za-z_$][\w$]*)\}\),(\w+)=e&&\8&&!\5,/,
    (_match, authMethodVar, authHook, flagVar, featureFlagHook, apiKeyGateVar, _apiKeyGateHook, disabledVar, availabilityVar, availabilityHook, hostIdVar, enabledVar) =>
      `{authMethod:${authMethodVar}}=${authHook}(),${flagVar}=${featureFlagHook}(\`533078438\`),${apiKeyGateVar}=!1,${disabledVar}=e&&${flagVar}&&${apiKeyGateVar},${availabilityVar}=${availabilityHook}({hostId:${hostIdVar}}),${enabledVar}=e&&${availabilityVar}&&!${apiKeyGateVar},`
  );

  rewriteFile(
    'plugin-skills-page-gate',
    skillsFile,
    /let (\w+)=!1,(\w+),(\w+);if\(e\[(\d+)\]!==(\w+)\|\|e\[(\d+)\]!==\1\|\|e\[(\d+)\]!==(\w+)\?/,
    /let (\w+)=(\w+),(\w+),(\w+);if\(e\[(\d+)\]!==(\w+)\|\|e\[(\d+)\]!==\1\|\|e\[(\d+)\]!==(\w+)\?/,
    (_match, pluginAuthBlockedVar, _sourceVar, effectFnVar, effectDepsVar, slotA, deepLinkBlockedVar, slotB, slotC, toastApiVar) =>
      `let ${pluginAuthBlockedVar}=!1,${effectFnVar},${effectDepsVar};if(e[${slotA}]!==${deepLinkBlockedVar}||e[${slotB}]!==${pluginAuthBlockedVar}||e[${slotC}]!==${toastApiVar}?`
  );

  rewriteFile(
    'plugin-detail-gate',
    detailFile,
    /\{authMethod:(\w+)\}=([A-Za-z_$][\w$]*)\(\);if\(!1\)\{let (\w+);return/,
    /\{authMethod:(\w+)\}=([A-Za-z_$][\w$]*)\(\);if\(([A-Za-z_$][\w$]*)\(\1\)\)\{let (\w+);return/,
    (_match, authMethodVar, authHook, _isAuthBlockedHook, redirectElementVar) =>
      `{authMethod:${authMethodVar}}=${authHook}();if(!1){let ${redirectElementVar};return`
  );
}

function patchPluginPageAuth(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (!text.includes('openPluginInstall') || !text.includes('authMethod:')) {
    process.stderr.write('plugin-page-auth-target-not-found\n');
    process.exit(2);
  }
  const migratedPatchedRe = /\{authMethod:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),[^;]{0,2500}?[A-Za-z_$][\w$]*=!1,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.kind===`manage`,/;
  if (/\{authMethod:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),(?:\{data:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),)?[A-Za-z_$][\w$]*=!1,/.test(text) || migratedPatchedRe.test(text)) return;

  const originalRe = /\{authMethod:([A-Za-z_$][\w$]*)\}=([A-Za-z_$][\w$]*)\(\),((?:\{data:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),)?)([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\1\),/;
  let next = text.replace(originalRe, (_match, authMethodVar, authHook, middle, blockedVar) =>
    `{authMethod:${authMethodVar}}=${authHook}(),${middle}${blockedVar}=!1,`
  );
  if (next === text) {
    const migratedOriginalRe = /\{authMethod:([A-Za-z_$][\w$]*)\}=([A-Za-z_$][\w$]*)\(\),([^;]{0,2500}?)([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\1\),([A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.kind===`manage`,)/;
    next = text.replace(migratedOriginalRe, (_match, authMethodVar, authHook, middle, blockedVar, _blockedHook, tail) =>
      `{authMethod:${authMethodVar}}=${authHook}(),${middle}${blockedVar}=!1,${tail}`
    );
  }
  if (next === text) {
    process.stderr.write('plugin-page-auth-patch-target-not-found\n');
    process.exit(2);
  }
  fs.writeFileSync(file, next);
  changed = true;
}

const oldFiles = [sidebarFile, skillsFile, detailFile];
const oldFileCount = oldFiles.filter(hasFile).length;
if (oldFileCount === 3) {
  patchOldPluginGates();
} else if (oldFileCount > 0 && !hasFile(pageAuthFile)) {
  process.stderr.write('plugin-old-gates-incomplete\n');
  process.exit(2);
}

if (hasFile(pageAuthFile)) {
  patchPluginPageAuth(pageAuthFile);
}

if (oldFileCount === 0 && !hasFile(pageAuthFile)) {
  process.stderr.write('plugin-gate-targets-not-found\n');
  process.exit(2);
}

process.stdout.write(changed ? 'patched' : 'already-patched');
'@

  Set-Content -LiteralPath $goalPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [composerFileArg, slashFileArg] = process.argv.slice(2);
const hasComposerFile = composerFileArg && composerFileArg !== '__none__';
const composerFile = hasComposerFile ? composerFileArg : null;
const slashFile = slashFileArg && slashFileArg !== '__none__' ? slashFileArg : composerFile;
const composerText = composerFile ? fs.readFileSync(composerFile, 'utf8') : '';
const slashText = slashFile ? fs.readFileSync(slashFile, 'utf8') : '';

const goalPatchedRe = /(\w+)=([A-Za-z_$][\w$]*)!==`cloud`(?:&&!?\w+)?,(\w+)=([^,]+),/;
const currentSplitGoalPatchedRe = /(\w+)=([A-Za-z_$][\w$]*)!==`cloud`&&!\w+,(\w+)=([^,]+),(\w+)=([^,]+),/;
const goalOriginalRe = /(\w+)=([A-Za-z_$][\w$]*)\(`3074100722`\)&&([A-Za-z_$][\w$]*)\((\w+)\?\.config,`goals`\)===!0&&(\w+)!==`cloud`,(\w+)=([^,]+),/;
const currentGoalOriginalRe = /(\w+)=([A-Za-z_$][\w$]*)\(`3074100722`\)&&([A-Za-z_$][\w$]*)\((\w+)\?\.config,`goals`\)===!0&&(\w+)!==`cloud`(&&!\w+)?,(\w+)=([^,]+),/;
const slashOriginal = 'function Nx(e,t){let n=t.trim();if(n.length===0)return e;let r=new Map;return e.forEach(e=>{let t=e.group??null;r.has(t)||r.set(t,r.size)}),(0,Tx.default)(e.map(e=>({command:e,score:zi(e.title,n)})).filter(e=>e.score>0),[e=>r.get(e.command.group??null)??2**53-1,e=>-e.score,e=>e.command.title]).map(e=>e.command)}';
const slashPatched = 'function Nx(e,t){let n=t.trim().replace(/^\\/+/,"");if(n.length===0)return e;let r=new Map;return e.forEach(e=>{let t=e.group??null;r.has(t)||r.set(t,r.size)}),(0,Tx.default)(e.map(e=>({command:e,score:Math.max(zi(e.title,n),zi(e.id,n))})).filter(e=>e.score>0),[e=>r.get(e.command.group??null)??2**53-1,e=>-e.score,e=>e.command.title]).map(e=>e.command)}';
const slashOriginalRe = /function (\w+)\(e,t\)\{let (\w+)=t\.trim\(\);if\(\2\.length===0\)return e;let (\w+)=new Map;return e\.forEach\(e=>\{let t=e\.group\?\?null;\3\.has\(t\)\|\|\3\.set\(t,\3\.size\)\}\),\(0,([A-Za-z_$][\w$]*)\.default\)\(e\.map\(e=>\(\{command:e,score:([A-Za-z_$][\w$]*)\(e\.title,\2\)\}\)\)\.filter\(e=>e\.score>0\),\[e=>\3\.get\(e\.command\.group\?\?null\)\?\?2\*\*53-1,e=>-e\.score,e=>e\.command\.title\]\)\.map\(e=>e\.command\)\}/;
const slashPatchedRe = /score:Math\.max\([A-Za-z_$][\w$]*\(e\.title,\w+\),[A-Za-z_$][\w$]*\(e\.id,\w+\)\)/;
const cmdkSlashRe = /cmdk-item/;
const cmdkKeywordSearchRe = /keywords:\w+|keywords,\.\.\./;
const goalCommandRe = /id:`goal`,title:[^,]+,description:[^,]+,requiresEmptyComposer:!1,[^}]*enabled:[^,]+/;
const currentGoalAlreadyOpenRe = /[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*!==`cloud`&&!?[A-Za-z_$][\w$]*,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\)\?\?!1/;

let nextComposer = composerText;
let nextSlash = slashText;
let changedComposer = false;
let changedSlash = false;

if (!nextSlash.includes(slashPatched) && !slashPatchedRe.test(nextSlash)) {
  const slashMatch = nextSlash.match(slashOriginalRe);
  if (slashMatch) {
    const [, fn, queryVar, groupOrderVar, sortByVar, scoreFn] = slashMatch;
    nextSlash = nextSlash.replace(slashOriginalRe, `function ${fn}(e,t){let ${queryVar}=t.trim().replace(/^\\/+/,"");if(${queryVar}.length===0)return e;let ${groupOrderVar}=new Map;return e.forEach(e=>{let t=e.group??null;${groupOrderVar}.has(t)||${groupOrderVar}.set(t,${groupOrderVar}.size)}),(0,${sortByVar}.default)(e.map(e=>({command:e,score:Math.max(${scoreFn}(e.title,${queryVar}),${scoreFn}(e.id,${queryVar}))})).filter(e=>e.score>0),[e=>${groupOrderVar}.get(e.command.group??null)??2**53-1,e=>-e.score,e=>e.command.title]).map(e=>e.command)}`);
    changedSlash = true;
  } else if (nextSlash.includes(slashOriginal)) {
    nextSlash = nextSlash.replace(slashOriginal, slashPatched);
    changedSlash = true;
  } else if (cmdkSlashRe.test(nextSlash) && (cmdkKeywordSearchRe.test(nextSlash) || nextSlash.includes('keywords:r'))) {
    // Codex 26.519+ moved slash filtering to cmdk keywords; command id matching is already handled there.
  } else if (nextSlash.includes('sourceMappingURL=slash-command-item') &&
             !nextSlash.includes('score:') &&
             !nextSlash.includes('e.command.group??null')) {
    // Codex 26.609.4994+ keeps this chunk but moved the legacy slash scorer elsewhere.
    // The composer gate below is the required Goal enablement patch for this shape.
  } else {
    process.stderr.write('slash-match-patch-target-not-found\n');
    process.exit(2);
  }
}

if (hasComposerFile) {
  if (goalOriginalRe.test(nextComposer)) {
    nextComposer = nextComposer.replace(goalOriginalRe, (_match, goalGateVar, _statsigFn, _configAccessFn, _configVar, modeVar, hasGoalVar, hasGoalExpr) => `${goalGateVar}=${modeVar}!==\`cloud\`,${hasGoalVar}=${hasGoalExpr},`);
    changedComposer = true;
  } else if (currentGoalOriginalRe.test(nextComposer)) {
    nextComposer = nextComposer.replace(currentGoalOriginalRe, (_match, goalGateVar, _statsigFn, _configAccessFn, _configVar, modeVar, sideChatGuard = '', hasGoalVar, hasGoalExpr) => `${goalGateVar}=${modeVar}!==\`cloud\`${sideChatGuard},${hasGoalVar}=${hasGoalExpr},`);
    changedComposer = true;
  } else if (!(goalPatchedRe.test(nextComposer) ||
               currentSplitGoalPatchedRe.test(nextComposer) ||
               currentGoalAlreadyOpenRe.test(nextComposer) ||
               (goalCommandRe.test(nextComposer) && nextComposer.includes('threadGoalObjective')))) {
    process.stderr.write('goal-patch-target-not-found\n');
    process.exit(2);
  }
}

if (!changedComposer && !changedSlash) {
  process.stdout.write('already-patched');
  process.exit(0);
}
if (changedComposer && composerFile) fs.writeFileSync(composerFile, nextComposer);
if (changedSlash) fs.writeFileSync(slashFile, nextSlash);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $computerUsePatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [availabilityFile, installFlowFile, setupFile] = process.argv.slice(2);
let changed = false;

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function writeIfChanged(file, before, after) {
  if (after !== before) {
    fs.writeFileSync(file, after);
    changed = true;
  }
}

function patchComputerUseAvailability(file) {
  const before = read(file);
  if (!before.includes('featureName:`computer_use`')) {
    process.stderr.write('computer-use-availability-target-not-found\n');
    process.exit(2);
  }

  let after = before;
  after = after.replace(/=[A-Za-z_$][\w$]*\(`1506311413`\)/, '=!0');
  after = after.replace(
    /(featureName:`computer_use`[^;]+;let )([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),/,
    '$1$2={enabled:!0,isLoading:!1},'
  );

  if (after === before && !/featureName:`computer_use`[^;]+;let [A-Za-z_$][\w$]*=\{enabled:!0,isLoading:!1\},/.test(before)) {
    process.stderr.write('computer-use-availability-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchComputerUseInstallFlow(file) {
  const before = read(file);
  if (!before.includes('openPluginInstall') ||
      (!before.includes('installPlugin:async') && !before.includes('install-plugin'))) {
    process.stderr.write('computer-use-install-flow-target-not-found\n');
    process.exit(2);
  }

  let after = before.replace(
    /([A-Za-z_$][\w$]*)=![A-Za-z_$][\w$]*\.isLoading&&[A-Za-z_$][\w$]*\.enabled,(?=[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,)/,
    '$1=!0,'
  );
  after = after.replace(
    /([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\.available,(?=[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,)/,
    '$1=!0,'
  );

  if (after === before &&
      !/featureName:`computer_use`[\s\S]*?=!0,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,/.test(before) &&
      !/=!0,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,/.test(before)) {
    process.stderr.write('computer-use-install-flow-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchComputerUseSetup(file) {
  const before = read(file);
  if (!before.includes('showComputerUseSetup')) {
    process.stderr.write('computer-use-setup-target-not-found\n');
    process.exit(2);
  }

  const after = before.replace(/=[A-Za-z_$][\w$]*\(`1506311413`\)/, '=!0');
  if (after === before && before.includes('1506311413')) {
    process.stderr.write('computer-use-setup-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

patchComputerUseAvailability(availabilityFile);
patchComputerUseInstallFlow(installFlowFile);
patchComputerUseSetup(setupFile);

process.stdout.write(changed ? 'patched' : 'already-patched');
'@

  Set-Content -LiteralPath $browserUsePatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [featureHookFile, sidebarAvailabilityFile, desktopFeatureSenderFile, desktopFeatureMainFile] = process.argv.slice(2);
let changed = false;

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

function writeIfChanged(file, before, after) {
  if (after !== before) {
    fs.writeFileSync(file, after);
    changed = true;
  }
}

function patchFeatureHook(file) {
  const before = read(file);
  if (!before.includes('featureName:`browser_use_external`') || !before.includes('featureName:`browser_use`')) {
    process.stderr.write('browser-use-feature-hook-target-not-found\n');
    process.exit(2);
  }

  let after = before.replace(
    /let c=u\(s\),d=a===`chrome-extension`\|\|o&&c\.enabled&&!c\.isLoading,f=a===`chrome-extension`\?!1:c\.isLoading,p;/,
    'let c={enabled:!0,isLoading:!1},d=!0,f=!1,p;'
  );
  after = after.replace(
    /s=t\(c\),d=i\(`410262010`\),f;/,
    's=!0,d=!0,f;'
  );
  after = after.replace(
    /let p=u\(f\),m=o\(e\.runCodexInWsl\),h=p\.enabled&&!p\.isLoading,_=p\.isLoading,v=m===!0,y;/,
    'let p={enabled:!0,isLoading:!1},m=!1,h=!0,_=!1,v=!1,y;'
  );
  after = after.replace(
    /let s=g\(o\),l=i===`chrome-extension`\|\|a&&s\.enabled&&!s\.isLoading,u=i===`chrome-extension`\?!1:s\.isLoading,d;/,
    'let s={enabled:!0,isLoading:!1},l=!0,u=!1,d;'
  );
  after = after.replace(
    /let ([A-Za-z_$][\w$]*)=x\(([A-Za-z_$][\w$]*)\),([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)===`chrome-extension`\|\|([A-Za-z_$][\w$]*)&&\1\.enabled&&!\1\.isLoading,([A-Za-z_$][\w$]*)=\4===`chrome-extension`\?!1:\1\.isLoading,([A-Za-z_$][\w$]*);/,
    'let $1={enabled:!0,isLoading:!1},$3=!0,$6=!1,$7;'
  );
  after = after.replace(
    /let ([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)===`chrome-extension`\|\|([A-Za-z_$][\w$]*)&&\1\.enabled&&!\1\.isLoading,([A-Za-z_$][\w$]*)=\3===`chrome-extension`\?!1:\1\.isLoading,([A-Za-z_$][\w$]*);/,
    'let $1={enabled:!0,isLoading:!1},$2=!0,$5=!1,$6;'
  );
  after = after.replace(
    /i=n\(m\),a=c\(`410262010`\),l;/,
    'i=!0,a=!0,l;'
  );
  after = after.replace(
    /([A-Za-z_$][\w$]*)=r\(g\),([A-Za-z_$][\w$]*)=u\(`410262010`\),([A-Za-z_$][\w$]*);/,
    '$1=!0,$2=!0,$3;'
  );
  after = after.replace(
    /([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(`410262010`\),([A-Za-z_$][\w$]*);/,
    '$1=!0,$2=!0,$3;'
  );
  after = after.replace(
    /let u=g\(l\),d=s\(o\.runCodexInWsl\),f=u\.enabled&&!u\.isLoading,p=u\.isLoading,_=d===!0,v;/,
    'let u={enabled:!0,isLoading:!1},d=!1,f=!0,p=!1,_=!1,v;'
  );
  after = after.replace(
    /let ([A-Za-z_$][\w$]*)=x\(([A-Za-z_$][\w$]*)\),([A-Za-z_$][\w$]*)=l\(c\.runCodexInWsl\),([A-Za-z_$][\w$]*)=\1\.enabled&&!\1\.isLoading,([A-Za-z_$][\w$]*)=\1\.isLoading,([A-Za-z_$][\w$]*)=\3===!0,([A-Za-z_$][\w$]*);/,
    'let $1={enabled:!0,isLoading:!1},$3=!1,$4=!0,$5=!1,$6=!1,$7;'
  );
  after = after.replace(
    /let ([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(c\.runCodexInWsl\),([A-Za-z_$][\w$]*)=\1\.enabled&&!\1\.isLoading,([A-Za-z_$][\w$]*)=\1\.isLoading,([A-Za-z_$][\w$]*)=\2===!0,([A-Za-z_$][\w$]*);/,
    'let $1={enabled:!0,isLoading:!1},$2=!1,$3=!0,$4=!1,$5=!1,$6;'
  );

  if (after === before &&
      !before.includes('let c={enabled:!0,isLoading:!1},d=!0,f=!1,p;') &&
      !before.includes('s=!0,d=!0,f;') &&
      !before.includes('let p={enabled:!0,isLoading:!1},m=!1,h=!0,_=!1,v=!1,y;') &&
      !before.includes('let s={enabled:!0,isLoading:!1},l=!0,u=!1,d;') &&
      !before.includes('i=!0,a=!0,l;') &&
      !before.includes('let u={enabled:!0,isLoading:!1},d=!1,f=!0,p=!1,_=!1,v;') &&
      !/\{enabled:!0,isLoading:!1\},[A-Za-z_$][\w$]*=!0,[A-Za-z_$][\w$]*=!1/.test(before) &&
      !/[A-Za-z_$][\w$]*=!0,[A-Za-z_$][\w$]*=!0,[A-Za-z_$][\w$]*;/.test(before)) {
    process.stderr.write('browser-use-feature-hook-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchSidebarAvailability(file) {
  const before = read(file);
  if (!before.includes('in_app_browser')) {
    process.stderr.write('browser-sidebar-availability-target-not-found\n');
    process.exit(2);
  }

  let after = before.replace(
    /var i=`in_app_browser`,a=t\(n,\(\{get:t\}\)=>\{let\{data:n\}=t\(r,t\(e\)\),a=n\?\.find\(e=>e\.name===i\);return n!=null&&a\?\.enabled!==!1\}\);/,
    'var i=`in_app_browser`,a=t(n,()=>!0);'
  );
  after = after.replace(
    /var ([A-Za-z_$][\w$]*)=`in_app_browser`,([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*),\(\{get:[A-Za-z_$][\w$]*\}\)=>\{let\{data:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\)\),[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\?\.find\([A-Za-z_$][\w$]*=>[A-Za-z_$][\w$]*\.name===\1\);return [A-Za-z_$][\w$]*!=null&&[A-Za-z_$][\w$]*\?\.enabled!==!1\}\);/,
    'var $1=`in_app_browser`,$2=$3($4,()=>!0);'
  );
  after = after.replace(
    /([A-Za-z_$][\w$]*)=`in_app_browser`,([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*),\(\{get:[A-Za-z_$][\w$]*\}\)=>\{let\{data:([A-Za-z_$][\w$]*)\}=[\s\S]*?,[A-Za-z_$][\w$]*=\5\?\.find\([A-Za-z_$][\w$]*=>[A-Za-z_$][\w$]*\.name===\1\);return \5!=null&&[A-Za-z_$][\w$]*\?\.enabled!==!1\}\)/,
    '$1=`in_app_browser`,$2=$3($4,()=>!0)'
  );
  if (after === before &&
      !before.includes('a=t(n,()=>!0)') &&
      !before.includes('()=>!0')) {
    process.stderr.write('browser-sidebar-availability-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchDesktopFeatureSender(file) {
  const before = read(file);
  const patchedSenderFragment = 'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:';
  const patchedSenderPattern = /inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,(findShortcuts:[^,}]+,)?computerUse:/;
  if (!before.includes('browser_use_availability_resolved') || !before.includes('electron-desktop-features-changed')) {
    process.stderr.write('browser-use-desktop-feature-sender-target-not-found\n');
    process.exit(2);
  }

  let after = before.replace(
    /inAppBrowserUse:[^,}]+,inAppBrowserUseAllowed:[^,}]+,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:[^,}]+,externalBrowserUse:[^,}]+,externalBrowserUseAllowed:[^,}]+,(findShortcuts:[^,}]+,)?computerUse:/,
    'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,$1$2$3browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,$4computerUse:'
  );
  after = after.replace(
    /browser_use_availability_resolved`,\{safe:\{available:[^,]+,platform:([^,]+),reason:[^,]+,release:([^}]+)\},sensitive:\{browserPane:[^}]+\}\}\)/,
    'browser_use_availability_resolved`,{safe:{available:!0,platform:$1,reason:`local-patched`,release:$2},sensitive:{browserPane:!0}})'
  );

  if (after === before &&
      !before.includes(patchedSenderFragment) &&
      !patchedSenderPattern.test(before)) {
    process.stderr.write('browser-use-desktop-feature-sender-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchDesktopFeatureMain(file) {
  const before = read(file);
  const patchedMainFragment = 'browserPane:!0,inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0';
  const envGatePattern = /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)===`win32`&&([A-Za-z_$][\w$]*)\.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`\?\{\.\.\.([A-Za-z_$][\w$]*),computerUse:!0,computerUseNodeRepl:!0\}:\4/;
  if (!before.includes(patchedMainFragment) &&
      (!before.includes('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE') ||
       (!envGatePattern.test(before) &&
        !/inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed/.test(before)))) {
    process.stderr.write('browser-use-desktop-feature-main-target-not-found\n');
    process.exit(2);
  }

  let after = before.replace(
    envGatePattern,
    '$1=$2===`win32`?{...$4,browserPane:!0,inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,...$3.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`?{computerUse:!0,computerUseNodeRepl:!0}:{}}:$4'
  );
  after = after.replace(
    /inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed,computerUse:/,
    'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:'
  );

  if (after === before &&
      !before.includes(patchedMainFragment)) {
    process.stderr.write('browser-use-desktop-feature-main-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

patchFeatureHook(featureHookFile);
patchSidebarAvailability(sidebarAvailabilityFile);
patchDesktopFeatureSender(desktopFeatureSenderFile);
patchDesktopFeatureMain(desktopFeatureMainFile);

process.stdout.write(changed ? 'patched' : 'already-patched');
'@

  Set-Content -LiteralPath $bundledMarketplaceCopyPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');

const copyPatchedMarker = 'codex_windows_bundled_marketplace_copy_fallback';
const sitesPatchedMarker = 'codex_windows_sites_bundled_plugin_available';
let after = text;
let changed = false;

const hasNativeWindowsCopyFallback =
  after.includes('copyDirectoryAllowDecryptedDestinationOnEncryptionFailure') &&
  after.includes('windows-file-copy-');

if (!after.includes(copyPatchedMarker) && !hasNativeWindowsCopyFallback) {
  const originalRe = /async function ([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*),([A-Za-z_$][\w$]*)\)\{if\(([A-Za-z_$][\w$]*)\.default\.platform===`darwin`\)\{await ([A-Za-z_$][\w$]*)\(`ditto`,\[`--noqtn`,\2,\3\]\);return\}await ([A-Za-z_$][\w$]*)\.default\.cp\(\2,\3,\{recursive:!0,verbatimSymlinks:!0\}\)\}/;
  const match = after.match(originalRe);
  if (!match) {
    process.stderr.write('bundled-marketplace-copy-target-not-found\n');
    process.exit(2);
  }

  const matchIndex = match.index ?? 0;
  const searchStart = Math.max(0, matchIndex - 2500);
  const searchEnd = Math.min(after.length, matchIndex + 2500);
  const nearby = after.slice(searchStart, searchEnd);
  const pathMatch = nearby.match(/\(0,([A-Za-z_$][\w$]*)\.join\)\(/) || after.match(/\(0,([A-Za-z_$][\w$]*)\.join\)\(/);
  if (!pathMatch) {
    process.stderr.write('bundled-marketplace-copy-path-var-not-found\n');
    process.exit(2);
  }

  const [, fn, sourceArg, targetArg, platformVar, dittoFn, fsVar] = match;
  const pathVar = pathMatch[1];
  const fallbackFn = `codexWindowsBundledMarketplaceCopyFallback`;
  const replacement = `async function ${fn}(${sourceArg},${targetArg}){if(${platformVar}.default.platform===\`darwin\`){await ${dittoFn}(\`ditto\`,[\`--noqtn\`,${sourceArg},${targetArg}]);return}try{await ${fsVar}.default.cp(${sourceArg},${targetArg},{recursive:!0,verbatimSymlinks:!0});return}catch(n){if(${platformVar}.default.platform!==\`win32\`)throw n;try{console.warn(\`${copyPatchedMarker}\`,n)}catch{}}async function ${fallbackFn}(e,t){let n=await ${fsVar}.default.lstat(e);if(n.isDirectory()){await ${fsVar}.default.mkdir(t,{recursive:!0});for(let r of await ${fsVar}.default.readdir(e))await ${fallbackFn}((0,${pathVar}.join)(e,r),(0,${pathVar}.join)(t,r));return}if(n.isSymbolicLink()){let r=await ${fsVar}.default.readlink(e);try{await ${fsVar}.default.symlink(r,t)}catch(e){if(e?.code!==\`EEXIST\`)throw e}return}await ${fsVar}.default.mkdir((0,${pathVar}.dirname)(t),{recursive:!0});let r=await ${fsVar}.default.readFile(e);await ${fsVar}.default.writeFile(t,r);try{await ${fsVar}.default.chmod(t,n.mode)}catch{}}await ${fallbackFn}(${sourceArg},${targetArg})}`;
  after = after.replace(originalRe, replacement);
  changed = true;
}

if (!after.includes(sitesPatchedMarker)) {
  const sitesAvailabilityRe = /isAvailable:\(\{features:([A-Za-z_$][\w$]*)\}\)=>\1\.sites/;
  if (!sitesAvailabilityRe.test(after)) {
    process.stderr.write('bundled-marketplace-sites-availability-target-not-found\n');
    process.exit(2);
  }
  after = after.replace(sitesAvailabilityRe, `isAvailable:()=>!0/*${sitesPatchedMarker}*/`);
  changed = true;
}

if (changed) {
  fs.writeFileSync(file, after);
  process.stdout.write('patched');
} else {
  process.stdout.write('already-patched');
}
'@

  return [pscustomobject]@{
    Fast = $fastPatcherPath
    FastUi = $fastUiPatcherPath
    CustomModels = $customModelsPatcherPath
    PowerSlider = $powerSliderPatcherPath
    UltraFullAccess = $ultraFullAccessPatcherPath
    LocaleI18n = $localePatcherPath
    Plugins = $pluginsPatcherPath
    Goal = $goalPatcherPath
    ComputerUse = $computerUsePatcherPath
    BrowserUse = $browserUsePatcherPath
    BundledMarketplaceCopy = $bundledMarketplaceCopyPatcherPath
  }
}

function Find-PatchTargets {
  param(
    [string]$RgPath,
    [string]$ExtractDir
  )
  $assetsDir = Join-Path $ExtractDir 'webview\assets'
  if (-not (Test-Path -LiteralPath $assetsDir -PathType Container)) {
    Fail "assets directory not found in extracted asar: $assetsDir"
  }
  $viteBuildDir = Join-Path $ExtractDir '.vite\build'

  $fastModeTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'read-service-tier-for-request-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('featureRequirements?.fast_mode')) {
      $fastModeTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($fastModeTarget)) {
    foreach ($candidate in (Invoke-RgList $RgPath 'Failed to read service tier for request' $assetsDir)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('featureRequirements?.fast_mode')) {
        $fastModeTarget = $candidate
        break
      }
    }
  }
  $fastModeUiTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-service-tier-settings-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('isServiceTierAllowed') -and
        ($text.Contains('featureRequirements?.fast_mode') -or
         $text -match 'let\{data:\w+,isPending:\w+\}=[^;]+,\w+=!1,\w+=!0,\w+;')) {
      $fastModeUiTarget = $candidate
      break
    }
  }
  $customModelsTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-list-filter-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if (($text.Contains('useHiddenModels') -or $text -match '\?\w+\.has\(\w+\.model\):!\w+\.hidden') -and
        $text.Contains('supportedReasoningEfforts')) {
      $customModelsTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($customModelsTarget)) {
    Fail 'could not find custom model visibility filter in extracted assets'
  }
  $powerSliderTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-and-reasoning-dropdown-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('harborEnabled:') -and
        $text.Contains('isElectron:') -and
        $text.Contains('isEverydayWorkMode:') -and
        $text.Contains('model-picker-power-slider-impl')) {
      $powerSliderTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($powerSliderTarget)) {
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-picker-power-slider-impl-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('PowerSlider')) {
        $powerSliderTarget = $candidate
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($powerSliderTarget)) {
    Fail 'could not find compact Power slider harbor gate in extracted assets'
  }
  $ultraFullAccessComposerTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter '*composer*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('ultraFullAccessConfirm.title') -and
        ($text.Contains('ultraFullAccessConfirm.useUltra') -or
         $text.Contains('onContinueWithFullAccess:'))) {
      $ultraFullAccessComposerTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($ultraFullAccessComposerTarget)) {
    Fail 'could not find Ultra and Full access confirmation gate in extracted assets'
  }
  $ultraFullAccessPermissionsTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-permissions-mode-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('CODEX_ULTRA_FULL_ACCESS_V1') -or
        ($text.Contains('reasoningEffort===`ultra`') -and
         $text.Contains('===`full-access`') -and
         $text.Contains('getNonFullAccessFallbackMode'))) {
      $ultraFullAccessPermissionsTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($ultraFullAccessPermissionsTarget)) {
    $text = Get-Content -Raw -LiteralPath $ultraFullAccessComposerTarget
    if ($text.Contains('onContinueWithFullAccess:') -and $text.Contains('ultraFullAccessConfirm.title')) {
      $ultraFullAccessPermissionsTarget = $ultraFullAccessComposerTarget
    }
  }
  if ([string]::IsNullOrWhiteSpace($ultraFullAccessPermissionsTarget)) {
    Fail 'could not find Ultra permission fallback gate in extracted assets'
  }
  $ultraFullAccessModelSettingsTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-model-settings-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if (($text.Contains('CODEX_ULTRA_FULL_ACCESS_V1_MODEL_READ') -and
         $text.Contains('CODEX_ULTRA_FULL_ACCESS_V1_MODEL_SET')) -or
        ($text.Contains('model_reasoning_effort===`ultra`?null:') -and
         $text.Contains('[0]===') -and
         $text.Contains('===`ultra`'))) {
      $ultraFullAccessModelSettingsTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($ultraFullAccessModelSettingsTarget)) {
    Fail 'could not find Ultra model settings fallback gate in extracted assets'
  }
  $localeI18nTarget = $null
  $localeCandidates = @(
    Invoke-RgList $RgPath 'enable_i18n' $assetsDir
    Invoke-RgList $RgPath 'locale_source' $assetsDir
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
  foreach ($candidate in $localeCandidates) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('locale_source') -and $text.Contains('localeOverride')) {
      $localeI18nTarget = $candidate
      break
    }
  }
  $browserUseFeatureHookTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'featureName:`browser_use_external`' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('featureName:`browser_use_external`') -and
        $text.Contains('featureName:`browser_use`') -and
        $text.Contains('featureName:`computer_use`')) {
      $browserUseFeatureHookTarget = $candidate
      break
    }
  }
  $browserSidebarAvailabilityTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'browser-sidebar-availability-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('in_app_browser')) {
      $browserSidebarAvailabilityTarget = $candidate
      break
    }
  }
  $desktopFeatureSenderTarget = $null
  $desktopFeatureSenderCandidates = @(
    Invoke-RgList $RgPath 'browser_use_availability_resolved' $assetsDir
    Invoke-RgList $RgPath 'inAppBrowserUse:!0' $assetsDir
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
  foreach ($candidate in $desktopFeatureSenderCandidates) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('electron-desktop-features-changed') -and
        (($text -match 'inAppBrowserUse:[^,}]+,inAppBrowserUseAllowed:[^,}]+,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:[^,}]+,externalBrowserUse:[^,}]+,externalBrowserUseAllowed:[^,}]+,(findShortcuts:[^,}]+,)?computerUse:[^,}]+') -or
         ($text -match 'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0'))) {
      $desktopFeatureSenderTarget = $candidate
      break
    }
  }
  $desktopFeatureMainTarget = $null
  if (Test-Path -LiteralPath $viteBuildDir -PathType Container) {
    $desktopFeatureMainCandidates = @(
      Invoke-RgList $RgPath 'CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE' $viteBuildDir
      Invoke-RgList $RgPath 'externalBrowserUse:' $viteBuildDir
      Invoke-RgList $RgPath 'browserPane:!0' $viteBuildDir
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    foreach ($candidate in $desktopFeatureMainCandidates) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE') -and
          (($text -match '([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)===`win32`&&([A-Za-z_$][\w$]*)\.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`\?\{\.\.\.([A-Za-z_$][\w$]*),computerUse:!0,computerUseNodeRepl:!0\}:\4') -or
           ($text -match 'inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed') -or
           $text.Contains('browserPane:!0,inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0'))) {
        $desktopFeatureMainTarget = $candidate
        break
      }
    }
  }
  $pluginSidebarTarget = Invoke-RgList $RgPath '533078438' $assetsDir | Select-Object -First 1
  $pluginSkillsTarget = Invoke-RgList $RgPath 'pluginDeepLinkAuthBlocked===!0' $assetsDir | Select-Object -First 1
  $pluginDetailTarget = Invoke-RgList $RgPath 'pluginDeepLinkAuthBlocked:!0' $assetsDir | Select-Object -First 1
  $pluginPageAuthTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'plugins-page-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('openPluginInstall') -and
        $text.Contains('authMethod:') -and
      (($text -match '\{authMethod:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),(?:\{data:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),)?[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),') -or
       ($text -match '\{authMethod:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),(?:\{data:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),)?[A-Za-z_$][\w$]*=!1,') -or
       ($text -match '\{authMethod:([A-Za-z_$][\w$]*)\}=[A-Za-z_$][\w$]*\(\),[^;]{0,2500}?[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\(\1\),[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.kind===`manage`,') -or
       ($text -match '\{authMethod:[A-Za-z_$][\w$]*\}=[A-Za-z_$][\w$]*\(\),[^;]{0,2500}?[A-Za-z_$][\w$]*=!1,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.kind===`manage`,'))) {
      $pluginPageAuthTarget = $candidate
      break
    }
  }

  if ([string]::IsNullOrWhiteSpace($fastModeTarget)) {
    Fail 'could not find patch target: fastModeTarget'
  }
  if ([string]::IsNullOrWhiteSpace($fastModeUiTarget)) {
    Fail 'could not find patch target: fastModeUiTarget'
  }
  if ([string]::IsNullOrWhiteSpace($localeI18nTarget)) {
    Fail 'could not find patch target: localeI18nTarget'
  }
  if ([string]::IsNullOrWhiteSpace($browserUseFeatureHookTarget)) {
    Fail 'could not find Browser Use feature hook gate in extracted assets'
  }
  if ([string]::IsNullOrWhiteSpace($browserSidebarAvailabilityTarget)) {
    Fail 'could not find browser sidebar availability gate in extracted assets'
  }
  if ([string]::IsNullOrWhiteSpace($desktopFeatureSenderTarget)) {
    Fail 'could not find desktop browser-use feature sender in extracted assets'
  }
  if ([string]::IsNullOrWhiteSpace($desktopFeatureMainTarget)) {
    Fail 'could not find desktop browser-use feature receiver in extracted ASAR'
  }
  $oldPluginTargetsFound = -not [string]::IsNullOrWhiteSpace($pluginSidebarTarget) -and
                           -not [string]::IsNullOrWhiteSpace($pluginSkillsTarget) -and
                           -not [string]::IsNullOrWhiteSpace($pluginDetailTarget)
  if (-not $oldPluginTargetsFound -and [string]::IsNullOrWhiteSpace($pluginPageAuthTarget)) {
    Fail 'could not find plugin auth patch target in extracted assets'
  }

  $goalComposerTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'threadGoalObjective|composer.goalSlashCommand.title' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if (($text.Contains('3074100722') -and $text.Contains('goals')) -or
        ($text.Contains('composer.goalSlashCommand.title') -and $text -match 'id:`goal`,title:[^,]+,description:[^,]+,requiresEmptyComposer:!1,[^}]*enabled:[^,]+') -or
        ($text.Contains('composer.goalSlashCommand.title') -and $text -match '[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*!==`cloud`&&!?[A-Za-z_$][\w$]*,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\),[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*\)\?\?!1') -or
        ($text -match '(\w+)=[A-Za-z_$][\w$]*!==`cloud`&&!\w+,(\w+)=')) {
      $goalComposerTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($goalComposerTarget)) {
    Write-Log 'goal composer gate not found; treating current build as already open or migrated'
  }

  $goalSlashTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'sourceMappingURL=slash-command-item|sourceMappingURL=local-remote-selection' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ((Split-Path -Leaf $candidate) -like 'slash-command-item-*.js' -and
        $text.Contains('sourceMappingURL=slash-command-item')) {
      $goalSlashTarget = $candidate
      break
    }
    if ($text.Contains('sourceMappingURL=slash-command-item') -and
        $text -match 'command:e,score:[A-Za-z_$][\w$]*\(e\.title,\w+\)') {
      $goalSlashTarget = $candidate
      break
    }
    if ((($text -match 'score:Math\.max\([A-Za-z_$][\w$]*\(e\.title,\w+\),[A-Za-z_$][\w$]*\(e\.id,\w+\)\)') -or
         ($text -match 'score:[A-Za-z_$][\w$]*\(e\.title,\w+\)')) -and
        $text.Contains('e.command.group??null') -and
        $text.Contains('requiresEmptyComposer')) {
      $goalSlashTarget = $candidate
      break
    }
    if ($text.Contains('cmdk-item') -and
        (($text -match 'keywords:\w+|keywords,\.\.\.') -or $text.Contains('keywords:r'))) {
      $goalSlashTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($goalSlashTarget)) {
    foreach ($candidate in (Invoke-RgList $RgPath 'score:' $assetsDir)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ((Split-Path -Leaf $candidate) -like 'slash-command-item-*.js' -and
          $text.Contains('sourceMappingURL=slash-command-item')) {
        $goalSlashTarget = $candidate
        break
      }
      if ($text.Contains('sourceMappingURL=slash-command-item') -and
          $text -match 'command:e,score:[A-Za-z_$][\w$]*\(e\.title,\w+\)') {
        $goalSlashTarget = $candidate
        break
      }
      if (((($text -match 'score:Math\.max\([A-Za-z_$][\w$]*\(e\.title,\w+\),[A-Za-z_$][\w$]*\(e\.id,\w+\)\)') -or
            ($text -match 'score:[A-Za-z_$][\w$]*\(e\.title,\w+\)')) -and
           $text.Contains('e.command.group??null') -and
           $text.Contains('requiresEmptyComposer'))) {
        $goalSlashTarget = $candidate
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($goalSlashTarget)) {
    Fail 'could not find goal slash-command matcher in extracted assets'
  }

  $computerUseAvailabilityTarget = $null
  $computerUseInstallFlowTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'featureName:`computer_use`' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ([string]::IsNullOrWhiteSpace($computerUseAvailabilityTarget) -and
        $text.Contains('available:') -and
        $text.Contains('isFetching:')) {
      $computerUseAvailabilityTarget = $candidate
    }
    if ([string]::IsNullOrWhiteSpace($computerUseInstallFlowTarget) -and
        $text.Contains('openPluginInstall') -and
        $text.Contains('installPlugin:async')) {
      $computerUseInstallFlowTarget = $candidate
    }
  }
  if ([string]::IsNullOrWhiteSpace($computerUseInstallFlowTarget)) {
    $computerUseInstallFlowCandidates = @(
      Invoke-RgList $RgPath 'installPlugin:async' $assetsDir
      Invoke-RgList $RgPath 'install-plugin' $assetsDir
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    foreach ($candidate in $computerUseInstallFlowCandidates) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('openPluginInstall') -and
          (($text -match '=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,') -or
           ($text -match '=!0,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\.available,'))) {
        $computerUseInstallFlowTarget = $candidate
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($computerUseAvailabilityTarget)) {
    Fail 'could not find Computer Use availability gate in extracted assets'
  }
  if ([string]::IsNullOrWhiteSpace($computerUseInstallFlowTarget)) {
    Fail 'could not find Computer Use install-flow gate in extracted assets'
  }

  $computerUseSetupTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'showComputerUseSetup' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('showComputerUseSetup')) {
      $computerUseSetupTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($computerUseSetupTarget)) {
    Fail 'could not find Computer Use setup gate in extracted assets'
  }

  $bundledMarketplaceCopyTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $viteBuildDir -Filter '*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if (($text.Contains('plugin_marketplace_folder_write_failed') -and $text.Contains('copy_plugins') -and $text.Contains('verbatimSymlinks:!0')) -or
        ($text.Contains('plugin_marketplace_folder_write_failed') -and $text.Contains('async function Bs(e,t)')) -or
        $text.Contains('codex_windows_bundled_marketplace_copy_fallback')) {
      $bundledMarketplaceCopyTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($bundledMarketplaceCopyTarget)) {
    Fail 'could not find bundled marketplace copy helper in extracted main bundle'
  }

  Write-Log "fast-mode patch target: $fastModeTarget"
  Write-Log "fast-mode UI patch target: $fastModeUiTarget"
  Write-Log "custom models patch target: $customModelsTarget"
  Write-Log "Power slider patch target: $powerSliderTarget"
  Write-Log "Ultra Full access composer patch target: $ultraFullAccessComposerTarget"
  Write-Log "Ultra Full access permission patch target: $ultraFullAccessPermissionsTarget"
  Write-Log "Ultra Full access model settings patch target: $ultraFullAccessModelSettingsTarget"
  Write-Log "locale i18n patch target: $localeI18nTarget"
  Write-Log "plugin sidebar patch target: $pluginSidebarTarget"
  Write-Log "plugin skills-page patch target: $pluginSkillsTarget"
  Write-Log "plugin detail patch target: $pluginDetailTarget"
  Write-Log "plugin page auth patch target: $pluginPageAuthTarget"
  Write-Log "goal composer patch target: $goalComposerTarget"
  Write-Log "goal slash-command patch target: $goalSlashTarget"
  Write-Log "browser-use feature hook patch target: $browserUseFeatureHookTarget"
  Write-Log "browser-sidebar availability patch target: $browserSidebarAvailabilityTarget"
  Write-Log "desktop browser-use sender patch target: $desktopFeatureSenderTarget"
  Write-Log "desktop browser-use receiver patch target: $desktopFeatureMainTarget"
  Write-Log "computer-use availability patch target: $computerUseAvailabilityTarget"
  Write-Log "computer-use install-flow patch target: $computerUseInstallFlowTarget"
  Write-Log "computer-use setup patch target: $computerUseSetupTarget"
  Write-Log "bundled marketplace copy patch target: $bundledMarketplaceCopyTarget"

  return [pscustomobject]@{
    FastMode = $fastModeTarget
    FastModeUi = $fastModeUiTarget
    CustomModels = $customModelsTarget
    PowerSlider = $powerSliderTarget
    UltraFullAccessComposer = $ultraFullAccessComposerTarget
    UltraFullAccessPermissions = $ultraFullAccessPermissionsTarget
    UltraFullAccessModelSettings = $ultraFullAccessModelSettingsTarget
    LocaleI18n = $localeI18nTarget
    PluginSidebar = $pluginSidebarTarget
    PluginSkills = $pluginSkillsTarget
    PluginDetail = $pluginDetailTarget
    PluginPageAuth = $pluginPageAuthTarget
    GoalComposer = $goalComposerTarget
    GoalSlash = $goalSlashTarget
    BrowserUseFeatureHook = $browserUseFeatureHookTarget
    BrowserSidebarAvailability = $browserSidebarAvailabilityTarget
    DesktopFeatureSender = $desktopFeatureSenderTarget
    DesktopFeatureMain = $desktopFeatureMainTarget
    ComputerUseAvailability = $computerUseAvailabilityTarget
    ComputerUseInstallFlow = $computerUseInstallFlowTarget
    ComputerUseSetup = $computerUseSetupTarget
    BundledMarketplaceCopy = $bundledMarketplaceCopyTarget
  }
}

function Invoke-NodePatcher {
  param(
    [string]$NodePath,
    [string]$ScriptPath,
    [string[]]$Arguments
  )
  $output = & $NodePath $ScriptPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    Fail "node patcher failed: $ScriptPath"
  }
  return ($output -join "`n").Trim()
}

function Invoke-PatchAppAsar {
  param(
    [string]$WorkAppPath,
    [string]$SourceAppPath,
    [string]$WorkDir
  )
  $asarPath = Join-Path $WorkAppPath 'resources\app.asar'
  $extractDir = Join-Path $WorkDir 'asar-extracted'
  $newAsarPath = Join-Path $WorkDir 'app.asar'
  $rgPath = Join-Path $WorkAppPath 'resources\rg.exe'
  if (-not (Test-Path -LiteralPath $rgPath)) {
    $rgPath = Join-Path $SourceAppPath 'resources\rg.exe'
  }
  if (-not (Test-Path -LiteralPath $rgPath)) {
    $rgPath = (Get-RequiredCommand 'rg').Source
  }
  $nodePath = (Get-RequiredCommand 'node').Source

  if (Test-Path -LiteralPath $extractDir) {
    Remove-DirectoryRobust -Path $extractDir -RequiredRoot $WorkDir
  }
  Write-Log 'extracting app.asar'
  Invoke-NpxAsar 'extract' $asarPath $extractDir
  $patchers = Write-PatcherFiles $WorkDir

  if ($OnlyModelExperience) {
    $assetsDir = Join-Path $extractDir 'webview\assets'
    $fastModeTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'read-service-tier-for-request-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('featureRequirements?.fast_mode')) {
        $fastModeTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($fastModeTarget)) {
      foreach ($candidate in (Invoke-RgList $rgPath 'Failed to read service tier for request' $assetsDir)) {
        $text = Get-Content -Raw -LiteralPath $candidate
        if ($text.Contains('featureRequirements?.fast_mode')) {
          $fastModeTarget = $candidate
          break
        }
      }
    }
    if ([string]::IsNullOrWhiteSpace($fastModeTarget)) {
      Fail 'could not find Model Experience Fast Mode request target'
    }

    $fastModeUiTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-service-tier-settings-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('isServiceTierAllowed') -and
          ($text.Contains('featureRequirements?.fast_mode') -or
           $text -match 'let\{data:\w+,isPending:\w+\}=[^;]+,\w+=!1,\w+=!0,\w+;')) {
        $fastModeUiTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($fastModeUiTarget)) {
      Fail 'could not find Model Experience Fast Mode UI target'
    }

    $customModelsTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-list-filter-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if (($text.Contains('useHiddenModels') -or $text -match '\?\w+\.has\(\w+\.model\):!\w+\.hidden') -and
          $text.Contains('supportedReasoningEfforts')) {
        $customModelsTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($customModelsTarget)) {
      Fail 'could not find custom model visibility filter in extracted assets'
    }
    $powerSliderTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-and-reasoning-dropdown-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('harborEnabled:') -and
          $text.Contains('isElectron:') -and
          $text.Contains('isEverydayWorkMode:') -and
          $text.Contains('model-picker-power-slider-impl')) {
        $powerSliderTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($powerSliderTarget)) {
      foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-picker-power-slider-impl-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
        $text = Get-Content -Raw -LiteralPath $candidate
        if ($text.Contains('PowerSlider')) {
          $powerSliderTarget = $candidate
          break
        }
      }
    }
    if ([string]::IsNullOrWhiteSpace($powerSliderTarget)) {
      Fail 'could not find Model Experience compact Power slider harbor gate'
    }
    $ultraFullAccessComposerTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter '*composer*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('ultraFullAccessConfirm.title') -and
          ($text.Contains('ultraFullAccessConfirm.useUltra') -or
           $text.Contains('onContinueWithFullAccess:'))) {
        $ultraFullAccessComposerTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($ultraFullAccessComposerTarget)) {
      Fail 'could not find Model Experience Ultra and Full access confirmation gate'
    }
    $ultraFullAccessPermissionsTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-permissions-mode-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('CODEX_ULTRA_FULL_ACCESS_V1') -or
          ($text.Contains('reasoningEffort===`ultra`') -and
           $text.Contains('===`full-access`') -and
           $text.Contains('getNonFullAccessFallbackMode'))) {
        $ultraFullAccessPermissionsTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($ultraFullAccessPermissionsTarget)) {
      $text = Get-Content -Raw -LiteralPath $ultraFullAccessComposerTarget
      if ($text.Contains('onContinueWithFullAccess:') -and $text.Contains('ultraFullAccessConfirm.title')) {
        $ultraFullAccessPermissionsTarget = $ultraFullAccessComposerTarget
      }
    }
    if ([string]::IsNullOrWhiteSpace($ultraFullAccessPermissionsTarget)) {
      Fail 'could not find Model Experience Ultra permission fallback gate'
    }
    $ultraFullAccessModelSettingsTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-model-settings-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if (($text.Contains('CODEX_ULTRA_FULL_ACCESS_V1_MODEL_READ') -and
           $text.Contains('CODEX_ULTRA_FULL_ACCESS_V1_MODEL_SET')) -or
          ($text.Contains('model_reasoning_effort===`ultra`?null:') -and
           $text.Contains('[0]===') -and
           $text.Contains('===`ultra`'))) {
        $ultraFullAccessModelSettingsTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($ultraFullAccessModelSettingsTarget)) {
      Fail 'could not find Model Experience Ultra model settings fallback gate'
    }
    Write-Log "Model Experience Fast Mode request target: $fastModeTarget"
    Write-Log "Model Experience Fast Mode UI target: $fastModeUiTarget"
    Write-Log "Model Experience custom models target: $customModelsTarget"
    Write-Log "Model Experience Power slider target: $powerSliderTarget"
    Write-Log "Model Experience Ultra Full access composer target: $ultraFullAccessComposerTarget"
    Write-Log "Model Experience Ultra Full access permission target: $ultraFullAccessPermissionsTarget"
    Write-Log "Model Experience Ultra Full access model settings target: $ultraFullAccessModelSettingsTarget"
    $fastModeResult = Invoke-NodePatcher $nodePath $patchers.Fast @($fastModeTarget)
    Write-Log "Model Experience Fast Mode request result: $fastModeResult"
    $fastModeUiResult = Invoke-NodePatcher $nodePath $patchers.FastUi @($fastModeUiTarget)
    Write-Log "Model Experience Fast Mode UI result: $fastModeUiResult"
    $customModelsResult = Invoke-NodePatcher $nodePath $patchers.CustomModels (@($customModelsTarget) + @($CustomModels))
    Write-Log "Model Experience custom models result: $customModelsResult ($($CustomModels -join ', '))"
    $powerSliderResult = Invoke-NodePatcher $nodePath $patchers.PowerSlider @($powerSliderTarget)
    Write-Log "Model Experience Power slider result: $powerSliderResult"
    $ultraFullAccessResult = Invoke-NodePatcher $nodePath $patchers.UltraFullAccess @($ultraFullAccessComposerTarget, $ultraFullAccessPermissionsTarget, $ultraFullAccessModelSettingsTarget)
    Write-Log "Model Experience Ultra Full access result: $ultraFullAccessResult"
    foreach ($syntaxTarget in @($fastModeTarget, $fastModeUiTarget, $customModelsTarget, $powerSliderTarget, $ultraFullAccessComposerTarget, $ultraFullAccessPermissionsTarget, $ultraFullAccessModelSettingsTarget)) {
      & $nodePath --check $syntaxTarget
      if ($LASTEXITCODE -ne 0) {
        Fail "Model Experience patched asset failed node --check: $syntaxTarget"
      }
    }
    Write-Log 'Model Experience patched asset syntax checks passed'

    if ($DryRun) {
      Write-Log 'dry run: Model Experience target validation completed; no package was changed'
      return $false
    }
    if ($fastModeResult -eq 'already-patched' -and
        $fastModeUiResult -eq 'already-patched' -and
        $customModelsResult -eq 'already-patched' -and
        $powerSliderResult -eq 'already-patched' -and
        $ultraFullAccessResult -eq 'already-patched') {
      Write-Log 'asar Model Experience patches already present'
      return $false
    }
    Write-Log 'repacking app.asar'
    Invoke-NpxAsar 'pack' $extractDir $newAsarPath
    Copy-Item -LiteralPath $newAsarPath -Destination $asarPath -Force
    return $true
  }

  if ($OnlyBundledMarketplaceCopy) {
    $viteBuildDir = Join-Path $extractDir '.vite\build'
    if (-not (Test-Path -LiteralPath $viteBuildDir -PathType Container)) {
      Fail "vite build directory not found in extracted asar: $viteBuildDir"
    }
    $bundledMarketplaceCopyTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $viteBuildDir -Filter '*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if (($text.Contains('plugin_marketplace_folder_write_failed') -and $text.Contains('copy_plugins') -and $text.Contains('verbatimSymlinks:!0')) -or
          ($text.Contains('plugin_marketplace_folder_write_failed') -and $text.Contains('async function Bs(e,t)')) -or
          $text.Contains('codex_windows_bundled_marketplace_copy_fallback')) {
        $bundledMarketplaceCopyTarget = $candidate
        break
      }
    }
    if ([string]::IsNullOrWhiteSpace($bundledMarketplaceCopyTarget)) {
      Fail 'could not find bundled marketplace copy helper in extracted main bundle'
    }
    Write-Log "bundled marketplace copy patch target: $bundledMarketplaceCopyTarget"
    $bundledMarketplaceCopy = Invoke-NodePatcher $nodePath $patchers.BundledMarketplaceCopy @($bundledMarketplaceCopyTarget)
    Write-Log "bundled marketplace copy patch result: $bundledMarketplaceCopy"

    if ($DryRun) {
      Write-Log 'dry run: bundled marketplace copy patch target validation completed; no package was changed'
      return $false
    }
    if ($bundledMarketplaceCopy -eq 'already-patched') {
      Write-Log 'asar bundled marketplace copy patch already present'
      return $false
    }
    Write-Log 'repacking app.asar'
    Invoke-NpxAsar 'pack' $extractDir $newAsarPath
    Copy-Item -LiteralPath $newAsarPath -Destination $asarPath -Force
    return $true
  }

  $targets = Find-PatchTargets $rgPath $extractDir

  $fast = Invoke-NodePatcher $nodePath $patchers.Fast @($targets.FastMode)
  Write-Log "fast-mode patch result: $fast"
  $fastUi = Invoke-NodePatcher $nodePath $patchers.FastUi @($targets.FastModeUi)
  Write-Log "fast-mode UI patch result: $fastUi"
  $customModels = Invoke-NodePatcher $nodePath $patchers.CustomModels (@($targets.CustomModels) + @($CustomModels))
  Write-Log "custom models patch result: $customModels ($($CustomModels -join ', '))"
  $powerSlider = Invoke-NodePatcher $nodePath $patchers.PowerSlider @($targets.PowerSlider)
  Write-Log "Power slider patch result: $powerSlider"
  $ultraFullAccess = Invoke-NodePatcher $nodePath $patchers.UltraFullAccess @($targets.UltraFullAccessComposer, $targets.UltraFullAccessPermissions, $targets.UltraFullAccessModelSettings)
  Write-Log "Ultra Full access patch result: $ultraFullAccess"

  $localeI18n = Invoke-NodePatcher $nodePath $patchers.LocaleI18n @($targets.LocaleI18n)
  Write-Log "locale i18n patch result: $localeI18n"
  $pluginArgs = @(
    $(if ([string]::IsNullOrWhiteSpace($targets.PluginSidebar)) { '__none__' } else { [string]$targets.PluginSidebar })
    $(if ([string]::IsNullOrWhiteSpace($targets.PluginSkills)) { '__none__' } else { [string]$targets.PluginSkills })
    $(if ([string]::IsNullOrWhiteSpace($targets.PluginDetail)) { '__none__' } else { [string]$targets.PluginDetail })
    $(if ([string]::IsNullOrWhiteSpace($targets.PluginPageAuth)) { '__none__' } else { [string]$targets.PluginPageAuth })
  )
  $plugins = Invoke-NodePatcher $nodePath $patchers.Plugins $pluginArgs
  Write-Log "plugin patch result: $plugins"
  $goalArgs = @(
    $(if ([string]::IsNullOrWhiteSpace($targets.GoalComposer)) { '__none__' } else { [string]$targets.GoalComposer })
    [string]$targets.GoalSlash
  )
  $goal = Invoke-NodePatcher $nodePath $patchers.Goal $goalArgs
  Write-Log "goal patch result: $goal"
  $browserUse = Invoke-NodePatcher $nodePath $patchers.BrowserUse @($targets.BrowserUseFeatureHook, $targets.BrowserSidebarAvailability, $targets.DesktopFeatureSender, $targets.DesktopFeatureMain)
  Write-Log "browser-use gate patch result: $browserUse"
  $computerUseArgs = @(
    [string]$targets.ComputerUseAvailability
    [string]$targets.ComputerUseInstallFlow
    [string]$targets.ComputerUseSetup
  )
  $computerUse = Invoke-NodePatcher $nodePath $patchers.ComputerUse $computerUseArgs
  Write-Log "computer-use gate patch result: $computerUse"
  $bundledMarketplaceCopy = Invoke-NodePatcher $nodePath $patchers.BundledMarketplaceCopy @($targets.BundledMarketplaceCopy)
  Write-Log "bundled marketplace copy patch result: $bundledMarketplaceCopy"

  if ($DryRun) {
    Write-Log 'dry run: patch target validation completed; no package was changed'
    return $false
  }

  if ($fast -eq 'already-patched' -and
      $fastUi -eq 'already-patched' -and
      $customModels -eq 'already-patched' -and
      $powerSlider -eq 'already-patched' -and
      $ultraFullAccess -eq 'already-patched' -and
      $localeI18n -eq 'already-patched' -and
      $plugins -eq 'already-patched' -and
      $goal -eq 'already-patched' -and
      $browserUse -eq 'already-patched' -and
      $computerUse -eq 'already-patched' -and
      $bundledMarketplaceCopy -eq 'already-patched') {
    Write-Log 'asar patch already present'
    return $false
  }

  Write-Log 'repacking app.asar'
  Invoke-NpxAsar 'pack' $extractDir $newAsarPath
  Copy-Item -LiteralPath $newAsarPath -Destination $asarPath -Force
  return $true
}

function Convert-BytesToHex {
  param([byte[]]$Bytes)
  return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-AsarHeaderSha256 {
  param([string]$AsarPath)
  $fs = [System.IO.File]::Open($AsarPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $pickleHeader = New-Object byte[] 16
    if ($fs.Read($pickleHeader, 0, 16) -ne 16) {
      Fail 'could not read asar pickle header'
    }
    # Electron hashes the ASAR JSON header, not the outer pickle-size fields.
    $headerSize = [BitConverter]::ToUInt32($pickleHeader, 12)
    if ($headerSize -le 0 -or $headerSize -gt ($fs.Length - 16)) {
      Fail "invalid asar JSON header size: $headerSize"
    }
    $headerBytes = New-Object byte[] $headerSize
    if ($fs.Read($headerBytes, 0, [int]$headerSize) -ne [int]$headerSize) {
      Fail 'could not read asar header bytes'
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      return (Convert-BytesToHex $sha.ComputeHash($headerBytes))
    } finally {
      $sha.Dispose()
    }
  } finally {
    $fs.Dispose()
  }
}

function Update-CodexExeAsarIntegrity {
  param(
    [string]$ExePath,
    [string]$AsarHash
  )
  $bytes = [System.IO.File]::ReadAllBytes($ExePath)
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  $pattern = '\[\{"file":"resources\\\\app\.asar","alg":"SHA256","value":"([0-9a-fA-F]{64})"\}\]'
  $match = [regex]::Match($text, $pattern)
  if (-not $match.Success) {
    if ($text.Contains('app.asar')) {
      Fail 'could not find Electron ASAR integrity JSON inside Codex.exe'
    }
    Write-Log 'Codex.exe ASAR integrity JSON not present; skipping executable integrity update'
    return
  }
  $oldHash = $match.Groups[1].Value
  if ($oldHash -eq $AsarHash) {
    Write-Log "Codex.exe asar integrity already current: $AsarHash"
    return
  }
  $oldBytes = [System.Text.Encoding]::ASCII.GetBytes($oldHash)
  $newBytes = [System.Text.Encoding]::ASCII.GetBytes($AsarHash)
  $pos = -1
  for ($i = 0; $i -le $bytes.Length - $oldBytes.Length; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $oldBytes.Length; $j++) {
      if ($bytes[$i + $j] -ne $oldBytes[$j]) {
        $ok = $false
        break
      }
    }
    if ($ok) {
      $pos = $i
      break
    }
  }
  if ($pos -lt 0) {
    Fail 'could not locate ASAR integrity hash bytes in Codex.exe'
  }
  [Array]::Copy($newBytes, 0, $bytes, $pos, $newBytes.Length)
  [System.IO.File]::WriteAllBytes($ExePath, $bytes)
  Write-Log "updated Codex.exe asar integrity: $oldHash -> $AsarHash"
}

function Get-ManifestPublisher {
  param([string]$WorkPackageRoot)
  $manifestPath = Join-Path $WorkPackageRoot 'AppxManifest.xml'
  [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
  return $manifest.Package.Identity.Publisher
}

function Get-OrCreateSigningCertificate {
  param([string]$Publisher)
  $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Publisher } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
  if ($cert) {
    Write-Log "using existing signing certificate: $($cert.Thumbprint)"
    return $cert
  }
  Write-Log "creating signing certificate: $Publisher"
  return New-SelfSignedCertificate -Type CodeSigningCert -Subject $Publisher -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(5)
}

function Trust-SigningCertificate {
  param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
  $tempCert = Join-Path $env:TEMP ('codex-msix-signing-' + $Cert.Thumbprint + '.cer')
  Export-Certificate -Cert $Cert -FilePath $tempCert -Force | Out-Null
  Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
  Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\CurrentUser\TrustedPeople | Out-Null
  if (Test-IsAdministrator) {
    Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
  }
  Remove-Item -LiteralPath $tempCert -Force -ErrorAction SilentlyContinue
}

function Invoke-MakeAppxPack {
  param(
    [string]$MakeAppx,
    [string]$WorkPackageRoot,
    [string]$MsixPath
  )
  if (Test-Path -LiteralPath $MsixPath) {
    Remove-Item -LiteralPath $MsixPath -Force
  }
  Write-Log "packing MSIX: $MsixPath"
  & $MakeAppx pack /d $WorkPackageRoot /p $MsixPath /o
  if ($LASTEXITCODE -ne 0) {
    Fail "makeappx pack failed with exit code $LASTEXITCODE"
  }
}

function Invoke-SignPackage {
  param(
    [string]$SignTool,
    [string]$MsixPath,
    [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
  )
  Write-Log 'signing MSIX'
  & $SignTool sign /fd SHA256 /sha1 $Cert.Thumbprint $MsixPath
  if ($LASTEXITCODE -ne 0) {
    Fail "signtool sign failed with exit code $LASTEXITCODE"
  }
}

function Stop-CodexDesktopProcesses {
  param([string]$InstallLocation)
  $targetRoot = if ($InstallLocation) { $InstallLocation.TrimEnd('\') } else { $null }
  $processes = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and (
      ($targetRoot -and $_.Path.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) -or
      $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\Codex.exe'
    )
  }
  foreach ($p in $processes) {
    Write-Log "stopping Codex desktop process pid=$($p.Id)"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}

function Install-PatchedPackage {
  param(
    [string]$MsixPath,
    [string]$PackageFamilyName
  )
  $existing = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($existing) {
    Stop-CodexDesktopProcesses $existing.InstallLocation
    Write-Log "removing existing package: $($existing.PackageFullName)"
    try {
      Remove-AppxPackage -Package $existing.PackageFullName -PreserveApplicationData -ErrorAction Stop
    } catch {
      Write-Log 'PreserveApplicationData is not supported here; retrying normal Remove-AppxPackage'
      Remove-AppxPackage -Package $existing.PackageFullName -ErrorAction Stop
    }
  }
  Write-Log "installing patched MSIX: $MsixPath"
  Add-AppxPackage -Path $MsixPath -ErrorAction Stop
  $installed = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
  Write-Log "installed package: $($installed.PackageFullName)"
  if ($Launch -and -not $NoLaunch) {
    $appUserModelId = "$($installed.PackageFamilyName)!App"
    Write-Log "launching Codex package app: $appUserModelId"
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$appUserModelId"
  }
}

function Find-CodexCli {
  $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (Test-Path -LiteralPath $binRoot) {
    $hit = Get-ChildItem -LiteralPath $binRoot -Recurse -Filter 'codex.exe' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($hit) {
      return $hit.FullName
    }
  }
  $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) {
    return $cmd.Source
  }
  return $null
}

function Add-LocalMarketplace {
  param(
    [string]$Source,
    [string]$Name
  )
  if (-not (Test-Path -LiteralPath (Join-Path $Source '.agents\plugins\marketplace.json'))) {
    Fail "local marketplace source does not contain .agents\plugins\marketplace.json: $Source"
  }
  $dest = Join-Path (Join-Path $env:USERPROFILE '.codex\marketplaces') $Name
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  Write-Log "copying local marketplace: $Source -> $dest"
  & robocopy.exe $Source $dest /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -gt 7) {
    Fail "robocopy marketplace failed with exit code $LASTEXITCODE"
  }
  $jsonPath = Join-Path $dest '.agents\plugins\marketplace.json'
  $json = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
  $json.name = $Name
  if ($json.metadata -and $json.metadata.displayName -eq 'Codex official') {
    $json.metadata.displayName = 'Codex official local'
  }
  $json | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  $codex = Find-CodexCli
  if (-not $codex) {
    Write-Log "codex CLI not found; marketplace copied but not registered: $dest"
    return
  }
  Write-Log "registering local marketplace: $Name"
  & $codex plugin marketplace add $dest
  if ($LASTEXITCODE -ne 0) {
    Write-Log "warning: marketplace registration returned exit code $LASTEXITCODE"
  }
}

function Invoke-FastModeVerification {
  $codex = Find-CodexCli
  if (-not $codex) {
    Write-Log 'fast verification skipped: codex CLI not found'
    return
  }

  $node = (Get-RequiredCommand 'node').Source
  $captureDir = Join-Path $env:TEMP ('codex-fast-wire-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $captureDir | Out-Null
  $serverPath = Join-Path $captureDir 'ws-capture-server.cjs'
  $logPath = Join-Path $captureDir 'frames.jsonl'
  $readyPath = $logPath + '.ready'

  $serverSource = @'
const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const zlib = require("zlib");

const port = Number(process.argv[2]);
const outPath = process.argv[3];

function write(obj) {
  fs.appendFileSync(outPath, JSON.stringify(obj) + "\n");
}

function getServiceTier(text) {
  try {
    const payload = JSON.parse(text);
    if (typeof payload.service_tier === "string") return payload.service_tier;
  } catch {
    // WebSocket payloads can wrap the request JSON, so fall back to a text match.
  }
  const match = String(text).match(/"service_tier"\s*:\s*"([^"]+)"/);
  return match ? match[1] : null;
}

function decodeFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const frameStart = offset;
    const b1 = buffer[offset++];
    const b2 = buffer[offset++];
    const opcode = b1 & 0x0f;
    const masked = (b2 & 0x80) !== 0;
    let length = b2 & 0x7f;
    if (length === 126) {
      if (offset + 2 > buffer.length) return { frames, rest: buffer.subarray(frameStart) };
      length = buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (offset + 8 > buffer.length) return { frames, rest: buffer.subarray(frameStart) };
      const high = buffer.readUInt32BE(offset);
      const low = buffer.readUInt32BE(offset + 4);
      offset += 8;
      length = high * 4294967296 + low;
    }
    let mask;
    if (masked) {
      if (offset + 4 > buffer.length) return { frames, rest: buffer.subarray(frameStart) };
      mask = buffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (offset + length > buffer.length) return { frames, rest: buffer.subarray(frameStart) };
    const payload = Buffer.from(buffer.subarray(offset, offset + length));
    offset += length;
    if (masked) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    frames.push({ opcode, text: payload.toString("utf8") });
  }
  return { frames, rest: buffer.subarray(offset) };
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    let body = Buffer.concat(chunks);
    const encoding = String(req.headers["content-encoding"] || "").toLowerCase();
    try {
      if (encoding.includes("gzip")) body = zlib.gunzipSync(body);
      else if (encoding.includes("deflate")) body = zlib.inflateSync(body);
      else if (encoding.includes("br")) body = zlib.brotliDecompressSync(body);
      else if (encoding.includes("zstd") && zlib.zstdDecompressSync) body = zlib.zstdDecompressSync(body);
    } catch {
      // Keep the raw body if a future client uses an encoding this runtime cannot decode.
    }
    const text = body.toString("utf8");
    write({ kind: "http", method: req.method, url: req.url, service_tier: getServiceTier(text) });
    const response = Buffer.from(JSON.stringify({ error: { message: "capture complete", type: "invalid_request_error" } }));
    res.writeHead(400, { "Content-Type": "application/json", "Content-Length": response.length });
    res.end(response);
  });
});

server.on("upgrade", (req, socket, head) => {
  const key = req.headers["sec-websocket-key"];
  const accept = crypto
    .createHash("sha1")
    .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "",
    "",
  ].join("\r\n"));
  write({ kind: "upgrade", url: req.url });
  let pending = Buffer.from(head || []);
  function consume(chunk) {
    if (chunk.length > 0) pending = Buffer.concat([pending, chunk]);
    const decoded = decodeFrames(pending);
    pending = Buffer.from(decoded.rest);
    for (const frame of decoded.frames) {
      if (frame.opcode === 1) write({ kind: "frame", service_tier: getServiceTier(frame.text) });
      if (frame.opcode === 8) socket.destroy();
    }
  }
  if (pending.length > 0) consume(Buffer.alloc(0));
  socket.on("data", consume);
  setTimeout(() => socket.destroy(), 8000);
});

server.listen(port, "127.0.0.1", () => {
  fs.writeFileSync(outPath + ".ready", "ready");
});

setTimeout(() => server.close(() => process.exit(0)), 15000).unref();
'@

  Set-Content -LiteralPath $serverPath -Value $serverSource -Encoding ASCII
  $port = Get-Random -Minimum 41000 -Maximum 49000
  $server = Start-Process -FilePath $node -ArgumentList @($serverPath, [string]$port, $logPath) -PassThru -WindowStyle Hidden
  $codexJob = $null

  try {
    $deadline = (Get-Date).AddSeconds(8)
    while (-not (Test-Path -LiteralPath $readyPath)) {
      if ($server.HasExited) {
        Fail 'fast verification capture server exited before it became ready'
      }
      if ((Get-Date) -gt $deadline) {
        Fail 'fast verification capture server did not become ready'
      }
      Start-Sleep -Milliseconds 100
    }

    Write-Log 'verifying Fast Mode by capturing Codex wire request service_tier'
    $providerId = 'codex-fast-wire'
    $providerNameConfig = 'model_providers.' + $providerId + '.name="Codex Fast Wire Capture"'
    $baseUrlConfig = 'model_providers.' + $providerId + '.base_url="http://127.0.0.1:' + $port + '/v1"'
    $wireApiConfig = 'model_providers.' + $providerId + '.wire_api="responses"'
    $providerConfig = 'model_provider="' + $providerId + '"'
    $wireTier = $null
    $codexJob = Start-Job -ScriptBlock {
      param(
        [string]$CodexPath,
        [string]$ProviderConfig,
        [string]$ProviderNameConfig,
        [string]$BaseUrlConfig,
        [string]$WireApiConfig
      )
      & $CodexPath exec --ignore-user-config --ephemeral --json --skip-git-repo-check -c $ProviderConfig -c $ProviderNameConfig -c $BaseUrlConfig -c $WireApiConfig -c 'service_tier="fast"' -c 'model_reasoning_effort="low"' -c 'features.enable_request_compression=false' 'wire capture only' 2>&1 | Out-Null
    } -ArgumentList $codex, $providerConfig, $providerNameConfig, $baseUrlConfig, $wireApiConfig

    $requestDeadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $requestDeadline -and -not $wireTier) {
      Start-Sleep -Milliseconds 200
      if (-not (Test-Path -LiteralPath $logPath)) {
        continue
      }
      foreach ($line in (Get-Content -LiteralPath $logPath)) {
        try {
          $entry = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
          continue
        }
        if ($entry.kind -notin @('frame', 'http')) {
          continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.service_tier)) {
          $wireTier = [string]$entry.service_tier
          break
        }
      }
      if ($codexJob.State -in @('Completed', 'Failed', 'Stopped') -and -not $wireTier) {
        Start-Sleep -Milliseconds 300
        if ((Get-Date) -lt $requestDeadline) {
          continue
        }
        break
      }
    }

    if ($codexJob -and $codexJob.State -eq 'Running') {
      Stop-Job -Job $codexJob -ErrorAction SilentlyContinue
    }
    if (-not $wireTier) {
      Fail 'fast verification did not find service_tier in the captured request'
    }
    if ($wireTier -eq 'priority') {
      Write-Log 'fast verification: request wire service_tier=priority (Codex Fast Mode)'
    } elseif ($wireTier -eq 'fast') {
      Write-Log 'fast verification: request wire service_tier=fast'
    } else {
      Fail "fast verification captured unexpected service_tier=$wireTier"
    }

    if ($KeepWorkDir) {
      Write-Log "fast verification capture kept at: $captureDir"
    }
  } finally {
    if ($codexJob -and $codexJob.State -eq 'Running') {
      Stop-Job -Job $codexJob -ErrorAction SilentlyContinue
    }
    if ($codexJob) {
      Remove-Job -Job $codexJob -Force -ErrorAction SilentlyContinue
    }
    if ($server -and -not $server.HasExited) {
      Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepWorkDir -and (Test-Path -LiteralPath $captureDir)) {
      Remove-Item -LiteralPath $captureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Cleanup-WindowsSdk {
  $nugetTempRoot = Join-Path $env:TEMP 'codex-windows-sdk-buildtools'
  if ($script:InstalledWindowsSdkViaNuGet -and (Test-Path -LiteralPath $nugetTempRoot)) {
    Write-Log "cleanup NuGet Windows SDK BuildTools cache: $nugetTempRoot"
    Remove-Item -LiteralPath $nugetTempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($script:InstalledWindowsSdkViaWinget) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($winget) {
      Write-Log 'uninstalling Windows SDK via winget'
      try {
        Invoke-ProcessWithTimeout `
          -FilePath $winget.Source `
          -ArgumentList @('uninstall', '--id', 'Microsoft.WindowsSDK.10.0.26100', '-e', '--source', 'winget', '--accept-source-agreements') `
          -TimeoutSeconds $WindowsSdkInstallTimeoutSeconds `
          -Description 'winget Windows SDK uninstall'
      } catch {
        Write-Log "warning: winget Windows SDK uninstall failed: $($_.Exception.Message)"
      }
    }
  }

  $temp = Join-Path $env:TEMP 'windowssdk'
  if (Test-Path -LiteralPath $temp) {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$OutputRoot = Resolve-OutputRoot -Candidate $OutputRoot -WasExplicit $OutputRootWasExplicit
$sourceApp = Find-CodexAppPath
$sourcePackageRoot = Get-PackageRoot $sourceApp
$packageShortId = Get-PackageShortId $sourcePackageRoot
$workRoot = Join-Path $OutputRoot $packageShortId
$workPackageRoot = Join-Path $workRoot 'package'
$workApp = Join-Path $workPackageRoot 'app'
$artifactsDir = Join-Path $workRoot 'artifacts'
$tempWork = Join-Path $workRoot ('work-' + [guid]::NewGuid().ToString('N'))
$msixPath = Join-Path $artifactsDir ($packageShortId + '_patched.msix')

Write-Log "source app: $sourceApp"
Write-Log "source package: $sourcePackageRoot"
Write-Log "output root: $workRoot"

if ($AddLocalPluginMarketplace) {
  Add-LocalMarketplace $LocalPluginMarketplaceSource $LocalPluginMarketplaceName
}

New-Item -ItemType Directory -Force -Path $artifactsDir | Out-Null
New-Item -ItemType Directory -Force -Path $tempWork | Out-Null

try {
  Copy-PackageLayout $sourcePackageRoot $workPackageRoot
  Remove-OldPackageArtifacts $workPackageRoot

  $patched = Invoke-PatchAppAsar $workApp $sourceApp $tempWork
  $asar = Join-Path $workApp 'resources\app.asar'
  $exe = Join-Path $workApp 'Codex.exe'
  if (-not $DryRun) {
    $asarHash = Get-AsarHeaderSha256 $asar
    Write-Log "app.asar header sha256: $asarHash"
    Update-CodexExeAsarIntegrity $exe $asarHash

    $makeappx = Require-WindowsSdkTool 'makeappx.exe'
    $signtool = Require-WindowsSdkTool 'signtool.exe'
    $publisher = Get-ManifestPublisher $workPackageRoot
    $cert = Get-OrCreateSigningCertificate $publisher
    Trust-SigningCertificate $cert
    Invoke-MakeAppxPack $makeappx $workPackageRoot $msixPath
    Invoke-SignPackage $signtool $msixPath $cert
    Write-Log "patched MSIX: $msixPath"

    if ($Install) {
      Install-PatchedPackage $msixPath 'OpenAI.Codex'
    }
  }

  if ($VerifyFastModeRequest) {
    Invoke-FastModeVerification
  }

  if ($CleanupWindowsSdkAfterInstall) {
    Cleanup-WindowsSdk
  }

  if ($CleanupAfter -and (Test-Path -LiteralPath $workRoot)) {
    Write-Log "cleanup build root: $workRoot"
    Remove-DirectoryRobust -Path $workRoot -RequiredRoot $OutputRoot -BestEffort
  }

  Write-Log 'done'
} finally {
  if ($KeepWorkDir) {
    Write-Log "keeping workdir: $tempWork"
  } elseif (Test-Path -LiteralPath $tempWork) {
    Remove-DirectoryRobust -Path $tempWork -RequiredRoot $workRoot -BestEffort
  }
}
