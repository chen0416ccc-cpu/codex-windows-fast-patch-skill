[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$WorkRoot,

  [string]$CodexRepoUrl = 'https://github.com/openai/codex.git',
  [string]$CodexSourceRef,
  [string]$AppServerVersion,
  [string]$PatchPathOverride,
  [string]$SourceRoot,
  [string]$CacheRoot,
  [string]$TempRoot,
  [string]$TargetRoot,
  [string]$RustToolchain = '1.95.0-x86_64-pc-windows-msvc',
  [string]$BuildTarget = 'x86_64-pc-windows-msvc',
  [string]$BuildProfile = 'dev-small',
  [switch]$SkipClone,
  [switch]$SkipPatch,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$SkillRoot = Split-Path -Parent $ScriptRoot
$NativePatchRelativePaths = @{
  '0.142.4' = 'references\remote-control-native-replacement-0.142.4.patch'
  '0.144.0-alpha.4' = 'references\remote-control-native-replacement.patch'
  '0.145.0-alpha.18' = 'references\remote-control-native-replacement-0.145.0-alpha.18.patch'
}
$PatchPath = $null
$WindowsSdkCppVersion = '10.0.26100.4188'
$WindowsSdkCppPackageIds = @(
  'Microsoft.Windows.SDK.CPP',
  'Microsoft.Windows.SDK.CPP.x64'
)

function Write-Log {
  param([string]$Message)
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Fail {
  param([string]$Message)
  throw $Message
}

function Get-SupportedNativePatchVersions {
  return @($NativePatchRelativePaths.Keys | Sort-Object)
}

function Resolve-NativePatchPath {
  $supported = (Get-SupportedNativePatchVersions) -join ', '
  if ([string]::IsNullOrWhiteSpace($CodexSourceRef) -or $CodexSourceRef.Trim() -notmatch '^rust-v(.+)$') {
    Fail "CodexSourceRef must be a supported rust-v<version> tag. Supported bundled native patch versions: $supported. For another source ref, provide a validated patch with -PatchPathOverride."
  }
  $sourceVersion = $Matches[1]
  if ([string]::IsNullOrWhiteSpace($AppServerVersion) -or $AppServerVersion.Trim() -ne $sourceVersion) {
    Fail "CodexSourceRef and AppServerVersion must match. CodexSourceRef=$CodexSourceRef AppServerVersion=$AppServerVersion"
  }
  if (-not [string]::IsNullOrWhiteSpace($PatchPathOverride)) {
    $resolvedOverride = Resolve-FullPath $PatchPathOverride.Trim()
    if (-not (Test-Path -LiteralPath $resolvedOverride -PathType Leaf)) {
      Fail "PatchPathOverride does not exist: $resolvedOverride"
    }
    Write-Log "using explicit native patch override for Codex Rust ${sourceVersion}: $resolvedOverride"
    return $resolvedOverride
  }
  if (-not $NativePatchRelativePaths.ContainsKey($sourceVersion)) {
    Fail "No bundled native patch is available for Codex Rust ${sourceVersion}. Supported bundled native patch versions: $supported. Provide a validated version-specific patch with -PatchPathOverride."
  }
  $resolved = Join-Path $SkillRoot $NativePatchRelativePaths[$sourceVersion]
  Write-Log "selected bundled native patch for Codex Rust ${sourceVersion}: $resolved"
  return $resolved
}

function Resolve-NativeBuildVersion {
  $hasSourceRef = -not [string]::IsNullOrWhiteSpace($CodexSourceRef)
  $hasAppServerVersion = -not [string]::IsNullOrWhiteSpace($AppServerVersion)
  if ($hasSourceRef -xor $hasAppServerVersion) {
    Fail 'CodexSourceRef and AppServerVersion must be supplied together.'
  }
  if ($hasSourceRef) {
    return
  }

  $getAppxPackage = Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue
  if (-not $getAppxPackage) {
    Fail 'Cannot auto-detect the installed native Codex version because Get-AppxPackage is unavailable. Supply -CodexSourceRef and -AppServerVersion explicitly.'
  }
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $package -or [string]::IsNullOrWhiteSpace($package.InstallLocation)) {
    Fail 'Cannot auto-detect the installed native Codex version because OpenAI.Codex is not installed. Supply -CodexSourceRef and -AppServerVersion explicitly.'
  }
  $installedNative = Join-Path $package.InstallLocation 'app\resources\codex.exe'
  if (-not (Test-Path -LiteralPath $installedNative -PathType Leaf)) {
    Fail "Cannot auto-detect the installed native Codex version because codex.exe is missing: $installedNative. Supply -CodexSourceRef and -AppServerVersion explicitly."
  }

  $probe = Join-Path $TempRoot ('installed-native-version-probe-' + [guid]::NewGuid().ToString('N') + '.exe')
  Copy-Item -LiteralPath $installedNative -Destination $probe -Force
  try {
    $result = Invoke-NativeProcess -FilePath $probe -Arguments @('--version') -CaptureOutput
  } finally {
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  }
  $versionMatch = [regex]::Match($result.Output, '(?im)\bcodex-cli\s+([^\s]+)')
  if ($result.ExitCode -ne 0 -or -not $versionMatch.Success) {
    Fail "Could not parse the installed native Codex version from a WorkRoot copy. Supply -CodexSourceRef and -AppServerVersion explicitly. Output: $($result.Output.Trim())"
  }
  $detectedVersion = $versionMatch.Groups[1].Value.Trim()
  if (-not $NativePatchRelativePaths.ContainsKey($detectedVersion)) {
    $supported = (Get-SupportedNativePatchVersions) -join ', '
    Fail "Installed native Codex version $detectedVersion has no bundled patch mapping. Supported bundled patch versions: $supported. Supply matching -CodexSourceRef, -AppServerVersion, and -PatchPathOverride explicitly."
  }
  $script:CodexSourceRef = "rust-v$detectedVersion"
  $script:AppServerVersion = $detectedVersion
  Write-Log "auto-detected installed native Codex version from WorkRoot copy: $detectedVersion"
}

function Resolve-FullPath {
  param([string]$Path)
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-RequiredCommand {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    Fail "required command not found: $Name"
  }
  return $cmd.Source
}

function Import-MsvcBuildEnvironment {
  if ($BuildTarget -notlike '*windows-msvc') {
    return
  }
  $cl = Get-Command 'cl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  $link = Get-Command 'link.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cl -and $link) {
    Write-Log "MSVC build environment already available: $($cl.Source)"
    return
  }

  $vswhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  if ($vswhereCandidates.Count -eq 0) {
    Fail "MSVC Build Tools were not found. Install Visual Studio Build Tools 2022 with the C++ workload, then rerun this script. winget example: winget install --id Microsoft.VisualStudio.2022.BuildTools --source winget --override `"--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`""
  }

  $vswhere = $vswhereCandidates | Select-Object -First 1
  $installationPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($installationPath)) {
    Fail "Visual Studio Build Tools were found, but the C++ x64 tools are missing. Install the Microsoft.VisualStudio.Workload.VCTools workload, then rerun this script."
  }
  $vcvars = Join-Path $installationPath 'VC\Auxiliary\Build\vcvars64.bat'
  if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
    Fail "vcvars64.bat not found under Visual Studio installation: $vcvars"
  }

  Write-Log "loading MSVC build environment: $vcvars"
  $envLines = & cmd.exe /s /c "`"$vcvars`" >nul && set"
  if ($LASTEXITCODE -ne 0) {
    Fail "failed to load MSVC build environment from vcvars64.bat (exit code $LASTEXITCODE)"
  }
  foreach ($line in $envLines) {
    $idx = $line.IndexOf('=')
    if ($idx -le 0) {
      continue
    }
    [Environment]::SetEnvironmentVariable($line.Substring(0, $idx), $line.Substring($idx + 1), 'Process')
  }

  $cl = Get-Command 'cl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  $link = Get-Command 'link.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not ($cl -and $link)) {
    Fail "MSVC build environment did not provide cl.exe and link.exe after loading vcvars64.bat."
  }
  Write-Log "MSVC build environment loaded: $($cl.Source)"
}

