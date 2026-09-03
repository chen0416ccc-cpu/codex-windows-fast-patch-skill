# Shared MSIX launch helper for the Codex Windows patchers.
#
# Never launch a repacked package by running an executable inside the install directory. The
# launcher file name is build-dependent: older Codex builds shipped Codex.exe as the Electron
# main binary, 26.9xx ships ChatGPT.exe and keeps Codex.exe only as a thin CLI shim. Starting
# app\Codex.exe on such a build starts the CLI, not the desktop UI, and reports success while
# no window ever appears. Launching through the AppUserModelId lets Windows resolve whatever
# executable the AppxManifest declares.
#
# Dot-source this file from a patcher that already defines Write-Log, Fail and
# Get-RequiredCommand:
#   . (Join-Path $PSScriptRoot 'lib\appx-launch.ps1')

function Start-InstalledAppxPackage {
  param(
    [Parameter(Mandatory = $true)]$Package
  )
  $manifest = Get-AppxPackageManifest -Package $Package -ErrorAction Stop
  $applications = @($manifest.Package.Applications.Application)
  if ($applications.Count -lt 1) {
    Fail "installed package has no application entry: $($Package.PackageFullName)"
  }
  $application = $applications[0]
  if ($applications.Count -gt 1) {
    $appEntries = @($applications | Where-Object { [string]$_.Id -eq 'App' })
    if ($appEntries.Count -ne 1) {
      $applicationIds = @($applications | ForEach-Object { [string]$_.Id }) -join ', '
      Fail "installed package has ambiguous application entries ($applicationIds): $($Package.PackageFullName)"
    }
    $application = $appEntries[0]
  }
  $packageFamilyName = [string]$Package.PackageFamilyName
  $applicationId = [string]$application.Id
  if ([string]::IsNullOrWhiteSpace($packageFamilyName) -or [string]::IsNullOrWhiteSpace($applicationId)) {
    Fail "installed package is missing PackageFamilyName or Application Id: $($Package.PackageFullName)"
  }
  $aumid = "$packageFamilyName!$applicationId"
  $explorer = Get-RequiredCommand 'explorer.exe'
  Write-Log "launching Codex through AppUserModelId: $aumid"
  Start-Process -FilePath $explorer -ArgumentList "shell:AppsFolder\$aumid" -WindowStyle Hidden -ErrorAction Stop | Out-Null
  return $aumid
}
