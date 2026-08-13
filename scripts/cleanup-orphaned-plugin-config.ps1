[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$')]
  [string]$PluginId,

  [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),

  [string]$CodexHome,

  [switch]$Install
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-orphan-plugin-config]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Read-Utf8Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Test-HasUtf8Bom {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return $bytes.Length -ge 3 -and
    $bytes[0] -eq 0xEF -and
    $bytes[1] -eq 0xBB -and
    $bytes[2] -eq 0xBF
}

function Split-LinesPreservingEndings {
  param([string]$Content)

  if ($Content.Length -eq 0) {
    return @()
  }

  $result = New-Object 'System.Collections.Generic.List[string]'
  foreach ($match in [regex]::Matches($Content, '[^\r\n]*(?:\r\n|\n|\r|$)')) {
    if ($match.Length -gt 0) {
      [void]$result.Add($match.Value)
    }
  }
  return $result.ToArray()
}

function Get-LineText {
  param([string]$Token)

  if ($Token.EndsWith("`r`n")) {
    return $Token.Substring(0, $Token.Length - 2)
  }
  if ($Token.EndsWith("`n") -or $Token.EndsWith("`r")) {
    return $Token.Substring(0, $Token.Length - 1)
  }
  return $Token
}

function Get-TableInner {
  param([string]$Line)

  $match = [regex]::Match($Line.Trim(), '^\[([^\[\]]+)\](?:\s*#.*)?$')
  if (-not $match.Success) {
    return $null
  }
  return $match.Groups[1].Value.Trim()
}

function Get-TableBlocks {
  param([string[]]$Tokens)

  $starts = New-Object 'System.Collections.Generic.List[object]'
  for ($index = 0; $index -lt $Tokens.Count; $index++) {
    $inner = Get-TableInner (Get-LineText $Tokens[$index])
    if ($null -ne $inner) {
      [void]$starts.Add([pscustomobject]@{
          Index = $index
          Inner = $inner
        })
    }
  }

  $blocks = New-Object 'System.Collections.Generic.List[object]'
  for ($position = 0; $position -lt $starts.Count; $position++) {
    $start = [int]$starts[$position].Index
    $end = if ($position + 1 -lt $starts.Count) { [int]$starts[$position + 1].Index } else { $Tokens.Count }
    [void]$blocks.Add([pscustomobject]@{
        Start = $start
        End = $end
        Inner = [string]$starts[$position].Inner
      })
  }
  return $blocks.ToArray()
}

function Get-QuotedTableNames {
  param(
    [string]$Prefix,
    [string]$Name
  )

  return @(
    "$Prefix.`"$Name`""
    "$Prefix.'$Name'"
  )
}

function Test-ExactHookTable {
  param(
    [string]$Inner,
    [string]$TargetPluginId
  )

  $doublePrefix = 'hooks.state."' + $TargetPluginId + ':'
  $singlePrefix = "hooks.state.'" + $TargetPluginId + ':'
  return ($Inner.StartsWith($doublePrefix) -and $Inner.EndsWith('"')) -or
    ($Inner.StartsWith($singlePrefix) -and $Inner.EndsWith("'"))
}

function Test-IsHooksStateTable {
  param([string]$Inner)
  return $Inner -eq 'hooks.state' -or $Inner -eq 'hooks."state"' -or $Inner -eq "hooks.'state'"
}

function Test-TableHasContent {
  param(
    [string[]]$Tokens,
    [object]$Block
  )

  for ($index = ([int]$Block.Start + 1); $index -lt ([int]$Block.End); $index += 1) {
    $line = (Get-LineText $Tokens[$index]).Trim()
    if ($line.Length -gt 0 -and -not $line.StartsWith('#')) {
      return $true
    }
  }
  return $false
}

function Remove-TableBlocks {
  param(
    [string[]]$Tokens,
    [object[]]$Blocks
  )

  $removed = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($block in $Blocks) {
    for ($index = [int]$block.Start; $index -lt [int]$block.End; $index++) {
      [void]$removed.Add($index)
    }
  }

  $builder = [System.Text.StringBuilder]::new()
  for ($index = 0; $index -lt $Tokens.Count; $index++) {
    if (-not $removed.Contains($index)) {
      [void]$builder.Append($Tokens[$index])
    }
  }
  return $builder.ToString()
}

function Test-MarketplaceConfigured {
  param(
    [string]$Content,
    [string]$MarketplaceName
  )

  $tokens = Split-LinesPreservingEndings $Content
  $blocks = Get-TableBlocks $tokens
  $targetNames = @(Get-QuotedTableNames 'marketplaces' $MarketplaceName) + @("marketplaces.$MarketplaceName")
  $escapedName = [regex]::Escape($MarketplaceName)

  foreach ($block in $blocks) {
    if ($targetNames -contains $block.Inner) {
      return $true
    }

    if ($block.Inner -eq 'marketplaces') {
      for ($index = ([int]$block.Start + 1); $index -lt ([int]$block.End); $index += 1) {
        $line = Get-LineText $tokens[$index]
        if ($line -match "^\s*(?:`"$escapedName`"|'$escapedName'|$escapedName)\s*=") {
          return $true
        }
      }
    }
  }
  return $false
}

