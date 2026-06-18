param(
  [switch]$DryRun,
  [switch]$Install,
  [switch]$Launch,
  [switch]$KeepWorkDir,
  [switch]$ForceRebuild,
  [switch]$InstallPrerequisites,
  [string]$ReplacementResourceCodexExe,
  [string]$OutputRoot = (Join-Path $env:TEMP 'codex-remote-control-msix-patch')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
  param([string]$Message)
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Fail {
  param([string]$Message)
  throw $Message
}

function Remove-DirectoryRobust {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$RequiredRoot
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
  $root = (Resolve-Path -LiteralPath $RequiredRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
  $comparison = [StringComparison]::OrdinalIgnoreCase
  if ($resolved.Equals($root, $comparison) -or -not $resolved.StartsWith($root + '\', $comparison)) {
    Fail "refusing to recursively delete outside safe root: $resolved"
  }
  try {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
  } catch {
    $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) {
      throw
    }
    $script = @'
const fs = require("node:fs");
const path = require("node:path");
const target = path.resolve(process.argv[2]);
const root = path.resolve(process.argv[3]);
if (target === root || !target.toLowerCase().startsWith(root.toLowerCase() + path.sep)) {
  throw new Error(`refusing to delete outside safe root: ${target}`);
}
fs.rmSync(target, { recursive: true, force: true, maxRetries: 20, retryDelay: 200 });
'@
    $tempScript = Join-Path $env:TEMP ('codex-remove-tree-' + [guid]::NewGuid().ToString() + '.js')
    Set-Content -LiteralPath $tempScript -Value $script -Encoding UTF8
    try {
      & $node.Source $tempScript $resolved $root
      if ($LASTEXITCODE -ne 0) {
        throw
      }
    } finally {
      Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-RequiredCommand {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    Fail "required command not found: $Name"
  }
  return $cmd.Source
}

function Test-BinaryContainsMarkers {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Markers,
    [string]$Label = 'binary'
  )
  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Fail "$Label not found: $FilePath"
  }
  $node = Get-RequiredCommand 'node'
  $script = @'
const fs = require('fs');
const file = process.argv[2];
const markers = process.argv.slice(3);
const bytes = fs.readFileSync(file);
const missing = markers.filter((marker) => !bytes.includes(Buffer.from(marker, 'utf8')));
if (missing.length > 0) {
  console.error(`missing markers in ${file}: ${missing.join(', ')}`);
  process.exit(2);
}
console.log(`binary markers ok: ${markers.length}`);
'@
  $tempScript = Join-Path $env:TEMP ('codex-binary-marker-check-' + [guid]::NewGuid().ToString() + '.js')
  Set-Content -LiteralPath $tempScript -Value $script -Encoding UTF8
  try {
    & $node $tempScript $FilePath @Markers
    if ($LASTEXITCODE -ne 0) {
      Fail "$Label marker check failed with exit code $LASTEXITCODE"
    }
  } finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
  }
}

function Find-WindowsSdkTool {
  param([string]$ToolName)
  $roots = @(
    (Join-Path $env:TEMP 'codex-remote-control-sdk-buildtools'),
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10\bin'),
    (Join-Path $env:USERPROFILE '.nuget\packages\microsoft.windows.sdk.buildtools')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  foreach ($root in $roots) {
    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $ToolName -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($hit) {
      return $hit.FullName
    }
  }
  return $null
}

function Install-WindowsSdkBuildToolsViaNuGet {
  $packageId = 'microsoft.windows.sdk.buildtools'
  $version = '10.0.26100.4188'
  $cacheRoot = Join-Path $env:TEMP 'codex-remote-control-sdk-buildtools'
  $packageRoot = Join-Path $cacheRoot "$packageId.$version"
  $x64Root = Join-Path $packageRoot 'bin'
  if ((Find-WindowsSdkTool 'makeappx.exe') -and (Find-WindowsSdkTool 'signtool.exe')) {
    return
  }
  if (Test-Path -LiteralPath $packageRoot) {
    Remove-DirectoryRobust -Path $packageRoot -RequiredRoot $cacheRoot
  }
  New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
  $nupkg = Join-Path $cacheRoot "$packageId.$version.nupkg"
  $zip = Join-Path $cacheRoot "$packageId.$version.zip"
  $url = "https://api.nuget.org/v3-flatcontainer/$packageId/$version/$packageId.$version.nupkg"
  if ((-not (Test-Path -LiteralPath $nupkg -PathType Leaf)) -or ((Get-Item -LiteralPath $nupkg).Length -lt 20000000)) {
    if (Test-Path -LiteralPath $nupkg -PathType Leaf) {
      Remove-Item -LiteralPath $nupkg -Force
    }
    Write-Log "downloading Windows SDK BuildTools from NuGet: $version"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curl) {
      & $curl.Source -L --proxy http://127.0.0.1:10808 --connect-timeout 30 --max-time 240 -o $nupkg $url
      if ($LASTEXITCODE -ne 0) {
        Fail "curl download failed with exit code $LASTEXITCODE"
      }
    } else {
      $oldProgress = $ProgressPreference
      try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -TimeoutSec 240 -Proxy 'http://127.0.0.1:10808'
      } finally {
        $ProgressPreference = $oldProgress
      }
    }
  } else {
    Write-Log "using existing Windows SDK BuildTools nupkg: $nupkg"
  }
  Copy-Item -LiteralPath $nupkg -Destination $zip -Force
  Expand-Archive -LiteralPath $zip -DestinationPath $packageRoot -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  if (-not (Get-ChildItem -LiteralPath $x64Root -Recurse -Filter 'makeappx.exe' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1)) {
    Fail "NuGet Windows SDK BuildTools did not provide makeappx.exe: $packageRoot"
  }
}

