param()
$ErrorActionPreference = 'Stop'
$checks = 0
function Assert($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}
# These are real X509 EKU extensions; no certificate/private key is written to
# any store and no trust prompt or package operation is allowed by this test.
function New-EkuFixture([string[]]$Oids) {
  $collection = [Security.Cryptography.OidCollection]::new()
  foreach ($oid in $Oids) { $null = $collection.Add([Security.Cryptography.Oid]::new($oid)) }
  $extension = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($collection, $false)
  return [pscustomobject]@{ Extensions = @($extension); EnhancedKeyUsageList = $null }
}
foreach ($file in @('patch_codex_fast_mode_windows_msix.ps1', 'repatch-model-experience-recoverable.ps1')) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$tokens, [ref]$errors)
  Assert ($errors.Count -eq 0) "Parse failed: $file"
  $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-CodeSigningCertificate' }, $true)
  . ([scriptblock]::Create($function.Extent.Text))
  Assert (Test-CodeSigningCertificate (New-EkuFixture @('1.3.6.1.5.5.7.3.3'))) "Raw code-signing EKU rejected: $file"
  Assert (Test-CodeSigningCertificate (New-EkuFixture @('1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.3'))) "Multiple EKUs rejected: $file"
  Assert (-not (Test-CodeSigningCertificate (New-EkuFixture @('1.3.6.1.5.5.7.3.1')))) "TLS certificate accepted: $file"
  Assert (-not (Test-CodeSigningCertificate ([pscustomobject]@{Extensions=@();EnhancedKeyUsageList=$null}))) "Missing EKU accepted: $file"
  Assert (Test-CodeSigningCertificate ([pscustomobject]@{Extensions=@();EnhancedKeyUsageList=@([pscustomobject]@{ObjectId='1.3.6.1.5.5.7.3.3'})})) "Provider adapter regressed: $file"
  # Exercise the actual store in this clean process before accessing Cert:.
  $store = [Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
  try {
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    foreach ($certificate in $store.Certificates) {
      $expected = @($certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | ForEach-Object { $_.EnhancedKeyUsages } | Where-Object Value -eq '1.3.6.1.5.5.7.3.3').Count -gt 0
      Assert ((Test-CodeSigningCertificate $certificate) -eq $expected) "Actual store EKU mismatch: $file"
    }
  } finally { $store.Close() }
}
Write-Output "SIGNING_CERTIFICATE_EKU_PASSED checks=$checks"
