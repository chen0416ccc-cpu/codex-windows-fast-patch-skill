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
  [switch]$VerifyFastModeRequest,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-msix-patch-win]'
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
    [string]$RequiredRoot
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
    & robocopy.exe $emptyDir $resolved /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
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
      Fail "failed to remove directory: $resolved ($($_.Exception.Message))"
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
    & robocopy.exe $SourcePackageRoot $WorkPackageRoot /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
      Fail "robocopy failed with exit code $LASTEXITCODE"
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
  $pluginsPatcherPath = Join-Path $WorkDir 'PatchPlugins.cjs'
  $goalPatcherPath = Join-Path $WorkDir 'PatchGoal.cjs'
  $computerUsePatcherPath = Join-Path $WorkDir 'PatchComputerUseGates.cjs'

  Set-Content -LiteralPath $fastPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');

const legacyPatchedRe = /function L\(e\)\{let (\w+)=v\(x\),(\w+)=e\?\.hostId\?\?\1,\{data:(\w+)\}=d\(E,\2\);return \3\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const currentDirectPatchedRe = /featureRequirements\?\.fast_mode===!1;return!\w+\}/;
const legacyOriginalRe = /function L\(e\)\{let (\w+)=v\(x\),(\w+)=e\?\.hostId\?\?\1,(\w+)=O\(\2\),\{data:(\w+)\}=d\(E,\2\);return!\(\3\?\.authMethod!==`chatgpt`\|\|\4\?\.requirements\?\.featureRequirements\?\.fast_mode===!1\)\}/;
const currentDirectOriginalRe = /function (\w+)\(e\)\{let (\w+)=([^,;]+),(\w+)=e\?\.hostId\?\?\2,(\w+)=(\w+\(\4\)),\{data:(\w+)\}=(\w+\(\w+,\4\)),(\w+)=\7\?\.requirements\?\.featureRequirements\?\.fast_mode===!1;return!\(\5\?\.authMethod!==`chatgpt`\|\|\9\)\}/;
const currentSplitConditionRe = /if\((\w+)\?\.authMethod!==`chatgpt`\|\|(\w+)\)\{/;

if (legacyPatchedRe.test(text) || (currentDirectPatchedRe.test(text) && !legacyOriginalRe.test(text) && !currentDirectOriginalRe.test(text) && !currentSplitConditionRe.test(text))) {
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

  Set-Content -LiteralPath $pluginsPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [sidebarFile, skillsFile, detailFile] = process.argv.slice(2);
let changed = false;

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

process.stdout.write(changed ? 'patched' : 'already-patched');
'@

  Set-Content -LiteralPath $goalPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [composerFile, slashFileArg] = process.argv.slice(2);
const slashFile = slashFileArg || composerFile;
const composerText = fs.readFileSync(composerFile, 'utf8');
const slashText = fs.readFileSync(slashFile, 'utf8');

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
  } else {
    process.stderr.write('slash-match-patch-target-not-found\n');
    process.exit(2);
  }
}

if (goalOriginalRe.test(nextComposer)) {
  nextComposer = nextComposer.replace(goalOriginalRe, (_match, goalGateVar, _statsigFn, _configAccessFn, _configVar, modeVar, hasGoalVar, hasGoalExpr) => `${goalGateVar}=${modeVar}!==\`cloud\`,${hasGoalVar}=${hasGoalExpr},`);
  changedComposer = true;
} else if (currentGoalOriginalRe.test(nextComposer)) {
  nextComposer = nextComposer.replace(currentGoalOriginalRe, (_match, goalGateVar, _statsigFn, _configAccessFn, _configVar, modeVar, sideChatGuard = '', hasGoalVar, hasGoalExpr) => `${goalGateVar}=${modeVar}!==\`cloud\`${sideChatGuard},${hasGoalVar}=${hasGoalExpr},`);
  changedComposer = true;
} else if (!(goalPatchedRe.test(nextComposer) || currentSplitGoalPatchedRe.test(nextComposer) || (goalCommandRe.test(nextComposer) && nextComposer.includes('threadGoalObjective')))) {
  process.stderr.write('goal-patch-target-not-found\n');
  process.exit(2);
}

