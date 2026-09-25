param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\msix-payload.ps1')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$base = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\')
$root = Join-Path $base ('msix-payload-' + [guid]::NewGuid().ToString('N'))
if (-not $root.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'test path escaped temporary root' }
New-Item -ItemType Directory -Path $root -Force | Out-Null
function New-Fixture([string]$Name, [switch]$Corrupt, [switch]$Missing, [switch]$Extra, [switch]$Empty) {
  $path = Join-Path $root ($Name + '.msix')
  $bytes = [Text.Encoding]::UTF8.GetBytes(('a' * 65536) + 'end')
  if ($Empty) { $bytes = New-Object byte[] 0 }
  $sha = [Security.Cryptography.SHA256]::Create()
  $blocks = ''
  for ($offset = 0; $offset -lt $bytes.Length; $offset += 65536) {
    $length = [Math]::Min(65536, $bytes.Length - $offset)
    $hash = [Convert]::ToBase64String($sha.ComputeHash($bytes, $offset, $length))
    $blocks += '<Block Hash="' + $hash + '"/>'
  }
  $sha.Dispose()
  $xml = '<BlockMap xmlns="http://schemas.microsoft.com/appx/2010/blockmap" HashMethod="http://www.w3.org/2001/04/xmlenc#sha256"><File Name="app\@scope\file.bin" Size="' + $bytes.Length + '" LfhSize="0">' + $blocks + '</File></BlockMap>'
  if ($Corrupt) { $bytes[65536] = $bytes[65536] -bxor 1 }
  $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
  try {
    $entry = $zip.CreateEntry('AppxBlockMap.xml')
    $writer = [IO.StreamWriter]::new($entry.Open()); $writer.Write($xml); $writer.Dispose()
    if (-not $Missing) {
      $entry = $zip.CreateEntry('app/%40scope/file.bin')
      $s = $entry.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    }
    $null = $zip.CreateEntry('AppxMetadata/CodeIntegrity.cat')
    if ($Extra) { $null = $zip.CreateEntry('unmapped.bin') }
  } finally { $zip.Dispose() }
  return $path
}
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notlike $Pattern) { throw }
    return
  }
  throw "expected failure: $Pattern"
}
try {
  $valid = New-Fixture 'valid'
  $v = Test-MsixPayload $valid
  if ($v.Files -ne 1 -or $v.Blocks -ne 2) { throw 'valid fixture counts differ' }
  $v = Test-MsixPayload (New-Fixture 'empty' -Empty)
  if ($v.Files -ne 1 -or $v.Blocks -ne 0) { throw 'empty-file fixture counts differ' }
  $bad = New-Fixture 'corrupt' -Corrupt
  Assert-Fails { Test-MsixPayload $bad } '*block hash mismatch*block=1*'
  Assert-Fails { Test-MsixPayload (New-Fixture 'missing' -Missing) } '*payload is missing*'
  Assert-Fails { Test-MsixPayload (New-Fixture 'extra' -Extra) } '*unmapped MSIX payload*'

  # Exercise the actual installation function with deployment/process stubs.
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'), [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw 'patcher parse failed' }
  $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-PatchedPackage' }, $true)
  . ([scriptblock]::Create($fn.Extent.Text))
  $Launch = $false; $NoLaunch = $true
  function Write-Log([string]$Message) {}
  function Get-AppxPackage { [pscustomobject]@{ InstallLocation = $root; PackageFullName = 'test-existing-package' } }
  function Stop-CodexDesktopProcesses { $script:stops++ }
  function Remove-AppxPackage { throw 'unexpected package removal' }
  function Add-AppxPackage { param($Path, [switch]$ForceUpdateFromAnyVersion, $ErrorAction)
    $script:adds++
    if (-not $ForceUpdateFromAnyVersion) { throw 'in-place update flag missing' }
    if ($script:deploymentFails) { throw 'test deployment failed' }
  }
  $script:stops = 0; $script:adds = 0
  Assert-Fails { Install-PatchedPackage $bad 'test' } '*block hash mismatch*'
  if ($script:stops -ne 0 -or $script:adds -ne 0) { throw 'corrupt package interrupted existing app' }
  $script:deploymentFails = $true
  Assert-Fails { Install-PatchedPackage $valid 'test' } 'test deployment failed'
  if ($script:stops -ne 1 -or $script:adds -ne 1) { throw 'deployment failure path differs' }
  $script:deploymentFails = $false
  Install-PatchedPackage $valid 'test'
  if ($script:stops -ne 2 -or $script:adds -ne 2) { throw 'valid in-place deployment was not attempted' }
  Write-Output 'MSIX_PAYLOAD_TESTS_PASSED cases=8'
} finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
