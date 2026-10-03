[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DesktopExe,
    [Parameter(Mandatory=$true)][string]$ExpectedPackageFullName,
    [Parameter(Mandatory=$true)][ValidatePattern('^http://127\.0\.0\.1:\d+$')][string]$ProxyUrl
)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexProxyPackageIdentity {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]
  public static extern int GetCurrentPackageFullName(ref uint length, StringBuilder name);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]
  public static extern int GetPackageFullName(IntPtr process, ref uint length, StringBuilder name);
  public static string ReadProcess(IntPtr process) {
    uint length=0;
    int result=GetPackageFullName(process,ref length,null);
    if(result!=122)throw new InvalidOperationException("Child package identity unavailable: "+result);
    var name=new StringBuilder((int)length);
    result=GetPackageFullName(process,ref length,name);
    if(result!=0)throw new InvalidOperationException("Child package identity read failed: "+result);
    return name.ToString();
  }
  public static string Read() {
    uint length=0;
    int result=GetCurrentPackageFullName(ref length,null);
    if(result!=122)throw new InvalidOperationException("Package identity unavailable: "+result);
    var name=new StringBuilder((int)length);
    result=GetCurrentPackageFullName(ref length,name);
    if(result!=0)throw new InvalidOperationException("Package identity read failed: "+result);
    return name.ToString();
  }
}
'@
if([CodexProxyPackageIdentity]::Read() -ne $ExpectedPackageFullName){throw 'Package identity does not match the requested Codex package.'}
if(-not(Test-Path -LiteralPath $DesktopExe -PathType Leaf)){throw 'Codex Desktop executable is missing.'}
$env:HTTP_PROXY=$ProxyUrl
$env:HTTPS_PROXY=$ProxyUrl
$env:ALL_PROXY=$ProxyUrl
$env:WS_PROXY=$ProxyUrl
$env:WSS_PROXY=$ProxyUrl
$env:NO_PROXY='localhost,127.0.0.1,::1'
$env:NODE_USE_ENV_PROXY='1'
$env:ELECTRON_GET_USE_PROXY='1'
$arguments="--proxy-server=$ProxyUrl --proxy-bypass-list=localhost;127.0.0.1;[::1] --disable-quic"
$startInfo=[Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName=$DesktopExe
$startInfo.Arguments=$arguments
$startInfo.WorkingDirectory=Split-Path -Parent $DesktopExe
$startInfo.UseShellExecute=$false
$desktop=[Diagnostics.Process]::Start($startInfo)
if([CodexProxyPackageIdentity]::ReadProcess($desktop.Handle) -ne $ExpectedPackageFullName){throw 'Child package identity does not match.'}
Start-Sleep -Seconds 3
$desktop.Refresh()
if($desktop.HasExited){throw 'Direct Desktop child exited; a broker PID is not successful startup.'}
[ordered]@{package=$ExpectedPackageFullName;rootPid=$desktop.Id;helperPid=$PID;time=(Get-Date).ToString('o');proxyEnvironmentSetInPackage=$true;useShellExecute=$false;childIdentityVerified=$true;childSurvivedStartup=$true}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.codex\last-proxy-launch.json') -Encoding UTF8
