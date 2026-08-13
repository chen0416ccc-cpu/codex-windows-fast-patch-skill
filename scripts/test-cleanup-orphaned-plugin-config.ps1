[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$cleanupScript = Join-Path $scriptRoot 'cleanup-orphaned-plugin-config.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-orphan-plugin-test-' + [guid]::NewGuid().ToString('N'))

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Read-Utf8Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )
  if (-not $Condition) {
    throw "ASSERTION FAILED: $Message"
  }
}

function Assert-Equal {
  param(
    $Expected,
    $Actual,
    [string]$Message
  )
  if ($Expected -ne $Actual) {
    throw "ASSERTION FAILED: $Message; expected '$Expected', got '$Actual'"
  }
}

function New-FixtureConfig {
  param(
    [string]$Root,
    [string]$Content
  )
  $config = Join-Path $Root '.codex\config.toml'
  Write-Utf8NoBom $config $Content
  return $config
}

function Invoke-Cleanup {
  param(
    [string]$ConfigPath,
    [string]$CodexHome,
    [string]$PluginId,
    [switch]$Install
  )

  $arguments = @(
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $cleanupScript
    '-PluginId'
    $PluginId
    '-ConfigPath'
    $ConfigPath
    '-CodexHome'
    $CodexHome
  )
  if ($Install) {
    $arguments += '-Install'
  }

  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& powershell @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedPreference
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  }
}

function Assert-TomlAndNoBom {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  Assert-True ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) 'result must be UTF-8 without BOM'
  & python -c "import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))" $Path
  Assert-Equal 0 $LASTEXITCODE 'result TOML must parse with tomllib'
}

