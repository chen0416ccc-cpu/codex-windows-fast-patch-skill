[CmdletBinding()]
param(
  [string]$HelperTransportPath
)

$ErrorActionPreference = 'Stop'
$ExpectedOriginalHash = '6423BA834F18139D55CDAC2290C91CD9B24B568332B07CDDD2A7EDA043702B7C'
$ExpectedPatchedHash = '3600AC240CD6CB7029F1E489DF990CAE22D72177350B8084412DF1F3FA5BB60A'
$PatchMarker = 'computer_use_node_repl_request_context_patch'
$Patcher = Join-Path $PSScriptRoot 'patch-computer-use-node-repl-context.ps1'

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )
  if ([string]$Actual -cne [string]$Expected) {
    throw "$Message / expected=$Expected actual=$Actual"
  }
}

function Get-Status {
  param(
    [string]$Path,
    [string]$CodexHome
  )
  $json = @(& $Patcher -HelperTransportPath $Path -CodexHome $CodexHome -Json) | Select-Object -Last 1
  return ([string]$json) | ConvertFrom-Json
}

function Resolve-OriginalHelperTransport {
  if (-not [string]::IsNullOrWhiteSpace($HelperTransportPath)) {
    return [IO.Path]::GetFullPath($HelperTransportPath)
  }

  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if ($package) {
    $packagePath = Join-Path $package.InstallLocation 'app\resources\cua_node\bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
    if ((Test-Path -LiteralPath $packagePath -PathType Leaf) -and
        (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -eq $ExpectedOriginalHash) {
      return $packagePath
    }
  }

  $backupRoot = Join-Path $env:USERPROFILE '.codex\backups\computer-use-node-repl-context'
  if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    $backup = Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'helper_transport.js.original' -File -ErrorAction SilentlyContinue |
      Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $ExpectedOriginalHash } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($backup) {
      return $backup.FullName
    }
  }

  throw 'the exact @oai/sky 0.6.2 original helper transport is unavailable for this regression test'
}

if (-not (Test-Path -LiteralPath $Patcher -PathType Leaf)) {
  throw "patcher is missing: $Patcher"
}

$sourceTransport = Resolve-OriginalHelperTransport
Assert-Equal (Get-FileHash -LiteralPath $sourceTransport -Algorithm SHA256).Hash $ExpectedOriginalHash 'unexpected original helper transport hash'

$tempBase = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($env:TEMP)) { [IO.Path]::GetTempPath() } else { $env:TEMP }))
$testRoot = Join-Path $tempBase ('codex-cua-node-repl-context-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($tempBase.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "test root is outside TEMP: $resolvedTestRoot"
}

try {
  $skyRoot = Join-Path $resolvedTestRoot 'bin\node_modules\@oai\sky'
  $transportPath = Join-Path $skyRoot 'dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
  $codexHome = Join-Path $resolvedTestRoot 'codex-home'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $transportPath) | Out-Null
  Copy-Item -LiteralPath $sourceTransport -Destination $transportPath -Force

  $distNeedle = [IO.Path]::DirectorySeparatorChar + 'dist' + [IO.Path]::DirectorySeparatorChar
  $distIndex = $sourceTransport.IndexOf($distNeedle, [StringComparison]::OrdinalIgnoreCase)
  if ($distIndex -lt 0) {
    throw "source helper transport is not under an @oai/sky dist directory: $sourceTransport"
  }
  $sourceSkyRoot = $sourceTransport.Substring(0, $distIndex)
  $sourcePackagePath = Join-Path $sourceSkyRoot 'package.json'
  if (-not (Test-Path -LiteralPath $sourcePackagePath -PathType Leaf)) {
    throw "source @oai/sky package.json is missing: $sourcePackagePath"
  }
  Copy-Item -LiteralPath $sourcePackagePath -Destination (Join-Path $skyRoot 'package.json') -Force

  $before = Get-Status $transportPath $codexHome
  Assert-Equal $before.State 'original-patchable' 'original state mismatch'
  Assert-Equal $before.CandidateSha256 $ExpectedPatchedHash 'candidate hash mismatch'

  & $Patcher -HelperTransportPath $transportPath -CodexHome $codexHome -Install
  $after = Get-Status $transportPath $codexHome
  Assert-Equal $after.State 'patched' 'patched state mismatch'
  Assert-Equal $after.Sha256 $ExpectedPatchedHash 'patched hash mismatch'
  Assert-Equal $after.BackupSha256 $ExpectedOriginalHash 'original backup hash mismatch'

  $patchedContent = [IO.File]::ReadAllText($transportPath)
  Assert-Equal $patchedContent.Contains($PatchMarker) $true 'patch marker is missing'
  Assert-Equal $patchedContent.Contains('runInRequestContext:ComputerUseAsyncLocalStorage.snapshot()') $true 'request context snapshot is missing'
  Assert-Equal $patchedContent.Contains('n.runInRequestContext((()=>e(this,f,"m",T).call(this,n,s)))') $true 'approval callback context restore is missing'

  $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $node) {
    throw 'node.exe is required for the helper transport syntax and AsyncLocalStorage regression checks'
  }
  & $node.Source --check $transportPath
  if ($LASTEXITCODE -ne 0) {
    throw 'node --check failed for the patched helper transport'
  }

  $harnessPath = Join-Path $resolvedTestRoot 'async-context-regression.mjs'
  $harness = @'
import { AsyncLocalStorage } from "node:async_hooks";

const storage = new AsyncLocalStorage();
let activeExecId = "capture";
const requireCurrentExec = () => {
  const state = storage.getStore();
  if (state?.id !== activeExecId) {
    throw new Error("node_repl exec context not found");
  }
  return "accept";
};

let runInRequestContext;
storage.run({ id: "capture" }, () => {
  runInRequestContext = AsyncLocalStorage.snapshot();
});

let staleError = null;
storage.run({ id: "list" }, () => {
  try {
    requireCurrentExec();
  } catch (error) {
    staleError = String(error);
  }
});
if (staleError !== "Error: node_repl exec context not found") {
  throw new Error(`stale callback did not reproduce the failure: ${staleError}`);
}

let restoredResult;
storage.run({ id: "list" }, () => {
  restoredResult = runInRequestContext(() => requireCurrentExec());
});
if (restoredResult !== "accept") {
  throw new Error(`request context was not restored: ${restoredResult}`);
}
console.log("ASYNC_CONTEXT_REGRESSION_OK");
'@
  [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($false))
  & $node.Source $harnessPath
  if ($LASTEXITCODE -ne 0) {
    throw 'AsyncLocalStorage request-context regression harness failed'
  }

  & $Patcher -HelperTransportPath $transportPath -CodexHome $codexHome -Rollback
  Assert-Equal (Get-FileHash -LiteralPath $transportPath -Algorithm SHA256).Hash $ExpectedOriginalHash 'rollback hash mismatch'

  [IO.File]::AppendAllText($transportPath, "`n", [Text.UTF8Encoding]::new($false))
  $unknown = Get-Status $transportPath $codexHome
  Assert-Equal $unknown.State 'unsupported' 'unknown hash state mismatch'
  $unknownRejected = $false
  try {
    & $Patcher -HelperTransportPath $transportPath -CodexHome $codexHome -Install
  } catch {
    $unknownRejected = $_.Exception.Message -like 'unsupported helper transport SHA-256:*'
  }
  Assert-Equal $unknownRejected $true 'unknown helper transport hash was not rejected'

  Write-Output 'ALL_TESTS_PASSED'
} finally {
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
