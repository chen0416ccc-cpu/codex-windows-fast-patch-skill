param([Parameter(Mandatory = $true)][string]$TemporaryRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\msix-safe-install.ps1')
New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null
$root = Join-Path $TemporaryRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
  $caught = $null
  try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
  Assert ($caught -and $caught -match $Pattern) "expected failure '$Pattern', got '$caught'"
}
function Write-Log([string]$Message) { Write-Host "[safe-msix-test] $Message" }
function New-Fixture([string]$Name, [string]$Version, [bool]$Services = $true) {
  $dir = Join-Path $root $Name
  New-Item -ItemType Directory -Path $dir | Out-Null
  $service = if ($Services) { '<Extensions><Extension Category="windows.service" /></Extensions>' } else { '' }
  $xml = '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="OpenAI.Codex" Publisher="CN=fixture" ProcessorArchitecture="x64" Version="' + $Version + '" />' + $service + '</Package>'
  [IO.File]::WriteAllText((Join-Path $dir 'AppxManifest.xml'), $xml)
  $zip = Join-Path $root ($Name + '.msix')
  [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
  return $zip
}
$target = New-Fixture 'target' '26.917.9434.1'
$same = New-Fixture 'same' '26.917.9434.0'
$ordinary = New-Fixture 'ordinary' '26.917.9434.1' $false
$recovery = New-Fixture 'recovery' '26.917.9434.2'
$info = Get-MsixManifestInfo $target
Assert ($info.RequiresAdministrator -and $info.Version -eq [version]'26.917.9434.1') 'service manifest detection'
Assert (-not (Get-MsixManifestInfo $ordinary).RequiresAdministrator) 'ordinary manifests remain unelevated-compatible'
$manifestPath = Join-Path $root 'same\AppxManifest.xml'
$version = Set-MsixUpdateVersion $manifestPath
[xml]$changed = Get-Content -LiteralPath $manifestPath -Raw
Assert ($version -eq [version]'26.917.9434.1') 'version increment'
Assert ($changed.Package.Identity.Publisher -eq 'CN=fixture') 'publisher preserved'
Assert (@($changed.SelectNodes('//*[local-name()="Extension" and @Category="windows.service"]')).Count -eq 1) 'service declaration preserved'
Assert ((Set-MsixUpdateVersion $manifestPath -MinimumVersion '26.917.9434.7') -eq [version]'26.917.9434.8') 'higher version floor'
Expect-Failure { Set-MsixUpdateVersion $manifestPath -MinimumVersion '26.917.9434.65535' } 'Cannot increment'

$script:admin = $false
$script:signatureValid = $true
$script:addCalls = 0
$script:failDeployment = $false
$script:wrongResult = $false
$script:current = [pscustomobject]@{
  Name='OpenAI.Codex'; Publisher='CN=fixture'; Architecture='X64'; Version=[version]'26.917.9434.0'
  PackageFullName='original-package'; InstallLocation='C:\fixture\original'
}
function Test-MsixAdministrator { return $script:admin }
function Get-AuthenticodeSignature {
  param([string]$LiteralPath)
  [pscustomobject]@{Status=if($script:signatureValid){'Valid'}else{'HashMismatch'};SignerCertificate=[pscustomobject]@{Subject='CN=fixture'}}
}
function Get-AppxPackage { param($Name,$ErrorAction); return $script:current }
$script:ancestorPath='C:\fixture\original\app\ChatGPT.exe'
function Get-CimInstance {
  param($ClassName,$Filter,$ErrorAction)
  if($Filter -eq "ProcessId=$PID") {
    return [pscustomobject]@{ExecutablePath='C:\fixture\pwsh.exe';ParentProcessId=1000001}
  }
  return [pscustomobject]@{ExecutablePath=$script:ancestorPath;ParentProcessId=0}
}
Expect-Failure {Assert-MsixExternalExecutor $script:current} 'outside the Codex process tree'
$script:ancestorPath='C:\Program Files\WindowsApps\OpenAI.Codex_26.908.9136.0_x64__fixture\app\ChatGPT.exe'
Expect-Failure {Assert-MsixExternalExecutor $script:current} 'outside the Codex process tree'
Expect-Failure {Assert-MsixExternalExecutor $null} 'outside the Codex process tree'
$script:ancestorPath='C:\Windows\System32\wbem\WmiPrvSE.exe'
Assert-MsixExternalExecutor $script:current
Assert $true 'independent external executor accepted'
function Assert-MsixExternalExecutor { param($ExistingPackage) }
function Add-AppxPackage {
  param($Path,[switch]$ForceApplicationShutdown,$ErrorAction)
  $script:addCalls++
  Assert ([bool]$ForceApplicationShutdown) 'shutdown belongs to the transactional deployment'
  if($script:failDeployment){throw 'synthetic deployment failure'}
  $resultVersion=if($script:wrongResult){[version]'26.917.9434.3'}else{(Get-MsixManifestInfo $Path).Version}
  $script:current=[pscustomobject]@{
    Name='OpenAI.Codex'; Publisher='CN=fixture'; Architecture='X64'
    Version=$resultVersion
    PackageFullName="updated-package-$resultVersion"; InstallLocation='C:\fixture\updated'
  }
}
Expect-Failure { Invoke-TransactionalMsixInstall $target } 'packaged services'
Assert ($script:addCalls -eq 0 -and $script:current.PackageFullName -eq 'original-package') 'non-admin failure leaves installed package untouched'
$script:admin=$true
$script:signatureValid=$false
Expect-Failure { Invoke-TransactionalMsixInstall $target } 'signature is invalid'
Assert ($script:addCalls -eq 0) 'invalid signature never deploys'
$script:signatureValid=$true
Expect-Failure { Invoke-TransactionalMsixInstall $same } 'higher package version'
Assert ($script:addCalls -eq 0) 'equal version never triggers uninstall or deployment'
$script:current.Publisher='CN=other'
Expect-Failure { Invoke-TransactionalMsixInstall $target } 'publisher or architecture'
$script:current.Publisher='CN=fixture'
$script:current.Architecture='Arm64'
Expect-Failure { Invoke-TransactionalMsixInstall $target } 'publisher or architecture'
$script:current.Architecture='X64'
$script:failDeployment=$true
Expect-Failure { Invoke-TransactionalMsixInstall $target } 'synthetic deployment failure'
Assert ($script:current.PackageFullName -eq 'original-package') 'failed update keeps original registration'
$script:failDeployment=$false
$installed=Invoke-TransactionalMsixInstall $target
Assert ($installed.Version -eq [version]'26.917.9434.1') 'successful update identity'
$script:current.Version=[version]'26.917.9434.0'
$script:wrongResult=$true
Expect-Failure { Invoke-TransactionalMsixInstall $target } 'expected package identity'
$script:wrongResult=$false
$script:current.Version=[version]'26.917.9434.0'
$script:current.PackageFullName='original-package'
$before=$script:addCalls
$outcome=Invoke-RecoverableMsixInstall $target $recovery -ValidateInstalledPackage {
  param($package)
  if($package.Version -eq [version]'26.917.9434.1'){throw 'synthetic startup failure'}
}
Assert (-not $outcome.Success -and $outcome.Recovered) 'failed startup reports recovery instead of success'
Assert ($outcome.Package.Version -eq [version]'26.917.9434.2') 'prepared higher-revision recovery is deployed'
Assert ($script:addCalls -eq $before+2) 'one update and one recovery, without retry loops'
$script:current.Version=[version]'26.917.9434.0'
$script:current.PackageFullName='original-package'
$script:failDeployment=$true
$before=$script:addCalls
$outcome=Invoke-RecoverableMsixInstall $target $recovery -ValidateInstalledPackage {param($package)}
Assert (-not $outcome.Success -and $outcome.Recovered -and $outcome.Package.PackageFullName -eq 'original-package') 'deployment failure retains and validates the original package'
Assert ($script:addCalls -eq $before+1) 'no recovery deployment when the original remains registered'
$script:failDeployment=$false
$before=$script:addCalls
Expect-Failure {Invoke-RecoverableMsixInstall $target $target -ValidateInstalledPackage {param($package)}} 'Recovery must be validated'
Assert ($script:addCalls -eq $before) 'invalid recovery is rejected before changing the app'

foreach($name in @('patch_codex_fast_mode_windows_msix.ps1','patch-dynamic-tools-windows-msix.ps1','patch-remote-control-windows-msix.ps1')) {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
  Assert ($errors.Count -eq 0) "$name parses"
  $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object {$_.GetCommandName()})
  Assert ($commands -notcontains 'Remove-AppxPackage') "$name never removes the registered package"
  Assert ($commands -notcontains 'Stop-CodexDesktopProcesses') "$name never stops Desktop before deployment preflight"
  Assert ($commands -contains 'Invoke-TransactionalMsixInstall') "$name uses shared guarded deployment"
  Assert ($commands -contains 'Set-MsixUpdateVersion') "$name builds a distinct update identity"
}
Write-Output "SAFE_MSIX_TESTS_PASSED checks=$script:checks fixtures=$root"