function Add-ProcessEnvironmentPaths {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Paths
  )

  $comparison = [StringComparer]::OrdinalIgnoreCase
  $entries = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ($comparison)
  foreach ($path in $Paths + @(([Environment]::GetEnvironmentVariable($Name, 'Process') -split ';'))) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    $trimmed = $path.Trim().TrimEnd('\')
    if ((Test-Path -LiteralPath $trimmed -PathType Container) -and $seen.Add($trimmed)) {
      $entries.Add($trimmed)
    }
  }
  [Environment]::SetEnvironmentVariable($Name, ($entries -join ';'), 'Process')
}

function Test-WindowsSdkBuildEnvironmentAvailable {
  $kernel32Available = $false
  $ucrtAvailable = $false
  foreach ($entry in @($env:LIB -split ';')) {
    if ([string]::IsNullOrWhiteSpace($entry)) {
      continue
    }
    if (Test-Path -LiteralPath (Join-Path $entry.Trim() 'kernel32.lib') -PathType Leaf) {
      $kernel32Available = $true
    }
    if (Test-Path -LiteralPath (Join-Path $entry.Trim() 'ucrt.lib') -PathType Leaf) {
      $ucrtAvailable = $true
    }
  }
  $windowsHeaderAvailable = $false
  foreach ($entry in @($env:INCLUDE -split ';')) {
    if (-not [string]::IsNullOrWhiteSpace($entry) -and (Test-Path -LiteralPath (Join-Path $entry.Trim() 'windows.h') -PathType Leaf)) {
      $windowsHeaderAvailable = $true
      break
    }
  }
  return ($kernel32Available -and $ucrtAvailable -and $windowsHeaderAvailable)
}

function Find-WindowsSdkFile {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$FileName,
    [string]$PathPattern
  )

  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $null
  }
  $hits = foreach ($hit in @(Get-ChildItem -LiteralPath $Root -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($PathPattern) -or $hit.FullName -match $PathPattern) {
      $hit
    }
  }
  return $hits | Sort-Object FullName -Descending | Select-Object -First 1
}

function Get-WindowsSdkBuildEnvironmentCandidate {
  param([Parameter(Mandatory = $true)][string]$Root)

  $resolvedRoot = Resolve-FullPath $Root
  $kernels = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Filter 'kernel32.lib' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '(?i)\\x64\\kernel32\.lib$' } |
    Sort-Object FullName -Descending
  foreach ($kernel32 in $kernels) {
    $installedMatch = [regex]::Match($kernel32.FullName, '(?i)\\Lib\\(?<version>[^\\]+)\\um\\x64\\kernel32\.lib$')
    if ($installedMatch.Success) {
      $sdkRoot = $kernel32.FullName.Substring(0, $installedMatch.Index)
      $version = $installedMatch.Groups['version'].Value
      $ucrtPath = Join-Path $sdkRoot "Lib\$version\ucrt\x64\ucrt.lib"
      $windowsHeaderPath = Join-Path $sdkRoot "Include\$version\um\Windows.h"
      if (-not (Test-Path -LiteralPath $ucrtPath -PathType Leaf) -or -not (Test-Path -LiteralPath $windowsHeaderPath -PathType Leaf)) {
        continue
      }
      $tool = Find-WindowsSdkFile -Root (Join-Path $sdkRoot 'bin') -FileName 'rc.exe' -PathPattern "(?i)\\$([regex]::Escape($version))\\x64\\rc\.exe$"
      return [pscustomobject]@{
        Root = $sdkRoot
        Version = $version
        Kernel32 = $kernel32
        Ucrt = Get-Item -LiteralPath $ucrtPath
        WindowsHeader = Get-Item -LiteralPath $windowsHeaderPath
        Tool = $tool
      }
    }

  }
  return $null
}

