# Shared MSIX launch helper for the Codex Windows patchers.
#
# Never launch a repacked package by running an executable inside the install directory. The
# launcher file name is build-dependent: older Codex builds shipped Codex.exe as the Electron
# main binary, 26.9xx ships ChatGPT.exe and keeps Codex.exe only as a thin CLI shim. Starting
# app\Codex.exe on such a build starts the CLI, not the desktop UI, and reports success while
# no window ever appears. Launching through the AppUserModelId lets Windows resolve whatever
# executable the AppxManifest declares.
#
# Dot-source this file from a patcher that already defines Write-Log and Fail:
#   . (Join-Path $PSScriptRoot 'lib\appx-launch.ps1')

function Get-InstalledAppxApplicationEntry {
  param([Parameter(Mandatory = $true)]$Package)
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
  return [pscustomobject]@{
    AppUserModelId = "$packageFamilyName!$applicationId"
    Executable = Join-Path $Package.InstallLocation ([string]$application.Executable).Replace('/', '\')
    ProcessName = [IO.Path]::GetFileNameWithoutExtension([string]$application.Executable)
  }
}

function Invoke-InstalledAppxApplicationActivation {
  param([Parameter(Mandatory = $true)][string]$AppUserModelId)
  # IApplicationActivationManager runs in the caller's desktop session, including
  # an elevated external installer. An elevated explorer.exe child cannot be used
  # as a Shell launch proxy and may return without activating the packaged app.
  if (-not ('CodexWindowsFastPatch.ApplicationActivationManager' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexWindowsFastPatch {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      uint options,
      out uint processId);
  }
  [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  public class ApplicationActivationManager { }
}
'@ -ErrorAction Stop
  }
  $manager = [CodexWindowsFastPatch.IApplicationActivationManager][Activator]::CreateInstance(
    [type]'CodexWindowsFastPatch.ApplicationActivationManager')
  try {
    $processId = [uint32]0
    $result = $manager.ActivateApplication($AppUserModelId, $null, 0, [ref]$processId)
    if ($result -ne 0) { throw ('Application activation failed for {0}: HRESULT 0x{1:X8}' -f $AppUserModelId, [uint32]$result) }
    return $processId
  } finally {
    $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($manager)
  }
}

function Wait-InstalledAppxDesktopProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [int]$TimeoutSeconds = 45
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {
      $_.Path -and $_.Path.Equals($Executable, [StringComparison]::OrdinalIgnoreCase) -and
      $_.SessionId -eq (Get-Process -Id $PID).SessionId
    } | Sort-Object -Property @{ Expression = { $_.MainWindowHandle -ne 0 }; Descending = $true }, StartTime -Descending | Select-Object -First 1
    if ($process) { return $process }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  throw "Codex did not start from the installed package path: $Executable"
}

function Start-InstalledAppxPackage {
  param(
    [Parameter(Mandatory = $true)]$Package,
    [switch]$WaitForProcess,
    [int]$TimeoutSeconds = 45
  )
  $entry = Get-InstalledAppxApplicationEntry -Package $Package
  $application = @(Get-AppxPackageManifest -Package $Package -ErrorAction Stop).Package.Applications.Application |
    Where-Object { "$($Package.PackageFamilyName)!$($_.Id)" -ceq $entry.AppUserModelId }
  if ([string]$application.EntryPoint -cne 'Windows.FullTrustApplication') {
    Fail "installed package application is not a supported full-trust Desktop entry: $($entry.AppUserModelId)"
  }
  Write-Log "launching Codex through AppUserModelId: $($entry.AppUserModelId)"
  $null = Invoke-InstalledAppxApplicationActivation -AppUserModelId $entry.AppUserModelId
  if ($WaitForProcess) {
    $null = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName -TimeoutSeconds $TimeoutSeconds
  }
  return $entry.AppUserModelId
}
