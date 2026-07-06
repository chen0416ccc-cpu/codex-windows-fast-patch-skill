[CmdletBinding()]
param(
  [string]$RepoRoot = 'C:\Users\WDAGUtilityAccount\Desktop\repo',
  [string]$OutputRoot = 'C:\Users\WDAGUtilityAccount\Desktop\sidecar-output',
  [string]$ProductId = '9PLM9XGG6VKS',
  [int]$GeoId = 45,
  [switch]$BootstrapStoreInfrastructure
)

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $OutputRoot 'sandbox-sidecar.log'
$StatusPath = Join-Path $OutputRoot 'status.json'
$PayloadZip = Join-Path $OutputRoot 'codex-payload.zip'
$StartedAt = (Get-Date).ToString('o')

function Write-SidecarJsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Value
  )
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $json = $Value | ConvertTo-Json -Depth 12
  $encoding = [System.Text.UTF8Encoding]::new($false)
  $tempPath = '{0}.{1}.tmp' -f $Path, $PID
  [System.IO.File]::WriteAllText($tempPath, $json + "`r`n", $encoding)
  Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Read-SidecarJsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  $raw = Get-Content -Raw -LiteralPath $Path
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }
  return ($raw | ConvertFrom-Json)
}

function Write-SidecarStatus {
  param(
    [Parameter(Mandatory = $true)][string]$State,
    [Parameter(Mandatory = $true)][string]$Step,
    [AllowNull()][string]$LastError = $null,
    [AllowNull()][object]$Details = $null
  )
  $safeLastError = $null
  if ($null -ne $LastError) {
    $safeLastError = ([string]$LastError -replace '[\r\n]+', ' ' -replace '"', "'")
    if ($safeLastError.Length -gt 1600) {
      $safeLastError = $safeLastError.Substring(0, 1600) + '...'
    }
  }
  $payload = [pscustomobject]@{
    schemaVersion = 1
    state = $State
    step = $Step
    lastError = $safeLastError
    payloadZip = $PayloadZip
    payloadZipExists = (Test-Path -LiteralPath $PayloadZip -PathType Leaf)
    updatedAt = (Get-Date).ToString('o')
    startedAt = $StartedAt
    logPath = $LogPath
    repoRoot = $RepoRoot
    outputRoot = $OutputRoot
    productId = $ProductId
    details = $Details
  }
  Write-SidecarJsonFile -Path $StatusPath -Value $payload
}

function Write-SidecarLine {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Convert-SidecarNativeOutput {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ''
  }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) {
    return ''
  }

  $zeroCount = 0
  foreach ($byte in $bytes) {
    if ($byte -eq 0) {
      $zeroCount++
    }
  }

  if ($zeroCount -gt [Math]::Max(4, [int]($bytes.Length / 10))) {
    $text = [System.Text.Encoding]::Unicode.GetString($bytes)
  } else {
    try {
      $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
      $text = $utf8.GetString($bytes)
    } catch {
      $text = [System.Text.Encoding]::Default.GetString($bytes)
    }
  }
  return ($text -replace "`0", '')
}

function Write-SidecarNativeOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Label,
    [AllowNull()][string]$Text
  )
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return
  }
  foreach ($line in ($Text -split "\r?\n")) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }
    if ($trimmed.Length -gt 1200) {
      $trimmed = $trimmed.Substring(0, 1200) + '...'
    }
    Write-SidecarLine "${Label}: $trimmed"
  }
}

function ConvertTo-SidecarExitCodeHex {
  param([AllowNull()][object]$ExitCode)
  if ($null -eq $ExitCode -or [string]::IsNullOrWhiteSpace([string]$ExitCode)) {
    return $null
  }
  try {
    $value = [int64]$ExitCode
    if ($value -lt 0) {
      $value += 4294967296
    }
    return ('0x{0:X8}' -f ([uint32]$value))
  } catch {
    return $null
  }
}

