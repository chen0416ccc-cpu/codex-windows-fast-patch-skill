[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('model probe 中文 ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$nodePath = (Get-Command node.exe -ErrorAction Stop).Source
$fixture = @'
const readline = require('node:readline');
const fs = require('node:fs');
readline.createInterface({ input: process.stdin }).on('line', line => {
  const request = JSON.parse(line);
  if (!request.id) return;
  const tier = fs.existsSync('deny-priority') ? [] : [{ id: 'priority' }];
  const result = request.method === 'initialize' ? {} : { data: [
    { id: 'fixture-default', isDefault: true, hidden: false, serviceTiers: tier },
    { id: 'fixture-fastest', hidden: false, serviceTiers: [{ id: 'ultrafast' }] }
  ] };
  process.stdout.write(JSON.stringify({ id: request.id, result }) + '\n');
});
'@
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'app-server'), $fixture, [Text.UTF8Encoding]::new($false))
$previousLocation = Get-Location
try {
  Set-Location -LiteralPath $fixtureRoot
  foreach ($scriptName in @('repatch-model-experience-recoverable.ps1', 'complete-model-experience-repair.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $scriptName), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Source script does not parse.' }
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ModelListFastTiers' }, $true)
    if (-not $function) { throw 'Model-list acceptance function is missing.' }
    Invoke-Expression $function.Extent.Text
    $OutputRoot = $fixtureRoot
    $StatePath = Join-Path $fixtureRoot 'checkpoint.state.json'
    function Write-Log { param([string]$Message) Write-Host $Message }
    $result = Test-ModelListFastTiers -CliPath $nodePath
    if ($result.model -ne 'fixture-default' -or @($result.serviceTiers) -notcontains 'priority') {
      throw "Model-list transport did not preserve JSON under $scriptName"
    }
    if (@($result.ultrafastModels) -notcontains 'fixture-fastest') { throw 'Advertised Ultrafast tier was lost.' }
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'deny-priority'), '')
    $denied = $false
    try { $null = Test-ModelListFastTiers -CliPath $nodePath } catch {
      if ($_.Exception.Message -notlike '*default model does not expose*') { throw }
      $denied = $true
    }
    [IO.File]::Delete((Join-Path $fixtureRoot 'deny-priority'))
    if (-not $denied) { throw 'A default model without priority passed acceptance.' }
    if (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter 'model-list-probe-*.cjs' -File).Count) {
      throw 'A temporary model probe leaked after acceptance.'
    }
    Write-Host "Model probe transport passed: $scriptName / PowerShell $($PSVersionTable.PSVersion)"
  }
} finally {
  Set-Location -LiteralPath $previousLocation.Path
}