function Add-WindowsSdkBuildEnvironment {
  param([Parameter(Mandatory = $true)][string[]]$SearchRoots)

  $candidate = $null
  foreach ($root in $SearchRoots) {
    $candidate = Get-WindowsSdkBuildEnvironmentCandidate -Root $root
    if ($candidate) {
      break
    }
  }
  if (-not $candidate) {
    return $false
  }

  $includeRoot = Split-Path -Parent $candidate.WindowsHeader.DirectoryName
  $includePaths = @('ucrt', 'shared', 'um', 'winrt', 'cppwinrt') |
    ForEach-Object { Join-Path $includeRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container }
  if ($includePaths.Count -eq 0) {
    return $false
  }

  Add-ProcessEnvironmentPaths -Name 'LIB' -Paths @($candidate.Kernel32.DirectoryName, $candidate.Ucrt.DirectoryName)
  Add-ProcessEnvironmentPaths -Name 'LIBPATH' -Paths @($candidate.Kernel32.DirectoryName, $candidate.Ucrt.DirectoryName)
  Add-ProcessEnvironmentPaths -Name 'INCLUDE' -Paths $includePaths

  if ($candidate.Tool) {
    Add-ProcessEnvironmentPaths -Name 'PATH' -Paths @($candidate.Tool.DirectoryName)
  }

  Write-Log "Windows SDK build environment ready: root=$($candidate.Root) version=$($candidate.Version) kernel32=$($candidate.Kernel32.FullName)"
  return (Test-WindowsSdkBuildEnvironmentAvailable)
}

function Add-NuGetWindowsSdkBuildEnvironment {
  param([Parameter(Mandatory = $true)][string]$Root)

  $kernel32 = Find-WindowsSdkFile -Root $Root -FileName 'kernel32.lib' -PathPattern '(?i)\\c\\um\\x64\\kernel32\.lib$'
  $ucrt = Find-WindowsSdkFile -Root $Root -FileName 'ucrt.lib' -PathPattern '(?i)\\c\\ucrt\\x64\\ucrt\.lib$'
  $windowsHeader = Find-WindowsSdkFile -Root $Root -FileName 'windows.h' -PathPattern '(?i)\\c\\Include\\[^\\]+\\um\\Windows\.h$'
  if (-not ($kernel32 -and $ucrt -and $windowsHeader)) {
    return $false
  }

  $includeRoot = Split-Path -Parent $windowsHeader.DirectoryName
  $includePaths = @('ucrt', 'shared', 'um', 'winrt', 'cppwinrt') |
    ForEach-Object { Join-Path $includeRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container }
  if ($includePaths.Count -eq 0) {
    return $false
  }

  Add-ProcessEnvironmentPaths -Name 'LIB' -Paths @($kernel32.DirectoryName, $ucrt.DirectoryName)
  Add-ProcessEnvironmentPaths -Name 'LIBPATH' -Paths @($kernel32.DirectoryName, $ucrt.DirectoryName)
  Add-ProcessEnvironmentPaths -Name 'INCLUDE' -Paths $includePaths

  $rc = Find-WindowsSdkFile -Root $Root -FileName 'rc.exe' -PathPattern '(?i)\\c\\bin\\[^\\]+\\x64\\rc\.exe$'
  if ($rc) {
    Add-ProcessEnvironmentPaths -Name 'PATH' -Paths @($rc.DirectoryName)
  }

  Write-Log "NuGet Windows SDK build environment ready: root=$Root kernel32=$($kernel32.FullName) ucrt=$($ucrt.FullName) windowsHeader=$($windowsHeader.FullName)"
  return (Test-WindowsSdkBuildEnvironmentAvailable)
}

function Get-WindowsSdkDownloadProxy {
  foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return [pscustomobject]@{ Uri = $value.Trim(); Source = $name }
    }
  }

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $connect = $client.BeginConnect('127.0.0.1', 10808, $null, $null)
    if ($connect.AsyncWaitHandle.WaitOne(500) -and $client.Connected) {
      $client.EndConnect($connect)
      return [pscustomobject]@{ Uri = 'http://127.0.0.1:10808'; Source = 'listening local proxy' }
    }
  } catch {
    # Direct download remains available when the optional local proxy is absent.
  } finally {
    $client.Dispose()
  }
  return $null
}

function Get-SanitizedDownloadErrorText {
  param(
    [string]$Text,
    [string]$ProxyUri
  )
  $safe = [string]$Text
  if (-not [string]::IsNullOrWhiteSpace($ProxyUri)) {
    $safe = $safe.Replace($ProxyUri, '<configured proxy>')
  }
  return [regex]::Replace($safe, '(?i)(https?://)[^/@\s]+@', '$1<credentials-redacted>@')
}