function Invoke-SidecarNativeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Label,
    [int]$TimeoutSeconds = 300
  )

  $nativeRoot = Join-Path $OutputRoot 'native-output'
  New-Item -ItemType Directory -Force -Path $nativeRoot | Out-Null
  $id = [System.Guid]::NewGuid().ToString('N')
  $stdoutPath = Join-Path $nativeRoot "$id.stdout.log"
  $stderrPath = Join-Path $nativeRoot "$id.stderr.log"

  Write-SidecarLine "Running ${Label}: $FilePath $($Arguments -join ' ')"
  try {
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  } catch {
    Write-SidecarLine "${Label} failed to start: $($_.Exception.Message)"
    return [pscustomobject]@{
      exitCode = $null
      timedOut = $false
      stdout = ''
      stderr = $_.Exception.Message
      stdoutPath = $stdoutPath
      stderrPath = $stderrPath
    }
  }

  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Write-SidecarLine "${Label} timed out after ${TimeoutSeconds}s."
    return [pscustomobject]@{
      exitCode = $null
      timedOut = $true
      stdout = Convert-SidecarNativeOutput -Path $stdoutPath
      stderr = Convert-SidecarNativeOutput -Path $stderrPath
      stdoutPath = $stdoutPath
      stderrPath = $stderrPath
    }
  }

  $process.WaitForExit()
  $process.Refresh()
  $exitCode = $null
  try {
    $exitCode = [int]$process.ExitCode
  } catch {
    $exitCode = $null
  }
  $stdout = Convert-SidecarNativeOutput -Path $stdoutPath
  $stderr = Convert-SidecarNativeOutput -Path $stderrPath
  Write-SidecarNativeOutput -Label $Label -Text $stdout
  Write-SidecarNativeOutput -Label "$Label stderr" -Text $stderr
  Write-SidecarLine "${Label} exit code: $exitCode"
  return [pscustomobject]@{
    exitCode = $exitCode
    timedOut = $false
    stdout = $stdout
    stderr = $stderr
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
  }
}

function Copy-SidecarWingetDiagnostics {
  $diagnosticRoot = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
  if (-not (Test-Path -LiteralPath $diagnosticRoot -PathType Container)) {
    Write-SidecarLine "winget diagnostics directory not found: $diagnosticRoot"
    return $null
  }

  $target = Join-Path (Join-Path $OutputRoot 'winget-diagnostics') (Get-Date -Format 'yyyyMMdd-HHmmss')
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Get-ChildItem -LiteralPath $diagnosticRoot -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 8 |
    Copy-Item -Destination $target -Force -ErrorAction SilentlyContinue
  Write-SidecarLine "Copied winget diagnostics to: $target"
  return $target
}

function Copy-SidecarWindowsEventDiagnostics {
  $target = Join-Path (Join-Path $OutputRoot 'windows-event-diagnostics') (Get-Date -Format 'yyyyMMdd-HHmmss')
  New-Item -ItemType Directory -Force -Path $target | Out-Null

  $logs = @(
    'Microsoft-Windows-AppXDeploymentServer/Operational',
    'Microsoft-Windows-AppxPackaging/Operational',
    'Microsoft-Windows-AppReadiness/Operational',
    'Microsoft-Windows-Store/Operational',
    'Microsoft-Windows-Store/Operational',
    'Microsoft-Windows-InstallService/Operational',
    'Microsoft-Windows-DeliveryOptimization/Operational',
    'Microsoft-Windows-WindowsUpdateClient/Operational'
  ) | Select-Object -Unique

  foreach ($logName in $logs) {
    $safeName = $logName -replace '[\\/:*?"<>|]', '_'
    $outFile = Join-Path $target "$safeName.json"
    try {
      $events = @(Get-WinEvent -LogName $logName -MaxEvents 60 -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
          timeCreated = if ($_.TimeCreated) { $_.TimeCreated.ToString('o') } else { $null }
          id = $_.Id
          providerName = $_.ProviderName
          level = $_.LevelDisplayName
          message = $_.Message
        }
      })
      Write-SidecarJsonFile -Path $outFile -Value $events
      Write-SidecarLine "Copied Windows event diagnostics for ${logName}: $outFile"
    } catch {
      Write-SidecarJsonFile -Path $outFile -Value ([pscustomobject]@{
        logName = $logName
        error = $_.Exception.Message
      })
      Write-SidecarLine "Windows event diagnostics failed for ${logName}: $($_.Exception.Message)"
    }
  }

  $storePackagesFile = Join-Path $target 'store-appx-packages.json'
  $storePackages = @(Get-AppxPackage -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Store|Purchase|DesktopAppInstaller|Delivery|OpenAI\.Codex' } |
    Select-Object Name, PackageFullName, Version, InstallLocation)
  Write-SidecarJsonFile -Path $storePackagesFile -Value $storePackages
  Write-SidecarLine "Copied Store/AppX package diagnostics: $storePackagesFile"
  return $target
}

function Get-SidecarStoreInfrastructurePackages {
  $names = @(
    'Microsoft.WindowsStore',
    'Microsoft.StorePurchaseApp',
    'Microsoft.Services.Store.Engagement'
  )
  return @($names | ForEach-Object {
    Get-AppxPackage -Name $_ -ErrorAction SilentlyContinue |
      Sort-Object Version -Descending |
      Select-Object -First 1
  } | Where-Object { $null -ne $_ })
}

