param(
  [Parameter(Mandatory = $true)][string]$OriginalService,
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [string]$OtherSupportedService
)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$installer=Join-Path $PSScriptRoot 'install-computer-use-local.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Installer parse failed.'}
foreach($name in @('Get-ChromeHeaderCompatibilityServicePaths','Invoke-ChromeHeaderCompatibility')) {
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
  if(-not $definition){throw "Missing function: $name"}
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-Log([string]$Message) { Write-Host "[header-cache-test] $Message" }
$script:checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Expect-Failure([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action | Out-Null}catch{$message=$_.Exception.Message};Assert ($message -and $message -match $Pattern) "Expected '$Pattern'; got '$message'"}
New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null
$root=Join-Path $TemporaryRoot ([guid]::NewGuid().ToString('N'))
$fixtureHome=Join-Path $root 'home'
$marketplace=Join-Path $root 'marketplace'
$installed=Join-Path $root 'installed'
$version='26.917.71314'
foreach($plugin in @('browser','chrome')) {
  $descriptor=Join-Path $installed "plugins\$plugin\.codex-plugin\plugin.json"
  New-Item -ItemType Directory -Path (Split-Path -Parent $descriptor) -Force | Out-Null
  [IO.File]::WriteAllText($descriptor,('{"name":"'+$plugin+'","version":"'+$version+'"}'))
  $sourceScripts=Join-Path $installed "plugins\$plugin\scripts"
  New-Item -ItemType Directory -Path $sourceScripts -Force | Out-Null
  Copy-Item -LiteralPath $OriginalService -Destination (Join-Path $sourceScripts 'browser-service.mjs')
  foreach($base in @((Join-Path $marketplace "plugins\$plugin"),(Join-Path $fixtureHome "plugins\cache\openai-bundled\$plugin\$version"),(Join-Path $root "openai-bundled-cache\$plugin\$version"),(Join-Path $fixtureHome ".tmp\bundled-marketplaces\openai-bundled\plugins\$plugin"))) {
    $scripts=Join-Path $base 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath $OriginalService -Destination (Join-Path $scripts 'browser-service.mjs')
    [IO.File]::WriteAllText((Join-Path $scripts 'browser-client.mjs'),'client must remain unchanged')
  }
}
$config=Join-Path $fixtureHome 'config.toml'
[IO.File]::WriteAllText($config,'model_provider = "untouched"')
$optional=Join-Path $marketplace 'plugins\sites\scripts\browser-service.mjs'
New-Item -ItemType Directory -Path (Split-Path -Parent $optional) -Force | Out-Null
[IO.File]::WriteAllText($optional,'optional plugin must remain unchanged')
$originalHash=(Get-FileHash -LiteralPath $OriginalService -Algorithm SHA256).Hash
$node=(Get-Command node.exe -ErrorAction Stop).Source
$patcher=Join-Path $PSScriptRoot 'patch-chrome-custom-provider-headers.cjs'
$pathOptions=@{CodexHomeRoot=$fixtureHome;MarketplaceRoot=$marketplace;InstalledMarketplaceRoot=$installed;NodePath=$node;PatcherPath=$patcher}
$paths=@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions)
Assert ($paths.Count -eq 8) 'Expected exactly browser/chrome copies in four existing roots.'
$invokeOptions=@{ServicePaths=$paths;NodePath=$node;PatcherPath=$patcher;BackupRoot=(Join-Path $root 'backups')}
Expect-Failure {Invoke-ChromeHeaderCompatibility @invokeOptions -VerifyOnly} 'missing custom-provider'
Assert (@($paths | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'VerifyOnly changed a service.'
[IO.File]::WriteAllText($paths[-1],'unknown service version')
Expect-Failure {Get-ChromeHeaderCompatibilityServicePaths @pathOptions} 'differs from supported package profile'
Expect-Failure {Invoke-ChromeHeaderCompatibility @invokeOptions} 'preflight failed'
Assert (@($paths[0..6] | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'Batch preflight modified earlier files before rejecting an unknown file.'
Copy-Item -LiteralPath $OriginalService -Destination $paths[-1] -Force
if($OtherSupportedService) {
  Assert ((Get-FileHash -LiteralPath $OtherSupportedService -Algorithm SHA256).Hash -ne $originalHash) 'Cross-profile fixture must have a different source hash.'
  Copy-Item -LiteralPath $OtherSupportedService -Destination $paths[-1] -Force
  Expect-Failure {Get-ChromeHeaderCompatibilityServicePaths @pathOptions} 'differs from supported package profile'
  Assert (@($paths[0..6] | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'Cross-profile rejection changed another copy.'
  Copy-Item -LiteralPath $OriginalService -Destination $paths[-1] -Force
}
$packagedServices=@('browser','chrome' | ForEach-Object {Join-Path $installed "plugins\$_\scripts\browser-service.mjs"})
[IO.File]::WriteAllText($packagedServices[1],'future official browser service')
Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 4) 'One unsupported package source must not hide the supported plugin.'
[IO.File]::WriteAllText($packagedServices[0],'future official browser service')
Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 0) 'Unknown official versions must skip only the overlay.'
Assert (@($paths | Where-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash -ne $originalHash}).Count -eq 0) 'Unknown-source probe modified cache files.'
foreach($source in $packagedServices){Copy-Item -LiteralPath $OriginalService -Destination $source -Force}
$results=@(Invoke-ChromeHeaderCompatibility @invokeOptions)
Assert ($results.Count -eq 8) 'Not every expected cache copy was patched.'
Assert (@(Get-ChromeHeaderCompatibilityServicePaths @pathOptions).Count -eq 8) 'Complete patched copies must match their package profile.'
Invoke-ChromeHeaderCompatibility @invokeOptions -VerifyOnly | Out-Null
$count=@(Get-ChildItem -LiteralPath (Join-Path $root 'backups') -File).Count
Assert ($count -eq 8) 'Each modified copy must have an original backup.'
Invoke-ChromeHeaderCompatibility @invokeOptions | Out-Null
Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'backups') -File).Count -eq $count) 'Idempotent apply created extra backups.'
Assert ((Get-Content -LiteralPath $config -Raw) -eq 'model_provider = "untouched"') 'Config was modified.'
Assert ((Get-Content -LiteralPath $optional -Raw) -eq 'optional plugin must remain unchanged') 'Optional plugin was modified.'
foreach($service in $paths){Assert ((Get-Content -LiteralPath (Join-Path (Split-Path -Parent $service) 'browser-client.mjs') -Raw) -eq 'client must remain unchanged') 'Trusted client bytes changed.'}
Write-Output "CHROME_HEADER_CACHE_SCOPE_PASSED checks=$script:checks root=$root"
