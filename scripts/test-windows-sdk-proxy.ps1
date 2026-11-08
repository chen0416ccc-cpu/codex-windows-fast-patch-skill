param()
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'build-remote-control-native-replacement.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'SDK build script parsing failed.' }
foreach ($name in @('Get-WindowsSdkDownloadProxy', 'Get-SanitizedDownloadErrorText', 'Save-NuGetPackage', 'Fail')) {
  $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  if (-not $functionAst) { throw "SDK proxy helper missing: $name" }
  . ([scriptblock]::Create($functionAst.Extent.Text))
}
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}
$names = @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
  $WindowsSdkProxy = $null
  $NoWindowsSdkProxy = $false
  Assert ($null -eq (Get-WindowsSdkDownloadProxy)) 'an unconfigured environment must not invent a local proxy'
  $env:HTTP_PROXY = 'http://http-proxy.test:3128'
  Assert ((Get-WindowsSdkDownloadProxy).Uri -eq $env:HTTP_PROXY) 'HTTP_PROXY must be honored'
  $env:HTTPS_PROXY = 'http://https-proxy.test:3128'
  Assert ((Get-WindowsSdkDownloadProxy).Uri -eq $env:HTTPS_PROXY) 'HTTPS_PROXY must take precedence for SDK HTTPS downloads'
  $WindowsSdkProxy = 'http://explicit.test:8888'
  Assert ((Get-WindowsSdkDownloadProxy).Uri -eq $WindowsSdkProxy) 'explicit SDK proxy must take precedence over environment settings'
  $env:NO_PROXY = '.nuget.org'
  Assert ((Get-WindowsSdkDownloadProxy).Direct) 'NO_PROXY domain suffix must bypass the SDK proxy'
  $env:NO_PROXY = 'api.nuget.org:80'
  Assert (-not (Get-WindowsSdkDownloadProxy).Direct) 'NO_PROXY port must match the requested endpoint'
  $env:NO_PROXY = 'api.nuget.org:443'
  Assert ((Get-WindowsSdkDownloadProxy).Direct) 'matching NO_PROXY host and port must bypass'
  $env:NO_PROXY = '*'
  Assert ((Get-WindowsSdkDownloadProxy).Direct) 'NO_PROXY wildcard must bypass all endpoints'
  $env:NO_PROXY = 'other.test'
  $WindowsSdkProxy = $null
  $NoWindowsSdkProxy = $true
  Assert ((Get-WindowsSdkDownloadProxy).Direct) 'explicit direct mode must ignore proxy environment variables'
  $WindowsSdkProxy = 'http://explicit.test:8888'
  $rejected = $false
  try { $null = Get-WindowsSdkDownloadProxy } catch { $rejected = $true }
  Assert $rejected 'contradictory explicit proxy modes must fail'
  $safe = Get-SanitizedDownloadErrorText -Text 'proxy=http://user:secret@proxy.test:3128' -ProxyUri 'http://user:secret@proxy.test:3128'
  Assert (-not $safe.Contains('secret') -and -not $safe.Contains('proxy.test')) 'download diagnostics must not expose proxy credentials or configured URI'

  $fixture = Join-Path ([IO.Path]::GetTempPath()) ('sdk-proxy-fixture-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $fixture | Out-Null
  function Write-Log { param($Message) }
  function Test-NuGetPackageArchive { param($PackagePath, $ExpectedPayloadNames) return (Test-Path -LiteralPath $PackagePath -PathType Leaf) }
  function Get-Command { param($Name, $ErrorAction) if ($Name -eq 'curl.exe') { return [pscustomobject]@{ Source = 'mock-curl' } }; throw 'Unexpected command lookup.' }
  function Invoke-NativeProcess {
    param($FilePath, $Arguments, [switch]$CaptureOutput)
    $script:capturedArguments = $Arguments
    $target = $Arguments[[array]::IndexOf($Arguments, '-o') + 1]
    [IO.File]::WriteAllText($target, 'validated fixture package')
    return [pscustomobject]@{ ExitCode = 0; Output = '' }
  }
  try {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    $WindowsSdkProxy = $null; $NoWindowsSdkProxy = $false
    Save-NuGetPackage -PackageId 'Fixture' -Version '1.0' -Destination (Join-Path $fixture 'default.nupkg') -ExpectedPayloadNames @('fixture')
    Assert ($script:capturedArguments -notcontains '--proxy' -and $script:capturedArguments -notcontains '--noproxy') 'unconfigured downloads must preserve the backend default route'
    $WindowsSdkProxy = 'http://explicit.test:8888'
    Save-NuGetPackage -PackageId 'Fixture' -Version '1.0' -Destination (Join-Path $fixture 'proxy.nupkg') -ExpectedPayloadNames @('fixture')
    Assert ($script:capturedArguments -contains '--proxy' -and $script:capturedArguments -contains $WindowsSdkProxy) 'explicit proxy must reach the actual downloader arguments'
    $WindowsSdkProxy = $null; $NoWindowsSdkProxy = $true
    $env:HTTPS_PROXY = 'http://must-not-use.test:3128'
    Save-NuGetPackage -PackageId 'Fixture' -Version '1.0' -Destination (Join-Path $fixture 'direct.nupkg') -ExpectedPayloadNames @('fixture')
    Assert ($script:capturedArguments -contains '--noproxy' -and $script:capturedArguments -contains '*' -and $script:capturedArguments -notcontains '--proxy') 'explicit direct mode must disable inherited proxy routing at the downloader'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'direct.nupkg.partial'))) 'validated downloads must promote the partial file without residue'
  } finally {
    $full = [IO.Path]::GetFullPath($fixture)
    if ((Split-Path -Parent $full) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
        (Split-Path -Leaf $full) -notmatch '^sdk-proxy-fixture-[a-f0-9]{32}$') { throw 'SDK test cleanup boundary changed.' }
    Remove-Item -LiteralPath $full -Recurse -Force
  }
} finally {
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
Write-Output "WINDOWS_SDK_PROXY_TESTS_PASSED checks=$script:checks"
