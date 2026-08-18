[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $scriptPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "patch script did not parse: $($parseErrors[0].Message)"
}

$patcherAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains("const marker = 'CODEX_NODE_REPL_TRUSTED_PATHS_V1';") -and
      $node.Value.Contains('node-repl-trusted-paths-target-not-found')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Node REPL trusted-paths patcher was not found in the patch script'
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Node REPL trusted-paths regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('node-repl-trusted-paths-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchNodeReplTrustedPaths.cjs'
[System.IO.File]::WriteAllText($patcherPath, $patcherAst.Value, [System.Text.UTF8Encoding]::new($false))

function Invoke-PatcherFixture {
  param(
    [string]$Name,
    [string]$Source,
    [int]$ExpectedExitCode
  )

  $assetPath = Join-Path $fixtureRoot ($Name + '.js')
  [System.IO.File]::WriteAllText($assetPath, $Source, [System.Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $node.Source $patcherPath $assetPath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Name patcher exit mismatch: expected=$ExpectedExitCode actual=$exitCode output=$($output -join ' | ')"
  }
  return [pscustomobject]@{
    AssetPath = $assetPath
    Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  }
}

$currentSource = 'var Be=`NODE_REPL_NODE_MODULE_DIRS`,Ke=`NODE_REPL_TRUSTED_CODE_PATHS`;function Je({codexHome:t,nodeModuleDirs:i=``,platform:s}){let f={[Be]:i,[Ke]:Ye([t,i],s),CODEX_HOME:t};return f}function Ye(e,t){let n=t===`win32`?`;`:`:`;return e.filter(e=>e.length>0).join(n)}'
$semanticPatchedSource = 'var Be=`NODE_REPL_NODE_MODULE_DIRS`,Ke=`NODE_REPL_TRUSTED_CODE_PATHS`;function Je({codexHome:t,nodeModuleDirs:i=``,platform:s}){let f={[Be]:i,[Ke]:Ye([t,i,process.env[Ke]??``],s),CODEX_HOME:t};return f}function Ye(e,t){let n=t===`win32`?`;`:`:`;return e.filter(e=>e.length>0).join(n)}'
$negativeSource = 'var Be=`NODE_REPL_NODE_MODULE_DIRS`,Ke=`NODE_REPL_TRUSTED_CODE_PATHS`;const unrelated={trusted:!0};'

$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
$previousNativePreference = $null
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  $result = Invoke-PatcherFixture -Name 'codex-26-814-main' -Source $currentSource -ExpectedExitCode 0
  if ($result.Output -cne 'patched') {
    throw "current Node REPL fixture did not report patched: $($result.Output)"
  }
  $patched = [System.IO.File]::ReadAllText($result.AssetPath)
  if (-not $patched.Contains('process.env[Ke]??``')) {
    throw 'patched Node REPL fixture does not append the parent trusted-code-path environment value'
  }
  if (-not $patched.Contains('CODEX_NODE_REPL_TRUSTED_PATHS_V1')) {
    throw 'patched Node REPL fixture is missing its marker'
  }
  $syntaxOutput = @(& $node.Source --check $result.AssetPath 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "patched Node REPL fixture produced invalid JavaScript: $($syntaxOutput -join ' | ')"
  }

  $secondOutput = @(& $node.Source $patcherPath $result.AssetPath 2>&1)
  if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
    throw "Node REPL trusted-path patch was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
  }

  $semantic = Invoke-PatcherFixture -Name 'semantic-already-patched' -Source $semanticPatchedSource -ExpectedExitCode 0
  if ($semantic.Output -cne 'already-patched') {
    throw "semantic already-patched fixture was not recognized: $($semantic.Output)"
  }
  if ([System.IO.File]::ReadAllText($semantic.AssetPath) -cne $semanticPatchedSource) {
    throw 'semantic already-patched fixture was unexpectedly modified'
  }

  $negative = Invoke-PatcherFixture -Name 'unrelated-trusted-path' -Source $negativeSource -ExpectedExitCode 2
  if ($negative.Output -cne 'node-repl-trusted-paths-target-not-found') {
    throw "unrelated Node REPL fixture failed for the wrong reason: $($negative.Output)"
  }
  if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
    throw 'unrelated Node REPL fixture was modified'
  }
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "Node REPL trusted-paths regression passed: $fixtureRoot"
