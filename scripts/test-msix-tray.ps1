$ErrorActionPreference = 'Stop'
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}
function Write-Log([string]$Message) { }
function Fail([string]$Message) { throw $Message }
. (Join-Path $PSScriptRoot 'lib\msix-safe-install.ps1')
$readImplementation = ${function:Get-MsixTrayItems}
$ownerImplementation = ${function:Get-MsixTrayOwner}
$removeImplementation = ${function:Remove-MsixTrayItem}
$script:process = [pscustomobject]@{Id=123;Path='C:\fixture\app\ChatGPT.exe';SessionId=7;HasExited=$false;StartTime=[datetime]'2026-11-09';MainWindowHandle=1;Handle=[intptr]1}
$script:process | Add-Member ScriptMethod Refresh { }
$script:process | Add-Member ScriptMethod CloseMainWindow { $script:events.Add('close'); return $true }
$script:events = [Collections.Generic.List[string]]::new()
$script:owner = 123
$script:tray = [pscustomobject]@{Window=[intptr]321;Id=3;Guid=[guid]'e5768d8b-6936-4f45-b1ad-4c5fb414cb35';Exe='ignored';Preference=2}
function Get-Process {
  param([int]$Id, $ErrorAction)
  if ($Id -eq $PID) { return [pscustomobject]@{SessionId=7} }
  return $script:process
}
function Stop-Process {
  param($InputObject, [switch]$Force, $ErrorAction)
  $script:events.Add('stop')
  $InputObject.HasExited=$true
  $script:owner=0
}
function Get-MsixTrayItems { $script:events.Add('snapshot'); return $script:tray }
function Get-MsixTrayOwner { param($Item); return $script:owner }
function Remove-MsixTrayItem {
  param($Item)
  Assert ($script:process.HasExited -and $script:owner -eq 0) 'cleanup only reaches an exited package owner'
  Assert ($Item.Preference -eq 2) 'cleanup preserves the existing display preference'
  $script:events.Add('cleanup')
  return $true
}
Stop-MsixPackageProcesses -ExistingPackage ([pscustomobject]@{InstallLocation='C:\fixture'}) -GracefulTimeoutSeconds 0 -ForceTimeoutSeconds 0
Assert (($script:events -join ',') -eq 'snapshot,close,stop,snapshot,cleanup') 'live tray identity is captured before shutdown and removed after verified exit'
$script:process.HasExited=$false; $script:owner=123; $script:events.Clear()
function Stop-Process { param($InputObject, [switch]$Force, $ErrorAction); $script:events.Add('stop') }
$caught=$null
try { Stop-MsixPackageProcesses -ExistingPackage ([pscustomobject]@{InstallLocation='C:\fixture'}) -GracefulTimeoutSeconds 0 -ForceTimeoutSeconds 0 } catch { $caught=$_.Exception.Message }
Assert ($caught -like '*did not exit before deployment*' -and -not $script:events.Contains('cleanup')) 'failed shutdown cannot delete the live tray item'

$script:items = @($script:tray)
$script:removals = 0
$script:deleteResult = $true
$script:removeOnCall = $false
function Get-MsixTrayItems { return $script:items }
function Remove-MsixTrayItem {
  param($Item)
  $script:removals++
  if ($script:removeOnCall) { $script:items=@() }
  return $script:deleteResult
}
function Reset-TrayFixture {
  $script:items=@($script:tray.PSObject.Copy())
  $script:owner=0; $script:removals=0; $script:deleteResult=$true; $script:removeOnCall=$false
}
Reset-TrayFixture
Remove-MsixStoppedTrayItems @($script:tray)
Assert ($script:removals -eq 1) 'exact dead item is removed'
Reset-TrayFixture
$script:owner=456
Remove-MsixStoppedTrayItems @($script:tray)
Assert ($script:removals -eq 0) 'a reused HWND with a live owner is preserved'
foreach ($field in @('Window','Id','Guid')) {
  Reset-TrayFixture
  switch ($field) {
    Window { $script:items[0].Window=[intptr]654 }
    Id { $script:items[0].Id=4 }
    Guid { $script:items[0].Guid=[guid]::NewGuid() }
  }
  Remove-MsixStoppedTrayItems @($script:tray)
  Assert ($script:removals -eq 0) "changed tray identity is preserved: $field"
}
Reset-TrayFixture
$script:items[0].Window=[intptr]::Zero
Remove-MsixStoppedTrayItems @($script:tray)
Assert ($script:removals -eq 0) 'historical entries with zero HWND are not removed'
Reset-TrayFixture
$script:items=@()
Remove-MsixStoppedTrayItems @($script:tray)
Assert ($script:removals -eq 0) 'graceful cleanup requires no deletion'
Reset-TrayFixture
$script:deleteResult=$false
$caught=$null
try { Remove-MsixStoppedTrayItems @($script:tray) } catch { $caught=$_.Exception.Message }
Assert ($caught -like '*could not be removed*') 'persistent stale entry blocks immediate restart'
Reset-TrayFixture
$script:deleteResult=$false; $script:removeOnCall=$true
Remove-MsixStoppedTrayItems @($script:tray)
Assert ($script:removals -eq 1) 'Explorer removing an item during deletion is accepted'

