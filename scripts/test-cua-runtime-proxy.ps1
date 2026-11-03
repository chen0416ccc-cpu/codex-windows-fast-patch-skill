$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
foreach ($name in @('Get-CuaRuntimeSystemProxy', 'Get-CuaNodeEntryPath', 'Resolve-ExistingFileProviderPath')) {
  $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  . ([scriptblock]::Create($function.Extent.Text))
}
function Get-ItemProperty {
  param($LiteralPath, $ErrorAction)
  if ($LiteralPath.EndsWith('Connections')) { return $script:connections }
  return $script:settings
}
function Assert-Equal($actual, $expected) { if ($actual -ne $expected) { throw "Expected '$expected', got '$actual'" } }
function Assert-Throws([scriptblock]$action) { $threw = $false; try { & $action } catch { $threw = $true }; if (-not $threw) { throw 'Expected rejection' } }
$script:connections = @{ DefaultConnectionSettings = [byte[]](0,0,0,0,0,0,0,0,1) }
$script:settings = @{ ProxyEnable = 0; AutoConfigURL = 'http://unused/pac' }
Assert-Equal (Get-CuaRuntimeSystemProxy) $null
$script:connections.DefaultConnectionSettings[8] = 5
Assert-Throws { Get-CuaRuntimeSystemProxy }
$script:settings = @{ ProxyEnable = 1; ProxyServer = '127.0.0.1:8080' }
Assert-Equal (Get-CuaRuntimeSystemProxy) 'http://127.0.0.1:8080'
$script:settings.ProxyServer = 'http=localhost:80;https=[::1]:8080;socks=localhost:1080'
Assert-Equal (Get-CuaRuntimeSystemProxy) 'http://[::1]:8080'
$script:settings.ProxyServer = 'http=a:80;http=b:80'
Assert-Throws { Get-CuaRuntimeSystemProxy }
$script:settings.ProxyServer = ''
Assert-Throws { Get-CuaRuntimeSystemProxy }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('cua-proxy-args-' + [guid]::NewGuid().ToString('N'))
try {
  $null = New-Item -ItemType Directory -Path $temporary
  $entry = Join-Path $temporary 'cua-repl.mjs'; $preload = Join-Path $temporary 'policy.mjs'
  Set-Content -LiteralPath $entry -Value ''; Set-Content -LiteralPath $preload -Value ''
  Assert-Equal (Get-CuaNodeEntryPath @('--import', ([uri]$preload).AbsoluteUri, $entry)) $entry
  Assert-Equal (Get-CuaNodeEntryPath @($entry)) $entry
  Assert-Throws { Get-CuaNodeEntryPath @('--import') }
  Assert-Throws { Get-CuaNodeEntryPath @('--import', (Join-Path $temporary 'absent'), $entry) }
  Assert-Throws { Get-CuaNodeEntryPath @('--eval', 'x', $entry) }
  Assert-Throws { Get-CuaNodeEntryPath @($entry, $entry) }
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force } }
Write-Host 'PASS: Windows proxy selection, stale/enabled PAC and Node preload entry parsing'