function Test-NuGetPackageArchive {
  param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string[]]$ExpectedPayloadNames
  )
  if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf) -or (Get-Item -LiteralPath $PackagePath).Length -le 100000) {
    return $false
  }
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
      $remaining = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($name in $ExpectedPayloadNames) {
        [void]$remaining.Add($name)
      }
      foreach ($entry in $archive.Entries) {
        if ($entry.Length -gt 0) {
          [void]$remaining.Remove([System.IO.Path]::GetFileName($entry.FullName))
        }
        if ($remaining.Count -eq 0) {
          return $true
        }
      }
    } finally {
      $archive.Dispose()
    }
  } catch {
    return $false
  }
  return $false
}

function Save-NuGetPackage {
  param(
    [Parameter(Mandatory = $true)][string]$PackageId,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string[]]$ExpectedPayloadNames
  )

  if (Test-NuGetPackageArchive -PackagePath $Destination -ExpectedPayloadNames $ExpectedPayloadNames) {
    Write-Log "using cached NuGet package: $Destination"
    return
  }
  if (Test-Path -LiteralPath $Destination) {
    Write-Log "removing invalid cached NuGet package: $Destination"
    Remove-Item -LiteralPath $Destination -Force
  }
  $partial = "$Destination.partial"
  Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

  $lowerId = $PackageId.ToLowerInvariant()
  $url = "https://api.nuget.org/v3-flatcontainer/$lowerId/$Version/$lowerId.$Version.nupkg"
  $proxy = Get-WindowsSdkDownloadProxy
  $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proxy) {
    Write-Log "using $($proxy.Source) for Windows SDK NuGet download"
  } else {
    Write-Log 'using direct Windows SDK NuGet download'
  }

  for ($attempt = 1; $attempt -le 3; $attempt++) {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    try {
      Write-Log "downloading $PackageId $Version to $partial (attempt $attempt of 3)"
      if ($curl) {
        $arguments = @('-fsSL', '--retry', '2', '--connect-timeout', '30', '--max-time', '900', '-o', $partial, $url)
        if ($proxy) {
          $arguments = @('-fsSL', '--retry', '2', '--proxy', $proxy.Uri, '--connect-timeout', '30', '--max-time', '900', '-o', $partial, $url)
        }
        $result = Invoke-NativeProcess -FilePath $curl.Source -Arguments $arguments -CaptureOutput
        if ($result.ExitCode -ne 0) {
          if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
            Write-Host (Get-SanitizedDownloadErrorText -Text $result.Output -ProxyUri $(if ($proxy) { $proxy.Uri } else { '' }))
          }
          Fail "failed to download $PackageId $Version (curl exit code $($result.ExitCode))"
        }
      } else {
        $oldProgress = $ProgressPreference
        try {
          $ProgressPreference = 'SilentlyContinue'
          $request = @{
            Uri = $url
            OutFile = $partial
            UseBasicParsing = $true
            TimeoutSec = 900
          }
          if ($proxy) {
            $request.Proxy = $proxy.Uri
          }
          Invoke-WebRequest @request
        } finally {
          $ProgressPreference = $oldProgress
        }
      }

      if (-not (Test-NuGetPackageArchive -PackagePath $partial -ExpectedPayloadNames $ExpectedPayloadNames)) {
        Fail "downloaded NuGet package is not a valid ZIP with expected payloads $($ExpectedPayloadNames -join ', '): $PackageId $Version"
      }
      Move-Item -LiteralPath $partial -Destination $Destination -Force
      return
    } catch {
      $failure = $_
      Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
      $safeFailureMessage = Get-SanitizedDownloadErrorText -Text $failure.Exception.Message -ProxyUri $(if ($proxy) { $proxy.Uri } else { '' })
      if ($attempt -ge 3) {
        Fail "failed to download $PackageId $Version after 3 attempts: $safeFailureMessage"
      }
      Write-Log "Windows SDK NuGet download attempt $attempt failed; retrying: $safeFailureMessage"
      Start-Sleep -Seconds ([Math]::Min(5, $attempt * 2))
    }
  }
}

function Expand-NuGetPackageArchive {
  param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  $tar = Get-RequiredCommand 'tar.exe'
  $result = Invoke-NativeProcess -FilePath $tar -Arguments @(
    '-xf',
    $PackagePath,
    '-C',
    $DestinationPath
  ) -CaptureOutput
  if ($result.ExitCode -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
      Write-Host $result.Output
    }
    Fail "failed to extract NuGet package with tar.exe: $PackagePath (exit code $($result.ExitCode))"
  }
}

