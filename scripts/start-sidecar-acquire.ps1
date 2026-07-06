[CmdletBinding()]
param(
  [string]$StateRoot,
  [string]$ProductId = '9PLM9XGG6VKS',
  [int]$GeoId = 0,
  [switch]$RestartSidecar,
  [switch]$ResetLog,
  [switch]$RefreshTrustedCerts,
  [switch]$BootstrapStoreInfrastructure
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot 'codex-desktop-guard-common.ps1')

Assert-GuardWindows
$state = Initialize-GuardState -StateRoot $StateRoot
$repoRoot = Resolve-GuardFullPath (Split-Path -Parent $ScriptRoot)
$outputRoot = Join-Path $state.Paths.Root 'sidecar-output'
$statusPath = Join-Path $outputRoot 'status.json'
$logPath = Join-Path $outputRoot 'sandbox-sidecar.log'
$payloadZip = Join-Path $outputRoot 'codex-payload.zip'
$wsbPath = Join-Path $outputRoot 'CodexPayloadSidecar.wsb'
$bootstrapRoot = Join-Path $outputRoot 'winget-bootstrap'
$trustedCertRoot = Join-Path $outputRoot 'trusted-certs'
$sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
New-Item -ItemType Directory -Force -Path $outputRoot, $bootstrapRoot, $trustedCertRoot | Out-Null

if ($GeoId -le 0) {
  try {
    $GeoId = [int](Get-WinHomeLocation).GeoId
  } catch {
    $GeoId = 45
  }
}

function Write-SidecarAcquireStatus {
  param(
    [Parameter(Mandatory = $true)][string]$StateName,
    [Parameter(Mandatory = $true)][string]$Step,
    [AllowNull()][string]$LastError = $null,
    [AllowNull()][object]$Details = $null
  )
  Write-GuardJsonFile -Path $statusPath -Value ([pscustomobject]@{
    schemaVersion = 1
    state = $StateName
    step = $Step
    lastError = $LastError
    payloadZip = $payloadZip
    payloadZipExists = (Test-Path -LiteralPath $payloadZip -PathType Leaf)
    updatedAt = (Get-Date).ToString('o')
    logPath = $logPath
    repoRoot = $repoRoot
    outputRoot = $outputRoot
    productId = $ProductId
    details = $Details
  })
}

if ($ResetLog -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
  $archive = Join-Path $outputRoot ('sandbox-sidecar-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Move-Item -LiteralPath $logPath -Destination $archive -Force
}

if (-not (Test-Path -LiteralPath $sandboxExe -PathType Leaf)) {
  Write-SidecarAcquireStatus -StateName 'needs_action' -Step 'windows_sandbox_missing' -LastError "Windows Sandbox executable was not found: $sandboxExe"
  throw "Windows Sandbox executable was not found: $sandboxExe"
}

function Export-SidecarTlsChain {
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
  )
  $records = New-Object System.Collections.Generic.List[object]
  $tcp = $null
  $ssl = $null
  try {
    $tcp = [System.Net.Sockets.TcpClient]::new($HostName, 443)
    $callback = [System.Net.Security.RemoteCertificateValidationCallback]{
      param(
        [object]$sender,
        [System.Security.Cryptography.X509Certificates.X509Certificate]$certificate,
        [System.Security.Cryptography.X509Certificates.X509Chain]$chain,
        [System.Net.Security.SslPolicyErrors]$sslPolicyErrors
      )
      return $true
    }
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $callback)
    $ssl.AuthenticateAsClient($HostName)
    $leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    [void]$chain.Build($leaf)
    for ($i = 1; $i -lt $chain.ChainElements.Count; $i++) {
      $cert = $chain.ChainElements[$i].Certificate
      $safeHostName = $HostName.Replace([string]'*', [string]'wildcard').Replace([string]':', [string]'_')
      $name = '{0}-{1}-{2}.cer' -f $safeHostName, $i, $cert.Thumbprint
      $path = Join-Path $OutputDirectory $name
      [System.IO.File]::WriteAllBytes($path, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
      $records.Add([pscustomobject]@{
        host = $HostName
        path = $path
        subject = $cert.Subject
        issuer = $cert.Issuer
        thumbprint = $cert.Thumbprint
        notAfter = $cert.NotAfter.ToString('o')
      })
    }
    $chain.Dispose()
  } catch {
    $records.Add([pscustomobject]@{
      host = $HostName
      error = $_.Exception.Message
    })
  } finally {
    if ($ssl) { $ssl.Dispose() }
    if ($tcp) { $tcp.Dispose() }
  }
  return @($records)
}

