# Shared Electron ASAR integrity helpers for the Codex Windows MSIX patchers.
#
# Electron validates resources\app.asar at startup against a SHA-256 table embedded in the
# launcher executable. Repacking app.asar without rewriting that table produces a package
# that installs cleanly and then dies immediately with:
#
#   FATAL:asar_util.cc Integrity check failed for asar archive (<embedded> vs <actual>)
#
# The launcher file name is build-dependent: older Codex builds shipped Codex.exe, 26.9xx
# ships ChatGPT.exe (with Codex.exe kept as a thin CLI shim that has no integrity table).
# Never hard-code the name; scan the app root instead, and fail loudly when a table exists
# but cannot be parsed, because silently skipping the update ships a package that cannot start.
#
# Dot-source this file from a patcher that already defines Write-Log and Fail:
#   . (Join-Path $PSScriptRoot 'lib\asar-integrity.ps1')

$script:AsarIntegrityEntryPattern = '\{"file":"(?<file>[^"]{1,240}?\.asar)","alg":"(?<alg>[A-Za-z0-9]{1,16})","value":"(?<value>[0-9a-fA-F]{40,128})"\}'

function Convert-BytesToHex {
  param([byte[]]$Bytes)
  return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-AsarHeaderSha256 {
  param([string]$AsarPath)
  $fs = [System.IO.File]::Open($AsarPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $pickleHeader = New-Object byte[] 16
    if ($fs.Read($pickleHeader, 0, 16) -ne 16) {
      Fail 'could not read asar pickle header'
    }
    # Electron hashes the ASAR JSON header, not the outer pickle-size fields.
    $headerSize = [BitConverter]::ToUInt32($pickleHeader, 12)
    if ($headerSize -le 0 -or $headerSize -gt ($fs.Length - 16)) {
      Fail "invalid asar JSON header size: $headerSize"
    }
    $headerBytes = New-Object byte[] $headerSize
    if ($fs.Read($headerBytes, 0, [int]$headerSize) -ne [int]$headerSize) {
      Fail 'could not read asar header bytes'
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      return (Convert-BytesToHex $sha.ComputeHash($headerBytes))
    } finally {
      $sha.Dispose()
    }
  } finally {
    $fs.Dispose()
  }
}

function Get-AsarIntegrityHostCandidates {
  param([string]$AppRoot)
  # The launcher that carries the integrity table lives directly in the app root. Nested
  # directories are skipped on purpose: resources\codex.exe is a ~300 MB CLI binary that
  # never hosts the table and is expensive to read into memory.
  return @(Get-ChildItem -LiteralPath $AppRoot -Filter '*.exe' -Force -File -ErrorAction SilentlyContinue |
    Sort-Object -Property Name)
}

function Get-AsarIntegrityRecords {
  param(
    [string]$ExePath,
    [string]$AppRoot
  )
  $bytes = [System.IO.File]::ReadAllBytes($ExePath)
  # ASCII.GetString maps every byte to exactly one char, so string indexes are byte offsets.
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  $records = @()
  foreach ($m in [regex]::Matches($text, $script:AsarIntegrityEntryPattern)) {
    $relative = $m.Groups['file'].Value -replace '\\\\', '\' -replace '/', '\'
    $records += [pscustomobject]@{
      RelativePath = $relative
      AsarPath     = (Join-Path $AppRoot $relative)
      Algorithm    = $m.Groups['alg'].Value
      Value        = $m.Groups['value'].Value
      ValueOffset  = $m.Groups['value'].Index
      ValueLength  = $m.Groups['value'].Length
    }
  }
  return [pscustomobject]@{
    ExePath      = $ExePath
    Bytes        = $bytes
    MentionsAsar = $text.Contains('app.asar')
    Records      = $records
  }
}

function Test-AsarIntegrityTargets {
  param([string]$AppRoot)
  $hosts = @()
  foreach ($exe in (Get-AsarIntegrityHostCandidates $AppRoot)) {
    $scan = $null
    try {
      $scan = Get-AsarIntegrityRecords -ExePath $exe.FullName -AppRoot $AppRoot
    } catch {
      Write-Log "warning: could not scan for ASAR integrity table in $($exe.Name): $($_.Exception.Message)"
      continue
    }
    if ($scan.Records.Count -gt 0) {
      $summary = (($scan.Records | ForEach-Object { "$($_.RelativePath)=$($_.Algorithm)" }) -join ', ')
      Write-Log "ASAR integrity host: $($exe.Name) entries=$($scan.Records.Count) [$summary]"
      $hosts += $scan
    } elseif ($scan.MentionsAsar) {
      Fail "ASAR integrity table format not recognized in $($exe.Name); the executable references app.asar but no {file,alg,value} record was found. Update the patcher before repacking, otherwise the installed app will fail Electron's integrity check at startup."
    }
  }
  return $hosts
}

function Update-ElectronAsarIntegrity {
  param([string]$AppRoot)
  # Wrap in @() because PowerShell unrolls a single-element array on return.
  $hosts = @(Test-AsarIntegrityTargets $AppRoot)
  if ($hosts.Count -eq 0) {
    Write-Log 'no embedded ASAR integrity table found in any app-root executable; skipping integrity update'
    return
  }
  foreach ($scan in $hosts) {
    $exeName = Split-Path -Leaf $scan.ExePath
    $bytes = $scan.Bytes
    $changed = 0
    foreach ($record in $scan.Records) {
      if ($record.Algorithm -ne 'SHA256') {
        Fail "unsupported ASAR integrity algorithm '$($record.Algorithm)' for $($record.RelativePath) in $exeName; update the patcher before repacking"
      }
      if (-not (Test-Path -LiteralPath $record.AsarPath -PathType Leaf)) {
        Fail "ASAR integrity table in $exeName references a missing archive: $($record.AsarPath)"
      }
      $actual = Get-AsarHeaderSha256 $record.AsarPath
      if ($actual.Length -ne $record.ValueLength) {
        Fail "computed hash length $($actual.Length) does not match embedded length $($record.ValueLength) for $($record.RelativePath) in $exeName"
      }
      if ($actual -eq $record.Value) {
        Write-Log "asar integrity already current in ${exeName}: $($record.RelativePath) = $actual"
        continue
      }
      $newBytes = [System.Text.Encoding]::ASCII.GetBytes($actual)
      [Array]::Copy($newBytes, 0, $bytes, $record.ValueOffset, $newBytes.Length)
      Write-Log "updated asar integrity in ${exeName}: $($record.RelativePath) $($record.Value) -> $actual"
      $changed++
    }
    if ($changed -gt 0) {
      $item = Get-Item -LiteralPath $scan.ExePath -Force
      if ($item.IsReadOnly) {
        $item.IsReadOnly = $false
      }
      [System.IO.File]::WriteAllBytes($scan.ExePath, $bytes)
    }
    Assert-AsarIntegrityConsistent -ExePath $scan.ExePath -AppRoot $AppRoot
  }
}

function Assert-AsarIntegrityConsistent {
  param(
    [string]$ExePath,
    [string]$AppRoot
  )
  $exeName = Split-Path -Leaf $ExePath
  $scan = Get-AsarIntegrityRecords -ExePath $ExePath -AppRoot $AppRoot
  if ($scan.Records.Count -eq 0) {
    Fail "ASAR integrity table disappeared from $exeName after the integrity update"
  }
  foreach ($record in $scan.Records) {
    $actual = Get-AsarHeaderSha256 $record.AsarPath
    if ($record.Value -ne $actual) {
      Fail "ASAR integrity verification failed for $($record.RelativePath) in ${exeName}: embedded=$($record.Value) actual=$actual"
    }
  }
  Write-Log "asar integrity verification ok: $exeName entries=$($scan.Records.Count)"
}