Reset-TrayFixture
$script:owner=123
$script:process.HasExited=$false
$candidate=[pscustomobject]@{Process=$script:process;StartedAt=$script:process.StartTime}
Assert (@(Get-MsixPackageTraySnapshot @($candidate)).Count -eq 1) 'live owner from the exact package process list is captured'
$script:owner=999
Assert (@(Get-MsixPackageTraySnapshot @($candidate)).Count -eq 0) 'other process icons are excluded regardless of path text'
$script:owner=123
$candidate.StartedAt=$candidate.StartedAt.AddSeconds(1)
Assert (@(Get-MsixPackageTraySnapshot @($candidate)).Count -eq 0) 'recycled PID with a different start time is excluded'
function Get-MsixTrayItems { throw 'unsupported shell interface' }
Assert (@(Get-MsixPackageTraySnapshot @($candidate)).Count -eq 0) 'unsupported enumeration makes no deletion target'
Set-Item Function:\Get-MsixTrayItems $readImplementation
Set-Item Function:\Get-MsixTrayOwner $ownerImplementation
Set-Item Function:\Remove-MsixTrayItem $removeImplementation

# Compile the actual interop and exercise the callback without borrowing shell memory.
Add-Type -Path (Join-Path $PSScriptRoot 'lib\msix-tray.cs')
$item=New-Object CodexWindowsFastPatch.TrayItem
$item.Exe='C:\fixture\ChatGPT.exe'; $item.Tip='fixture tray'; $item.Window=[intptr]321
$item.Guid=$script:tray.Guid; $item.Preference=2; $item.Id=3
$size=[Runtime.InteropServices.Marshal]::SizeOf($item)
$pointer=[Runtime.InteropServices.Marshal]::AllocHGlobal($size)
try {
  [Runtime.InteropServices.Marshal]::StructureToPtr($item,$pointer,$false)
  $callback=New-Object CodexWindowsFastPatch.TrayCallback
  for($i=0;$i -lt 20;$i++) { $null=$callback.Notify(0,$pointer) }
  $copy=[Runtime.InteropServices.Marshal]::PtrToStructure($pointer,[type]'CodexWindowsFastPatch.TrayItem')
  Assert ($copy.Exe -eq $item.Exe -and $copy.Tip -eq $item.Tip -and $callback.Items.Count -eq 20) 'native callback copies shell-owned strings without freeing or changing them'
  Assert ($callback.Items[0].Guid -eq $item.Guid -and $callback.Items[0].Window -eq $item.Window) 'callback preserves native tray identity'
} finally {
  [Runtime.InteropServices.Marshal]::DestroyStructure($pointer,[type]'CodexWindowsFastPatch.TrayItem')
  [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
}
$item.Window=[intptr]::Zero
$caught=$null
try { [CodexWindowsFastPatch.MsixTray]::RemoveDead($item) | Out-Null } catch { $caught=$_.Exception.Message }
Assert ($caught -like '*empty or live tray window*') 'native deletion also rejects empty window identity'
Write-Output "MSIX_TRAY_INTEGRATION_TESTS_PASSED checks=$script:checks"
