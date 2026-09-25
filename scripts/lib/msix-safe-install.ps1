# Transactional MSIX updates. Never remove the working package before deployment.

function Get-MsixManifestInfo {
  param([Parameter(Mandatory = $true)][string]$MsixPath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $MsixPath).ProviderPath)
  try {
    $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'AppxManifest.xml' })
    if ($entries.Count -ne 1 -or $entries[0].Length -gt 4MB) {
      throw 'MSIX must contain exactly one bounded AppxManifest.xml.'
    }
    $stream = $entries[0].Open()
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($stream, $settings)
    try {
      $manifest = [Xml.XmlDocument]::new()
      $manifest.XmlResolver = $null
      $manifest.Load($reader)
    } finally {
      $reader.Dispose()
      $stream.Dispose()
    }
  } finally {
    $archive.Dispose()
  }
  $identity = $manifest.DocumentElement.SelectSingleNode('./*[local-name()="Identity"]')
  if (-not $identity -or [string]$identity.Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw 'MSIX package identity or four-part version is missing.'
  }
  $services = @($manifest.SelectNodes('//*[local-name()="Extension" and @Category="windows.service"]'))
  $serviceCapabilities = @($manifest.SelectNodes('//*[local-name()="Capability" and (@Name="packagedServices" or @Name="localSystemServices")]'))
  [pscustomobject]@{
    Path = (Resolve-Path -LiteralPath $MsixPath).ProviderPath
    Name = [string]$identity.Name
    Publisher = [string]$identity.Publisher
    Architecture = [string]$identity.ProcessorArchitecture
    Version = [version]$identity.Version
    RequiresAdministrator = ($services.Count -gt 0 -or $serviceCapabilities.Count -gt 0)
  }
}

function Set-MsixUpdateVersion {
  param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [version]$MinimumVersion
  )
  [xml]$manifest = Get-Content -LiteralPath $ManifestPath -Raw
  $identity = $manifest.Package.Identity
  $baseline = [version]$identity.Version
  if ($MinimumVersion -and $MinimumVersion -gt $baseline) { $baseline = $MinimumVersion }
  if ($baseline.Revision -lt 0 -or $baseline.Revision -ge 65535) {
    throw "Cannot increment MSIX revision safely: $baseline"
  }
  $next = [version]::new($baseline.Major, $baseline.Minor, $baseline.Build, $baseline.Revision + 1)
  $identity.SetAttribute('Version', [string]$next)
  $settings = [Xml.XmlWriterSettings]::new()
  $settings.Encoding = [Text.UTF8Encoding]::new($false)
  $settings.Indent = $true
  $writer = [Xml.XmlWriter]::Create([IO.Path]::GetFullPath($ManifestPath), $settings)
  try { $manifest.Save($writer) } finally { $writer.Dispose() }
  return $next
}

function Test-MsixAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-MsixExternalExecutor {
  param($ExistingPackage)
  $installRoot = if ($ExistingPackage -and $ExistingPackage.InstallLocation) {
    ([string]$ExistingPackage.InstallLocation).TrimEnd('\') + '\'
  } else { $null }
  $currentId = $PID
  $seen = @{}
  while ($currentId -gt 0 -and -not $seen.ContainsKey($currentId)) {
    $seen[$currentId] = $true
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$currentId" -ErrorAction Stop
    if (-not $process) { break }
    $executable = [string]$process.ExecutablePath
    if ($executable -and
        (($installRoot -and $executable.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) -or
         $executable -match '(?i)[\\/]WindowsApps[\\/]OpenAI\.Codex_[^\\/]+[\\/]')) {
      throw 'Install must run outside the Codex process tree; a child Start-Process is not an independent executor.'
    }
    $currentId = [int]$process.ParentProcessId
    if ($seen.Count -gt 64) { throw 'Cannot establish independent installer ancestry.' }
  }
}

function Test-MsixDeploymentPreflight {
  param(
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [string]$PackageName = 'OpenAI.Codex'
  )
  $target = Get-MsixManifestInfo $MsixPath
  if ($target.Name -cne $PackageName) { throw "Unexpected package identity: $($target.Name)" }
  if ($target.RequiresAdministrator -and -not (Test-MsixAdministrator)) {
    throw 'This MSIX contains packaged services. An elevated external executor is required before any app shutdown or deployment. The existing package has not been removed.'
  }
  $signature = Get-AuthenticodeSignature -LiteralPath $target.Path
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -cne $target.Publisher) {
    throw 'MSIX signature is invalid or does not match its manifest publisher.'
  }
  $existing = Get-AppxPackage -Name $PackageName -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
  if ($existing) {
    if ([string]$existing.Publisher -cne $target.Publisher -or
        [string]$existing.Architecture -ine $target.Architecture) {
      throw 'MSIX publisher or architecture does not match the installed package.'
    }
    if ($target.Version -le [version]$existing.Version) {
      throw "Transactional update requires a higher package version: installed=$($existing.Version) target=$($target.Version). Rebuild with an incremented revision; never uninstall to bypass this check."
    }
  }
  return [pscustomobject]@{ Target = $target; Existing = $existing }
}