function Install-WindowsSdkCppViaNuGet {
  param([Parameter(Mandatory = $true)][string]$SdkCacheRoot)

  Test-PathUnderRoot -Path $SdkCacheRoot -Root $WorkRoot -Label 'WindowsSdkCacheRoot'
  New-Item -ItemType Directory -Force -Path $SdkCacheRoot | Out-Null
  foreach ($packageId in $WindowsSdkCppPackageIds) {
    $lowerId = $packageId.ToLowerInvariant()
    $nupkg = Join-Path $SdkCacheRoot "$lowerId.$WindowsSdkCppVersion.nupkg"
    $packageRoot = Join-Path $SdkCacheRoot "$lowerId.$WindowsSdkCppVersion"
    $payloadNames = if ($packageId -ieq 'Microsoft.Windows.SDK.CPP.x64') { @('kernel32.lib', 'ucrt.lib') } else { @('windows.h') }
    $hasPayload = (Test-Path -LiteralPath $packageRoot -PathType Container) -and
      (@($payloadNames | Where-Object {
        $null -eq (Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter $_ -File -ErrorAction SilentlyContinue | Select-Object -First 1)
      }).Count -eq 0)
    if ($hasPayload) {
      Write-Log "using extracted NuGet package: $packageRoot"
      continue
    }

    $installed = $false
    for ($attempt = 1; $attempt -le 2 -and -not $installed; $attempt++) {
      $extractPartial = "$packageRoot.partial"
      try {
        Save-NuGetPackage -PackageId $packageId -Version $WindowsSdkCppVersion -Destination $nupkg -ExpectedPayloadNames $payloadNames
        Remove-Item -LiteralPath $extractPartial -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $extractPartial | Out-Null
        Expand-NuGetPackageArchive -PackagePath $nupkg -DestinationPath $extractPartial
        $missingPayloads = @($payloadNames | Where-Object {
          $null -eq (Get-ChildItem -LiteralPath $extractPartial -Recurse -Filter $_ -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        })
        if ($missingPayloads.Count -gt 0) {
          throw "extracted package is missing expected payloads: $($missingPayloads -join ', ')"
        }
        Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $extractPartial -Destination $packageRoot
        $installed = $true
      } catch {
        Remove-Item -LiteralPath $extractPartial -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $nupkg -Force -ErrorAction SilentlyContinue
        if ($attempt -ge 2) {
          throw
        }
        Write-Log "cached/downloaded $PackageId package was unusable; deleting it and retrying once"
      }
    }
  }
  return $SdkCacheRoot
}

function Initialize-WindowsSdkBuildEnvironment {
  if ($BuildTarget -notlike '*windows-msvc') {
    return
  }
  if (Test-WindowsSdkBuildEnvironmentAvailable) {
    Write-Log 'Windows SDK libraries and headers already available from the MSVC environment'
    return
  }

  $installedRoots = @(
    $env:WindowsSdkDir,
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
  if ($installedRoots.Count -gt 0 -and (Add-WindowsSdkBuildEnvironment -SearchRoots $installedRoots)) {
    Write-Log 'using an existing Windows SDK installation; NuGet bootstrap not needed'
    return
  }

  $sdkCacheRoot = Join-Path $CacheRoot "windows-sdk-cpp\$WindowsSdkCppVersion"
  Write-Log "kernel32.lib is unavailable; bootstrapping Windows SDK C++ packages under WorkRoot: $sdkCacheRoot"
  $coherentSdkRoot = Install-WindowsSdkCppViaNuGet -SdkCacheRoot $sdkCacheRoot
  $sdkReady = Add-WindowsSdkBuildEnvironment -SearchRoots @($coherentSdkRoot)
  if (-not $sdkReady) {
    $sdkReady = Add-NuGetWindowsSdkBuildEnvironment -Root $coherentSdkRoot
  }
  if (-not $sdkReady) {
    Fail "NuGet Windows SDK C++ packages did not provide a usable x64 kernel32.lib/ucrt.lib/header environment: $sdkCacheRoot"
  }
}

function ConvertTo-NativeArgumentString {
  param([AllowNull()][string]$Argument)
  if ($null -eq $Argument) {
    return '""'
  }
  $arg = [string]$Argument
  if ($arg.Length -gt 0 -and $arg -notmatch '[\s"]') {
    return $arg
  }

  $result = New-Object System.Text.StringBuilder
  [void]$result.Append('"')
  $backslashes = 0
  foreach ($ch in $arg.ToCharArray()) {
    if ($ch -eq '\') {
      $backslashes++
      continue
    }
    if ($ch -eq '"') {
      [void]$result.Append(('\' * (($backslashes * 2) + 1)))
      [void]$result.Append('"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$result.Append(('\' * $backslashes))
      $backslashes = 0
    }
    [void]$result.Append($ch)
  }
  if ($backslashes -gt 0) {
    [void]$result.Append(('\' * ($backslashes * 2)))
  }
  [void]$result.Append('"')
  return $result.ToString()
}

function Join-NativeArgumentString {
  param([string[]]$Arguments)
  $quoted = New-Object System.Collections.Generic.List[string]
  foreach ($argument in $Arguments) {
    $quoted.Add((ConvertTo-NativeArgumentString -Argument $argument))
  }
  return ($quoted -join ' ')
}

function Invoke-NativeProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$WorkingDirectory,
    [switch]$CaptureOutput
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = Join-NativeArgumentString -Arguments $Arguments
  if ($WorkingDirectory) {
    $psi.WorkingDirectory = $WorkingDirectory
  }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi

  if ($CaptureOutput) {
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Output = (($stdout, $stderr | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join [Environment]::NewLine)
    }
  }

  $stdoutHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      Write-Host $eventArgs.Data
    }
  }
  $stderrHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      Write-Host $eventArgs.Data
    }
  }
  $process.add_OutputDataReceived($stdoutHandler)
  $process.add_ErrorDataReceived($stderrHandler)
  try {
    [void]$process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $process.WaitForExit()
    # WaitForExit() again flushes async event handlers on Windows PowerShell.
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Output = ''
    }
  } finally {
    $process.remove_OutputDataReceived($stdoutHandler)
    $process.remove_ErrorDataReceived($stderrHandler)
    $process.Dispose()
  }
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$ErrorMessage,
    [string]$WorkingDirectory
  )
  $prefix = if ($WorkingDirectory) { "[$WorkingDirectory] " } else { '' }
  Write-Log "$prefix$FilePath $($Arguments -join ' ')"
  $oldErrorActionPreference = $ErrorActionPreference
  $hadNativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
  if ($hadNativeErrorPreference) {
    $oldNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
  }
  try {
    $ErrorActionPreference = 'Continue'
    if ($hadNativeErrorPreference) {
      $PSNativeCommandUseErrorActionPreference = $false
    }
    if ($WorkingDirectory) {
      Push-Location -LiteralPath $WorkingDirectory
      try {
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
      } finally {
        Pop-Location
      }
    } else {
      & $FilePath @Arguments
      $exitCode = $LASTEXITCODE
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
    if ($hadNativeErrorPreference) {
      $PSNativeCommandUseErrorActionPreference = $oldNativeErrorPreference
    }
  }
  if ($exitCode -ne 0) {
    Fail "$ErrorMessage (exit code $exitCode)"
  }
}

function Test-GitPatchCheck {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$PatchFile,
    [switch]$Reverse
  )
  $arguments = @('-C', $RepositoryRoot, 'apply')
  if ($Reverse) {
    $arguments += '--reverse'
  }
  $arguments += @('--check', $PatchFile)
  return Invoke-NativeProcess -FilePath $GitPath -Arguments $arguments -CaptureOutput
}

