[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\toml-config.ps1')
$python = (Get-Command python -ErrorAction Stop).Source
& $python -c 'import tomllib'
if ($LASTEXITCODE -ne 0) { throw 'This regression requires Python with tomllib.' }
$base = [IO.Path]::GetFullPath($TemporaryRoot)
$root = Join-Path $base ('toml-writing-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$records = @()
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}
function Expect-Failure([scriptblock]$Action) {
  $message = $null
  try { & $Action } catch { $message = $_.Exception.Message }
  Assert ($message -like '*TOML syntax validation failed*') "Expected TOML rejection, got: $message"
}
$values = @(
  '',
  'C:\Users\normal\plugins',
  "C:\Users\h'p\plugins",
  "\\?\C:\Users\h'p\plugins",
  'C:\Users\$1-${header}-$$-$&\plugins',
  ('C:\Users\' + [char]0x4e2d + [char]0x6587 + "'\plugins"),
  'quotes " and backslash \ and apostrophe ''',
  ("line`nnext`r`n`tend" + [char]0 + [char]0x7f),
  'C:\trailing\'
)
function Write-Log([string]$Message) {}
Test-CodexTomlContent "sentinel = 'valid'"
Assert $true 'Native stdin rejected valid TOML; run this regression on Windows PowerShell 5.1 as well as pwsh.'
Expect-Failure { Test-CodexTomlContent "broken = [`n" }
try {
  foreach ($scriptName in @('repatch-codex-windows.ps1', 'install-computer-use-local.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $scriptName), [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "$scriptName parse failed"
    $keyWriter = if ($scriptName -eq 'repatch-codex-windows.ps1') { 'Set-TomlTableValue' } else { 'Set-TomlTableKey' }
    foreach ($name in @('Write-Utf8NoBom', 'Backup-ConfigBeforeOverwrite', 'Set-TomlTable', $keyWriter)) {
      $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
      Assert ($null -ne $definition) "Missing function $name"
      . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Write-Log([string]$Message) {}
    foreach ($writer in @('Set-TomlTable', $keyWriter)) {
      foreach ($value in $values) {
        foreach ($mode in @('new', 'append', 'replace', 'quoted', 'literal-quoted')) {
          $caseRoot = Join-Path $root ([guid]::NewGuid().ToString('N') + "-h'p")
          New-Item -ItemType Directory -Path $caseRoot | Out-Null
          $config = Join-Path $caseRoot 'config.toml'
          $before = "sentinel = 'unchanged'`r`n"
          if ($mode -eq 'append') { $before += "[marketplaces.fixture]`r`nretained = 'keep'`r`n" }
          if ($mode -eq 'replace') { $before += "[marketplaces.fixture]`r`nsource = 'old'`r`n" }
          if ($mode -eq 'quoted') { $before += "[`"marketplaces`" . `"fixture`"]`r`n`"source`" = 'old'`r`n" }
          if ($mode -eq 'literal-quoted') { $before += "['marketplaces'.'fixture']`r`n'source' = 'old'`r`n" }
          $before += "[unrelated]`r`nvalue = 'preserve'`r`n"
          Write-Utf8NoBom $config $before
          $script:ConfigBackupBeforeOverwrite = @{}
          $options = @{ ConfigPath = $config; Header = '[marketplaces.fixture]' }
          if ($writer -eq 'Set-TomlTable') {
            $options.Values = @{ source = $value; enabled = $true; disabled = $false }
          } else {
            $options.Key = 'source'; $options.Value = $value
          }
          & $writer @options
          $first = [IO.File]::ReadAllText($config)
          & $writer @options
          Assert ([IO.File]::ReadAllText($config) -ceq $first) "$writer is not idempotent ($mode)"
          $backups = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'backups\config') -File)
          Assert ($backups.Count -eq 1) 'Expected exactly one pre-write backup'
          Assert ([IO.File]::ReadAllText($backups[0].FullName) -ceq $before) 'Original backup changed'
          $records += @{ path = $config; expected = [string]$value; table = ($writer -eq 'Set-TomlTable'); retained = ($mode -eq 'append' -and $writer -ne 'Set-TomlTable') }
        }
      }
      # A bad unrelated table must stop the write, not corrupt the live file first.
      $badConfig = Join-Path $root ([guid]::NewGuid().ToString('N') + '.toml')
      Write-Utf8NoBom $badConfig "broken = [`n"
      $options = @{ ConfigPath = $badConfig; Header = '[marketplaces.fixture]' }
      if ($writer -eq 'Set-TomlTable') { $options.Values = @{ source = "C:\Users\h'p" } }
      else { $options.Key = 'source'; $options.Value = "C:\Users\h'p" }
      Expect-Failure { & $writer @options }
      Assert ([IO.File]::ReadAllText($badConfig) -ceq "broken = [`n") 'Invalid candidate overwrote the original config'
      Assert (-not $script:ConfigBackupBeforeOverwrite.ContainsKey($badConfig)) 'Invalid candidate reached the backup/write stage'
    }
  }
  $oracle = @'
import json, pathlib, sys, tomllib
records = json.loads(sys.stdin.buffer.read().decode('utf-8-sig'))
for r in records:
    raw = pathlib.Path(r['path']).read_bytes()
    assert not raw.startswith(b'\xef\xbb\xbf'), r['path']
    doc = tomllib.loads(raw.decode('utf-8'))
    assert doc['sentinel'] == 'unchanged' and doc['unrelated']['value'] == 'preserve', r
    entry = doc['marketplaces']['fixture']
    assert entry['source'] == r['expected'], r
    if r['table']:
        assert entry['enabled'] is True and entry['disabled'] is False, r
    if r['retained']:
        assert entry['retained'] == 'keep', r
print('TOML_ROUND_TRIP_PASSED cases=' + str(len(records)))
'@
  $oldEncoding = $OutputEncoding
  try {
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    ConvertTo-Json -InputObject $records -Depth 5 -Compress | & $python -c $oracle
    Assert ($LASTEXITCODE -eq 0) 'Independent TOML round-trip oracle failed'
  } finally { $OutputEncoding = $oldEncoding }
  # Missing parser tooling is not a TOML syntax error.
  & {
    function Get-Command { return $null }
    Test-CodexTomlContent "source = 'valid'"
  }
  Write-Output "TOML_CONFIG_WRITING_PASSED checks=$checks cases=$($records.Count)"
} finally {
  $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
  if (-not $resolved.StartsWith($base.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup root' }
  if (@(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Refusing cleanup through a reparse point' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