try {
  New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
  $pluginId = 'obsolete-helper@personal'
  $fixture = @(
    '# fixture'
    '[plugins."obsolete-helper@personal"]'
    'enabled = true'
    ''
    '[plugins."obsolete-helper@personal-extra"]'
    'enabled = true'
    ''
    '[plugins."keep-helper@personal"]'
    'enabled = true'
    ''
    '[hooks.state."obsolete-helper@personal:startup"]'
    'value = 1'
    ''
    '[hooks.state."obsolete-helper@personalized:startup"]'
    'value = 2'
    ''
    '[hooks.state."keep-helper@personal:startup"]'
    'value = 3'
    ''
    '[hooks.state]'
    'keep = true'
    ''
  ) -join "`r`n"

  $successRoot = Join-Path $testRoot 'success'
  $successConfig = New-FixtureConfig $successRoot $fixture
  $fixturePath = Join-Path $testRoot 'fixture.toml'
  Write-Utf8NoBom $fixturePath $fixture
  $fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
  $readOnly = Invoke-Cleanup $successConfig (Join-Path $successRoot '.codex') $pluginId
  Assert-Equal 0 $readOnly.ExitCode 'read-only classification should succeed'
  Assert-True ($readOnly.Text -match 'orphaned plugin configuration classified') 'read-only classification output is missing'
  Assert-Equal $fixture (Read-Utf8Text $successConfig) 'read-only mode must not modify config'

  $installed = Invoke-Cleanup $successConfig (Join-Path $successRoot '.codex') $pluginId -Install
  Assert-Equal 0 $installed.ExitCode 'orphan cleanup should succeed'
  $cleaned = Read-Utf8Text $successConfig
  Assert-True ($cleaned -notmatch '\[plugins\."obsolete-helper@personal"\]') 'exact plugin table should be removed'
  Assert-True ($cleaned -notmatch '\[hooks\.state\."obsolete-helper@personal:startup"\]') 'exact target hook should be removed'
  Assert-True ($cleaned -match '\[plugins\."obsolete-helper@personal-extra"\]') 'similar plugin id must remain'
  Assert-True ($cleaned -match '\[hooks\.state\."obsolete-helper@personalized:startup"\]') 'similar hook id must remain'
  Assert-True ($cleaned -match '\[hooks\.state\."keep-helper@personal:startup"\]') 'other hook must remain'
  Assert-True ($cleaned -match 'keep = true') 'other hooks.state content must remain'
  Assert-TomlAndNoBom $successConfig

  $backups = @(Get-ChildItem -LiteralPath (Join-Path $successRoot '.codex\backups\config') -Filter '*.bak')
  Assert-Equal 1 $backups.Count 'one backup should be created'
  Assert-Equal $fixtureHash ((Get-FileHash -LiteralPath $backups[0].FullName -Algorithm SHA256).Hash) 'backup must equal the pre-write fixture'

  $manifestRoot = Join-Path $testRoot 'manifest'
  $manifestConfig = New-FixtureConfig $manifestRoot $fixture
  $manifestPath = Join-Path $manifestRoot '.codex\marketplaces\personal\.agents\plugins\marketplace.json'
  Write-Utf8NoBom $manifestPath '{"plugins":[{"name":"obsolete-helper","version":"1.0.0"}]}'
  $manifestBefore = Read-Utf8Text $manifestConfig
  $manifestResult = Invoke-Cleanup $manifestConfig (Join-Path $manifestRoot '.codex') $pluginId -Install
  Assert-True ($manifestResult.ExitCode -ne 0) 'plugin descriptor must block cleanup'
  Assert-True ($manifestResult.Text -match 'plugin-disk-evidence-present') 'plugin descriptor failure should be reported'
  Assert-Equal $manifestBefore (Read-Utf8Text $manifestConfig) 'blocked descriptor case must not modify config'

  $second = Invoke-Cleanup $successConfig (Join-Path $successRoot '.codex') $pluginId -Install
  Assert-Equal 0 $second.ExitCode 'repeated cleanup should be idempotent'
  Assert-Equal 1 (@(Get-ChildItem -LiteralPath (Join-Path $successRoot '.codex\backups\config') -Filter '*.bak').Count) 'idempotent cleanup must not create a backup'

  $marketplaceRoot = Join-Path $testRoot 'marketplace'
  $marketplaceConfig = New-FixtureConfig $marketplaceRoot ($fixture + "`r`n[marketplaces.personal]`r`nsource = 'local'`r`n")
  $marketplaceBefore = Read-Utf8Text $marketplaceConfig
  $marketplaceResult = Invoke-Cleanup $marketplaceConfig (Join-Path $marketplaceRoot '.codex') $pluginId -Install
  Assert-True ($marketplaceResult.ExitCode -ne 0) 'configured marketplace must block cleanup'
  Assert-True ($marketplaceResult.Text -match 'marketplace-configured') 'configured marketplace failure should be reported'
  Assert-Equal $marketplaceBefore (Read-Utf8Text $marketplaceConfig) 'blocked marketplace case must not modify config'

  $diskRoot = Join-Path $testRoot 'disk'
  $diskConfig = New-FixtureConfig $diskRoot $fixture
  New-Item -ItemType Directory -Force -Path (Join-Path $diskRoot '.codex\plugins\cache\personal\obsolete-helper') | Out-Null
  $diskBefore = Read-Utf8Text $diskConfig
  $diskResult = Invoke-Cleanup $diskConfig (Join-Path $diskRoot '.codex') $pluginId -Install
  Assert-True ($diskResult.ExitCode -ne 0) 'plugin directory must block cleanup'
  Assert-True ($diskResult.Text -match 'plugin-disk-evidence-present') 'plugin directory failure should be reported'
  Assert-Equal $diskBefore (Read-Utf8Text $diskConfig) 'blocked disk case must not modify config'

  $emptyHooksRoot = Join-Path $testRoot 'empty-hooks'
  $emptyHooksFixture = @(
    '[plugins."obsolete-helper@personal"]'
    'enabled = true'
    ''
    '[hooks.state."obsolete-helper@personal:startup"]'
    'value = 1'
    ''
    '[hooks.state]'
    ''
  ) -join "`n"
  $emptyHooksConfig = New-FixtureConfig $emptyHooksRoot $emptyHooksFixture
  $emptyHooksResult = Invoke-Cleanup $emptyHooksConfig (Join-Path $emptyHooksRoot '.codex') $pluginId -Install
  Assert-Equal 0 $emptyHooksResult.ExitCode 'empty hooks.state cleanup should succeed'
  $emptyHooksCleaned = Read-Utf8Text $emptyHooksConfig
  Assert-True ($emptyHooksCleaned -notmatch '\[hooks\.state\]') 'empty hooks.state table should be removed'
  Assert-True ($emptyHooksCleaned -notmatch "`r") 'LF input should retain LF line endings'
  Assert-TomlAndNoBom $emptyHooksConfig

  $noTargetHookRoot = Join-Path $testRoot 'no-target-hook'
  $noTargetHookFixture = @(
    '[plugins."obsolete-helper@personal"]'
    'enabled = true'
    ''
    '[hooks.state]'
    ''
  ) -join "`r`n"
  $noTargetHookConfig = New-FixtureConfig $noTargetHookRoot $noTargetHookFixture
  $noTargetHookResult = Invoke-Cleanup $noTargetHookConfig (Join-Path $noTargetHookRoot '.codex') $pluginId -Install
  Assert-Equal 0 $noTargetHookResult.ExitCode 'cleanup without a target hook should succeed'
  Assert-True ((Read-Utf8Text $noTargetHookConfig) -match '\[hooks\.state\]') 'pre-existing empty hooks.state must remain when no target hook was removed'

  $invalidRoot = Join-Path $testRoot 'invalid-toml'
  $invalidConfig = New-FixtureConfig $invalidRoot ($fixture + "broken = [`r`n")
  $invalidBefore = Read-Utf8Text $invalidConfig
  $invalidResult = Invoke-Cleanup $invalidConfig (Join-Path $invalidRoot '.codex') $pluginId -Install
  Assert-True ($invalidResult.ExitCode -ne 0) 'invalid source TOML must block cleanup'
  Assert-Equal $invalidBefore (Read-Utf8Text $invalidConfig) 'invalid source TOML must remain unchanged'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidRoot '.codex\backups\config'))) 'invalid source TOML must fail before backup and write'

  Write-Output 'Orphaned plugin config cleanup tests passed'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
