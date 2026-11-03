[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TemporaryRoot)

$ErrorActionPreference = 'Stop'
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}

$sourcePath = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'the production installer parses'
$script:fixtureScriptRoot = $PSScriptRoot
foreach ($name in @('Invoke-CuaRuntimeProxyRepair', 'Resolve-ExistingFileProviderPath', 'Get-CuaNodeEntryPath')) {
  $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Assert ($null -ne $function) "production function exists: $name"
  . ([scriptblock]::Create($function.Extent.Text.Replace('$PSScriptRoot', '$script:fixtureScriptRoot')))
}
function Get-CuaRuntimeSystemProxy { return $script:proxyUrl }
function Write-Log { param([string]$Message) $script:messages += $Message }

$root = Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('proxy ' + [char]0x4e2d + [char]0x6587 + ' space-' + [guid]::NewGuid().ToString('N'))
$bin = Join-Path $root 'bin'
$entry = Join-Path $bin 'node_modules\@oai\cua-repl\bin\cua-repl.mjs'
$fixtureCodexHome = Join-Path $root 'home'
$backupRoot = Join-Path $fixtureCodexHome 'backups\cua-runtime-proxy'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$patcher = Join-Path $PSScriptRoot 'patch-cua-runtime-proxy.cjs'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entry) | Out-Null
$inventory = [pscustomobject]@{ NodePath = $node; AllowedCuaBinRoots = @($bin) }
$manifestRoot = Join-Path $fixtureCodexHome 'plugins\cache\openai-bundled\unified-computer-use\fixture'
New-Item -ItemType Directory -Force -Path $manifestRoot | Out-Null
$preload = Join-Path $root 'policy.mjs'
[IO.File]::WriteAllText($preload, '', [Text.UTF8Encoding]::new($false))
$manifest = @{ mcpServers = @{ cua_repl = @{ command = $node; args = @('--import', ([uri]$preload).AbsoluteUri, $entry) } } }
# The active manifest must point at the fixture runtime's node path.
$manifest.mcpServers.cua_repl.command = Join-Path $bin 'node.exe'
[IO.File]::WriteAllText((Join-Path $manifestRoot '.mcp.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

$proxyServer = Join-Path $root 'proxy-fixture.cjs'
$portPath = Join-Path $root 'port.txt'
$modePath = Join-Path $root 'mode.txt'
$proxySource = @'
const fs = require('node:fs');
const http = require('node:http');
const [portPath, modePath] = process.argv.slice(2);
const server = http.createServer();
server.on('connect', (request, socket) => {
  if (request.url !== 'chatgpt.com:443') return socket.destroy();
  const status = fs.readFileSync(modePath, 'utf8').trim();
  socket.on('error', () => {});
  socket.end(`HTTP/1.1 ${status} Fixture\r\n\r\n`);
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portPath, String(server.address().port)));
setTimeout(() => process.exit(0), 120000).unref();
'@
[IO.File]::WriteAllText($proxyServer, $proxySource, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($modePath, '200')

$previousEncoding = $OutputEncoding
$previousConsoleEncoding = [Console]::OutputEncoding
$server = $null
try {
  $OutputEncoding = [Text.Encoding]::ASCII
  [Console]::OutputEncoding = [Text.Encoding]::ASCII
  $original = & $node -e 'process.stdout.write(require(process.argv[1]).STUB)' $patcher
  Assert ($LASTEXITCODE -eq 0 -and $original) 'the fixture uses the recognized original launcher'
  $originalText = ($original -join "`n") + "`n"
  [IO.File]::WriteAllText($entry, $originalText, [Text.UTF8Encoding]::new($false))
  $originalHash = (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
  $arguments = @($proxyServer, $portPath, $modePath) | ForEach-Object { '"' + $_ + '"' }
  $server = Start-Process -FilePath $node -ArgumentList $arguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $root 'proxy.stdout.log') -RedirectStandardError (Join-Path $root 'proxy.stderr.log')
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $portPath) -and [DateTime]::UtcNow -lt $deadline) {
    if ($server.HasExited) { throw 'The fixture proxy exited before listening.' }
    Start-Sleep -Milliseconds 50
  }
  Assert (Test-Path -LiteralPath $portPath) 'the loopback-only fixture proxy started'
  $script:proxyUrl = 'http://127.0.0.1:' + [IO.File]::ReadAllText($portPath)

  function Invoke-TransportCase([bool]$Verify, [string]$ExpectedState, [string]$ExpectedError) {
    $script:messages = @()
    $failure = $null
    try { Invoke-CuaRuntimeProxyRepair $inventory $fixtureCodexHome -VerifyOnly:$Verify } catch { $failure = $_.Exception.Message }
    Assert ($OutputEncoding.CodePage -eq [Text.Encoding]::ASCII.CodePage) 'the caller native stdin encoding is preserved'
    Assert ([Console]::OutputEncoding.CodePage -eq [Text.Encoding]::ASCII.CodePage) 'the caller native stdout encoding is restored'
    Assert ($ErrorActionPreference -eq 'Stop') 'the caller error preference is preserved'
    if ($ExpectedError) {
      Assert ($failure -like "*$ExpectedError*") "the production path rejects: $ExpectedError"
    } else {
      Assert ($null -eq $failure) "the production path succeeds: $ExpectedState; failure=$failure"
      $detail = $script:messages -join "`n"
      Assert ($detail.Contains("CUA runtime proxy: $ExpectedState entry=$entry")) 'the production Node operation succeeds for the complete Unicode path'
    }
  }

  Invoke-TransportCase $true '' 'missing or proxy URL drifted'
  Assert ((Get-FileHash -LiteralPath $entry).Hash -eq $originalHash) 'strict missing-patch failure does not change the launcher'
  Assert (-not (Test-Path -LiteralPath $backupRoot)) 'strict failure does not create a backup'
  Invoke-TransportCase $false 'patched' ''
  $patchedHash = (Get-FileHash -LiteralPath $entry).Hash
  Assert ($patchedHash -ne $originalHash) 'apply changes the isolated launcher'
  $backups = @(Get-ChildItem -LiteralPath $backupRoot -File)
  Assert ($backups.Count -eq 1 -and (Get-FileHash -LiteralPath $backups[0].FullName).Hash -eq $originalHash) 'the Unicode backup directory retains exact original bytes'
  Invoke-TransportCase $true 'already-patched' ''
  Invoke-TransportCase $false 'already-patched' ''
  Assert (@(Get-ChildItem -LiteralPath $backupRoot -File).Count -eq 1) 'repeat apply does not duplicate the backup'
  [IO.File]::WriteAllText($modePath, '407')
  Invoke-TransportCase $true '' 'HTTP CONNECT returned 407'
  Assert ((Get-FileHash -LiteralPath $entry).Hash -eq $patchedHash) 'failed CONNECT leaves the launcher unchanged'
  $script:proxyUrl = $null
  Invoke-TransportCase $true '' 'missing or proxy URL drifted'
  Invoke-TransportCase $false 'restored' ''
  Assert ((Get-FileHash -LiteralPath $entry).Hash -eq $originalHash) 'restore returns the exact original bytes'
  Invoke-TransportCase $true 'not-needed' ''
  $script:proxyUrl = 'http://127.0.0.1:' + [IO.File]::ReadAllText($portPath)
  [IO.File]::WriteAllText($entry, $originalText + '// unknown change', [Text.UTF8Encoding]::new($false))
  $unknownHash = (Get-FileHash -LiteralPath $entry).Hash
  Invoke-TransportCase $false '' 'unsupported cua-repl entry shape'
  Assert ((Get-FileHash -LiteralPath $entry).Hash -eq $unknownHash) 'unknown launcher content is never overwritten'
} finally {
  $OutputEncoding = $previousEncoding
  [Console]::OutputEncoding = $previousConsoleEncoding
  if ($server) {
    $server.Refresh()
    if (-not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
    $server.Dispose()
  }
}
Write-Output "CUA_PROXY_TRANSPORT_TESTS_PASSED checks=$script:checks PowerShell=$($PSVersionTable.PSVersion)"
