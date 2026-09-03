param(
  [switch]$DryRun,
  [switch]$Install,
  [switch]$Launch,
  [switch]$KeepWorkDir,
  [switch]$InstallPrerequisites,
  [string]$OutputRoot = (Join-Path $env:TEMP 'codex-dynamic-tools-msix-patch')
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-dynamic-tools-msix]'
$WindowsSdkBuildToolsPackageId = 'microsoft.windows.sdk.buildtools'
$WindowsSdkBuildToolsVersion = '10.0.26100.7705'
$InstalledWindowsSdkViaNuGet = $false

function Write-Log([string]$Message) {
  Write-Host "$LogPrefix $Message"
}

function Fail([string]$Message) {
  throw "$LogPrefix error: $Message"
}

function Get-RequiredCommand([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    Fail "required command not found: $Name"
  }
  return $cmd.Source
}

function Remove-DirectoryRobust {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$RequiredRoot
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  if (-not (Test-Path -LiteralPath $RequiredRoot)) {
    Fail "safe deletion root does not exist: $RequiredRoot"
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
    $longPath = '\\?\' + $resolved
    [System.IO.Directory]::Delete($longPath, $true)
  }
}

function Find-WindowsSdkTool([string]$ToolName) {
  $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) {
    return $cmd.Source
  }
  $roots = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10\bin'),
    (Join-Path $OutputRoot 'sdk-buildtools')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  foreach ($root in $roots) {
    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $ToolName -File -ErrorAction SilentlyContinue |
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
  if ((Find-WindowsSdkTool 'makeappx.exe') -and (Find-WindowsSdkTool 'signtool.exe')) {
    return
  }
  $cacheRoot = Join-Path $OutputRoot 'sdk-buildtools'
  $packageRoot = Join-Path $cacheRoot $WindowsSdkBuildToolsVersion
  $x64Root = Join-Path $packageRoot 'bin'
  if (Test-Path -LiteralPath $packageRoot) {
    Remove-DirectoryRobust -Path $packageRoot -RequiredRoot $cacheRoot
  }
  New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
  $packageId = $WindowsSdkBuildToolsPackageId.ToLowerInvariant()
  $nupkg = Join-Path $cacheRoot "$packageId.$WindowsSdkBuildToolsVersion.nupkg"
  $zip = Join-Path $cacheRoot "$packageId.$WindowsSdkBuildToolsVersion.zip"
  $url = "https://api.nuget.org/v3-flatcontainer/$packageId/$WindowsSdkBuildToolsVersion/$packageId.$WindowsSdkBuildToolsVersion.nupkg"
  Write-Log "downloading Windows SDK BuildTools to $cacheRoot"
  $oldProgress = $ProgressPreference
  try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -TimeoutSec 240
  } finally {
    $ProgressPreference = $oldProgress
  }
  Copy-Item -LiteralPath $nupkg -Destination $zip -Force
  Expand-Archive -LiteralPath $zip -DestinationPath $packageRoot -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  $makeappx = Get-ChildItem -LiteralPath $x64Root -Recurse -Filter 'makeappx.exe' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Select-Object -First 1
  $signtool = Get-ChildItem -LiteralPath $x64Root -Recurse -Filter 'signtool.exe' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Select-Object -First 1
  if (-not $makeappx -or -not $signtool) {
    Fail "NuGet Windows SDK BuildTools did not provide required x64 MSIX tools: $packageRoot"
  }
  $script:InstalledWindowsSdkViaNuGet = $true
}

function Require-WindowsSdkTool([string]$ToolName) {
  $tool = Find-WindowsSdkTool $ToolName
  if (-not $tool -and $InstallPrerequisites) {
    Install-WindowsSdkBuildToolsViaNuGet
    $tool = Find-WindowsSdkTool $ToolName
  }
  if (-not $tool) {
    Fail "$ToolName not found. Re-run with -InstallPrerequisites."
  }
  return $tool
}

. (Join-Path $PSScriptRoot 'lib\asar-integrity.ps1')
. (Join-Path $PSScriptRoot 'lib\appx-launch.ps1')

