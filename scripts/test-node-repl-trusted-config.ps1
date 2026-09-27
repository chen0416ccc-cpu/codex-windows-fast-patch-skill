param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Get-NodeReplConfiguredTrustedRoots'
}, $false)
if (-not $function) { throw 'Production config reader is missing' }
Invoke-Expression $function.Extent.Text
$root = Join-Path $TemporaryRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$path = Join-Path $root 'config.toml'
$expected = @((Join-Path $root 'fixture-marketplace'), (Join-Path $root 'fixture-extra'))
$joined = $expected -join ';'
$basicValue = ConvertTo-Json -InputObject $joined -Compress
$cases = @(
  "[mcp_servers.node_repl.env]`nNODE_REPL_TRUSTED_CODE_PATHS = '$joined'`n",
  "[mcp_servers.node_repl.env]`nNODE_REPL_TRUSTED_CODE_PATHS = $basicValue`n",
  ("[mcp_servers.other.env]`nNODE_REPL_TRUSTED_CODE_PATHS = 'unrelated'`n[mcp_servers.node_repl.env]`nNODE_REPL_TRUSTED_CODE_PATHS = " + $basicValue.Replace('fixture','fixt\u0075re') + "`n")
)
$checks = 0
foreach ($body in $cases) {
  [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($false))
  $actual = @(Get-NodeReplConfiguredTrustedRoots $path)
  if (($actual -join '|') -cne ($expected -join '|')) {
    throw "TOML trusted paths were not decoded: $($actual -join '|')"
  }
  $checks++
}
[IO.File]::WriteAllText($path, "[mcp_servers.other.env]`nNODE_REPL_TRUSTED_CODE_PATHS = 'unrelated'`n", [Text.UTF8Encoding]::new($false))
$caught = $false
try { Get-NodeReplConfiguredTrustedRoots $path | Out-Null } catch { $caught = $true }
if (-not $caught) { throw 'A different MCP table was accepted as node_repl config' }
$checks++
Write-Output "TRUSTED_CONFIG_TESTS_PASSED checks=$checks"
