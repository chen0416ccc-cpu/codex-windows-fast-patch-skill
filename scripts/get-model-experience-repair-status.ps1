[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$StatePath,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\repair-deployment-state.ps1')
$state = Read-RepairDeploymentState $StatePath
$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
$installer = $null
$probeFailed = $false
try {
  $process = Get-Process -Id ([int]$state.installerPid) -ErrorAction Stop
  $installer = [pscustomobject]@{ Id = $process.Id; StartTime = $process.StartTime; SessionId = $process.SessionId }
  if (-not $installer.StartTime) { $probeFailed = $true }
} catch {
  # An access error is not evidence of an exited installer.
  if (-not (Test-RepairProcessNotFoundError -ErrorRecord $_)) { $probeFailed = $true }
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$result = Get-RepairDeploymentAssessment -State $state -CurrentPackage $package -InstallerProcess $installer -CurrentUserSid $sid -InstallerProbeFailed:$probeFailed
if ($Json) { $result | ConvertTo-Json -Depth 4 } else { $result }