function Invoke-TransactionalMsixInstall {
  param(
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [string]$PackageName = 'OpenAI.Codex'
  )
  $plan = Test-MsixDeploymentPreflight -MsixPath $MsixPath -PackageName $PackageName
  Assert-MsixExternalExecutor $plan.Existing
  Write-Log "transactional MSIX update: $($plan.Target.Version); no explicit package removal"
  try {
    Add-AppxPackage -Path $plan.Target.Path -ForceApplicationShutdown -ErrorAction Stop
    $installed = Get-AppxPackage -Name $PackageName -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed -or [version]$installed.Version -ne $plan.Target.Version -or
        [string]$installed.Publisher -cne $plan.Target.Publisher) {
      throw 'Deployment returned without the expected package identity being registered.'
    }
    return $installed
  } catch {
    $failure = $_
    $after = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($plan.Existing -and $after -and $after.PackageFullName -eq $plan.Existing.PackageFullName) {
      Write-Log 'update failed; the original package remains registered. No uninstall fallback was attempted.'
    }
    throw $failure
  }
}

function Invoke-RecoverableMsixInstall {
  param(
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [Parameter(Mandatory = $true)][string]$RecoveryMsixPath,
    [Parameter(Mandatory = $true)][scriptblock]$ValidateInstalledPackage,
    [string]$PackageName = 'OpenAI.Codex'
  )
  $update = Test-MsixDeploymentPreflight -MsixPath $MsixPath -PackageName $PackageName
  $recovery = Test-MsixDeploymentPreflight -MsixPath $RecoveryMsixPath -PackageName $PackageName
  if (-not $update.Existing -or $recovery.Target.Version -le $update.Target.Version -or
      $recovery.Target.Publisher -cne $update.Target.Publisher) {
    throw 'Recovery must be validated before deployment and have the same publisher and a higher revision than the update.'
  }
  try {
    $installed = Invoke-TransactionalMsixInstall -MsixPath $MsixPath -PackageName $PackageName
    & $ValidateInstalledPackage $installed | Out-Null
    return [pscustomobject]@{Success=$true;Recovered=$false;Package=$installed;Error=$null}
  } catch {
    $failure = $_.Exception.Message
    $current = Get-AppxPackage -Name $PackageName -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
    if ($current -and $current.PackageFullName -eq $update.Existing.PackageFullName) {
      & $ValidateInstalledPackage $current | Out-Null
      return [pscustomobject]@{Success=$false;Recovered=$true;Package=$current;Error=$failure}
    }
    if (-not $current -or [version]$current.Version -ne $update.Target.Version -or
        [string]$current.Publisher -cne $update.Target.Publisher) {
      throw "Update failed and registration changed unexpectedly; no blind recovery attempt: $failure"
    }
    Write-Log "update launch/validation failed; applying the prepared original-content recovery package: $failure"
    try {
      $restored = Invoke-TransactionalMsixInstall -MsixPath $RecoveryMsixPath -PackageName $PackageName
      & $ValidateInstalledPackage $restored | Out-Null
    } catch {
      throw "Update failed: $failure; recovery failed: $($_.Exception.Message)"
    }
    return [pscustomobject]@{Success=$false;Recovered=$true;Package=$restored;Error=$failure}
  }
}
