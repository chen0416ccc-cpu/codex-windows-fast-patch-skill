param(
  [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}
function Fail([string]$Message) { throw $Message }
function Write-Log([string]$Message) { }

$root = [IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $root | Out-Null
$shell = [scriptblock]::Create(@'
param([Parameter(Mandatory = $true)]$Package)
$nodes = @($Package.Apps | ForEach-Object {
  '<Application Id="{0}" Executable="{1}" EntryPoint="{2}" />' -f $_.Id, $_.Executable, $_.EntryPoint
}) -join ''
[xml]('<Package><Applications>' + $nodes + '</Applications></Package>')
'@)
Set-Item -LiteralPath 'function:Get-AppxPackageManifest' -Value $shell
. (Join-Path $PSScriptRoot 'lib\appx-launch.ps1')
$app = [pscustomobject]@{ Id = 'App'; Executable = 'app/ChatGPT.exe'; EntryPoint = 'Windows.FullTrustApplication' }
$package = [pscustomobject]@{
  PackageFullName = 'OpenAI.Codex_fixture'
  PackageFamilyName = 'OpenAI.Codex_fixture'
  InstallLocation = $root
  Apps = @($app)
  Kind = 'normal'
}
$entry = Get-InstalledAppxApplicationEntry -Package $package
Assert ($entry.AppUserModelId -ceq 'OpenAI.Codex_fixture!App') 'manifest identity becomes the exact AUMID'
Assert ($entry.Executable -ceq (Join-Path $root 'app\ChatGPT.exe')) 'manifest executable resolves below the package'
Assert ($entry.ProcessName -ceq 'ChatGPT') 'process name comes from the manifest, not a hard-coded build'
$ambiguous = $package.PSObject.Copy()
$ambiguous.Apps = @(
  [pscustomobject]@{ Id = 'Other'; Executable = 'app/ChatGPT.exe'; EntryPoint = 'Windows.FullTrustApplication' }
  [pscustomobject]@{ Id = 'Secondary'; Executable = 'app/ChatGPT.exe'; EntryPoint = 'Windows.FullTrustApplication' }
)
$rejected = $false
try { $null = Get-InstalledAppxApplicationEntry -Package $ambiguous } catch { $rejected = $_.Exception.Message -like '*ambiguous application entries*' }
Assert $rejected 'multiple non-App entries remain an ambiguous launch target'
$badEntryPoint = $package.PSObject.Copy()
$badEntryPoint.Apps = @([pscustomobject]@{ Id = 'App'; Executable = 'app/ChatGPT.exe'; EntryPoint = 'Windows.UapApplication' })
$rejected = $false
try { $null = Start-InstalledAppxPackage -Package $badEntryPoint } catch { $rejected = $_.Exception.Message -like '*not a supported full-trust Desktop entry*' }
Assert $rejected 'a different activation contract fails before invoking COM'

# Compile the exact activation source in the system PowerShell without activating an app.
$declaration = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\appx-launch.ps1'))
$typeMatch = [regex]::Match($declaration, '(?ms)Add-Type -TypeDefinition @"(.*?)"@')
Assert $typeMatch.Success 'bounded COM declaration is present'
$typeSource = $typeMatch.Groups[1].Value
Assert ($typeSource.Contains('(IApplicationActivationManager)new ApplicationActivationManager()')) 'the activation wrapper performs the COM cast inside C#'
Assert ($typeSource.Contains('public static uint Launch(string appUserModelId)')) 'the activation wrapper returns the native PID'
$probe = '$ErrorActionPreference = ''Stop''' + [Environment]::NewLine +
  '$code = @''' + [Environment]::NewLine + $typeSource + [Environment]::NewLine + '''@' + [Environment]::NewLine +
  'Add-Type -TypeDefinition $code -ErrorAction Stop' + [Environment]::NewLine +
  'if (-not [Environment]::Is64BitProcess) { exit 3 }' + [Environment]::NewLine +
  '$method = [PackagedAppActivation].GetMethod(''Launch'')' + [Environment]::NewLine +
  'if ($method.ReturnType -ne [uint32] -or -not $method.IsStatic) { exit 4 }' + [Environment]::NewLine +
  '''activation-contract-ok'''
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$contract = & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -EncodedCommand $encoded
Assert ($LASTEXITCODE -eq 0 -and $contract -ceq 'activation-contract-ok') 'the real system PowerShell compiles the activation wrapper in its native bitness'

$probes = [scriptblock]::Create(@'
param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)
$ProcessName = $null
$Id = 0
for ($index = 0; $index -lt $Arguments.Count; $index++) {
  switch ([string]$Arguments[$index]) {
    '-Name' { $ProcessName = [string]$Arguments[++$index] }
    '-Id' { $Id = [int]$Arguments[++$index] }
    default { if (-not $ProcessName) { $ProcessName = [string]$Arguments[$index] } else { $Id = [int]$Arguments[$index] } }
  }
}
if ($Id) { return [pscustomobject]@{ SessionId = 1 } }
$items = @($script:processes | Where-Object Name -ceq $ProcessName | ForEach-Object {
  $path = $_.Path
  if ($script:denied) { $path = $null }
  $process = [pscustomobject]@{ Name = $_.Name; Path = $path; Id = $_.Id; SessionId = 1; StartTime = $_.StartTime; MainWindowHandle = $_.Window; Responding = $true; HasExited = $false }
  $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value { if ($this.Id -eq 999) { throw 'process exited' } }
  $process
})
@($items)
'@)
Set-Item -LiteralPath 'function:Get-Process' -Value $probes
$script:processes = @(
  [pscustomobject]@{ Name = 'ChatGPT'; Path = Join-Path $root 'app\ChatGPT.exe'; Id = 10; StartTime = [datetime]'2026-10-31T12:00:00'; Window = [intptr]0 },
  [pscustomobject]@{ Name = 'ChatGPT'; Path = Join-Path $root 'app\ChatGPT.exe'; Id = 11; StartTime = [datetime]'2026-10-31T12:00:01'; Window = [intptr]42 },
  [pscustomobject]@{ Name = 'ChatGPT'; Path = 'C:\other-package\app\ChatGPT.exe'; Id = 12; StartTime = [datetime]'2026-10-31T12:00:02'; Window = [intptr]43 }
)
$process = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName
Assert ($process.Id -eq 11) 'visible matching-package process wins over a newer wrong-package process'
$script:processes = @($script:processes[0])
$process = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName
Assert ($process.Id -eq 10) 'background-only package process also satisfies process launch validation'
$exitedProbe = $script:processes[0].PSObject.Copy()
$exitedProbe.Id = 999
$script:processes = @($exitedProbe, $script:processes[0])
$process = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName
Assert ($process.Id -eq 10) 'a process that exits during inspection is retried instead of being accepted'
$script:processes = @($script:processes[1])
$script:denied = $true
$rejected = $false
try { $null = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName -TimeoutSeconds 1 } catch { $rejected = $_.Exception.Message -like '*did not start from the installed package path*' }
Assert $rejected 'unreadable process identity still fails closed'
$script:denied = $false

foreach ($file in @('repatch-model-experience-recoverable.ps1', 'patch_codex_fast_mode_windows_msix.ps1')) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $file))
  Assert ($text.Contains("lib\appx-launch.ps1")) "$file uses the shared activation helper"
  Assert (-not $text.Contains('shell:AppsFolder')) "$file no longer depends on elevated Explorer Shell activation"
  Assert ($text.Contains('Wait-InstalledAppxDesktopProcess')) "$file keeps exact-package process acceptance"
}
Write-Output "APPX_LAUNCH_TESTS_PASSED checks=$script:checks"
