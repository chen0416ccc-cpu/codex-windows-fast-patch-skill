[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $scriptRoot 'install-computer-use-local.ps1'
$parseErrors = $null
$tokens = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $installer,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "Installer has PowerShell parse errors: $($parseErrors.Message -join '; ')"
}
foreach ($statement in $installerAst.EndBlock.Statements) {
  if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
    Invoke-Expression $statement.Extent.Text
  }
}

function Assert-ThrowsLike {
  param(
    [scriptblock]$Action,
    [string]$ExpectedMessage
  )
  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notlike $ExpectedMessage) {
      throw "Expected failure '$ExpectedMessage' but got '$($_.Exception.Message)'"
    }
    return
  }
  throw "Expected failure '$ExpectedMessage' but the verification passed"
}

function Get-IndependentV2Identity {
  param(
    [string]$Prefix,
    [string[]]$Fields
  )

  $payload = [System.IO.MemoryStream]::new()
  try {
    foreach ($field in $Fields) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$field)
      $payload.Write($bytes, 0, $bytes.Length)
      $payload.WriteByte(0)
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
      $hash = ([System.BitConverter]::ToString($sha256.ComputeHash($payload.ToArray()))).Replace('-', '').ToLowerInvariant()
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $payload.Dispose()
  }
  return $Prefix + $hash.Substring(0, 32)
}

