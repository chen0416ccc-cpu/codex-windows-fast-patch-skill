[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$updater = Join-Path $scriptRoot 'update-skill-from-github.ps1'
$repoRoot = Split-Path -Parent $scriptRoot
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
  throw "self-update script is missing: $updater"
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )
  if (-not $Condition) {
    throw "assertion failed: $Message"
  }
}

$parseErrors = $null
$tokens = $null
$updaterAst = [System.Management.Automation.Language.Parser]::ParseFile($updater, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
  throw "self-update script has parse errors: $($parseErrors[0].Message)"
}

# The declared top-level file set must be a single reusable list, not a literal
# inlined at the copy site, so the sync loop and this test cannot drift apart.
$listAssignment = $updaterAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
  $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
  $node.Left.VariablePath.UserPath -eq 'TopLevelSyncedFiles'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $listAssignment) 'self-update script declares $TopLevelSyncedFiles'

$topLevelSynced = @(& ([scriptblock]::Create($listAssignment.Right.Extent.Text)))
Assert-True ($topLevelSynced.Count -gt 0) '$TopLevelSyncedFiles is not empty'

# Every tracked top-level file must be installed. README acceptance checklists
# are the contract a run is verified against; shipping only SKILL.md makes
# .skill-version advertise a commit whose criteria were never installed.
$expectedTopLevel = @(Get-ChildItem -LiteralPath $repoRoot -File |
  Where-Object { -not $_.Name.StartsWith('.') } |
  Select-Object -ExpandProperty Name)
Assert-True ($expectedTopLevel -contains 'README.md') 'repository root contains README.md'
foreach ($name in $expectedTopLevel) {
  Assert-True ($topLevelSynced -contains $name) "top-level file is synced by self-update: $name"
}

$copyLoop = $updaterAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
  $node.Condition.Extent.Text -eq '$TopLevelSyncedFiles'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $copyLoop) 'the copy loop iterates $TopLevelSyncedFiles'
Assert-True ($copyLoop.Body.Extent.Text -match 'Copy-AllowedFile') 'the copy loop calls Copy-AllowedFile'

# The version marker is compared against a remote SHA and read by non-PowerShell
# tooling, so it must never be written with a UTF-8 BOM.
Assert-True ($updaterAst.Extent.Text -notmatch '(?m)Set-Content[^\r\n]*\$versionPath') 'the version marker is not written with Set-Content'
$versionWrite = $updaterAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
  $node.GetCommandName() -eq 'Write-Utf8NoBom' -and
  $node.Extent.Text -match '\$versionPath'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $versionWrite) 'the version marker is written with Write-Utf8NoBom'

$requiredFunctions = @('Write-Utf8NoBom', 'Copy-AllowedFile', 'Assert-UnderPath')
$definitions = @{}
foreach ($name in $requiredFunctions) {
  $definition = $updaterAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true) | Select-Object -First 1
  Assert-True ($null -ne $definition) "self-update script defines $name"
  $definitions[$name] = $definition.Extent.Text
}
. ([scriptblock]::Create(($requiredFunctions | ForEach-Object { $definitions[$_] }) -join "`n"))

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixture = Join-Path $temp ('skill-self-update-files-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $fixture 'source'
$skillRoot = Join-Path $fixture 'skill'
New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null

try {
  foreach ($name in $topLevelSynced) {
    Set-Content -LiteralPath (Join-Path $sourceRoot $name) -Value "remote $name" -Encoding ASCII
  }
  # A stale installed copy plus one file the archive does not ship at all.
  Set-Content -LiteralPath (Join-Path $skillRoot 'README.md') -Value 'stale README' -Encoding ASCII
  Remove-Item -LiteralPath (Join-Path $sourceRoot ($topLevelSynced | Select-Object -Last 1)) -Force

  foreach ($fileName in $topLevelSynced) {
    Copy-AllowedFile -Source (Join-Path $sourceRoot $fileName) -Destination (Join-Path $skillRoot $fileName) -AllowedRoot $skillRoot
  }

  $absentFromArchive = $topLevelSynced | Select-Object -Last 1
  foreach ($fileName in $topLevelSynced) {
    $installed = Join-Path $skillRoot $fileName
    if ($fileName -eq $absentFromArchive) {
      Assert-True (-not (Test-Path -LiteralPath $installed -PathType Leaf)) "a file missing from the archive is skipped, not faked: $fileName"
      continue
    }
    Assert-True (Test-Path -LiteralPath $installed -PathType Leaf) "top-level file was installed: $fileName"
    Assert-True ((Get-Content -LiteralPath $installed -Raw).Trim() -eq "remote $fileName") "installed copy is the remote content: $fileName"
  }

  $escape = Join-Path $fixture 'escape.md'
  Set-Content -LiteralPath (Join-Path $sourceRoot 'SKILL.md') -Value 'remote SKILL.md' -Encoding ASCII
  $blocked = $false
  try {
    Copy-AllowedFile -Source (Join-Path $sourceRoot 'SKILL.md') -Destination $escape -AllowedRoot $skillRoot
  } catch {
    $blocked = $true
  }
  Assert-True $blocked 'writes outside the skill root are still refused'
  Assert-True (-not (Test-Path -LiteralPath $escape)) 'no file was written outside the skill root'

  $versionPath = Join-Path $skillRoot '.skill-version'
  $sha = '2f07a7234dfb27b1dc27720e185286644ed1ddff'
  Write-Utf8NoBom -Path $versionPath -Content ($sha + "`n")
  $bytes = [System.IO.File]::ReadAllBytes($versionPath)
  Assert-True ($bytes.Length -gt 3) 'version marker is not empty'
  $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  Assert-True (-not $hasBom) 'version marker has no UTF-8 BOM'
  Assert-True ((Get-Content -LiteralPath $versionPath -Raw).Trim() -eq $sha) 'version marker round-trips to the remote SHA'

  # A marker left behind by an older BOM-writing install must still compare equal.
  [System.IO.File]::WriteAllText($versionPath, $sha + "`n", [System.Text.UTF8Encoding]::new($true))
  $legacySha = (Get-Content -LiteralPath $versionPath -Raw).Trim().TrimStart([char]0xFEFF)
  Assert-True ($legacySha -eq $sha) 'a legacy BOM marker still compares equal to the remote SHA'

  Write-Host "Skill self-update file coverage regression passed: $fixture"
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