if (!changedComposer && !changedSlash) {
  process.stdout.write('already-patched');
  process.exit(0);
}
if (changedComposer) fs.writeFileSync(composerFile, nextComposer);
if (changedSlash) fs.writeFileSync(slashFile, nextSlash);
process.stdout.write('patched');
'@

  Set-Content -LiteralPath $computerUsePatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const [availabilityFile, installFlowFile, mobileSetupFile, mobileSetupFlowFile, remoteControlMainFile] = process.argv.slice(2);
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
  if (!before.includes('openPluginInstall') || !before.includes('installPlugin:async')) {
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

function patchMobileSetup(file) {
  const before = read(file);
  if (!before.includes('showComputerUseSetup')) {
    process.stderr.write('computer-use-mobile-setup-target-not-found\n');
    process.exit(2);
  }

  const after = before.replace(/=[A-Za-z_$][\w$]*\(`1506311413`\)/, '=!0');
  if (after === before && before.includes('1506311413')) {
    process.stderr.write('computer-use-mobile-setup-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchCodexMobileSetupFlow(file) {
  const before = read(file);
  if (!before.includes('CODEX_MOBILE_SETUP_COMPLETED') || !before.includes('ChatGPT auth is required to load remote control environments')) {
    process.stderr.write('codex-mobile-setup-flow-target-not-found\n');
    process.exit(2);
  }

  const after = before.replace('let W=U,G,J;', 'let W=!1,G,J;');
  if (after === before && !before.includes('let W=!1,G,J;')) {
    process.stderr.write('codex-mobile-setup-flow-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

function patchRemoteControlMain(file) {
  const before = read(file);
  if (!before.includes('load_remote_control_unauthed') || !before.includes('remote_control_connections_state')) {
    process.stderr.write('remote-control-main-target-not-found\n');
    process.exit(2);
  }

  let after = before.replace(
    'if(e instanceof Am)return this.sharedObjectRepository.set(`local_remote_control_client_id`,null),this.sharedObjectRepository.set(`remote_control_connections_state`,{available:!0,accessRequired:!1,authRequired:!0,clientAuthorized:!1}),sJ().warning(`load_remote_control_unauthed`,{safe:{},sensitive:{error:e}}),[];',
    'if(e instanceof Am)return this.sharedObjectRepository.set(`local_remote_control_client_id`,`codex-windows-local-fallback`),this.sharedObjectRepository.set(`remote_control_connections_state`,{available:!0,accessRequired:!1,authRequired:!1,clientAuthorized:!0}),sJ().warning(`load_remote_control_unauthed`,{safe:{fallback:`windows-safe-empty-state`},sensitive:{error:e}}),[];'
  );

  if (after === before &&
      !before.includes('safe:{fallback:`windows-safe-empty-state`}') &&
      !before.includes('clientAuthorized:!0}),sJ().warning(`load_remote_control_unauthed`')) {
    process.stderr.write('remote-control-main-patch-target-not-found\n');
    process.exit(2);
  }
  writeIfChanged(file, before, after);
}

patchComputerUseAvailability(availabilityFile);
patchComputerUseInstallFlow(installFlowFile);
patchMobileSetup(mobileSetupFile);
patchCodexMobileSetupFlow(mobileSetupFlowFile);
patchRemoteControlMain(remoteControlMainFile);

process.stdout.write(changed ? 'patched' : 'already-patched');
'@

  return [pscustomobject]@{
    Fast = $fastPatcherPath
    Plugins = $pluginsPatcherPath
    Goal = $goalPatcherPath
    ComputerUse = $computerUsePatcherPath
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

  $fastModeTarget = Invoke-RgList $RgPath 'featureRequirements\?\.fast_mode' $assetsDir | Select-Object -First 1
  $pluginSidebarTarget = Invoke-RgList $RgPath '533078438' $assetsDir | Select-Object -First 1
  $pluginSkillsTarget = Invoke-RgList $RgPath 'pluginDeepLinkAuthBlocked===!0' $assetsDir | Select-Object -First 1
  $pluginDetailTarget = Invoke-RgList $RgPath 'pluginDeepLinkAuthBlocked:!0' $assetsDir | Select-Object -First 1

  foreach ($name in @('fastModeTarget', 'pluginSidebarTarget', 'pluginSkillsTarget', 'pluginDetailTarget')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $name).Value)) {
      Fail "could not find patch target: $name"
    }
  }

  $goalComposerTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'threadGoalObjective' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if (($text.Contains('3074100722') -and $text.Contains('goals')) -or
        ($text.Contains('composer.goalSlashCommand.title') -and $text -match 'id:`goal`,title:[^,]+,description:[^,]+,requiresEmptyComposer:!1,[^}]*enabled:[^,]+') -or
        ($text -match '(\w+)=[A-Za-z_$][\w$]*!==`cloud`&&!\w+,(\w+)=')) {
      $goalComposerTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($goalComposerTarget)) {
    Fail 'could not find goal composer gate in extracted assets'
  }

  $goalSlashTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'sourceMappingURL=slash-command-item|sourceMappingURL=local-remote-selection' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
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
    foreach ($candidate in (Invoke-RgList $RgPath 'installPlugin:async' $assetsDir)) {
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

  $computerUseMobileSetupTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'showComputerUseSetup' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('showComputerUseSetup')) {
      $computerUseMobileSetupTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($computerUseMobileSetupTarget)) {
    Fail 'could not find Computer Use mobile setup gate in extracted assets'
  }

  $codexMobileSetupFlowTarget = $null
  foreach ($candidate in (Invoke-RgList $RgPath 'ChatGPT auth is required to load remote control environments' $assetsDir)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('CODEX_MOBILE_SETUP_COMPLETED') -and $text.Contains('let W=U,G,J;')) {
      $codexMobileSetupFlowTarget = $candidate
      break
    }
    if ($text.Contains('CODEX_MOBILE_SETUP_COMPLETED') -and $text.Contains('let W=!1,G,J;')) {
      $codexMobileSetupFlowTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($codexMobileSetupFlowTarget)) {
    Fail 'could not find Codex mobile setup-flow auth fallback target in extracted assets'
  }

  $remoteControlMainTarget = $null
  $viteBuildDir = Join-Path $ExtractDir '.vite\build'
  if (Test-Path -LiteralPath $viteBuildDir -PathType Container) {
    foreach ($candidate in (Invoke-RgList $RgPath 'load_remote_control_unauthed' $viteBuildDir)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('remote_control_connections_state') -and $text.Contains('loadRemoteControlConnections')) {
        $remoteControlMainTarget = $candidate
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($remoteControlMainTarget)) {
    Fail 'could not find remote-control main-process auth fallback target in extracted ASAR'
  }

  Write-Log "fast-mode patch target: $fastModeTarget"
  Write-Log "plugin sidebar patch target: $pluginSidebarTarget"
  Write-Log "plugin skills-page patch target: $pluginSkillsTarget"
  Write-Log "plugin detail patch target: $pluginDetailTarget"
  Write-Log "goal composer patch target: $goalComposerTarget"
  Write-Log "goal slash-command patch target: $goalSlashTarget"
  Write-Log "computer-use availability patch target: $computerUseAvailabilityTarget"
  Write-Log "computer-use install-flow patch target: $computerUseInstallFlowTarget"
  Write-Log "computer-use mobile setup patch target: $computerUseMobileSetupTarget"
  Write-Log "codex mobile setup-flow auth fallback target: $codexMobileSetupFlowTarget"
  Write-Log "remote-control main auth fallback target: $remoteControlMainTarget"

  return [pscustomobject]@{
    FastMode = $fastModeTarget
    PluginSidebar = $pluginSidebarTarget
    PluginSkills = $pluginSkillsTarget
    PluginDetail = $pluginDetailTarget
    GoalComposer = $goalComposerTarget
    GoalSlash = $goalSlashTarget
    ComputerUseAvailability = $computerUseAvailabilityTarget
    ComputerUseInstallFlow = $computerUseInstallFlowTarget
    ComputerUseMobileSetup = $computerUseMobileSetupTarget
    CodexMobileSetupFlow = $codexMobileSetupFlowTarget
    RemoteControlMain = $remoteControlMainTarget
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
  $targets = Find-PatchTargets $rgPath $extractDir

  $fast = Invoke-NodePatcher $nodePath $patchers.Fast @($targets.FastMode)
  Write-Log "fast-mode patch result: $fast"
  $plugins = Invoke-NodePatcher $nodePath $patchers.Plugins @($targets.PluginSidebar, $targets.PluginSkills, $targets.PluginDetail)
  Write-Log "plugin patch result: $plugins"
  $goal = Invoke-NodePatcher $nodePath $patchers.Goal @($targets.GoalComposer, $targets.GoalSlash)
  Write-Log "goal patch result: $goal"
  $computerUse = Invoke-NodePatcher $nodePath $patchers.ComputerUse @($targets.ComputerUseAvailability, $targets.ComputerUseInstallFlow, $targets.ComputerUseMobileSetup, $targets.CodexMobileSetupFlow, $targets.RemoteControlMain)
  Write-Log "computer-use gate patch result: $computerUse"

  if ($DryRun) {
    Write-Log 'dry run: patch targets matched; no package was changed'
    return $false
  }

  if ($fast -eq 'already-patched' -and $plugins -eq 'already-patched' -and $goal -eq 'already-patched' -and $computerUse -eq 'already-patched') {
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
  Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\CurrentUser\TrustedPeople | Out-Null
  if (Test-IsAdministrator) {
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
    $exe = Join-Path $installed.InstallLocation 'app\Codex.exe'
    Write-Log "launching Codex: $exe"
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
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
  & robocopy.exe $Source $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
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

const port = Number(process.argv[2]);
const outPath = process.argv[3];

function write(obj) {
  fs.appendFileSync(outPath, JSON.stringify(obj) + "\n");
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
  write({ kind: "http", method: req.method, url: req.url });
  res.writeHead(404);
  res.end();
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
      if (frame.opcode === 1) write({ kind: "frame", text: frame.text });
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
    $baseUrlConfig = 'openai_base_url="http://127.0.0.1:' + $port + '/v1"'
    $wireTier = $null
    $codexJob = Start-Job -ScriptBlock {
      param([string]$CodexPath, [string]$BaseUrlConfig)
      & $CodexPath exec --json --skip-git-repo-check -c $BaseUrlConfig -c 'service_tier="fast"' -c 'model_reasoning_effort="low"' 'wire capture only' 2>&1 | Out-Null
    } -ArgumentList $codex, $baseUrlConfig

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
        if ($entry.kind -ne 'frame' -or -not $entry.text) {
          continue
        }
        $match = [regex]::Match([string]$entry.text, '"service_tier"\s*:\s*"([^"]+)"')
        if ($match.Success) {
          $wireTier = $match.Groups[1].Value
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
    Remove-DirectoryRobust -Path $workRoot -RequiredRoot $OutputRoot
  }

  Write-Log 'done'
} finally {
  if ($KeepWorkDir) {
    Write-Log "keeping workdir: $tempWork"
  } elseif (Test-Path -LiteralPath $tempWork) {
    Remove-DirectoryRobust -Path $tempWork -RequiredRoot $workRoot
  }
}