function Test-GitWorktreeDirty {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot
  )
  $status = Invoke-NativeProcess -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'status', '--porcelain') -CaptureOutput
  if ($status.ExitCode -ne 0) {
    Fail "failed to inspect Codex source git status (exit code $($status.ExitCode))"
  }
  return (-not [string]::IsNullOrWhiteSpace($status.Output))
}

function Get-GitCommit {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$Revision
  )
  $result = Invoke-NativeProcess -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'rev-parse', '--verify', "$Revision^{commit}") -CaptureOutput
  if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
    return $null
  }
  return ($result.Output.Trim() -split '\s+')[0]
}

function Resolve-CodexSourceRefCommit {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$SourceRef
  )
  $commit = Get-GitCommit -GitPath $GitPath -RepositoryRoot $RepositoryRoot -Revision $SourceRef
  if ($commit) {
    return $commit
  }
  Write-Log "fetching Codex source ref for exact commit verification: $SourceRef"
  Invoke-Checked -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'fetch', '--depth', '1', 'origin', $SourceRef) -ErrorMessage "failed to fetch Codex source ref '$SourceRef'"
  $commit = Get-GitCommit -GitPath $GitPath -RepositoryRoot $RepositoryRoot -Revision 'FETCH_HEAD'
  if (-not $commit) {
    Fail "failed to resolve Codex source ref commit: $SourceRef"
  }
  return $commit
}

function Checkout-CodexSourceRef {
  param(
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [string]$SourceRef
  )

  $ref = $SourceRef.Trim()
  if ([string]::IsNullOrWhiteSpace($ref)) {
    return
  }

  $requestedCommit = Resolve-CodexSourceRefCommit -GitPath $GitPath -RepositoryRoot $RepositoryRoot -SourceRef $ref
  $currentCommit = Get-GitCommit -GitPath $GitPath -RepositoryRoot $RepositoryRoot -Revision 'HEAD'
  if (-not $currentCommit) {
    Fail "failed to resolve current Codex source HEAD: $RepositoryRoot"
  }

  $reverseCheck = Test-GitPatchCheck -GitPath $GitPath -RepositoryRoot $RepositoryRoot -PatchFile $PatchPath -Reverse
  if ($reverseCheck.ExitCode -eq 0) {
    if ($currentCommit -ne $requestedCommit) {
      Fail "native patch is already applied, but SourceRoot HEAD does not match requested CodexSourceRef. HEAD=$currentCommit requested=$requestedCommit ref=$ref"
    }
    Write-Log "native patch already applied on requested source commit: $currentCommit"
    return
  }

  if (Test-GitWorktreeDirty -GitPath $GitPath -RepositoryRoot $RepositoryRoot) {
    Fail "SourceRoot has uncommitted changes; cannot safely check out Codex source ref '$ref'. Use a clean SourceRoot or a new WorkRoot."
  }

  Write-Log "checking out Codex source ref: $ref"
  Invoke-Checked -FilePath $GitPath -Arguments @('-C', $RepositoryRoot, 'checkout', '--detach', $requestedCommit) -ErrorMessage "failed to check out Codex source ref '$ref'"
  $checkedOutCommit = Get-GitCommit -GitPath $GitPath -RepositoryRoot $RepositoryRoot -Revision 'HEAD'
  if ($checkedOutCommit -ne $requestedCommit) {
    Fail "checked out Codex source commit does not match requested ref. HEAD=$checkedOutCommit requested=$requestedCommit ref=$ref"
  }
}