function Initialize-SidecarStoreInfrastructure {
  Write-SidecarStatus -State 'running' -Step 'bootstrap_store_infrastructure'
  $packages = @(Get-SidecarStoreInfrastructurePackages)
  foreach ($package in $packages) {
    Write-SidecarLine "Store infrastructure package: $($package.PackageFullName)"
  }
  if (($packages | Where-Object { $_.Name -eq 'Microsoft.WindowsStore' }) -and
      ($packages | Where-Object { $_.Name -eq 'Microsoft.StorePurchaseApp' })) {
    Write-SidecarLine 'Microsoft Store infrastructure is already visible in the sandbox.'
    return
  }

  $wsreset = Join-Path $env:SystemRoot 'System32\wsreset.exe'
  if (-not (Test-Path -LiteralPath $wsreset -PathType Leaf)) {
    Write-SidecarLine "wsreset.exe was not found; continuing without Microsoft Store bootstrap: $wsreset"
    return
  }

  Write-SidecarLine 'Microsoft Store infrastructure is incomplete; trying wsreset.exe -i inside the sandbox.'
  [void](Invoke-SidecarNativeCommand -FilePath $wsreset -Arguments @('-i') -Label 'wsreset install Microsoft Store' -TimeoutSeconds 300)
  Start-Sleep -Seconds 15

  $packagesAfter = @(Get-SidecarStoreInfrastructurePackages)
  foreach ($package in $packagesAfter) {
    Write-SidecarLine "Store infrastructure package after wsreset: $($package.PackageFullName)"
  }
  if (-not ($packagesAfter | Where-Object { $_.Name -eq 'Microsoft.WindowsStore' })) {
    Write-SidecarLine 'Microsoft.WindowsStore is still not visible after wsreset.exe -i; continuing with winget msstore install attempt.'
  }
}

function Stop-SidecarWithFailure {
  param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$Message,
    [int]$ExitCode = 1,
    [AllowNull()][object]$Details = $null
  )
  Write-SidecarLine $Message
  Write-SidecarStatus -State 'failed' -Step $Step -LastError $Message -Details $Details
  exit $ExitCode
}

function Get-WingetCommand {
  $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  if ((Test-Path -LiteralPath $windowsApps -PathType Container) -and
      ($env:Path -notlike "*$windowsApps*")) {
    $env:Path = "$windowsApps;$env:Path"
  }

  $command = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) {
    return [pscustomobject]@{ Source = $command.Source }
  }

  $aliasPath = Join-Path $windowsApps 'winget.exe'
  if (Test-Path -LiteralPath $aliasPath -PathType Leaf) {
    return [pscustomobject]@{ Source = $aliasPath }
  }

  $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if ($pkg -and -not [string]::IsNullOrWhiteSpace($pkg.InstallLocation)) {
    $packageWinget = Join-Path $pkg.InstallLocation 'winget.exe'
    if (Test-Path -LiteralPath $packageWinget -PathType Leaf) {
      return [pscustomobject]@{ Source = $packageWinget }
    }
  }

  $windowsAppsRoot = 'C:\Program Files\WindowsApps'
  if (Test-Path -LiteralPath $windowsAppsRoot -PathType Container) {
    $programFilesWinget = Get-ChildItem -LiteralPath $windowsAppsRoot -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending |
      ForEach-Object {
        $candidate = Join-Path $_.FullName 'winget.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          Get-Item -LiteralPath $candidate
        }
      } |
      Select-Object -First 1
    if ($programFilesWinget) {
      return [pscustomobject]@{ Source = $programFilesWinget.FullName }
    }
  }

  return $null
}

function Invoke-DownloadFile {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$OutFile
  )

  if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
    $existing = Get-Item -LiteralPath $OutFile
    if ($existing.Length -gt 0) {
      Write-SidecarLine "Using cached download: $OutFile ($($existing.Length) bytes)"
      return
    }
  }

  Write-SidecarStatus -State 'running' -Step 'download_bootstrap' -Details ([pscustomobject]@{ uri = $Uri; outFile = $OutFile })
  Write-SidecarLine "Downloading: $Uri"
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 240 -MaximumRedirection 5
  } catch {
    $message = "Download failed: $($_.Exception.Message)"
    $step = if ($message -match 'trust relationship|SSL/TLS|certificate') { 'tls_trust_failed' } else { 'download_failed' }
    Stop-SidecarWithFailure -Step $step -Message $message -ExitCode 20 -Details ([pscustomobject]@{ uri = $Uri; outFile = $OutFile })
  }
}