function Require-WindowsSdkTool {
  param([string]$ToolName)
  $tool = Find-WindowsSdkTool $ToolName
  if (-not $tool -and $InstallPrerequisites) {
    Install-WindowsSdkBuildToolsViaNuGet
    $tool = Find-WindowsSdkTool $ToolName
  }
  if (-not $tool) {
    Fail "$ToolName not found. Re-run with -InstallPrerequisites or install Windows SDK."
  }
  return $tool
}

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

function Update-CodexExeAsarIntegrity {
  param(
    [string]$ExePath,
    [string]$AsarHash
  )
  $bytes = [System.IO.File]::ReadAllBytes($ExePath)
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  $pattern = '\[\{"file":"resources\\\\app\.asar","alg":"SHA256","value":"([0-9a-fA-F]{64})"\}\]'
  $match = [regex]::Match($text, $pattern)
  if (-not $match.Success) {
    if ($text.Contains('app.asar')) {
      Fail 'could not find Electron ASAR integrity JSON inside Codex.exe'
    }
    Write-Log 'Codex.exe ASAR integrity JSON not present; skipping executable integrity update'
    return
  }
  $oldHash = $match.Groups[1].Value
  if ($oldHash -eq $AsarHash) {
    Write-Log "Codex.exe asar integrity already current: $AsarHash"
    return
  }
  $oldBytes = [System.Text.Encoding]::ASCII.GetBytes($oldHash)
  $newBytes = [System.Text.Encoding]::ASCII.GetBytes($AsarHash)
  $pos = -1
  for ($i = 0; $i -le $bytes.Length - $oldBytes.Length; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $oldBytes.Length; $j++) {
      if ($bytes[$i + $j] -ne $oldBytes[$j]) {
        $ok = $false
        break
      }
    }
    if ($ok) {
      $pos = $i
      break
    }
  }
  if ($pos -lt 0) {
    Fail 'could not locate ASAR integrity hash bytes in Codex.exe'
  }
  [Array]::Copy($newBytes, 0, $bytes, $pos, $newBytes.Length)
  [System.IO.File]::WriteAllBytes($ExePath, $bytes)
  Write-Log "updated Codex.exe asar integrity: $oldHash -> $AsarHash"
}

