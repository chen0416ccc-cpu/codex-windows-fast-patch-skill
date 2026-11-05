function Get-CodexTomlHeaderPattern {
  param([string]$Header)

  if (-not $Header.StartsWith('[') -or -not $Header.EndsWith(']')) { throw 'Unsupported TOML table header.' }
  $remaining = $Header.Substring(1, $Header.Length - 2).Trim()
  $parts = @()
  while ($remaining.Length -gt 0) {
    $match = [regex]::Match($remaining, '^(?:[A-Za-z0-9_-]+|"[^"\\\r\n]*"|''[^''\r\n]*'')')
    if (-not $match.Success) { throw 'Unsupported TOML table key.' }
    $token = $match.Value
    if ($token.StartsWith('"') -or $token.StartsWith("'")) { $token = $token.Substring(1, $token.Length - 2) }
    $escaped = [regex]::Escape($token)
    $variants = @(('"' + $escaped + '"'), ("'" + $escaped + "'"))
    if ($token -match '^[A-Za-z0-9_-]+$') { $variants += $escaped }
    $parts += '(?:' + ($variants -join '|') + ')'
    $remaining = $remaining.Substring($match.Length).TrimStart()
    if ($remaining.Length -eq 0) { break }
    if (-not $remaining.StartsWith('.')) { throw 'Unsupported TOML table separator.' }
    $remaining = $remaining.Substring(1).TrimStart()
    if ($remaining.Length -eq 0) { throw 'Unsupported TOML trailing separator.' }
  }
  if ($parts.Count -eq 0) { throw 'Empty TOML table header.' }
  return '\[[ \t]*' + ($parts -join '[ \t]*\.[ \t]*') + '[ \t]*\]'
}

function Get-CodexTomlKeyPattern {
  param([string]$Key)
  $escaped = [regex]::Escape($Key)
  return '(?:' + $escaped + '|"' + $escaped + '"|''' + $escaped + ''')'
}

function ConvertTo-CodexTomlString {
  param([AllowEmptyString()][string]$Value)

  if ($Value -notmatch "['\x00-\x1f\x7f]") {
    return "'$Value'"
  }
  # TOML literal strings cannot escape apostrophes; use a basic string instead.
  $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
  $escaped = [regex]::Replace($escaped, '[\x00-\x1f\x7f]', {
    param($match)
    return '\u{0:x4}' -f [int][char]$match.Value
  })
  return '"' + $escaped + '"'
}

function Test-CodexTomlContent {
  param([AllowEmptyString()][string]$Content)

  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python not found; skipping tomllib syntax validation'
    return
  }
  $validator = @'
import sys
try:
    import tomllib
except ImportError:
    sys.exit(42)
try:
    # Windows PowerShell 5.1 can prefix native stdin with a UTF-8 BOM.
    tomllib.loads(sys.stdin.buffer.read().decode('utf-8-sig'))
except (ValueError, UnicodeError):
    sys.exit(1)
'@
  $oldEncoding = $OutputEncoding
  $oldPreference = $ErrorActionPreference
  try {
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    $ErrorActionPreference = 'Continue'
    $null = $Content | & $python.Source -c $validator 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $OutputEncoding = $oldEncoding
    $ErrorActionPreference = $oldPreference
  }
  if ($exitCode -eq 42) {
    Write-Log 'warning: python has no tomllib; skipping TOML syntax validation'
    return
  }
  if ($exitCode -ne 0) {
    throw 'TOML syntax validation failed; configuration was not written.'
  }
}
