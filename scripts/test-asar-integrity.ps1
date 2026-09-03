# Regression test for scripts\lib\asar-integrity.ps1.
#
# This test exists because a patched Codex MSIX that keeps a stale ASAR integrity hash installs
# cleanly and then dies at startup with:
#   FATAL:asar_util.cc Integrity check failed for asar archive (<embedded> vs <actual>)
# The original bug was a hard-coded Codex.exe launcher name: on 26.9xx the integrity table moved
# to ChatGPT.exe, the patcher found no table in Codex.exe, silently skipped the update, and
# shipped an unstartable package. Every assertion below guards one part of that failure mode.
#
# Everything runs against synthetic fixtures, so the test needs no installed Codex package and
# never touches one. Pass -TemporaryRoot to keep large files off the system drive.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-asar-integrity.ps1 -TemporaryRoot D:\tmp\asar-test

param(
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [switch]$CheckInstalledPackage
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$Message) {
  Write-Host "[asar-integrity-test] $Message"
}

# The shared library calls Fail for unrecoverable conditions; tag it so assertions can tell a
# library-raised failure apart from a test-harness bug.
function Fail([string]$Message) {
  throw "LIBFAIL: $Message"
}

function Assert-True {
  param([bool]$Condition, [string]$Because)
  if (-not $Condition) {
    throw "ASSERT FAILED: $Because"
  }
}

function Assert-LibraryFails {
  param([scriptblock]$Action, [string]$Because)
  try {
    & $Action | Out-Null
  } catch {
    if ([string]$_.Exception.Message -notlike 'LIBFAIL: *') {
      throw "ASSERT FAILED: $Because (expected a library Fail, got: $($_.Exception.Message))"
    }
    Write-Log "  expected failure: $([string]$_.Exception.Message -replace '^LIBFAIL: ', '')"
    return
  }
  throw "ASSERT FAILED: $Because (no failure was raised)"
}

. (Join-Path $PSScriptRoot 'lib\asar-integrity.ps1')

function New-TestAsar {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$HeaderJson,
    [string]$Payload = 'x'
  )
  # asar layout: UInt32 4, UInt32 headerSize+8, UInt32 headerSize+4, UInt32 headerSize,
  # then the JSON header, then file payloads. Electron hashes only the JSON header.
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($HeaderJson)
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  try {
    $bw.Write([UInt32]4)
    $bw.Write([UInt32]($headerBytes.Length + 8))
    $bw.Write([UInt32]($headerBytes.Length + 4))
    $bw.Write([UInt32]$headerBytes.Length)
    $bw.Write($headerBytes)
    $bw.Write([System.Text.Encoding]::UTF8.GetBytes($Payload))
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
  } finally {
    $bw.Dispose()
    $ms.Dispose()
  }
  return (Get-Sha256OfString $HeaderJson)
}

function Get-Sha256OfString {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return (Convert-BytesToHex $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))
  } finally {
    $sha.Dispose()
  }
}

function New-TestLauncherExe {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string[]]$IntegrityEntries = @(),
    [switch]$MentionAsarWithoutTable,
    [switch]$ReadOnly
  )
  # Only the ASCII text matters to the scanner, so a plain byte blob stands in for a PE file.
  # PADDINGX padding mirrors the real launcher, where the table sits in a fixed-size region.
  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add(("MZ" + ([string][char]0) * 16 + "fixture-launcher"))
  if ($MentionAsarWithoutTable) {
    $parts.Add('resources/app.asar loaded from app.asar bundle')
  }
  if ($IntegrityEntries.Count -gt 0) {
    $parts.Add('[' + ($IntegrityEntries -join ',') + ']')
    $parts.Add('PADDINGXPADDINGXPADDINGXPADDINGX')
  }
  $parts.Add(([string][char]0) * 8 + 'end-of-fixture')
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::ASCII.GetBytes(($parts -join '')))
  if ($ReadOnly) {
    (Get-Item -LiteralPath $Path -Force).IsReadOnly = $true
  }
}

function New-IntegrityEntry {
  param(
    [string]$RelativePath = 'resources\\app.asar',
    [string]$Algorithm = 'SHA256',
    [Parameter(Mandatory = $true)][string]$Value
  )
  return ('{"file":"' + $RelativePath + '","alg":"' + $Algorithm + '","value":"' + $Value + '"}')
}

