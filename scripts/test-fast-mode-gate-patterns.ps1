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
      $node.Value.Contains('const currentManagerCachedAsyncOriginalRe =') -and
      $node.Value.Contains('fast-mode-patch-target-not-found')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Fast Mode patcher was not found in the patch script'
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Fast Mode gate regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('fast-mode-gates-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchFastMode.cjs'
[System.IO.File]::WriteAllText(
  $patcherPath,
  $patcherAst.Value,
  [System.Text.UTF8Encoding]::new($false)
)

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

$positiveFixtures = @(
  [pscustomobject]@{
    Name = 'cached-host-id-requirements'
    Source = 'async function qUr(e,t){let n=await WUr(e,t);if(n!==`chatgpt`)return!1;let r=await P2t(t,{priority:`critical`});return e.query.setData(ix,{authMethod:n,hostId:t},r),r.requirements?.featureRequirements?.fast_mode!==!1}'
  },
  [pscustomobject]@{
    Name = 'codex-26-814-manager-requirements'
    Source = 'async function qUr(e,t){let n=await WUr(e,t);if(n!==`chatgpt`)return!1;let r=await P2t(e,t,{priority:`critical`});return e.query.setData(ix,{authMethod:n,hostId:t},r),r.requirements?.featureRequirements?.fast_mode!==!1}'
  }
)

$hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
$previousNativePreference = $null
if ($hasNativePreference) {
  $previousNativePreference = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
}
try {
  foreach ($fixture in $positiveFixtures) {
    $result = Invoke-PatcherFixture -Name $fixture.Name -Source $fixture.Source -ExpectedExitCode 0
    if ($result.Output -cne 'patched') {
      throw "$($fixture.Name) did not report patched: $($result.Output)"
    }

    $patched = [System.IO.File]::ReadAllText($result.AssetPath)
    if ($patched.Contains('if(n!==`chatgpt`)return!1')) {
      throw "$($fixture.Name) retained the ChatGPT-only Fast Mode gate"
    }
    $syntaxOutput = @(& $node.Source --check $result.AssetPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "$($fixture.Name) produced invalid JavaScript: $($syntaxOutput -join ' | ')"
    }

    $secondOutput = @(& $node.Source $patcherPath $result.AssetPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
      throw "$($fixture.Name) was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
    }
  }

  $negativeSource = 'const unrelated={fast_mode:false};const always=()=>!0;'
  $negative = Invoke-PatcherFixture -Name 'unrelated-fast-mode' -Source $negativeSource -ExpectedExitCode 2
  if ($negative.Output -cne 'fast-mode-patch-target-not-found') {
    throw "unrelated Fast Mode fixture failed for the wrong reason: $($negative.Output)"
  }
  if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
    throw 'unrelated Fast Mode fixture was modified'
  }
} finally {
  if ($hasNativePreference) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
  }
}

Write-Output "Fast Mode gate regression passed: $fixtureRoot"