function Remove-OldPackageArtifacts {
  param([string]$WorkPackageRoot)
  foreach ($rel in @('AppxSignature.p7x', 'AppxBlockMap.xml', 'AppxMetadata\CodeIntegrity.cat')) {
    $path = Join-Path $WorkPackageRoot $rel
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }
}

function Get-ManifestPublisher {
  param([string]$WorkPackageRoot)
  [xml]$manifest = Get-Content -Raw -LiteralPath (Join-Path $WorkPackageRoot 'AppxManifest.xml')
  return $manifest.Package.Identity.Publisher
}

function Get-OrCreateSigningCertificate {
  param([string]$Publisher)
  $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Publisher } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
  if ($cert) {
    Write-Log "using existing signing certificate: $($cert.Thumbprint)"
    return $cert
  }
  Write-Log "creating signing certificate: $Publisher"
  return New-SelfSignedCertificate -Type CodeSigningCert -Subject $Publisher -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(5)
}

function Trust-SigningCertificate {
  param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
  $tempCert = Join-Path $env:TEMP ('codex-remote-control-signing-' + $Cert.Thumbprint + '.cer')
  Export-Certificate -Cert $Cert -FilePath $tempCert -Force | Out-Null
  Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\CurrentUser\TrustedPeople | Out-Null
  Remove-Item -LiteralPath $tempCert -Force -ErrorAction SilentlyContinue
}

function Stop-CodexDesktopProcesses {
  $processes = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\Codex.exe'
  }
  foreach ($p in $processes) {
    Write-Log "stopping Codex desktop process pid=$($p.Id)"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$patcher = Join-Path $PSScriptRoot 'patch-remote-control-asar.cjs'
if (-not (Test-Path -LiteralPath $patcher -PathType Leaf)) {
  Fail "patcher not found: $patcher"
}

$pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $pkg -or -not $pkg.InstallLocation) {
  Fail 'OpenAI.Codex package not found'
}