function Find-PluginDescriptor {
  param(
    [object]$Node,
    [string]$PluginName,
    [string]$TargetPluginId
  )

  if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) {
    return $false
  }

  if ($Node -is [System.Collections.IEnumerable]) {
    foreach ($item in $Node) {
      if (Find-PluginDescriptor $item $PluginName $TargetPluginId) {
        return $true
      }
    }
    return $false
  }

  foreach ($propertyName in @('name', 'id', 'pluginId')) {
    $property = $Node.PSObject.Properties[$propertyName]
    if ($property) {
      $value = [string]$property.Value
      if ($value -eq $PluginName -or $value -eq $TargetPluginId) {
        return $true
      }
    }
  }

  foreach ($property in $Node.PSObject.Properties) {
    if (Find-PluginDescriptor $property.Value $PluginName $TargetPluginId) {
      return $true
    }
  }
  return $false
}

function Get-PluginDiskEvidence {
  param(
    [string]$Root,
    [string]$MarketplaceName,
    [string]$PluginName,
    [string]$TargetPluginId
  )

  $evidence = New-Object 'System.Collections.Generic.List[object]'
  $marketplaceRoots = @(
    (Join-Path $Root "marketplaces\$MarketplaceName")
    (Join-Path $Root "plugins\cache\$MarketplaceName")
    (Join-Path $Root ".tmp\bundled-marketplaces\$MarketplaceName")
  ) | Select-Object -Unique
  $candidateNames = @($PluginName, $TargetPluginId) | Select-Object -Unique

  foreach ($marketplaceRoot in $marketplaceRoots) {
    foreach ($candidateName in $candidateNames) {
      foreach ($candidate in @(
          (Join-Path $marketplaceRoot $candidateName)
          (Join-Path $marketplaceRoot "plugins\$candidateName")
        )) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
          [void]$evidence.Add([pscustomobject]@{
              Kind = 'plugin-directory-present'
              Path = [System.IO.Path]::GetFullPath($candidate)
            })
        }
      }
    }

    foreach ($manifest in @(
        (Join-Path $marketplaceRoot '.agents\plugins\marketplace.json')
        (Join-Path $marketplaceRoot 'marketplace.json')
      )) {
      if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
          $json = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
          if (Find-PluginDescriptor $json $PluginName $TargetPluginId) {
            [void]$evidence.Add([pscustomobject]@{
                Kind = 'plugin-descriptor-present'
                Path = [System.IO.Path]::GetFullPath($manifest)
              })
          }
        } catch {
          [void]$evidence.Add([pscustomobject]@{
              Kind = 'unreadable-marketplace-manifest'
              Path = [System.IO.Path]::GetFullPath($manifest)
            })
        }
      }
    }
  }
  return @($evidence | Sort-Object Kind, Path -Unique)
}

function Backup-ConfigBeforeOverwrite {
  param(
    [string]$Path,
    [string]$TargetPluginId
  )

  $backupRoot = Join-Path (Split-Path -Parent $Path) 'backups\config'
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $safeId = ($TargetPluginId -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
  $backupPath = Join-Path $backupRoot "config.toml.$stamp.orphan-$safeId.bak"
  $suffix = 1
  while (Test-Path -LiteralPath $backupPath) {
    $backupPath = Join-Path $backupRoot "config.toml.$stamp.orphan-$safeId-$suffix.bak"
    $suffix++
  }

  Copy-Item -LiteralPath $Path -Destination $backupPath -Force
  $sourceHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
  if ($sourceHash -ne $backupHash) {
    throw "config backup hash mismatch: $backupPath"
  }
  Write-Log "config.toml backup created and hash verified: $backupPath ($sourceHash)"
  return $backupPath
}

function Test-TomlSyntax {
  param([string]$Path)

  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python not found; skipping tomllib syntax validation'
    return
  }

  $script = @'
import pathlib
import sys
import tomllib

tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
'@
  $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-toml-validate-' + [guid]::NewGuid().ToString('N') + '.py')
  try {
    Write-Utf8NoBom $temp $script
    & $python.Source $temp $Path
    if ($LASTEXITCODE -ne 0) {
      throw "tomllib validation failed: $Path"
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
  $CodexHome = Split-Path -Parent $ConfigPath
}
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)

$at = $PluginId.LastIndexOf('@')
$pluginName = $PluginId.Substring(0, $at)
$marketplaceName = $PluginId.Substring($at + 1)

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  Write-Log "config.toml not found; nothing to classify: $ConfigPath"
  exit 0
}

