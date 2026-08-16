[CmdletBinding()]
param(
  [string]$Owner = 'chen0416ccc-cpu',
  [string]$Repo = 'codex-windows-fast-patch-skill',
  [string]$Branch = 'main',
  [string]$SkillDir,
  [switch]$CheckOnly,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-skill-self-update]'

# Every tracked top-level file the installed skill needs. SKILL.md alone is not
# enough: the README acceptance checklists are what a run is verified against,
# so leaving them behind makes .skill-version advertise a commit whose
# acceptance criteria were never installed.
$TopLevelSyncedFiles = @('SKILL.md', 'README.md', 'README.en.md', 'AGENTS.md', 'SECURITY.md')

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Resolve-OrCreateDirectory {
  param([string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Resolve-UpdateSource {
  param(
    [string]$SkillRoot,
    [string]$Owner,
    [string]$Repo,
    [string]$Branch,
    [object]$BoundParameters
  )

  $overlayPath = Join-Path $SkillRoot '.skill-local-overlay'
  $sourcePath = Join-Path $SkillRoot '.skill-update-source.json'
  $hasExplicitSource = (
    $BoundParameters.ContainsKey('Owner') -or
    $BoundParameters.ContainsKey('Repo') -or
    $BoundParameters.ContainsKey('Branch')
  )

  if ((Test-Path -LiteralPath $overlayPath -PathType Leaf) -and
      -not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
      -not $hasExplicitSource) {
    throw 'local overlay marker is present but .skill-update-source.json is missing; refusing to overwrite the overlay with the default upstream source'
  }

  $sourceKind = 'parameters'
  if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
    try {
      $configured = Get-Content -Raw -LiteralPath $sourcePath | ConvertFrom-Json
    } catch {
      throw "invalid local skill update source file: $sourcePath ($($_.Exception.Message))"
    }

    foreach ($name in @('owner', 'repo', 'branch')) {
      if ([string]::IsNullOrWhiteSpace([string]$configured.$name)) {
        throw "invalid local skill update source file: missing $name in $sourcePath"
      }
    }

    if (-not $BoundParameters.ContainsKey('Owner')) {
      $Owner = [string]$configured.owner
    }
    if (-not $BoundParameters.ContainsKey('Repo')) {
      $Repo = [string]$configured.repo
    }
    if (-not $BoundParameters.ContainsKey('Branch')) {
      $Branch = [string]$configured.branch
    }
    $sourceKind = 'local-config'
  }

  return [pscustomobject]@{
    Owner = $Owner
    Repo = $Repo
    Branch = $Branch
    Kind = $sourceKind
  }
}

function Assert-UnderPath {
  param(
    [string]$Path,
    [string]$Parent
  )
  $full = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "refusing to update path outside skill root: $full"
  }
}

function Get-RemoteHeadSha {
  param(
    [string]$Owner,
    [string]$Repo,
    [string]$Branch
  )

  $apiUrl = "https://api.github.com/repos/$Owner/$Repo/commits/$Branch"
  try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'codex-skill-self-update' } -ErrorAction Stop
    if ($response.sha) {
      return [string]$response.sha
    }
  } catch {
    Write-Log "GitHub API check failed, trying git ls-remote: $($_.Exception.Message)"
  }

  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $remote = "https://github.com/$Owner/$Repo.git"
    $line = & $git.Source ls-remote $remote "refs/heads/$Branch" 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $line -match '^([0-9a-fA-F]{40})\s+') {
      return $matches[1]
    }
  }

  throw "could not resolve remote head for $Owner/$Repo@$Branch"
}

function Sync-Directory {
  param(
    [string]$Source,
    [string]$Destination,
    [string]$AllowedRoot
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    return
  }

  Assert-UnderPath $Destination $AllowedRoot
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy.exe $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed while syncing $Source to $Destination (exit code $LASTEXITCODE)"
  }
}

function Copy-AllowedFile {
  param(
    [string]$Source,
    [string]$Destination,
    [string]$AllowedRoot
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    return
  }

  Assert-UnderPath $Destination $AllowedRoot
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

try {
  if ([string]::IsNullOrWhiteSpace($SkillDir)) {
    if (-not $PSScriptRoot) {
      throw 'cannot infer skill directory because PSScriptRoot is empty'
    }
    $SkillDir = Split-Path -Parent $PSScriptRoot
  }

  $skillRoot = Resolve-OrCreateDirectory $SkillDir
  $updateSource = Resolve-UpdateSource `
    -SkillRoot $skillRoot `
    -Owner $Owner `
    -Repo $Repo `
    -Branch $Branch `
    -BoundParameters $PSBoundParameters
  $Owner = $updateSource.Owner
  $Repo = $updateSource.Repo
  $Branch = $updateSource.Branch
  if ($updateSource.Kind -eq 'local-config') {
    Write-Log "using local update source: $Owner/$Repo@$Branch"
  }
  $versionPath = Join-Path $skillRoot '.skill-version'
  $remoteSha = Get-RemoteHeadSha -Owner $Owner -Repo $Repo -Branch $Branch
  $localSha = ''
  if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    # Older installs wrote this marker with a UTF-8 BOM, which Trim() keeps.
    $localSha = (Get-Content -LiteralPath $versionPath -Raw).Trim().TrimStart([char]0xFEFF)
  } elseif (Test-Path -LiteralPath (Join-Path $skillRoot '.git') -PathType Container) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
      Push-Location $skillRoot
      try {
        $localSha = (& $git.Source rev-parse HEAD 2>$null).Trim()
      } finally {
        Pop-Location
      }
    }
  }

  if (-not $Force -and $localSha -eq $remoteSha) {
    Write-Log "already up to date: $remoteSha"
    exit 0
  }

  if ($CheckOnly) {
    Write-Log "update available: local=$(if ($localSha) { $localSha } else { '<unknown>' }) remote=$remoteSha"
    exit 0
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-skill-update-' + [guid]::NewGuid().ToString('N'))
  $zipPath = Join-Path $tempRoot 'source.zip'
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  try {
    $archiveUrl = "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Branch"
    Write-Log "downloading latest skill: $Owner/$Repo@$Branch"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing -Headers @{ 'User-Agent' = 'codex-skill-self-update' }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $tempRoot -Force
    $sourceRoot = Get-ChildItem -LiteralPath $tempRoot -Directory | Select-Object -First 1
    if (-not $sourceRoot) {
      throw 'downloaded archive did not contain a source directory'
    }

    $sourceSkill = Join-Path $sourceRoot.FullName 'SKILL.md'
    if (-not (Test-Path -LiteralPath $sourceSkill -PathType Leaf)) {
      throw 'downloaded archive is missing SKILL.md'
    }

    foreach ($fileName in $TopLevelSyncedFiles) {
      Copy-AllowedFile -Source (Join-Path $sourceRoot.FullName $fileName) -Destination (Join-Path $skillRoot $fileName) -AllowedRoot $skillRoot
    }

    foreach ($dirName in @('agents', 'scripts', 'references', 'assets')) {
      Sync-Directory -Source (Join-Path $sourceRoot.FullName $dirName) -Destination (Join-Path $skillRoot $dirName) -AllowedRoot $skillRoot
    }

    Write-Utf8NoBom -Path $versionPath -Content ($remoteSha + "`n")
    Write-Log "updated skill from GitHub: $remoteSha"
    Write-Log 'reload SKILL.md before continuing'
  } finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
} catch {
  Write-Log "warning: self-update skipped: $($_.Exception.Message)"
  exit 0
}