function Test-SidecarNetwork {
  Write-SidecarStatus -State 'running' -Step 'network_probe'
  Write-SidecarLine 'Sandbox network probe begin.'
  $domains = @(
    'aka.ms',
    'www.msftconnecttest.com',
    'dns.msftncsi.com',
    'storeedgefd.dsx.mp.microsoft.com',
    'cdn.winget.microsoft.com',
    'login.live.com'
  )
  foreach ($domain in $domains) {
    try {
      $answers = Resolve-DnsName $domain -ErrorAction Stop |
        Where-Object { $_.IPAddress -or $_.NameHost } |
        ForEach-Object {
          if ($_.IPAddress) { "$($_.Type):$($_.IPAddress)" } else { "$($_.Type):$($_.NameHost)" }
        }
      Write-SidecarLine "DNS ${domain}: $($answers -join ', ')"
    } catch {
      Write-SidecarLine "DNS ${domain}: FAILED: $($_.Exception.Message)"
    }
  }

  $urls = @(
    'http://www.msftconnecttest.com/connecttest.txt',
    'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx',
    'https://storeedgefd.dsx.mp.microsoft.com'
  )
  foreach ($url in $urls) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -TimeoutSec 30 -MaximumRedirection 5 -ErrorAction Stop
      Write-SidecarLine "HTTP ${url}: $($response.StatusCode)"
    } catch {
      $status = $null
      if ($_.Exception.Response) {
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
      }
      if ($status) {
        Write-SidecarLine "HTTP ${url}: $status ($($_.Exception.Message))"
      } else {
        Write-SidecarLine "HTTP ${url}: FAILED: $($_.Exception.Message)"
      }
    }
  }
  Write-SidecarLine 'Sandbox network probe end.'
}

function Set-SidecarRegion {
  if ($GeoId -le 0) {
    Write-SidecarLine 'No sidecar GeoId was provided; keeping the sandbox default region.'
    return
  }

  Write-SidecarStatus -State 'running' -Step 'set_region' -Details ([pscustomobject]@{ geoId = $GeoId })
  try {
    Set-WinHomeLocation -GeoId $GeoId
    $location = Get-WinHomeLocation
    Write-SidecarLine "Sandbox home location set to GeoId $($location.GeoId): $($location.HomeLocation)"
  } catch {
    Write-SidecarLine "Setting sandbox home location failed: $($_.Exception.Message)"
  }
}

function Invoke-SidecarRootCertificateImport {
  param(
    [Parameter(Mandatory = $true)][System.IO.FileInfo]$CertFile,
    [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
    [int]$TimeoutSeconds = 8
  )

  $existing = Get-ChildItem -Path 'Cert:\CurrentUser\Root' -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint } |
    Select-Object -First 1
  if ($existing) {
    Write-SidecarLine "Trusted root certificate already present: $($Certificate.Thumbprint)"
    return
  }

  $escapedPath = $CertFile.FullName.Replace("'", "''")
  $command = "`$ErrorActionPreference = 'Stop'; Import-Certificate -FilePath '$escapedPath' -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null"
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) -PassThru -WindowStyle Hidden
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Write-SidecarLine "Trusted root certificate import timed out; continuing without this root: $($Certificate.Thumbprint)"
    return
  }
  Write-SidecarLine "Trusted root certificate import exit code: $($process.ExitCode) ($($Certificate.Thumbprint))"
}

function Import-SidecarTrustedCertificates {
  $trustedCertRoot = Join-Path $OutputRoot 'trusted-certs'
  if (-not (Test-Path -LiteralPath $trustedCertRoot -PathType Container)) {
    Write-SidecarLine "No sidecar trusted certificate directory found: $trustedCertRoot"
    return
  }

  Write-SidecarStatus -State 'running' -Step 'import_trusted_certificates' -Details ([pscustomobject]@{ path = $trustedCertRoot })
  $certFiles = @(Get-ChildItem -LiteralPath $trustedCertRoot -Filter '*.cer' -File -ErrorAction SilentlyContinue)
  foreach ($certFile in $certFiles) {
    try {
      $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certFile.FullName)
      if ($cert.Subject -eq $cert.Issuer) {
        Write-SidecarLine "Skipping trusted root certificate import to avoid sandbox trust prompt: $($cert.Subject)"
        continue
      }
      Write-SidecarLine "Importing trusted intermediate certificate into CurrentUser\CA: $($cert.Subject)"
      Import-Certificate -FilePath $certFile.FullName -CertStoreLocation 'Cert:\CurrentUser\CA' -ErrorAction Stop | Out-Null
    } catch {
      Write-SidecarLine "Trusted certificate import failed for $($certFile.FullName): $($_.Exception.Message)"
    }
  }
}

