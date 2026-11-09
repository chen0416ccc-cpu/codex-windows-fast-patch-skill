$script:MsixTrayNativeSource = Join-Path $PSScriptRoot 'msix-tray.cs'

function Get-MsixTrayItems {
  if (-not ('CodexWindowsFastPatch.MsixTray' -as [type])) {
    Add-Type -Path $script:MsixTrayNativeSource -ErrorAction Stop
  }
  return [CodexWindowsFastPatch.MsixTray]::Read()
}

function Get-MsixTrayOwner {
  param($Item)
  return [CodexWindowsFastPatch.MsixTray]::Owner($Item.Window)
}

function Remove-MsixTrayItem {
  param($Item)
  return [CodexWindowsFastPatch.MsixTray]::RemoveDead($Item)
}

function Get-MsixPackageTraySnapshot {
  param([object[]]$Processes)
  try {
    $items = @(Get-MsixTrayItems)
  } catch {
    # This undocumented enumeration interface is not available in every shell.
    Write-Log "tray enumeration unavailable; tray cleanup is unverified: $($_.Exception.Message)"
    return
  }
  foreach ($item in $items) {
    if ($item.Window -eq [IntPtr]::Zero) { continue }
    $ownerId = Get-MsixTrayOwner $item
    foreach ($candidate in $Processes) {
      $process = $candidate.Process
      if ($process.Id -ne $ownerId) { continue }
      try {
        $null = $process.Handle
        $process.Refresh()
        if (-not $process.HasExited -and $process.StartTime -eq $candidate.StartedAt) { $item }
      } catch { continue }
    }
  }
}

function Remove-MsixStoppedTrayItems {
  param([object[]]$Items)
  if (-not $Items.Count) { return }
  foreach ($item in $Items) {
    # Re-read after shutdown: Explorer may have removed the icon or reused a GUID.
    $current = @(Get-MsixTrayItems | Where-Object {
      $_.Window -ne [IntPtr]::Zero -and $_.Window -eq $item.Window -and
      $_.Id -eq $item.Id -and $_.Guid -eq $item.Guid
    })
    foreach ($entry in $current) {
      if ((Get-MsixTrayOwner $entry) -ne 0) { continue }
      $removed = Remove-MsixTrayItem $entry
      if (-not $removed) {
        # A false result is harmless only when Explorer already discarded it.
        $stale = @(Get-MsixTrayItems | Where-Object {
          $_.Window -eq $entry.Window -and $_.Id -eq $entry.Id -and $_.Guid -eq $entry.Guid -and
          (Get-MsixTrayOwner $_) -eq 0
        })
        if ($stale.Count) { throw 'The stopped package tray icon could not be removed; refusing an immediate restart.' }
      }
      Write-Log "stopped package tray icon cleared: window=$($entry.Window) id=$($entry.Id) guid=$($entry.Guid)"
    }
  }
}