function Set-CargoWorkspacePackageVersion {
  param(
    [Parameter(Mandatory = $true)][string]$CargoManifestPath,
    [string]$Version
  )

  if ([string]::IsNullOrWhiteSpace($Version)) {
    return
  }
  $versionValue = $Version.Trim()
  if ($versionValue -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {
    Fail "invalid AppServerVersion: $versionValue"
  }

  $text = Get-Content -Raw -LiteralPath $CargoManifestPath
  $match = [regex]::Match($text, '(?ms)(^\[workspace\.package\]\s*?\r?\n)(.*?)(?=^\[|\z)')
  if (-not $match.Success) {
    Fail "Cargo workspace package section not found: $CargoManifestPath"
  }

  $section = $match.Groups[2].Value
  if ($section -notmatch '(?m)^version\s*=') {
    Fail "Cargo workspace package version not found: $CargoManifestPath"
  }

  $newSection = [regex]::Replace($section, '(?m)^version\s*=\s*"[^"]*"', "version = `"$versionValue`"", 1)
  $newText = $text.Substring(0, $match.Groups[2].Index) + $newSection + $text.Substring($match.Groups[2].Index + $match.Groups[2].Length)
  if ($newText -ne $text) {
    Set-Content -LiteralPath $CargoManifestPath -Value $newText -NoNewline
    Write-Log "set Cargo workspace package version for remote-control app-server: $versionValue"
  }
}

function Test-PathUnderRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $fullPath = Resolve-FullPath $Path
  $fullRoot = (Resolve-FullPath $Root).TrimEnd('\')
  $comparison = [StringComparison]::OrdinalIgnoreCase
  if ($fullPath.Equals($fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + '\', $comparison)) {
    return
  }
  Fail "$Label must stay under WorkRoot. $Label=$fullPath WorkRoot=$fullRoot"
}

function Test-BinaryMarkers {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Markers
  )
  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Fail "replacement codex.exe not found: $FilePath"
  }
  $remaining = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($marker in $Markers) {
    [void]$remaining.Add($marker)
  }
  $maxMarkerLength = ($Markers | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
  $chunkSize = 8MB
  $buffer = New-Object byte[] ($chunkSize + $maxMarkerLength)
  $carry = 0
  $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    while ($remaining.Count -gt 0) {
      $read = $stream.Read($buffer, $carry, $chunkSize)
      if ($read -eq 0) {
        break
      }
      $total = $carry + $read
      $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $total)
      foreach ($marker in @($remaining)) {
        if ($text.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) {
          [void]$remaining.Remove($marker)
        }
      }
      $carry = [Math]::Min([Math]::Max(0, $maxMarkerLength - 1), $total)
      if ($carry -gt 0) {
        [System.Array]::Copy($buffer, $total - $carry, $buffer, 0, $carry)
      }
    }
  } finally {
    $stream.Dispose()
  }
  if ($remaining.Count -gt 0) {
    Fail "replacement codex.exe is missing native remote-control markers: $(@($remaining) -join ', ')"
  }
  Write-Log "replacement codex.exe marker check passed: $($Markers.Count)"
}

function Get-CodexCliVersion {
  param([Parameter(Mandatory = $true)][string]$FilePath)
  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Fail "replacement codex.exe not found: $FilePath"
  }
  $result = Invoke-NativeProcess -FilePath $FilePath -Arguments @('--version') -CaptureOutput
  $match = [regex]::Match($result.Output, '(?im)\bcodex-cli\s+([^\s]+)')
  if ($result.ExitCode -ne 0 -or -not $match.Success) {
    Fail "could not parse replacement codex.exe version (exit code $($result.ExitCode)): $($result.Output.Trim())"
  }
  return $match.Groups[1].Value.Trim()
}

$WorkRoot = Resolve-FullPath $WorkRoot
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  $SourceRoot = Join-Path $WorkRoot 'codex'
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
  $CacheRoot = Join-Path $WorkRoot 'cache'
}
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $TempRoot = Join-Path $WorkRoot 'tmp'
}
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot = Join-Path $WorkRoot 'target-msvc'
}

$SourceRoot = Resolve-FullPath $SourceRoot
$CacheRoot = Resolve-FullPath $CacheRoot
$TempRoot = Resolve-FullPath $TempRoot
$TargetRoot = Resolve-FullPath $TargetRoot

foreach ($item in @(
  @{ Path = $SourceRoot; Label = 'SourceRoot' },
  @{ Path = $CacheRoot; Label = 'CacheRoot' },
  @{ Path = $TempRoot; Label = 'TempRoot' },
  @{ Path = $TargetRoot; Label = 'TargetRoot' }
)) {
  Test-PathUnderRoot -Path $item.Path -Root $WorkRoot -Label $item.Label
}

New-Item -ItemType Directory -Force -Path $WorkRoot, $CacheRoot, $TempRoot, $TargetRoot | Out-Null

$env:CARGO_HOME = Join-Path $CacheRoot 'cargo'
$env:RUSTUP_HOME = Join-Path $CacheRoot 'rustup'
$env:TEMP = $TempRoot
$env:TMP = $TempRoot
$env:CARGO_TARGET_DIR = $TargetRoot
$env:CARGO_BUILD_JOBS = '1'

Resolve-NativeBuildVersion
$PatchPath = Resolve-NativePatchPath
if (-not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
  Fail "native patch reference not found: $PatchPath"
}

$git = Get-RequiredCommand 'git'
if (-not $SkipBuild) {
  $cargo = Get-RequiredCommand 'cargo'
  Import-MsvcBuildEnvironment
  Initialize-WindowsSdkBuildEnvironment
}

if (-not $SkipClone) {
  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    $parent = Split-Path -Parent $SourceRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Invoke-Checked -FilePath $git -Arguments @(
      'clone',
      '--filter=blob:none',
      '--depth',
      '1',
      $CodexRepoUrl,
      $SourceRoot
    ) -ErrorMessage 'failed to clone Codex source'
  } else {
    Write-Log "using existing source tree: $SourceRoot"
  }
} elseif (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
  Fail "SkipClone was set but SourceRoot does not exist: $SourceRoot"
}

$gitDir = Join-Path $SourceRoot '.git'
if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
  Fail "SourceRoot is not a git checkout: $SourceRoot"
}

if (-not [string]::IsNullOrWhiteSpace($CodexSourceRef)) {
  Checkout-CodexSourceRef -GitPath $git -RepositoryRoot $SourceRoot -SourceRef $CodexSourceRef
}

if (-not $SkipPatch) {
  $reverseCheck = Test-GitPatchCheck -GitPath $git -RepositoryRoot $SourceRoot -PatchFile $PatchPath -Reverse
  if ($reverseCheck.ExitCode -eq 0) {
    Write-Log "native patch already applied"
  } else {
    $applyCheck = Test-GitPatchCheck -GitPath $git -RepositoryRoot $SourceRoot -PatchFile $PatchPath
    if ($applyCheck.ExitCode -ne 0) {
      if (-not [string]::IsNullOrWhiteSpace($applyCheck.Output)) {
        Write-Host $applyCheck.Output
      }
      $supported = (Get-SupportedNativePatchVersions) -join ', '
      Fail "native patch does not apply cleanly: $PatchPath (exit code $($applyCheck.ExitCode)). Supported bundled versions: $supported. For another source version, supply its validated patch with -PatchPathOverride."
    }
    Invoke-Checked -FilePath $git -Arguments @('-C', $SourceRoot, 'apply', $PatchPath) -ErrorMessage 'failed to apply native patch'
  }
}

$CargoWorkspaceRoot = Join-Path $SourceRoot 'codex-rs'
$CargoManifestPath = Join-Path $CargoWorkspaceRoot 'Cargo.toml'
if (-not (Test-Path -LiteralPath $CargoManifestPath -PathType Leaf)) {
  Fail "Cargo.toml not found at expected Codex Rust workspace path: $CargoManifestPath"
}
Set-CargoWorkspacePackageVersion -CargoManifestPath $CargoManifestPath -Version $AppServerVersion
$sourceCommit = Get-GitCommit -GitPath $git -RepositoryRoot $SourceRoot -Revision 'HEAD'
if (-not $sourceCommit) {
  Fail "failed to resolve source commit after checkout: $SourceRoot"
}
$patchSha256 = (Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256).Hash

Write-Log "CARGO_HOME=$env:CARGO_HOME"
Write-Log "RUSTUP_HOME=$env:RUSTUP_HOME"
Write-Log "TEMP=$env:TEMP"
Write-Log "CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR"

$builtExe = Join-Path $TargetRoot "$BuildTarget\$BuildProfile\codex.exe"
$buildStampPath = Join-Path $TargetRoot "$BuildTarget\$BuildProfile\codex.remote-control-build.json"
if (-not $SkipBuild) {
  Invoke-Checked -FilePath $cargo -Arguments @(
    "+$RustToolchain",
    'build',
    '--profile',
    $BuildProfile,
    '-p',
    'codex-cli',
    '--target',
    $BuildTarget
  ) -ErrorMessage 'failed to build patched native Codex app-server binary' -WorkingDirectory $CargoWorkspaceRoot
  [pscustomobject]@{
    schema = 'codex-remote-control-native-build-v1'
    source_ref = $CodexSourceRef
    source_commit = $sourceCommit
    app_server_version = $AppServerVersion
    patch_sha256 = $patchSha256
    rust_toolchain = $RustToolchain
    build_target = $BuildTarget
    build_profile = $BuildProfile
  } | ConvertTo-Json | Set-Content -LiteralPath $buildStampPath -Encoding UTF8
  Write-Log "wrote native build stamp: $buildStampPath"
} else {
  if (-not (Test-Path -LiteralPath $buildStampPath -PathType Leaf)) {
    Fail "SkipBuild requires a matching native build stamp, but none was found: $buildStampPath"
  }
  try {
    $buildStamp = Get-Content -Raw -LiteralPath $buildStampPath | ConvertFrom-Json
  } catch {
    Fail "SkipBuild native build stamp is invalid JSON: $buildStampPath ($($_.Exception.Message))"
  }
  $expectedStamp = @{
    schema = 'codex-remote-control-native-build-v1'
    source_ref = $CodexSourceRef
    source_commit = $sourceCommit
    app_server_version = $AppServerVersion
    patch_sha256 = $patchSha256
    rust_toolchain = $RustToolchain
    build_target = $BuildTarget
    build_profile = $BuildProfile
  }
  foreach ($key in $expectedStamp.Keys) {
    if ([string]$buildStamp.$key -ne [string]$expectedStamp[$key]) {
      Fail "SkipBuild native build stamp mismatch for ${key}: actual=$($buildStamp.$key) expected=$($expectedStamp[$key])"
    }
  }
  Write-Log 'SkipBuild native build stamp matches requested source, patch, version, toolchain, target, and profile'
}

$builtVersion = Get-CodexCliVersion -FilePath $builtExe
if ($builtVersion -ne $AppServerVersion) {
  Fail "replacement codex.exe version mismatch: actual=$builtVersion expected=$AppServerVersion file=$builtExe"
}
Write-Log "replacement codex.exe version verified: $builtVersion"
$markers = @(
  'remote_control_app_server_isolated_oauth_used',
  'remote_control_native_remote_json_first',
  'remote_control_websocket_proxy_attempt',
  'remote_control_websocket_proxy_connected',
  'remote-control-oauth.json',
  'remote.json',
  'codex.remote_control.enroll'
)
Test-BinaryMarkers -FilePath $builtExe -Markers $markers

Write-Log "replacement native binary ready: $builtExe"
[pscustomobject]@{
  ReplacementResourceCodexExe = $builtExe
  WorkRoot = $WorkRoot
  SourceRoot = $SourceRoot
  CacheRoot = $CacheRoot
  TargetRoot = $TargetRoot
  TempRoot = $TempRoot
  BuildStampPath = $buildStampPath
} | ConvertTo-Json
