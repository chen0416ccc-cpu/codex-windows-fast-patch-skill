param(
  [Parameter(Mandatory = $true)][string]$TemporaryRoot,
  [switch]$SkipWow64Child
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
$probe = '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue''' + [Environment]::NewLine +
  '$code = @''' + [Environment]::NewLine + $typeSource + [Environment]::NewLine + '''@' + [Environment]::NewLine +
  'Add-Type -TypeDefinition $code -ErrorAction Stop' + [Environment]::NewLine +
  'if ([Environment]::Is64BitProcess -ne [Environment]::Is64BitOperatingSystem) { exit 3 }' + [Environment]::NewLine +
  '$method = [PackagedAppActivation].GetMethod(''Launch'')' + [Environment]::NewLine +
  'if ($method.ReturnType -ne [uint32] -or -not $method.IsStatic) { exit 4 }' + [Environment]::NewLine +
  '''activation-contract-ok'''
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$nativeShell = Get-AppxNativePowerShellPath
$expectedSystemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
Assert ($nativeShell -ieq (Join-Path $env:WINDIR "$expectedSystemDirectory\WindowsPowerShell\v1.0\powershell.exe")) 'native shell selection accounts for WOW64 redirection'
$contract = & $nativeShell -NoProfile -EncodedCommand $encoded
Assert ($LASTEXITCODE -eq 0 -and $contract -ceq 'activation-contract-ok') 'the real system PowerShell compiles the activation wrapper in its native bitness'

# Replace only the actual app activation call; exercise the production child/output path.
$activationAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'lib\appx-launch.ps1'), [ref]$null, [ref]$null)
$activationFunction = $activationAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-InstalledAppxApplicationActivation' }, $true).Extent.Text
$activationCall = '[Console]::Out.WriteLine([PackagedAppActivation]::Launch($args[0]))'
Assert ($activationFunction.Contains($activationCall)) 'the real activation seam is present before non-interactive substitution'
# Use the real child process, replacing only COM activation, to catch installer
# scheduling leaking into the interactive Desktop and its descendants.
& {
  $self = [Diagnostics.Process]::GetCurrentProcess()
  $priority = $self.PriorityClass
  $affinity = $self.ProcessorAffinity
  try {
    $mask = $affinity.ToInt64()
    $singleCore = $mask -band (-$mask)
    $self.PriorityClass = 'Idle'
    $self.ProcessorAffinity = [IntPtr]$singleCore
    $schedulingProbe = '$child = [Diagnostics.Process]::GetCurrentProcess(); if ($child.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::Normal -or $child.ProcessorAffinity.ToInt64() -eq ' + $singleCore + ') { exit 9 }; [Console]::Out.WriteLine([uint32]53124)'
    if (($mask -band ($mask - 1)) -eq 0) {
      $schedulingProbe = '$child = [Diagnostics.Process]::GetCurrentProcess(); if ($child.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::Normal) { exit 9 }; [Console]::Out.WriteLine([uint32]53124)'
    }
    . ([scriptblock]::Create($activationFunction.Replace($activationCall, $schedulingProbe)))
    $actual = Invoke-InstalledAppxApplicationActivation -AppUserModelId 'Fixture.NoActivation!App'
    Assert ($actual -eq 53124) 'activation child restores normal interactive scheduling before COM'
    $self.Refresh()
    Assert ($self.PriorityClass -eq [Diagnostics.ProcessPriorityClass]::Idle -and $self.ProcessorAffinity.ToInt64() -eq $singleCore) 'activation leaves installer scheduling unchanged'
  } finally {
    $self.PriorityClass = $priority
    $self.ProcessorAffinity = $affinity
    $self.Dispose()
  }
}
foreach ($case in @(
  @{ Source = '[Console]::Out.WriteLine([uint32]53124)'; Expected = [uint32]53124 },
  @{ Source = '[Console]::Out.WriteLine([uint32]4294967295)'; Expected = [uint32]::MaxValue },
  @{ Source = 'exit 0'; Expected = $null },
  @{ Source = '[Console]::Out.WriteLine(''not-a-pid'')'; Expected = $null },
  @{ Source = '[Console]::Out.WriteLine(''0'')'; Expected = $null },
  @{ Source = '[Console]::Out.WriteLine(''4294967296'')'; Expected = $null },
  @{ Source = '[Console]::Out.WriteLine(''53124''); [Console]::Out.WriteLine(''53125'')'; Expected = $null },
  @{ Source = '[Console]::Out.WriteLine(''53124''); exit 7'; Expected = $null }
)) {
  & {
    . ([scriptblock]::Create($activationFunction.Replace($activationCall, $case.Source)))
    $failure = $null
    $actual = $null
    try { $actual = Invoke-InstalledAppxApplicationActivation -AppUserModelId "Fixture.NoActivation!App'Quoted" } catch { $failure = $_.Exception.Message }
    if ($null -eq $case.Expected) {
      Assert ($failure -like 'Packaged app activation failed*') "invalid child output is rejected: $($case.Source)"
    } else {
      Assert ($null -eq $failure -and $actual -eq $case.Expected) "the complete uint32 PID survives child output: $($case.Expected)"
    }
  }
}

if (-not $SkipWow64Child -and [Environment]::Is64BitOperatingSystem -and [Environment]::Is64BitProcess) {
  $wow64Shell = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
  $wow64Result = @(& $wow64Shell -NoProfile -File $PSCommandPath -TemporaryRoot (Join-Path $root 'wow64') -SkipWow64Child 2>&1)
  Assert ($LASTEXITCODE -eq 0 -and ($wow64Result -join '\n') -match 'APPX_LAUNCH_TESTS_PASSED') 'a real 32-bit parent compiles and parses activation output through the native system shell'
}

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
  $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value { if ($this.Id -eq 999) { throw 'process exited' }; if ($this.Id -eq 998 -and $script:transientExited) { $this.HasExited = $true } }
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
$script:processes = @($script:processes[0])
# A renderer can survive enumeration but exit during the startup grace period.
$stableProbe = $script:processes[0].PSObject.Copy()
$stableProbe.Id = 20
$transientProbe = $stableProbe.PSObject.Copy()
$transientProbe.Id = 998
$transientProbe.Window = [intptr]42
$script:processes = @($transientProbe, $stableProbe)
$script:transientExited = $false
function Start-Sleep {
  param([int]$Seconds, [int]$Milliseconds)
  $script:transientExited = $true
  $script:processes = @($script:processes | Where-Object Id -ne 998)
}
try {
  $process = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName -StableSeconds 4
  Assert ($process.Id -eq 20) 'startup grace-period exit retries the replacement matching-package process'
} finally { Remove-Item Function:\Start-Sleep }
$script:denied = $true
$rejected = $false
try { $null = Wait-InstalledAppxDesktopProcess -Executable $entry.Executable -ProcessName $entry.ProcessName -TimeoutSeconds 1 } catch { $rejected = $_.Exception.Message -like '*did not start from the installed package path*' }
Assert $rejected 'unreadable process identity still fails closed'
$script:denied = $false

$launcherText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'start-model-experience-repair.ps1'))
Assert ($launcherText.Contains("lib\appx-launch.ps1") -and $launcherText.Contains('$powershellExe = Get-AppxNativePowerShellPath')) 'the elevated installer bootstrap also uses native system bitness'
foreach ($file in @('repatch-model-experience-recoverable.ps1', 'patch_codex_fast_mode_windows_msix.ps1')) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $file))
  Assert ($text.Contains("lib\appx-launch.ps1")) "$file uses the shared activation helper"
  Assert (-not $text.Contains('shell:AppsFolder')) "$file no longer depends on elevated Explorer Shell activation"
  Assert ($text.Contains('Wait-InstalledAppxDesktopProcess')) "$file keeps exact-package process acceptance"
}
Write-Output "APPX_LAUNCH_TESTS_PASSED checks=$script:checks"