function Copy-JsonValue {
  param([object]$Value)

  return (($Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json)
}

$fixedVectorFields = @('alpha', 'beta', 'gamma')
$fixedVectorExpected = '3a521ad250cdab627adf4f9099a7782a'
$fixedVectorIndependent = Get-IndependentV2Identity -Prefix '' -Fields $fixedVectorFields
if ($fixedVectorIndependent -cne $fixedVectorExpected) {
  throw "Independent v2 identity oracle does not match the fixed alpha-NUL-beta-NUL-gamma-NUL SHA-256 vector: actual=$fixedVectorIndependent expected=$fixedVectorExpected"
}
$fixedVectorProduction = Get-ChromeNativeHostV2Identity -Prefix '' -Values $fixedVectorFields
if ($fixedVectorProduction -cne $fixedVectorExpected) {
  throw "Production v2 identity helper does not hash explicit NUL-separated fields: actual=$fixedVectorProduction expected=$fixedVectorExpected"
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('chrome-native-host-v2-' + [guid]::NewGuid().ToString('N'))
$script:CodexHome = Join-Path $fixtureRoot 'codex-home'
$localAppData = Join-Path $fixtureRoot 'local-app-data'
$chromeVersion = '26.803.41515'
$chromeRoot = Join-Path $fixtureRoot "chrome\$chromeVersion"
$scriptsRoot = Join-Path $chromeRoot 'scripts'
$descriptorRoot = Join-Path $chromeRoot '.codex-plugin'
$hostRoot = Join-Path $chromeRoot 'extension-host\windows\x64'
$hostPath = Join-Path $hostRoot 'extension-host.exe'
$browserClientPath = Join-Path $scriptsRoot 'browser-client.mjs'
$browserServicePath = Join-Path $scriptsRoot 'browser-service.mjs'
$runtimeBin = Join-Path $fixtureRoot 'runtime\cua_node\current\bin'
$nodePath = Join-Path $runtimeBin 'node.exe'
$nodeReplPath = Join-Path $runtimeBin 'node_repl.exe'
$codexCliPath = Join-Path $fixtureRoot 'runtime\codex\current\codex.exe'
$packageResourcesRoot = Join-Path $fixtureRoot 'package-resources'
$nodeSource = [string](Get-Command node.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source)
New-Item -ItemType Directory -Force -Path @(
  $script:CodexHome,
  $localAppData,
  $scriptsRoot,
  $descriptorRoot,
  $hostRoot,
  $runtimeBin,
  (Join-Path $runtimeBin 'node_modules'),
  (Split-Path -Parent $codexCliPath),
  $packageResourcesRoot
) | Out-Null
Set-Content -LiteralPath $hostPath -Value 'fixture extension host' -Encoding ASCII
Set-Content -LiteralPath $browserClientPath -Value 'export const fixture = true;' -Encoding ASCII
Set-Content -LiteralPath $browserServicePath -Value 'export const fixtureService = true;' -Encoding ASCII
Set-Content -LiteralPath $codexCliPath -Value 'fixture codex' -Encoding ASCII
Copy-Item -LiteralPath $nodeSource -Destination $nodePath -Force
Set-Content -LiteralPath $nodeReplPath -Value 'fixture node repl' -Encoding ASCII
ConvertTo-JsonFile (Join-Path $descriptorRoot 'plugin.json') ([ordered]@{
  name = 'chrome'
  version = $chromeVersion
})
$extensionIds = @(
  'hehggadaopoacecdllhhajmbjkdcmajg',
  'odlomjlbamekndcpllcnffbgeohgkmjh'
)
ConvertTo-JsonFile (Join-Path $scriptsRoot 'extension-ids.json') ([ordered]@{
  extensionIds = $extensionIds
  extensionHostName = 'com.openai.codexextension'
  windowsNativeMessaging = [ordered]@{
    registryRoot = 'HKCU\Software\Google\Chrome\NativeMessagingHosts'
  }
})

$desktopManagedCodexCliPath = Join-Path $script:CodexHome 'plugins\.plugin-appserver\codex.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $desktopManagedCodexCliPath) | Out-Null
Copy-Item -LiteralPath $codexCliPath -Destination $desktopManagedCodexCliPath -Force

$runtimeInventory = [pscustomobject]@{
  CodexCliPath = $codexCliPath
  NodePath = $nodePath
  NodeReplPath = $nodeReplPath
  AllowedCodexCliPaths = @($codexCliPath)
  DesktopManagedCodexCliPaths = @($desktopManagedCodexCliPath)
  AllowedCuaBinRoots = @($runtimeBin)
  PackageResourcesRoot = $packageResourcesRoot
}

$previousLocalAppData = $env:LOCALAPPDATA
try {
  $env:LOCALAPPDATA = $localAppData
  $settings = Get-ChromeNativeMessagingSettings $chromeRoot
  ConvertTo-JsonFile $settings.ManifestPath ([ordered]@{
    allowed_origins = @($extensionIds | ForEach-Object { "chrome-extension://$_/" })
    description = 'ChatGPT browser native messaging host'
    name = $settings.HostName
    path = $hostPath
    type = 'stdio'
  })
  ConvertTo-JsonFile (Join-Path $hostRoot 'extension-host-config.json') ([ordered]@{
    schemaVersion = 1
    channel = 'prod'
    browserClientPath = $browserClientPath
    codexCliPath = $codexCliPath
    nodePath = $nodePath
    nodeReplPath = $nodeReplPath
    proxyHost = '127.0.0.1'
    proxyPort = 0
  })

  $staleEntry = [ordered]@{
    schemaVersion = 2
    appServerProtocolVersion = 2
    appVersion = '26.707.31428'
    channel = 'prod'
    cliVersion = '26.707.31428'
    entryId = 'codex-runtime-stale'
    extensionBuildChannels = @('prod')
    extensionIds = @($extensionIds[0])
    installId = 'codex-install-stale'
    nativeHostNames = @($settings.HostName)
    nativeHostProtocolVersion = 2
    nativeHostVersion = '26.707.31428'
    paths = [ordered]@{
      browserClientPath = 'D:\missing\browser-client.mjs'
      browserServicePath = 'D:\missing\browser-service.mjs'
      codexCliPath = 'D:\missing\codex.exe'
      codexHome = $script:CodexHome
      extensionHostPath = 'D:\missing\extension-host.exe'
      nodePath = 'D:\missing\node.exe'
      nodeModuleDirs = @('D:\missing\node_modules')
      nodeReplPath = 'D:\missing\node_repl.exe'
      resourcesPath = 'D:\missing\resources'
    }
    proxyHost = '127.0.0.1'
    proxyPort = 0
    updatedAt = '2026-07-10T04:59:25.190Z'
  }
  $statePaths = @(Get-ChromeNativeHostV2StatePaths $script:CodexHome)
  foreach ($statePath in $statePaths) {
    ConvertTo-JsonFile $statePath ([ordered]@{
      schemaVersion = 2
      entries = @($staleEntry)
    })
  }

  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  $expected = Get-ChromeNativeHostV2ExpectedResource $chromeRoot $runtimeInventory $script:CodexHome
  # pwsh 7 can materialize ISO timestamps as DateTime values during JSON round-trip;
  # the production schema must accept that representation without loosening other fields.
  $roundTripExpected = Copy-JsonValue $expected
  if (-not (Test-ChromeNativeHostV2EntrySchema $roundTripExpected)) {
    throw 'V2 schema rejected a JSON-round-tripped current entry (pwsh 7 timestamp compatibility)'
  }
  $roundTripUpdatedAt = $roundTripExpected.PSObject.Properties['updatedAt'].Value
  if ($roundTripUpdatedAt -isnot [string] -and $roundTripUpdatedAt -isnot [datetime] -and $roundTripUpdatedAt -isnot [datetimeoffset]) {
    throw "V2 JSON round-trip produced an unsupported updatedAt type: $($roundTripUpdatedAt.GetType().FullName)"
  }
  $roundTripPresence = $roundTripExpected.PSObject.Properties['presence']
  if ($null -ne $roundTripPresence) {
    foreach ($timestampName in @('lastSeenAt', 'startedAt')) {
      $timestampProperty = $roundTripPresence.Value.PSObject.Properties[$timestampName]
      if ($null -eq $timestampProperty -or
          ($timestampProperty.Value -isnot [string] -and
           $timestampProperty.Value -isnot [datetime] -and
           $timestampProperty.Value -isnot [datetimeoffset])) {
        throw "V2 JSON round-trip produced an unsupported presence.$timestampName type"
      }
    }
  }
  if ($expected.entryId -cnotmatch '^codex-runtime-[0-9a-f]{32}$' -or
      $expected.installId -cnotmatch '^codex-install-[0-9a-f]{32}$') {
    throw 'Current v2 resource did not use the official truncated SHA-256 identity format'
  }
  if ([string]$expected.paths.browserServicePath -cne $browserServicePath) {
    throw "Current v2 resource did not bind browserServicePath beside browserClientPath: actual=$($expected.paths.browserServicePath) expected=$browserServicePath"
  }
  if ($extensionIds.Count -ne 2) {
    throw "V2 identity fixture must contain exactly two independently hashed extension IDs: count=$($extensionIds.Count)"
  }
  $expectedEntryId = Get-IndependentV2Identity -Prefix 'codex-runtime-' -Fields @(
    $settings.HostName,
    $extensionIds[0],
    $extensionIds[1],
    'prod',
    $chromeVersion,
    $hostPath,
    $codexCliPath,
    $script:CodexHome,
    $packageResourcesRoot
  )
  if ([string]$expected.entryId -cne $expectedEntryId) {
    throw "V2 entryId did not hash each extension ID as an independent NUL-separated field: actual=$($expected.entryId) expected=$expectedEntryId"
  }
  $expectedInstallId = Get-IndependentV2Identity -Prefix 'codex-install-' -Fields @(
    $settings.HostName,
    $packageResourcesRoot,
    $script:CodexHome
  )
  if ([string]$expected.installId -cne $expectedInstallId) {
    throw "V2 installId did not hash each identity value as an independent NUL-separated field: actual=$($expected.installId) expected=$expectedInstallId"
  }

  $validOverlap = Copy-JsonValue $expected
  $validOverlap.entryId = 'codex-runtime-valid-overlap'
  if (-not (Test-ChromeNativeHostV2EntryReplacedBy $validOverlap $expected)) {
    throw 'A valid entry with the same install/channel and overlapping extension/host must be superseded'
  }
  $invalidOverlap = Copy-JsonValue $validOverlap
  $invalidOverlap.PSObject.Properties.Remove('updatedAt')
  if (Test-ChromeNativeHostV2EntryReplacedBy $invalidOverlap $expected) {
    throw 'The secondary supersede rule must preserve an invalid entry, matching the official Mq gate'
  }
  $invalidSameEntryId = Copy-JsonValue $invalidOverlap
  $invalidSameEntryId.entryId = $expected.entryId
  if (-not (Test-ChromeNativeHostV2EntryReplacedBy $invalidSameEntryId $expected)) {
    throw 'The primary same-entryId rule must remove an invalid entry without requiring the full Mq schema'
  }
  $disjointExtension = Copy-JsonValue $validOverlap
  $disjointExtension.extensionIds = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
  if (Test-ChromeNativeHostV2EntryReplacedBy $disjointExtension $expected) {
    throw 'The secondary supersede rule must require an overlapping extension ID'
  }
  $disjointHost = Copy-JsonValue $validOverlap
  $disjointHost.nativeHostNames = @('com.openai.otherextension')
  if (Test-ChromeNativeHostV2EntryReplacedBy $disjointHost $expected) {
    throw 'The secondary supersede rule must require an overlapping native host name'
  }

  $beforeHashes = @{}
  foreach ($statePath in $statePaths) {
    $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
    $currentEntries = @($document.entries | Where-Object { $_.entryId -ceq $expected.entryId })
    if ($currentEntries.Count -ne 1 -or @($document.entries).Count -ne 2) {
      throw "V2 repair did not preserve the stale entry and add exactly one current entry: $statePath"
    }
    $backupCount = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter "$(Split-Path -Leaf $statePath).*.bak" -File).Count
    if ($backupCount -ne 1) {
      throw "First v2 state replacement should create exactly one persistent backup: $statePath backups=$backupCount"
    }
    $currentEntries[0].updatedAt = '2026-08-18T13:39:12.300Z'
    $currentEntries[0].presence.lastSeenAt = '2026-08-18T13:39:12.300Z'
    $currentEntries[0].presence.startedAt = '2026-08-18T13:39:11.300Z'
    ConvertTo-JsonFile $statePath $document
    $beforeHashes[$statePath] = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
  }

  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  foreach ($statePath in $statePaths) {
    if ((Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash -cne $beforeHashes[$statePath]) {
      throw "Idempotent v2 repair rewrote an already-current state file: $statePath"
    }
    $backupCount = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter "$(Split-Path -Leaf $statePath).*.bak" -File).Count
    if ($backupCount -ne 1) {
      throw "Idempotent v2 repair created an unnecessary backup: $statePath backups=$backupCount"
    }
    $transientFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -File | Where-Object {
      $_.Name -like "$(Split-Path -Leaf $statePath).tmp-*" -or
      $_.Name -like "$(Split-Path -Leaf $statePath).replace-*.bak"
    })
    if ($transientFiles.Count -ne 0) {
      throw "V2 atomic replacement left transient files behind: $($transientFiles.FullName -join ',')"
    }
  }

  $desktopManagedResource = Get-ChromeNativeHostV2ExpectedResource `
    $chromeRoot $runtimeInventory $script:CodexHome -CodexCliPathOverride $desktopManagedCodexCliPath
  if ([string]$desktopManagedResource.paths.codexCliPath -cne $desktopManagedCodexCliPath) {
    throw 'The app-server path override did not reach the v2 entry paths'
  }
  if ([string]$desktopManagedResource.entryId -ceq [string]$expected.entryId) {
    throw 'A different app-server path must produce a different v2 entryId'
  }
  if ([string]$desktopManagedResource.installId -cne [string]$expected.installId) {
    throw 'The Desktop-managed app-server variant must keep the same v2 installId'
  }
  if (Test-ChromeNativeHostV2EntryCoreEqual $desktopManagedResource $expected) {
    throw 'The Desktop-managed app-server variant must not core-equal the preferred entry'
  }
  $acceptableResources = @(Get-ChromeNativeHostV2AcceptableResources $chromeRoot $runtimeInventory $script:CodexHome)
  if ($acceptableResources.Count -ne 2) {
    throw "Acceptable v2 resources must cover the preferred and Desktop-managed app-server paths: count=$($acceptableResources.Count)"
  }
  if ([string]$acceptableResources[0].entryId -cne [string]$expected.entryId) {
    throw 'The preferred v2 resource must stay first in the acceptable list'
  }

  # Desktop registers its own entry with the app-server copy it extracts under
  # CODEX_HOME\plugins\.plugin-appserver. Verification must accept that entry
  # instead of reporting a healthy install as missing, and repair must not keep
  # trading the entry back and forth with Desktop.
  foreach ($statePath in $statePaths) {
    ConvertTo-JsonFile $statePath ([ordered]@{
      schemaVersion = 2
      entries = @($staleEntry, (Copy-JsonValue $desktopManagedResource))
    })
  }
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  foreach ($statePath in $statePaths) {
    $desktopDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
    $keptEntries = @($desktopDocument.entries | Where-Object { $_.entryId -ceq $desktopManagedResource.entryId })
    if ($keptEntries.Count -ne 1) {
      throw "V2 repair replaced the Desktop-managed app-server entry: $statePath"
    }
    $preferredEntries = @($desktopDocument.entries | Where-Object { $_.entryId -ceq $expected.entryId })
    if ($preferredEntries.Count -ne 0) {
      throw "V2 repair added a duplicate entry for the same install: $statePath"
    }
  }
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome

  foreach ($statePath in $statePaths) {
    ConvertTo-JsonFile $statePath ([ordered]@{
      schemaVersion = 2
      entries = @($staleEntry)
    })
  }
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome

  $brokenStatePath = $statePaths[0]
  $brokenDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json
  $brokenEntry = @($brokenDocument.entries | Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  $brokenEntry.paths.nodePath = Join-Path $fixtureRoot 'missing-node.exe'
  ConvertTo-JsonFile $brokenStatePath $brokenDocument
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*has no current app-server entry*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome

  $brokenServiceDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json
  $brokenServiceEntry = @($brokenServiceDocument.entries | Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  $brokenServiceEntry.paths.browserServicePath = Join-Path $fixtureRoot 'missing-browser-service.mjs'
  ConvertTo-JsonFile $brokenStatePath $brokenServiceDocument
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*has no current app-server entry*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome

  $stringNumberDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json
  $stringNumberEntry = @($stringNumberDocument.entries | Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  $stringNumberEntry.schemaVersion = '2'
  $stringNumberEntry.appServerProtocolVersion = '2'
  $stringNumberEntry.nativeHostProtocolVersion = '2'
  $stringNumberEntry.proxyPort = '0'
  ConvertTo-JsonFile $brokenStatePath $stringNumberDocument
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*has no current app-server entry*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  $repairedNumberEntry = @((Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json).entries |
    Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  if ($repairedNumberEntry.schemaVersion -is [string] -or
      $repairedNumberEntry.appServerProtocolVersion -is [string] -or
      $repairedNumberEntry.nativeHostProtocolVersion -is [string] -or
      $repairedNumberEntry.proxyPort -is [string]) {
    throw 'V2 repair preserved JSON string values for native numeric fields'
  }

  $missingUpdatedDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json
  $missingUpdatedEntry = @($missingUpdatedDocument.entries | Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  $missingUpdatedEntry.PSObject.Properties.Remove('updatedAt')
  ConvertTo-JsonFile $brokenStatePath $missingUpdatedDocument
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*has no current app-server entry*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  $repairedUpdatedEntry = @((Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json).entries |
    Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  if (-not (Test-ChromeNativeHostV2TimestampValue $repairedUpdatedEntry.updatedAt)) {
    throw 'V2 repair did not restore required updatedAt'
  }

  $badPresenceDocument = Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json
  $badPresenceEntry = @($badPresenceDocument.entries | Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  $badPresenceEntry.presence.pid = 0
  $badPresenceEntry.presence.startedAt = ''
  ConvertTo-JsonFile $brokenStatePath $badPresenceDocument
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*has no current app-server entry*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  $repairedPresenceEntry = @((Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json).entries |
    Where-Object { $_.entryId -ceq $expected.entryId } | Select-Object -First 1)[0]
  if (-not (Test-ChromeNativeHostV2EntrySchema $repairedPresenceEntry)) {
    throw 'V2 repair did not replace an entry with invalid optional presence metadata'
  }

  $stringTopLevelSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $brokenStatePath | ConvertFrom-Json
  $stringTopLevelSchema.schemaVersion = '2'
  ConvertTo-JsonFile $brokenStatePath $stringTopLevelSchema
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*invalid schemaVersion or entries array*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome

  $badEntriesDocument = [ordered]@{
    schemaVersion = 2
    entries = [ordered]@{ entryId = $expected.entryId }
  }
  ConvertTo-JsonFile $brokenStatePath $badEntriesDocument
  Assert-ThrowsLike {
    Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  } '*invalid schemaVersion or entries array*'
  Update-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
  Test-ChromeNativeHostV2State $chromeRoot $runtimeInventory $script:CodexHome
} finally {
  $env:LOCALAPPDATA = $previousLocalAppData
}

Write-Output "Chrome native-host v2 state regression passed: $fixtureRoot"