$content = Read-Utf8Text $ConfigPath
$tokens = Split-LinesPreservingEndings $content
$blocks = Get-TableBlocks $tokens
$pluginTableNames = Get-QuotedTableNames 'plugins' $PluginId
$pluginBlocks = @($blocks | Where-Object { $pluginTableNames -contains $_.Inner })
$targetHookBlocks = @($blocks | Where-Object { Test-ExactHookTable $_.Inner $PluginId })
$targetBlocks = @($pluginBlocks) + @($targetHookBlocks)

if ($pluginBlocks.Count -eq 0) {
  Write-Log "plugin table not found; nothing to do: $PluginId"
  exit 0
}

if (Test-MarketplaceConfigured $content $marketplaceName) {
  Write-Log "refusing orphan cleanup because marketplace is configured: $marketplaceName"
  throw "marketplace-configured: $marketplaceName"
}

$diskEvidence = @(Get-PluginDiskEvidence $CodexHome $marketplaceName $pluginName $PluginId)
if ($diskEvidence.Count -gt 0) {
  foreach ($item in $diskEvidence) {
    Write-Log "refusing orphan cleanup because plugin evidence exists [$($item.Kind)]: $($item.Path)"
  }
  throw "plugin-disk-evidence-present: $PluginId"
}

Write-Log "orphaned plugin configuration classified: $PluginId"
if (-not $Install) {
  Write-Log 'read-only mode; pass -Install to remove the exact plugin and hook tables'
  exit 0
}

Test-TomlSyntax $ConfigPath
$null = Backup-ConfigBeforeOverwrite $ConfigPath $PluginId
$afterTargetRemoval = Remove-TableBlocks $tokens $targetBlocks
$afterTokens = Split-LinesPreservingEndings $afterTargetRemoval
$afterBlocks = Get-TableBlocks $afterTokens
$emptyHooksStateBlocks = if ($targetHookBlocks.Count -gt 0) {
  $candidates = New-Object 'System.Collections.Generic.List[object]'
  foreach ($block in $afterBlocks) {
    if ((Test-IsHooksStateTable $block.Inner) -and -not (Test-TableHasContent $afterTokens $block)) {
      [void]$candidates.Add($block)
    }
  }
  Write-Output -NoEnumerate $candidates.ToArray()
} else {
  @()
}
$result = if ($emptyHooksStateBlocks.Count -gt 0) {
  Remove-TableBlocks $afterTokens $emptyHooksStateBlocks
} else {
  $afterTargetRemoval
}

$validationPath = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-orphan-plugin-config-' + [guid]::NewGuid().ToString('N') + '.toml')
try {
  Write-Utf8NoBom $validationPath $result
  Test-TomlSyntax $validationPath
  if (Test-HasUtf8Bom $validationPath) {
    throw "cleanup candidate unexpectedly contains a UTF-8 BOM: $validationPath"
  }
} finally {
  Remove-Item -LiteralPath $validationPath -Force -ErrorAction SilentlyContinue
}

Write-Utf8NoBom $ConfigPath $result
Test-TomlSyntax $ConfigPath
if (Test-HasUtf8Bom $ConfigPath) {
  throw "config.toml unexpectedly contains a UTF-8 BOM after cleanup: $ConfigPath"
}

$finalContent = Read-Utf8Text $ConfigPath
$finalTokens = Split-LinesPreservingEndings $finalContent
$finalBlocks = Get-TableBlocks $finalTokens
$remainingPluginBlocks = @($finalBlocks | Where-Object { $pluginTableNames -contains $_.Inner })
$remainingHookBlocks = @($finalBlocks | Where-Object { Test-ExactHookTable $_.Inner $PluginId })
$remainingEmptyHooksState = if ($targetHookBlocks.Count -gt 0) {
  $candidates = New-Object 'System.Collections.Generic.List[object]'
  foreach ($block in $finalBlocks) {
    if ((Test-IsHooksStateTable $block.Inner) -and -not (Test-TableHasContent $finalTokens $block)) {
      [void]$candidates.Add($block)
    }
  }
  Write-Output -NoEnumerate $candidates.ToArray()
} else {
  @()
}
if ($remainingPluginBlocks.Count -gt 0 -or $remainingHookBlocks.Count -gt 0 -or $remainingEmptyHooksState.Count -gt 0) {
  throw "orphan plugin cleanup verification failed: $PluginId"
}

Write-Log "removed exact plugin and hook state tables: $PluginId"
Write-Log 'cleanup verification passed: TOML valid, no BOM, target tables absent'