$sourceRoot = $pkg.InstallLocation
$sourceAsar = Join-Path $sourceRoot 'app\resources\app.asar'
$sourceCodexExe = Join-Path $sourceRoot 'app\Codex.exe'
$sourceResourceCodexExe = Join-Path $sourceRoot 'app\resources\codex.exe'
if (-not (Test-Path -LiteralPath $sourceAsar -PathType Leaf)) {
  Fail "app.asar not found: $sourceAsar"
}
if (-not (Test-Path -LiteralPath $sourceCodexExe -PathType Leaf)) {
  Fail "Codex.exe not found: $sourceCodexExe"
}
if ($ReplacementResourceCodexExe -and -not (Test-Path -LiteralPath $sourceResourceCodexExe -PathType Leaf)) {
  Fail "bundled resource codex.exe not found: $sourceResourceCodexExe"
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$workRoot = Join-Path $OutputRoot ("work-" + $pkg.Version + "-" + $stamp)
$workPackageRoot = Join-Path $workRoot 'package'
$asarDir = Join-Path $workRoot 'app-asar'
$npxCache = Join-Path $workRoot 'npm-cache'
$msixPath = Join-Path $OutputRoot ("OpenAI.Codex_" + $pkg.Version + "_remote-control-patched.msix")
$scriptSucceeded = $false
$installedSuccessfully = $false

if ((Test-Path -LiteralPath $workRoot) -and $ForceRebuild) {
  Remove-DirectoryRobust -Path $workRoot -RequiredRoot $OutputRoot
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

try {
  Write-Log "package: $($pkg.PackageFullName)"
  Write-Log "copying package layout to: $workPackageRoot"
  & robocopy.exe $sourceRoot $workPackageRoot /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -gt 7) {
    Fail "robocopy failed with exit code $LASTEXITCODE"
  }

  Remove-OldPackageArtifacts $workPackageRoot

  $workAsar = Join-Path $workPackageRoot 'app\resources\app.asar'
  $workCodexExe = Join-Path $workPackageRoot 'app\Codex.exe'
  $workResourceCodexExe = Join-Path $workPackageRoot 'app\resources\codex.exe'
  $npx = Get-RequiredCommand 'npx'
  if (Test-Path -LiteralPath $asarDir) {
    Remove-DirectoryRobust -Path $asarDir -RequiredRoot $workRoot
  }

  Write-Log "extracting ASAR"
  & $npx --yes --cache $npxCache asar extract $workAsar $asarDir
  if ($LASTEXITCODE -ne 0) {
    Fail "npx asar extract failed with exit code $LASTEXITCODE"
  }

  Write-Log "patching remote-control Electron bundles"
  $patchResult = & node $patcher $asarDir
  if ($LASTEXITCODE -ne 0) {
    Fail "remote-control ASAR patcher failed with exit code $LASTEXITCODE"
  }
  $patchResult | Write-Host
  $patchInfo = $patchResult | ConvertFrom-Json

  Write-Log "checking patched JS syntax"
  $mainFile = [string]$patchInfo.mainFile
  $mobileFiles = @()
  if ($patchInfo.PSObject.Properties.Name -contains 'mobileSetupNoAuthRedirectFiles') {
    foreach ($entry in @($patchInfo.mobileSetupNoAuthRedirectFiles)) {
      $entryFile = [string]$entry.file
      if (-not [string]::IsNullOrWhiteSpace($entryFile)) {
        $mobileFiles += $entryFile
      }
    }
  }
  if ($mobileFiles.Count -eq 0) {
    $mobileFile = [string]$patchInfo.mobileSetupNoAuthRedirectFile
    if ([string]::IsNullOrWhiteSpace($mobileFile)) {
      $mobileFile = [string]$patchInfo.mobileSetupFile
    }
    if (-not [string]::IsNullOrWhiteSpace($mobileFile)) {
      $mobileFiles += $mobileFile
    }
  }
  $mobileFlowFile = [string]$patchInfo.mobileSetupFlowFile
  $remoteConnectionsSettingsFile = [string]$patchInfo.remoteConnectionsSettingsFile
  if (-not (Test-Path -LiteralPath $mainFile -PathType Leaf)) {
    Fail "patched main file missing: $mainFile"
  }
  if ($mobileFiles.Count -eq 0) {
    Fail "patched mobile setup file missing from patcher result"
  }
  foreach ($mobileFile in $mobileFiles) {
    if (-not (Test-Path -LiteralPath $mobileFile -PathType Leaf)) {
      Fail "patched mobile setup file missing: $mobileFile"
    }
  }
  if (-not (Test-Path -LiteralPath $mobileFlowFile -PathType Leaf)) {
    Fail "patched mobile setup flow file missing: $mobileFlowFile"
  }
  if (-not (Test-Path -LiteralPath $remoteConnectionsSettingsFile -PathType Leaf)) {
    Fail "patched remote connections settings file missing: $remoteConnectionsSettingsFile"
  }
  $mainText = Get-Content -LiteralPath $mainFile -Raw
  $mobileTexts = @()
  foreach ($mobileFile in $mobileFiles) {
    $mobileTexts += [pscustomobject]@{
      Path = $mobileFile
      Text = Get-Content -LiteralPath $mobileFile -Raw
    }
  }
  $mobileFlowText = Get-Content -LiteralPath $mobileFlowFile -Raw
  $remoteConnectionsSettingsText = Get-Content -LiteralPath $remoteConnectionsSettingsFile -Raw
  if (-not $mainText.Contains('remote_control_desktop_fetch_override_used')) {
    Fail 'patched main marker missing'
  }
  if (-not $mainText.Contains('remote_control_appserver_bh_isolated_auth_fallback')) {
    Fail 'patched main app-server auth fallback marker missing'
  }
  if (-not $mainText.Contains('remote_control_connection_auth_fallback_used')) {
    Fail 'patched main connection auth fallback helper marker missing'
  }
  foreach ($mobileItem in $mobileTexts) {
    if (-not $mobileItem.Text.Contains('remote_control_mobile_setup_no_auth_redirect')) {
      Fail "patched mobile setup marker missing: $($mobileItem.Path)"
    }
  }
  if (-not $mobileFlowText.Contains('remote_control_mobile_setup_authorize_before_enable')) {
    Fail 'patched mobile setup flow marker missing'
  }
  if (-not $remoteConnectionsSettingsText.Contains('remote_control_settings_force_control_this_pc_visible')) {
    Fail 'patched remote connections settings visibility marker missing'
  }
  if (-not $remoteConnectionsSettingsText.Contains('remote_control_settings_force_remote_control_section_visible')) {
    Fail 'patched remote connections remote-control section visibility marker missing'
  }
  & node --check $mainFile
  if ($LASTEXITCODE -ne 0) {
    Fail "node --check failed for $mainFile"
  }
  foreach ($mobileFile in ($mobileFiles | Select-Object -Unique)) {
    & node --check $mobileFile
    if ($LASTEXITCODE -ne 0) {
      Fail "node --check failed for $mobileFile"
    }
  }
  & node --check $mobileFlowFile
  if ($LASTEXITCODE -ne 0) {
    Fail "node --check failed for $mobileFlowFile"
  }
  & node --check $remoteConnectionsSettingsFile
  if ($LASTEXITCODE -ne 0) {
    Fail "node --check failed for $remoteConnectionsSettingsFile"
  }

  foreach ($mobileItem in $mobileTexts) {
    if (
      $mobileItem.Text.Contains('e.status===401?(J(),new Se(') -or
      $mobileItem.Text.Contains('e.status===401?(v(),new C(')
    ) {
      Fail "mobile setup forced ChatGPT auth redirect still present: $($mobileItem.Path)"
    }
  }

  Write-Log "packing patched ASAR"
  & $npx --yes --cache $npxCache asar pack $asarDir $workAsar
  if ($LASTEXITCODE -ne 0) {
    Fail "npx asar pack failed with exit code $LASTEXITCODE"
  }

  $asarHash = Get-AsarHeaderSha256 $workAsar
  Update-CodexExeAsarIntegrity -ExePath $workCodexExe -AsarHash $asarHash

  if ($ReplacementResourceCodexExe) {
    $replacement = (Resolve-Path -LiteralPath $ReplacementResourceCodexExe -ErrorAction Stop).ProviderPath
    $resourceMarkers = @(
      'remote_control_app_server_isolated_oauth_used',
      'remote_control_native_remote_json_first',
      'remote_control_websocket_proxy_attempt',
      'remote_control_websocket_proxy_connected',
      'remote-control-oauth.json',
      'remote.json',
      'codex.remote_control.enroll'
    )
    Write-Log "validating replacement resources\codex.exe: $replacement"
    Test-BinaryContainsMarkers -FilePath $replacement -Markers $resourceMarkers -Label 'replacement resources\codex.exe'
    if (-not (Test-Path -LiteralPath $workResourceCodexExe -PathType Leaf)) {
      Fail "work package resources\codex.exe not found: $workResourceCodexExe"
    }
    $originalBackup = Join-Path $workRoot 'codex.exe.original'
    Copy-Item -LiteralPath $workResourceCodexExe -Destination $originalBackup -Force
    Copy-Item -LiteralPath $replacement -Destination $workResourceCodexExe -Force
    Test-BinaryContainsMarkers -FilePath $workResourceCodexExe -Markers $resourceMarkers -Label 'work package resources\codex.exe'
    $copied = Get-Item -LiteralPath $workResourceCodexExe
    Write-Log "replaced app\resources\codex.exe; bytes=$($copied.Length); original backup=$originalBackup"
  }

  if ($DryRun) {
    Write-Log "dry run complete; patched package root validated at: $workPackageRoot"
    Write-Log "dry run markers: remote_control_desktop_fetch_override_used, remote_control_appserver_bh_isolated_auth_fallback, remote_control_mobile_setup_no_auth_redirect, remote_control_mobile_setup_authorize_before_enable, remote_control_settings_force_control_this_pc_visible, remote_control_settings_force_remote_control_section_visible"
    $scriptSucceeded = $true
    return
  }

  $makeappx = Require-WindowsSdkTool 'makeappx.exe'
  $signtool = Require-WindowsSdkTool 'signtool.exe'
  $publisher = Get-ManifestPublisher $workPackageRoot
  $cert = Get-OrCreateSigningCertificate $publisher
  Trust-SigningCertificate $cert

  if (Test-Path -LiteralPath $msixPath) {
    Remove-Item -LiteralPath $msixPath -Force
  }
  Write-Log "packing MSIX: $msixPath"
  & $makeappx pack /d $workPackageRoot /p $msixPath /o
  if ($LASTEXITCODE -ne 0) {
    Fail "makeappx pack failed with exit code $LASTEXITCODE"
  }
  Write-Log 'signing MSIX'
  & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $msixPath
  if ($LASTEXITCODE -ne 0) {
    Fail "signtool sign failed with exit code $LASTEXITCODE"
  }

  if ($Install) {
    Stop-CodexDesktopProcesses
    $existing = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
      Write-Log "removing existing package: $($existing.PackageFullName)"
      try {
        Remove-AppxPackage -Package $existing.PackageFullName -PreserveApplicationData -ErrorAction Stop
      } catch {
        Write-Log 'PreserveApplicationData unsupported; retrying normal Remove-AppxPackage'
        Remove-AppxPackage -Package $existing.PackageFullName -ErrorAction Stop
      }
    }
    Write-Log "installing patched MSIX: $msixPath"
    Add-AppxPackage -Path $msixPath -ErrorAction Stop
    $installed = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
    Write-Log "installed package: $($installed.PackageFullName)"
    $installedSuccessfully = $true
    if ($Launch) {
      $exe = Join-Path $installed.InstallLocation 'app\Codex.exe'
      Write-Log "launching Codex: $exe"
      Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    }
  } else {
    Write-Log "patched MSIX ready: $msixPath"
  }
  $scriptSucceeded = $true
} finally {
  if ($KeepWorkDir -or -not $scriptSucceeded) {
    Write-Log "keeping workdir: $workRoot"
  } elseif (Test-Path -LiteralPath $workRoot) {
    try {
      Remove-DirectoryRobust -Path $workRoot -RequiredRoot $OutputRoot
    } catch {
      Write-Log "warning: cleanup failed, leaving workdir for inspection: $workRoot ($($_.Exception.Message))"
    }
  }
  if ($installedSuccessfully -and -not $KeepWorkDir -and (Test-Path -LiteralPath $msixPath -PathType Leaf)) {
    try {
      Remove-Item -LiteralPath $msixPath -Force -ErrorAction Stop
      Write-Log "removed installed patched MSIX artifact: $msixPath"
    } catch {
      Write-Log "warning: could not remove installed patched MSIX artifact: $msixPath ($($_.Exception.Message))"
    }
  }
  $sdkCacheRoot = Join-Path $env:TEMP 'codex-remote-control-sdk-buildtools'
  if ($installedSuccessfully -and -not $KeepWorkDir -and (Test-Path -LiteralPath $sdkCacheRoot)) {
    try {
      Remove-DirectoryRobust -Path $sdkCacheRoot -RequiredRoot $env:TEMP
      Write-Log "removed temporary Windows SDK BuildTools cache: $sdkCacheRoot"
    } catch {
      Write-Log "warning: could not remove temporary Windows SDK BuildTools cache: $sdkCacheRoot ($($_.Exception.Message))"
    }
  }
}