function New-TestAppRoot {
  param([Parameter(Mandatory = $true)][string]$Name)
  $root = Join-Path $TemporaryRoot $Name
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
    Remove-Item -LiteralPath $root -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

New-Item -ItemType Directory -Force -Path $TemporaryRoot | Out-Null
$TemporaryRoot = (Resolve-Path -LiteralPath $TemporaryRoot).ProviderPath
Write-Log "temporary root: $TemporaryRoot"

Write-Log 'case 1: header hash covers the JSON header only, not the pickle size fields'
$root1 = New-TestAppRoot 'case1'
$json1 = '{"files":{"a.txt":{"size":1,"offset":"0"}}}'
$expected1 = New-TestAsar -Path (Join-Path $root1 'resources\app.asar') -HeaderJson $json1
$actual1 = Get-AsarHeaderSha256 (Join-Path $root1 'resources\app.asar')
Assert-True ($actual1 -eq $expected1) "header sha256 mismatch: expected $expected1 got $actual1"
Assert-True ($actual1.Length -eq 64) "header sha256 is not 64 hex chars: $actual1"

Write-Log 'case 2: host scan stays in the app root and never recurses into resources'
$root2 = New-TestAppRoot 'case2'
New-TestLauncherExe -Path (Join-Path $root2 'Launcher.exe')
New-TestLauncherExe -Path (Join-Path $root2 'resources\codex.exe')
$names2 = @(Get-AsarIntegrityHostCandidates $root2 | ForEach-Object { $_.Name })
Assert-True ($names2.Count -eq 1) "expected 1 candidate in the app root, got $($names2.Count): $($names2 -join ', ')"
Assert-True ($names2[0] -eq 'Launcher.exe') "unexpected candidate: $($names2[0])"

Write-Log 'case 3: the integrity host is found by content, not by a hard-coded launcher name'
# This is the exact regression: 26.9xx renamed the Electron launcher to ChatGPT.exe and the old
# patcher, which only looked at Codex.exe, shipped a package that failed Electron's check.
$root3 = New-TestAppRoot 'case3'
$hash3 = New-TestAsar -Path (Join-Path $root3 'resources\app.asar') -HeaderJson '{"files":{"b.txt":{"size":1,"offset":"0"}}}'
New-TestLauncherExe -Path (Join-Path $root3 'SomeFutureName.exe') -IntegrityEntries @(New-IntegrityEntry -Value $hash3)
# A CLI shim with neither a table nor an app.asar mention must be skipped without complaint.
New-TestLauncherExe -Path (Join-Path $root3 'Codex.exe')
$hosts3 = @(Test-AsarIntegrityTargets $root3)
Assert-True ($hosts3.Count -eq 1) "expected exactly 1 integrity host, got $($hosts3.Count)"
Assert-True ((Split-Path -Leaf $hosts3[0].ExePath) -eq 'SomeFutureName.exe') "wrong host: $($hosts3[0].ExePath)"
Assert-True ($hosts3[0].Records.Count -eq 1) "expected 1 record, got $($hosts3[0].Records.Count)"
Assert-True ($hosts3[0].Records[0].RelativePath -eq 'resources\app.asar') "wrong relative path: $($hosts3[0].Records[0].RelativePath)"
Assert-AsarIntegrityConsistent -ExePath $hosts3[0].ExePath -AppRoot $root3

Write-Log 'case 4: an unparsable table must fail loudly instead of being skipped'
# Silently skipping is what shipped the broken package, so this must stay a hard failure.
$root4 = New-TestAppRoot 'case4'
New-TestAsar -Path (Join-Path $root4 'resources\app.asar') -HeaderJson '{"files":{}}' | Out-Null
New-TestLauncherExe -Path (Join-Path $root4 'ChatGPT.exe') -MentionAsarWithoutTable
Assert-LibraryFails { Test-AsarIntegrityTargets $root4 } 'a launcher that mentions app.asar but has no parsable table must fail'

Write-Log 'case 5: an app root with no integrity table at all is skipped, not failed'
$root5 = New-TestAppRoot 'case5'
New-TestAsar -Path (Join-Path $root5 'resources\app.asar') -HeaderJson '{"files":{}}' | Out-Null
New-TestLauncherExe -Path (Join-Path $root5 'ChatGPT.exe')
$hosts5 = @(Test-AsarIntegrityTargets $root5)
Assert-True ($hosts5.Count -eq 0) "expected no integrity host, got $($hosts5.Count)"
Update-ElectronAsarIntegrity $root5

Write-Log 'case 6: a stale embedded hash is detected, repaired, and verified'
$root6 = New-TestAppRoot 'case6'
$stale6 = '0' * 64
New-TestLauncherExe -Path (Join-Path $root6 'ChatGPT.exe') -IntegrityEntries @(New-IntegrityEntry -Value $stale6)
$hash6 = New-TestAsar -Path (Join-Path $root6 'resources\app.asar') -HeaderJson '{"files":{"c.txt":{"size":1,"offset":"0"}}}'
Assert-True ($hash6 -ne $stale6) 'fixture hash accidentally equals the stale placeholder'
Assert-LibraryFails { Assert-AsarIntegrityConsistent -ExePath (Join-Path $root6 'ChatGPT.exe') -AppRoot $root6 } 'a stale embedded hash must be detected'
Update-ElectronAsarIntegrity $root6
Assert-AsarIntegrityConsistent -ExePath (Join-Path $root6 'ChatGPT.exe') -AppRoot $root6
$embedded6 = @(Get-AsarIntegrityRecords -ExePath (Join-Path $root6 'ChatGPT.exe') -AppRoot $root6).Records[0].Value
Assert-True ($embedded6 -eq $hash6) "embedded hash was not rewritten: $embedded6 vs $hash6"

Write-Log 'case 7: the repaired launcher keeps its original byte length'
# Equal-length hex replacement is what makes in-place patching safe; a length change would
# shift every PE offset after the table.
$len7 = (Get-Item -LiteralPath (Join-Path $root6 'ChatGPT.exe')).Length
Assert-True ($len7 -gt 0) 'repaired launcher is empty'
New-TestLauncherExe -Path (Join-Path $TemporaryRoot 'case7-reference.exe') -IntegrityEntries @(New-IntegrityEntry -Value $stale6)
$refLen7 = (Get-Item -LiteralPath (Join-Path $TemporaryRoot 'case7-reference.exe')).Length
Assert-True ($len7 -eq $refLen7) "launcher length changed during repair: $len7 vs $refLen7"

Write-Log 'case 8: repair works on a read-only launcher (robocopy /MIR preserves that attribute)'
$root8 = New-TestAppRoot 'case8'
New-TestLauncherExe -Path (Join-Path $root8 'ChatGPT.exe') -IntegrityEntries @(New-IntegrityEntry -Value ('1' * 64)) -ReadOnly
New-TestAsar -Path (Join-Path $root8 'resources\app.asar') -HeaderJson '{"files":{"d.txt":{"size":1,"offset":"0"}}}' | Out-Null
Assert-True ((Get-Item -LiteralPath (Join-Path $root8 'ChatGPT.exe') -Force).IsReadOnly) 'fixture launcher is not read-only'
Update-ElectronAsarIntegrity $root8
Assert-AsarIntegrityConsistent -ExePath (Join-Path $root8 'ChatGPT.exe') -AppRoot $root8

Write-Log 'case 9: a second run is idempotent and leaves the launcher untouched'
$before9 = (Get-Item -LiteralPath (Join-Path $root8 'ChatGPT.exe')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
Update-ElectronAsarIntegrity $root8
$after9 = (Get-Item -LiteralPath (Join-Path $root8 'ChatGPT.exe')).LastWriteTimeUtc
Assert-True ($before9 -eq $after9) "already-current launcher was rewritten: $before9 -> $after9"

Write-Log 'case 10: every record in a multi-archive table is updated'
$root10 = New-TestAppRoot 'case10'
$entries10 = @(
  (New-IntegrityEntry -RelativePath 'resources\\app.asar' -Value ('2' * 64)),
  (New-IntegrityEntry -RelativePath 'resources\\busy-bar.asar' -Value ('3' * 64))
)
New-TestLauncherExe -Path (Join-Path $root10 'ChatGPT.exe') -IntegrityEntries $entries10
$hashA10 = New-TestAsar -Path (Join-Path $root10 'resources\app.asar') -HeaderJson '{"files":{"e.txt":{"size":1,"offset":"0"}}}'
$hashB10 = New-TestAsar -Path (Join-Path $root10 'resources\busy-bar.asar') -HeaderJson '{"files":{"f.txt":{"size":1,"offset":"0"}}}'
Assert-True ($hashA10 -ne $hashB10) 'fixture archives accidentally share a header hash'
Update-ElectronAsarIntegrity $root10
Assert-AsarIntegrityConsistent -ExePath (Join-Path $root10 'ChatGPT.exe') -AppRoot $root10
$records10 = @(Get-AsarIntegrityRecords -ExePath (Join-Path $root10 'ChatGPT.exe') -AppRoot $root10).Records
Assert-True ($records10.Count -eq 2) "expected 2 records, got $($records10.Count)"

Write-Log 'case 11: an unsupported algorithm fails instead of being written blindly'
$root11 = New-TestAppRoot 'case11'
New-TestLauncherExe -Path (Join-Path $root11 'ChatGPT.exe') -IntegrityEntries @(New-IntegrityEntry -Algorithm 'SHA512' -Value ('4' * 64))
New-TestAsar -Path (Join-Path $root11 'resources\app.asar') -HeaderJson '{"files":{}}' | Out-Null
Assert-LibraryFails { Update-ElectronAsarIntegrity $root11 } 'a non-SHA256 algorithm must fail'

Write-Log 'case 12: a table entry pointing at a missing archive fails'
$root12 = New-TestAppRoot 'case12'
New-TestLauncherExe -Path (Join-Path $root12 'ChatGPT.exe') -IntegrityEntries @(New-IntegrityEntry -RelativePath 'resources\\gone.asar' -Value ('5' * 64))
Assert-LibraryFails { Update-ElectronAsarIntegrity $root12 } 'a table entry for a missing archive must fail'

Write-Log 'case 13: a forward-slash path in the table resolves to the same archive'
$root13 = New-TestAppRoot 'case13'
New-TestLauncherExe -Path (Join-Path $root13 'ChatGPT.exe') -IntegrityEntries @(New-IntegrityEntry -RelativePath 'resources/app.asar' -Value ('6' * 64))
New-TestAsar -Path (Join-Path $root13 'resources\app.asar') -HeaderJson '{"files":{"g.txt":{"size":1,"offset":"0"}}}' | Out-Null
Update-ElectronAsarIntegrity $root13
Assert-AsarIntegrityConsistent -ExePath (Join-Path $root13 'ChatGPT.exe') -AppRoot $root13

Write-Log 'case 14: repacking the archive invalidates the launcher until integrity is rerun'
$root14 = New-TestAppRoot 'case14'
$hash14 = New-TestAsar -Path (Join-Path $root14 'resources\app.asar') -HeaderJson '{"files":{"h.txt":{"size":1,"offset":"0"}}}'
New-TestLauncherExe -Path (Join-Path $root14 'ChatGPT.exe') -IntegrityEntries @(New-IntegrityEntry -Value $hash14)
Assert-AsarIntegrityConsistent -ExePath (Join-Path $root14 'ChatGPT.exe') -AppRoot $root14
New-TestAsar -Path (Join-Path $root14 'resources\app.asar') -HeaderJson '{"files":{"h.txt":{"size":2,"offset":"0"}}}' | Out-Null
Assert-LibraryFails { Assert-AsarIntegrityConsistent -ExePath (Join-Path $root14 'ChatGPT.exe') -AppRoot $root14 } 'a repacked archive must invalidate the embedded hash'
Update-ElectronAsarIntegrity $root14
Assert-AsarIntegrityConsistent -ExePath (Join-Path $root14 'ChatGPT.exe') -AppRoot $root14

if ($CheckInstalledPackage) {
  Write-Log 'case 15: the installed Codex package is self-consistent (read-only)'
  $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
  if (-not $pkg -or -not $pkg.InstallLocation) {
    Write-Log '  no installed OpenAI.Codex package found; skipping'
  } else {
    $installedApp = Join-Path $pkg.InstallLocation 'app'
    Write-Log "  package: $($pkg.PackageFullName)"
    $installedHosts = @(Test-AsarIntegrityTargets $installedApp)
    if ($installedHosts.Count -eq 0) {
      Write-Log '  package has no embedded integrity table; nothing to check'
    } else {
      foreach ($h in $installedHosts) {
        Assert-AsarIntegrityConsistent -ExePath $h.ExePath -AppRoot $installedApp
      }
    }
  }
}

Get-ChildItem -LiteralPath $TemporaryRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
  ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'ASAR integrity regression passed'