function Install-WingetForSandbox {
  Write-SidecarStatus -State 'running' -Step 'bootstrap_winget'
  $bootstrapRoot = Join-Path $OutputRoot 'winget-bootstrap'
  New-Item -ItemType Directory -Force -Path $bootstrapRoot | Out-Null

  $vclibsPath = Join-Path $bootstrapRoot 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
  $appInstallerDependenciesZipPath = Join-Path $bootstrapRoot 'DesktopAppInstaller_Dependencies.zip'
  $appInstallerDependenciesRoot = Join-Path $bootstrapRoot 'DesktopAppInstaller_Dependencies'
  $xamlZipPath = Join-Path $bootstrapRoot 'Microsoft.UI.Xaml.2.8.zip'
  $xamlNupkgPath = Join-Path $bootstrapRoot 'Microsoft.UI.Xaml.2.8.nupkg'
  $xamlExtractRoot = Join-Path $bootstrapRoot 'Microsoft.UI.Xaml.2.8'
  $xamlAppxPath = Join-Path $xamlExtractRoot 'tools\AppX\x64\Release\Microsoft.UI.Xaml.2.8.appx'
  $windowsAppRuntimePath = Join-Path $bootstrapRoot 'WindowsAppRuntimeInstall-x64-1.8.260529003.exe'
  $appInstallerPath = Join-Path $bootstrapRoot 'Microsoft.DesktopAppInstaller.msixbundle'

  Write-SidecarLine 'winget.exe was not found; bootstrapping App Installer inside the sandbox.'
  if ((-not (Test-Path -LiteralPath $xamlZipPath -PathType Leaf)) -and
      (Test-Path -LiteralPath $xamlNupkgPath -PathType Leaf)) {
    Write-SidecarLine "Using cached XAML nupkg as zip source: $xamlNupkgPath"
    Copy-Item -LiteralPath $xamlNupkgPath -Destination $xamlZipPath -Force
  }

  Invoke-DownloadFile -Uri 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile $vclibsPath
  Invoke-DownloadFile -Uri 'https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.zip' -OutFile $appInstallerDependenciesZipPath
  Invoke-DownloadFile -Uri 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6' -OutFile $xamlZipPath
  Invoke-DownloadFile -Uri 'https://aka.ms/windowsappsdk/1.8/1.8.260529003/windowsappruntimeinstall-x64.exe' -OutFile $windowsAppRuntimePath
  Invoke-DownloadFile -Uri 'https://aka.ms/getwinget' -OutFile $appInstallerPath

  if (Test-Path -LiteralPath $xamlExtractRoot) {
    Remove-Item -LiteralPath $xamlExtractRoot -Recurse -Force
  }
  Expand-Archive -LiteralPath $xamlZipPath -DestinationPath $xamlExtractRoot -Force
  if (Test-Path -LiteralPath $appInstallerDependenciesRoot) {
    Remove-Item -LiteralPath $appInstallerDependenciesRoot -Recurse -Force
  }
  Expand-Archive -LiteralPath $appInstallerDependenciesZipPath -DestinationPath $appInstallerDependenciesRoot -Force
  $vclibsFrameworkPackage = Get-ChildItem -LiteralPath $appInstallerDependenciesRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^Microsoft\.VCLibs\.140\.00_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+_x64\.appx$' } |
    Sort-Object Name -Descending |
    Select-Object -First 1
  $vclibsUwpDesktopPackage = Get-ChildItem -LiteralPath $appInstallerDependenciesRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^Microsoft\.VCLibs\.140\.00\.UWPDesktop_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+_x64\.appx$' } |
    Sort-Object Name -Descending |
    Select-Object -First 1

  foreach ($dependency in @($vclibsPath, $xamlAppxPath)) {
    if (Test-Path -LiteralPath $dependency -PathType Leaf) {
      Write-SidecarLine "Installing winget dependency: $dependency"
      try {
        Add-AppxPackage -Path $dependency -ErrorAction Stop *>&1 |
          Tee-Object -FilePath $LogPath -Append
      } catch {
        Stop-SidecarWithFailure -Step 'dependency_install_failed' -Message "Dependency install failed: $($_.Exception.Message)" -ExitCode 21 -Details ([pscustomobject]@{ path = $dependency })
      }
    } else {
      Stop-SidecarWithFailure -Step 'dependency_missing' -Message "winget dependency was not found after download/extract: $dependency" -ExitCode 22
    }
  }

  if ($vclibsFrameworkPackage) {
    Write-SidecarLine "Installing ordinary VCLibs framework appx: $($vclibsFrameworkPackage.FullName)"
    try {
      Add-AppxPackage -Path $vclibsFrameworkPackage.FullName -ErrorAction Stop *>&1 |
        Tee-Object -FilePath $LogPath -Append
    } catch {
      Stop-SidecarWithFailure -Step 'vclibs_framework_install_failed' -Message "Ordinary VCLibs framework install failed: $($_.Exception.Message)" -ExitCode 26 -Details ([pscustomobject]@{ path = $vclibsFrameworkPackage.FullName })
    }
  } else {
    Stop-SidecarWithFailure -Step 'vclibs_framework_missing' -Message "Ordinary VCLibs framework package was not found inside $appInstallerDependenciesZipPath." -ExitCode 26
  }

  if ($vclibsUwpDesktopPackage) {
    Write-SidecarLine "Installing UWPDesktop VCLibs framework appx: $($vclibsUwpDesktopPackage.FullName)"
    try {
      Add-AppxPackage -Path $vclibsUwpDesktopPackage.FullName -ErrorAction Stop *>&1 |
        Tee-Object -FilePath $LogPath -Append
    } catch {
      Stop-SidecarWithFailure -Step 'vclibs_uwpdesktop_install_failed' -Message "UWPDesktop VCLibs framework install failed: $($_.Exception.Message)" -ExitCode 27 -Details ([pscustomobject]@{ path = $vclibsUwpDesktopPackage.FullName })
    }
  } else {
    Stop-SidecarWithFailure -Step 'vclibs_uwpdesktop_missing' -Message "UWPDesktop VCLibs framework package was not found inside $appInstallerDependenciesZipPath." -ExitCode 27
  }

  Write-SidecarStatus -State 'running' -Step 'install_windows_app_runtime' -Details ([pscustomobject]@{ path = $windowsAppRuntimePath })
  Write-SidecarLine "Installing Windows App Runtime 1.8: $windowsAppRuntimePath"
  try {
    & $windowsAppRuntimePath --quiet *>&1 |
      Tee-Object -FilePath $LogPath -Append
    $runtimeExit = $LASTEXITCODE
    Write-SidecarLine "Windows App Runtime installer exit code: $runtimeExit"
    if ($runtimeExit -ne 0 -and $runtimeExit -ne 3010) {
      Stop-SidecarWithFailure -Step 'windows_app_runtime_install_failed' -Message "Windows App Runtime installer failed with exit code $runtimeExit." -ExitCode 24 -Details ([pscustomobject]@{ path = $windowsAppRuntimePath })
    }
  } catch {
    Stop-SidecarWithFailure -Step 'windows_app_runtime_install_failed' -Message "Windows App Runtime install failed: $($_.Exception.Message)" -ExitCode 24 -Details ([pscustomobject]@{ path = $windowsAppRuntimePath })
  }

  $runtimePackages = @(Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending)
  foreach ($package in $runtimePackages) {
    Write-SidecarLine "WindowsAppRuntime package: $($package.PackageFullName)"
    Write-SidecarLine "WindowsAppRuntime location: $($package.InstallLocation)"
  }
  if ($runtimePackages.Count -eq 0) {
    Stop-SidecarWithFailure -Step 'windows_app_runtime_not_visible' -Message 'Windows App Runtime 1.8 was not visible after installer completed.' -ExitCode 25 -Details ([pscustomobject]@{ path = $windowsAppRuntimePath })
  }

  Write-SidecarStatus -State 'running' -Step 'install_app_installer' -Details ([pscustomobject]@{ path = $appInstallerPath })
  Write-SidecarLine "Installing App Installer bundle: $appInstallerPath"
  try {
    Add-AppxPackage -Path $appInstallerPath -ErrorAction Stop *>&1 |
      Tee-Object -FilePath $LogPath -Append
  } catch {
    Stop-SidecarWithFailure -Step 'appinstaller_install_failed' -Message "App Installer bundle install failed: $($_.Exception.Message)" -ExitCode 23 -Details ([pscustomobject]@{ path = $appInstallerPath })
  }
  Start-Sleep -Seconds 10

  $desktopInstallerPackages = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending
  foreach ($package in $desktopInstallerPackages) {
    Write-SidecarLine "DesktopAppInstaller package: $($package.PackageFullName)"
    Write-SidecarLine "DesktopAppInstaller location: $($package.InstallLocation)"
  }

  $winget = Get-WingetCommand
  if (-not $winget) {
    Stop-SidecarWithFailure -Step 'winget_not_visible' -Message 'App Installer bootstrap completed, but winget.exe is still not visible in this sandbox.' -ExitCode 10
  }

  Write-SidecarLine "winget bootstrap succeeded: $($winget.Source)"
  return $winget
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Write-SidecarStatus -State 'running' -Step 'started'
Write-SidecarLine 'Codex Desktop sidecar sandbox started.'
Write-SidecarLine "RepoRoot: $RepoRoot"
Write-SidecarLine "OutputRoot: $OutputRoot"

try {
  Set-SidecarRegion
  Import-SidecarTrustedCertificates
  Test-SidecarNetwork

  $winget = Get-WingetCommand
  if (-not $winget) {
    $winget = Install-WingetForSandbox
  }

  Write-SidecarStatus -State 'running' -Step 'winget_available' -Details ([pscustomobject]@{ winget = $winget.Source })
  Write-SidecarLine "winget: $($winget.Source)"
  [void](Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('--version') -Label 'winget version' -TimeoutSeconds 60)
  if ($BootstrapStoreInfrastructure) {
    Initialize-SidecarStoreInfrastructure
  } else {
    Write-SidecarLine 'Skipping Microsoft Store infrastructure bootstrap; sidecar uses winget download and must not require Store broker installation.'
  }

  Write-SidecarStatus -State 'running' -Step 'configure_winget_msstore_source'
  Write-SidecarLine 'Configuring winget Microsoft Store source inside the sandbox.'
  $settingsResult = Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('settings', '--enable', 'BypassCertificatePinningForMicrosoftStore') -Label 'winget settings' -TimeoutSeconds 60
  $sourceResetResult = Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('source', 'reset', '--force') -Label 'winget source reset' -TimeoutSeconds 120
  $sourceUpdateResult = Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('source', 'update') -Label 'winget source update' -TimeoutSeconds 180
  if ($settingsResult.timedOut -or $sourceResetResult.timedOut -or $sourceUpdateResult.timedOut) {
    Stop-SidecarWithFailure -Step 'winget_source_config_timeout' -Message 'winget source configuration timed out.' -ExitCode 30 -Details ([pscustomobject]@{
      settings = $settingsResult
      sourceReset = $sourceResetResult
      sourceUpdate = $sourceUpdateResult
    })
  }

  Write-SidecarStatus -State 'running' -Step 'winget_msstore_diagnostics' -Details ([pscustomobject]@{ productId = $ProductId })
  $sourceListResult = Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('source', 'list') -Label 'winget source list' -TimeoutSeconds 60
  $searchResult = Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('search', '--source', 'msstore', 'Codex', '--accept-source-agreements', '--disable-interactivity') -Label 'winget search Codex' -TimeoutSeconds 180
  $showResult = Invoke-SidecarNativeCommand -FilePath $winget.Source -Arguments @('show', '--id', $ProductId, '--source', 'msstore', '--accept-source-agreements', '--disable-interactivity') -Label 'winget show Codex product' -TimeoutSeconds 180
  if ($sourceListResult.timedOut -or $searchResult.timedOut -or $showResult.timedOut) {
    Stop-SidecarWithFailure -Step 'winget_msstore_diagnostics_timeout' -Message 'winget Microsoft Store diagnostics timed out.' -ExitCode 31 -Details ([pscustomobject]@{
      sourceList = $sourceListResult
      search = $searchResult
      show = $showResult
    })
  }

  $acquireScript = Join-Path $RepoRoot 'scripts\acquire-codex-update-package.ps1'
  $exportScript = Join-Path $RepoRoot 'scripts\export-installed-codex-payload.ps1'
  if (-not (Test-Path -LiteralPath $acquireScript -PathType Leaf)) {
    Stop-SidecarWithFailure -Step 'acquire_script_missing' -Message "Acquire script not found: $acquireScript" -ExitCode 12
  }
  if (-not (Test-Path -LiteralPath $exportScript -PathType Leaf)) {
    Stop-SidecarWithFailure -Step 'export_script_missing' -Message "Export script not found: $exportScript" -ExitCode 12
  }

  $downloadRoot = Join-Path $OutputRoot 'payload-download'
  $acquireOutputPath = Join-Path $OutputRoot 'payload-acquire.json'
  if (Test-Path -LiteralPath $downloadRoot) {
    Remove-Item -LiteralPath $downloadRoot -Recurse -Force
  }
  if (Test-Path -LiteralPath $PayloadZip -PathType Leaf) {
    Remove-Item -LiteralPath $PayloadZip -Force
  }
  New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null

  Write-SidecarStatus -State 'running' -Step 'store_download' -Details ([pscustomobject]@{
    productId = $ProductId
    downloadRoot = $downloadRoot
    acquireOutputPath = $acquireOutputPath
  })
  Write-SidecarLine "Downloading official Codex Desktop offline payload from Microsoft Store product $ProductId."
  $acquireConsolePath = Join-Path $OutputRoot 'payload-acquire.console.log'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $acquireScript `
    -StateRoot $OutputRoot `
    -EventId 'sidecar-acquire' `
    -OutputPath $acquireOutputPath `
    -DownloadDirectory $downloadRoot `
    -ProductId $ProductId `
    -NoNotifications *> $acquireConsolePath
  $acquireExit = $LASTEXITCODE
  Write-SidecarLine "acquire exit code: $acquireExit"
  Write-SidecarLine "acquire console output: $acquireConsolePath"

  $diagnosticsPath = Copy-SidecarWingetDiagnostics
  $acquire = Read-SidecarJsonFile -Path $acquireOutputPath
  $acquireText = ''
  $downloadExit = $null
  $detectedErrorCode = $null
  $detectedExitCodeHex = $null
  if ($acquire) {
    $downloadExit = $acquire.WingetExitCode
    $detectedExitCodeHex = ConvertTo-SidecarExitCodeHex -ExitCode $downloadExit
    $acquireText = [string]::Concat([string]$acquire.WingetStdout, "`n", [string]$acquire.WingetStderr)
    if ($acquireText -match '0x[0-9A-Fa-f]{8}') {
      $detectedErrorCode = $Matches[0]
    } elseif ($detectedExitCodeHex) {
      $detectedErrorCode = $detectedExitCodeHex
    }
  }

  $payloadRoots = @()
  if ($acquire -and $acquire.UnpackedPayloadRoots) {
    $payloadRoots = @($acquire.UnpackedPayloadRoots | Where-Object {
      $_.Path -and (Test-Path -LiteralPath ([string]$_.Path) -PathType Container)
    })
  }
  if ($acquireExit -ne 0 -or -not $acquire -or $acquire.Status -ne 'update_source_ready' -or $payloadRoots.Count -eq 0) {
    $eventDiagnosticsPath = Copy-SidecarWindowsEventDiagnostics
    $failureStep = 'store_download_failed'
    $downloadFailureMessage = "Store offline download did not produce a usable OpenAI.Codex payload."
    if ($detectedErrorCode -eq '0x8A150076') {
      $failureStep = 'store_offline_authorization_required'
      $downloadFailureMessage = 'Microsoft Store offline package download requires Microsoft Entra ID authorization; this Sandbox sidecar cannot produce the Codex payload with winget download.'
    }
    if ($downloadExit -ne $null) {
      $downloadFailureMessage = "$downloadFailureMessage winget exit code: $downloadExit."
    }
    if ($detectedErrorCode) {
      $downloadFailureMessage = "$downloadFailureMessage Detected winget/store error: $detectedErrorCode."
    }
    Stop-SidecarWithFailure -Step $failureStep -Message $downloadFailureMessage -ExitCode 32 -Details ([pscustomobject]@{
      sourceListExitCode = $sourceListResult.exitCode
      searchExitCode = $searchResult.exitCode
      showExitCode = $showResult.exitCode
      acquireExitCode = $acquireExit
      wingetDownloadExitCode = $downloadExit
      wingetDownloadExitCodeHex = $detectedExitCodeHex
      detectedErrorCode = $detectedErrorCode
      diagnosticsPath = $diagnosticsPath
      eventDiagnosticsPath = $eventDiagnosticsPath
      acquireOutputPath = $acquireOutputPath
      acquireConsolePath = $acquireConsolePath
      acquire = $acquire
      recommendation = if ($failureStep -eq 'store_offline_authorization_required') {
        'Use the clean Windows / VM sidecar export flow with official Codex installed through Microsoft Store, then import the resulting codex-payload.zip. This is a Store offline distribution authorization boundary, not a host DNS fix.'
      } else {
        'Keep host DNS on the OpenClash/Resin path. If this is a Store broker endpoint failure, hand the exact status/log/diagnostics evidence to the network repair thread before changing OpenClash rules.'
      }
    })
  }

  $payloadRoot = [string]$payloadRoots[0].Path
  Write-SidecarLine "Downloaded payload root: $payloadRoot"
  Write-SidecarStatus -State 'running' -Step 'export_payload' -Details ([pscustomobject]@{
    outputZip = $PayloadZip
    payloadRoot = $payloadRoot
    acquireOutputPath = $acquireOutputPath
  })
  Write-SidecarLine "Exporting sidecar payload zip from downloaded payload: $PayloadZip"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exportScript -SourceRoot $payloadRoot -OutputZip $PayloadZip *>&1 |
    Tee-Object -FilePath $LogPath -Append
  $exportExit = $LASTEXITCODE
  Write-SidecarLine "export exit code: $exportExit"
  if ($exportExit -ne 0) {
    Stop-SidecarWithFailure -Step 'export_failed' -Message "Export failed with exit code $exportExit." -ExitCode $exportExit
  }

  if (Test-Path -LiteralPath $PayloadZip -PathType Leaf) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $PayloadZip
    Write-SidecarLine "READY: $PayloadZip"
    Write-SidecarLine "SHA256: $($hash.Hash)"
    Write-SidecarStatus -State 'ready' -Step 'payload_ready' -Details ([pscustomobject]@{ sha256 = $hash.Hash; length = (Get-Item -LiteralPath $PayloadZip).Length })
    exit 0
  }

  Stop-SidecarWithFailure -Step 'payload_missing' -Message 'Export command completed but payload zip is missing.' -ExitCode 13
} catch {
  Stop-SidecarWithFailure -Step 'unexpected_error' -Message $_.Exception.Message -ExitCode 99
}