function Get-OrCreateSigningCertificate([string]$Publisher) {
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

function Trust-SigningCertificate($Cert) {
  $tempCert = Join-Path $OutputRoot ('codex-msix-signing-' + $Cert.Thumbprint + '.cer')
  Export-Certificate -Cert $Cert -FilePath $tempCert -Force | Out-Null
  Import-Certificate -FilePath $tempCert -CertStoreLocation Cert:\CurrentUser\TrustedPeople | Out-Null
  Remove-Item -LiteralPath $tempCert -Force -ErrorAction SilentlyContinue
}

function Stop-CodexDesktopProcesses([string]$InstallLocation) {
  $targetRoot = $InstallLocation.TrimEnd('\')
  $processes = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)
  }
  foreach ($process in $processes) {
    Write-Log "stopping Codex desktop process pid=$($process.Id)"
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  $appServers = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'codex.exe' -and $_.CommandLine -like '*WindowsApps\\OpenAI.Codex_*app-server*' }
  foreach ($server in $appServers) {
    Write-Log "stopping Codex app-server pid=$($server.ProcessId)"
    Stop-Process -Id ([int]$server.ProcessId) -Force -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath
$pkg = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Select-Object -First 1
if (-not $pkg -or -not $pkg.InstallLocation) {
  Fail 'OpenAI.Codex package not found'
}

$sourcePackageRoot = $pkg.InstallLocation
$sourceAsar = Join-Path $sourcePackageRoot 'app\resources\app.asar'
if (-not (Test-Path -LiteralPath $sourceAsar -PathType Leaf)) {
  Fail "app.asar not found: $sourceAsar"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$workRoot = Join-Path $OutputRoot "dynamic-tools-$($pkg.Version)-$stamp"
$workPackageRoot = Join-Path $workRoot 'package'
$asarDir = Join-Path $workRoot 'app-asar'
$npxCache = Join-Path $workRoot 'npm-cache'
$msixPath = Join-Path $OutputRoot "OpenAI.Codex_$($pkg.Version)_dynamic-tools-patched.msix"
$patcher = Join-Path $PSScriptRoot 'patch-dynamic-tools-schema.cjs'
$installedSuccessfully = $false

if (-not (Test-Path -LiteralPath $patcher -PathType Leaf)) {
  Fail "dynamic tools patcher not found: $patcher"
}

try {
  Write-Log "source package: $sourcePackageRoot"
  Write-Log "work root: $workRoot"
  New-Item -ItemType Directory -Force -Path $workPackageRoot | Out-Null
  Write-Log 'copying package layout'
  & robocopy.exe $sourcePackageRoot $workPackageRoot /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -gt 7) {
    Fail "robocopy failed with exit code $LASTEXITCODE"
  }
  foreach ($rel in @('AppxSignature.p7x', 'AppxBlockMap.xml', 'AppxMetadata\CodeIntegrity.cat')) {
    $artifact = Join-Path $workPackageRoot $rel
    if (Test-Path -LiteralPath $artifact) {
      Remove-Item -LiteralPath $artifact -Force
    }
  }

  $npx = Get-RequiredCommand 'npx'
  $workAppRoot = Join-Path $workPackageRoot 'app'
  $workAsar = Join-Path $workPackageRoot 'app\resources\app.asar'
  Write-Log 'extracting app.asar'
  & $npx --yes --cache $npxCache asar extract $workAsar $asarDir
  if ($LASTEXITCODE -ne 0) {
    Fail "npx asar extract failed with exit code $LASTEXITCODE"
  }

  Write-Log 'patching dynamic tools schema'
  $patchResult = & node $patcher $asarDir
  if ($LASTEXITCODE -ne 0) {
    Fail "dynamic tools patch failed with exit code $LASTEXITCODE"
  }
  Write-Log "dynamic tools patch result: $patchResult"
  $dynamicToolsFile = Get-ChildItem -LiteralPath (Join-Path $asarDir 'webview\assets') -Filter 'app-server-dynamic-tools-*.js' -File | Select-Object -First 1
  if (-not $dynamicToolsFile) {
    Fail 'app-server-dynamic-tools asset missing after extraction'
  }
  & node --check $dynamicToolsFile.FullName
  if ($LASTEXITCODE -ne 0) {
    Fail "node syntax check failed for $($dynamicToolsFile.FullName)"
  }

  if ($DryRun) {
    # Surface integrity-host detection during a dry run so an unrecognized table format is
    # reported before anyone repacks a package that cannot start.
    Test-AsarIntegrityTargets $workAppRoot | Out-Null
    Write-Log 'dry run passed; package was not repacked or installed'
    return
  }

  Write-Log 'packing app.asar'
  & $npx --yes --cache $npxCache asar pack $asarDir $workAsar
  if ($LASTEXITCODE -ne 0) {
    Fail "npx asar pack failed with exit code $LASTEXITCODE"
  }

  Write-Log "app.asar header sha256: $(Get-AsarHeaderSha256 $workAsar)"
  Update-ElectronAsarIntegrity $workAppRoot

  $makeappx = Require-WindowsSdkTool 'makeappx.exe'
  $signtool = Require-WindowsSdkTool 'signtool.exe'
  [xml]$manifest = Get-Content -Raw -LiteralPath (Join-Path $workPackageRoot 'AppxManifest.xml')
  $publisher = [string]$manifest.Package.Identity.Publisher
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
    Stop-CodexDesktopProcesses $sourcePackageRoot
    Write-Log "removing existing package: $($pkg.PackageFullName)"
    try {
      Remove-AppxPackage -Package $pkg.PackageFullName -PreserveApplicationData -ErrorAction Stop
    } catch {
      Write-Log 'PreserveApplicationData unsupported; retrying normal Remove-AppxPackage'
      Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
    }
    Write-Log "installing patched MSIX: $msixPath"
    Add-AppxPackage -Path $msixPath -ErrorAction Stop
    $installed = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Select-Object -First 1
    Write-Log "installed package: $($installed.PackageFullName)"
    $installedSuccessfully = $true
    if ($Launch) {
      Start-InstalledAppxPackage -Package $installed | Out-Null
    }
  }

  Write-Log 'done'
} finally {
  if ($KeepWorkDir) {
    Write-Log "keeping work root: $workRoot"
  } else {
    Remove-DirectoryRobust -Path $workRoot -RequiredRoot $OutputRoot
    if ($installedSuccessfully -and (Test-Path -LiteralPath $msixPath -PathType Leaf)) {
      Remove-Item -LiteralPath $msixPath -Force -ErrorAction SilentlyContinue
      Write-Log "removed installed patched MSIX artifact: $msixPath"
    }
    if ($InstalledWindowsSdkViaNuGet) {
      $sdkRoot = Join-Path $OutputRoot 'sdk-buildtools'
      if (Test-Path -LiteralPath $sdkRoot) {
        Remove-DirectoryRobust -Path $sdkRoot -RequiredRoot $OutputRoot
      }
    }
  }
}