$tlsHosts = @(
  'aka.ms',
  'storeedgefd.dsx.mp.microsoft.com',
  'cdn.winget.microsoft.com',
  'login.live.com',
  'github.com'
)
if ($RefreshTrustedCerts) {
  $trustedCertManifest = foreach ($tlsHost in $tlsHosts) {
    try {
      Export-SidecarTlsChain -HostName $tlsHost -OutputDirectory $trustedCertRoot
    } catch {
      [pscustomobject]@{
        host = $tlsHost
        error = $_.Exception.Message
        line = $_.InvocationInfo.Line
      }
    }
  }
  Write-GuardJsonFile -Path (Join-Path $trustedCertRoot 'manifest.json') -Value ([pscustomobject]@{
    createdAt = (Get-Date).ToString('o')
    hosts = $tlsHosts
    certificates = @($trustedCertManifest)
  })
}

$existing = @(Get-Process WindowsSandbox, WindowsSandboxClient -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
  if (-not $RestartSidecar) {
    Write-SidecarAcquireStatus -StateName 'needs_action' -Step 'sandbox_already_running' -LastError 'Windows Sandbox is already running. Use -RestartSidecar or stop-sidecar-acquire.ps1 first.' -Details $existing
    throw 'Windows Sandbox is already running. Use -RestartSidecar or stop-sidecar-acquire.ps1 first.'
  }
  $existing | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

$hostRepo = [System.Security.SecurityElement]::Escape($repoRoot)
$hostOutput = [System.Security.SecurityElement]::Escape($outputRoot)
$runnerCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\WDAGUtilityAccount\Desktop\repo\scripts\sidecar-acquire-runner.ps1" -RepoRoot "C:\Users\WDAGUtilityAccount\Desktop\repo" -OutputRoot "C:\Users\WDAGUtilityAccount\Desktop\sidecar-output" -ProductId "{0}" -GeoId {1}' -f $ProductId.Replace('"', '\"'), $GeoId
if ($BootstrapStoreInfrastructure) {
  $runnerCommand = "$runnerCommand -BootstrapStoreInfrastructure"
}
$runnerCommandEscaped = [System.Security.SecurityElement]::Escape($runnerCommand)
$wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$hostRepo</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\repo</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$hostOutput</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\sidecar-output</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$runnerCommandEscaped</Command>
  </LogonCommand>
</Configuration>
"@
Write-GuardUtf8NoBom -Path $wsbPath -Content $wsb

Write-SidecarAcquireStatus -StateName 'starting' -Step 'launching_sandbox'
$process = Start-Process -FilePath $sandboxExe -ArgumentList @($wsbPath) -PassThru
Write-SidecarAcquireStatus -StateName 'running' -Step 'sandbox_started' -Details ([pscustomobject]@{
  sandboxConfig = $wsbPath
  sandboxExe = $sandboxExe
  trustedCertRoot = $trustedCertRoot
  refreshedTrustedCerts = [bool]$RefreshTrustedCerts
  bootstrapStoreInfrastructure = [bool]$BootstrapStoreInfrastructure
  geoId = $GeoId
  launcherProcessId = $process.Id
})

[pscustomobject]@{
  status = 'started'
  statusPath = $statusPath
  logPath = $logPath
  payloadZip = $payloadZip
  sandboxConfig = $wsbPath
  outputRoot = $outputRoot
  geoId = $GeoId
} | ConvertTo-Json -Depth 6
