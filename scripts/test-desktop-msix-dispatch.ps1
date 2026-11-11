[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourceAsarRoot,
  [Parameter(Mandatory=$true)][string]$TemporaryRoot
)
$ErrorActionPreference='Stop'
$script:patcherRoot=$PSScriptRoot
$source=[IO.Path]::GetFullPath($SourceAsarRoot)
$root=Join-Path ([IO.Path]::GetFullPath($TemporaryRoot)) ('desktop-dispatch-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$ast=[Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Fail','Get-RequiredCommand','Write-PatcherFiles','Invoke-NodePatcher','Invoke-PatchAppAsar')) {
  $function=$ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  },$true)
  if(-not $function){throw "Missing patcher function: $name"}
  Invoke-Expression $function.Extent.Text.Replace('$PSScriptRoot','$script:patcherRoot')
}
function Write-Log([string]$Message){$script:reports.Add($Message)}
function Invoke-NpxAsar([string]$Action,[string]$Source,[string]$Target) {
  if($Action -ne 'extract'){throw 'Dry-run dispatcher attempted repacking'}
  New-Item -ItemType Directory -Path $Target|Out-Null
  Get-ChildItem -LiteralPath $script:source -Force|Copy-Item -Destination $Target -Recurse
}
$CustomModels=@('fixture-model')
$DryRun=$true
$LogPrefix='fixture'
$names=@($ast.ParamBlock.Parameters.Name.VariablePath.UserPath|Where-Object{$_ -like 'Only*' -or $_ -like 'Patch*'})
$checks=0
try {
  foreach($mode in @('full','models','marketplace','heartbeat','full-heartbeat')) {
    foreach($name in $names){Set-Variable -Name $name -Value $false -Scope Script}
    switch($mode) {
      'models' {$OnlyModelExperience=$true}
      'marketplace' {$OnlyBundledMarketplaceCopy=$true}
      'heartbeat' {$OnlyThreadAutomations=$true}
      'full-heartbeat' {$PatchThreadAutomations=$true}
    }
    $script:reports=[Collections.Generic.List[string]]::new()
    $work=Join-Path $root $mode
    $app=Join-Path $work 'app'
    New-Item -ItemType Directory -Path (Join-Path $app 'resources') -Force|Out-Null
    if(Invoke-PatchAppAsar $app $app $work){throw 'DryRun requested package replacement'}
    $entry=$reports|Where-Object{$_ -match '^(Pinned desktop|Model Experience pinned desktop|bundled marketplace copy pinned desktop|Thread automation instructions) patch result:'}
    if(-not $entry){throw "Dispatcher skipped the pinned $mode profile"}
    foreach($line in $entry) {
      $report=$line.Substring($line.IndexOf(':')+1)|ConvertFrom-Json
      if($report.file) {
        if($report.status -ne 'patched'){throw 'Original heartbeat was not patched'}
      } else {
        if(@($report.files|Where-Object status -ne 'patched').Count){throw 'Original desktop files were not patched'}
        if($mode -eq 'models' -and @($report.files.kinds|Where-Object{$_ -eq 'trusted-paths'}).Count){throw 'Model-only mode included trust edits'}
        if($mode -eq 'marketplace' -and $report.files.Count -ne 1){throw 'Marketplace-only mode changed unrelated files'}
      }
      $checks++
    }
    if(Test-Path -LiteralPath (Join-Path $work 'app.asar')){throw 'DryRun repacked an ASAR'}
    $checks++
  }
  Write-Output "PINNED_DESKTOP_DISPATCH_PASSED checks=$checks modes=5"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  $parent=[IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\')
  if((Split-Path -Parent $full) -ine $parent){throw 'Temporary cleanup path mismatch'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
