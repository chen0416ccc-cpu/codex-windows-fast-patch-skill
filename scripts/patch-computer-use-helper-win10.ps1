[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$HelperPath,
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [switch]$Install,
  [switch]$Rollback,
  [switch]$ComputeCandidateHash
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-cua-win10-screenshot-helper]'

$PatchProfiles = @(
  [ordered]@{
    Name = '@oai/sky 0.4.20 helper F2B2F56F / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.707.12708.0'
    SkyVersion = '0.4.20'
    OriginalSha256 = 'F2B2F56FCD1699B0FA32DEC3214A56A1D36B937A2ECF58CC822AB4A904551E03'
    PatchedSha256 = '71A13CBC4BB333F0707D2311C99DBA54D8B24D1BBB9F7CE25C3B9386577FFDDA'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x000BB5D1
        OriginalHex = '4889c689d3eb4f'
        PatchedHex = 'e97d0000009090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x000BFA4F
        OriginalHex = '0f85c3340000'
        PatchedHex = '0f85a6340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x000BFA60
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x0012C94E
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15610f00004885c074104889c1ff15330e000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff150b0c0000488b4c2428e82d30f9ffff15eb0b0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0013C050
        OriginalHex = '0c060c4001000000'
        PatchedHex = '4ed5124001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.5.2 helper 2C4CAC16 / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.721.4979.0'
    SkyVersion = '0.5.2'
    OriginalSha256 = '2C4CAC168200520C2752058177EA9FE7D1CCF9A26B7287DDDFF669D41CA9AF16'
    PatchedSha256 = 'D816B14A80370697380BA702863DA9528AA5B73ED34C2B189ACE2BF9E103BEFF'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x000BC7C1
        OriginalHex = '4889c689d3eb4f'
        PatchedHex = 'e97d0000009090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x000C0C3F
        OriginalHex = '0f85c3340000'
        PatchedHex = '0f85a6340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x000C0C50
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x0012DF37
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15980900004885c074104889c1ff15a208000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff1502060000488b4c2428e8342cf9ffff1502060000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0013D918
        OriginalHex = 'fc170c4001000000'
        PatchedHex = '37eb124001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.6 helper BE488E66 / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.803.10989.0'
    SkyVersion = '0.6.6'
    OriginalSha256 = 'BE488E66C38E12FA46850EE48C1F5E44ECDB0A3A64042E064E3A1A1DA286AC42'
    PatchedSha256 = '34D6EB4F23630AD6E7211898AA7678472C9ED7ACFD972C78B7D9E575A1C5C640'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x0014868F
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15281200004885c074104889c1ff156211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15220f0000488b4c2428e82348f0ffff151a0f0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = '8f92144001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.16 helper E40BE614 / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.814.5167.0'
    SkyVersion = '0.6.16'
    OriginalSha256 = 'E40BE6145157885F0E155A4247DF3B64BD5D3455A04E276503B0E2821B3EA39E'
    PatchedSha256 = 'F35CA6D89959EDEFB4DF46A5ECC6202091AB3C63E885E6CD6CF9824D92B66EB7'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x001486AF
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15081200004885c074104889c1ff154211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15020f0000488b4c2428e80348f0ffff15fa0e0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = 'af92144001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.16 helper BEB498C2 / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.814.5517.0'
    SkyVersion = '0.6.16-202608171739-pr-1311460-c66628846294'
    OriginalSha256 = 'BEB498C287889D807DCCB0E1FAD8A39ED9BE6BDF084D10313B5D52BA26C1E370'
    PatchedSha256 = 'AF7D14EE6E2B850E06798EC14117D29F1C839DB5C135A7F515DE37074DB66A23'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x001486AF
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15081200004885c074104889c1ff154211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15020f0000488b4c2428e80348f0ffff15fa0e0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = 'af92144001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.17 helper 29D5E113 / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.818.2872.0'
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalSha256 = '29D5E113A5D24A1DD3F3CCA4245CE5AE82A56E88AF5AFCD8E0AE4CC2E5C94992'
    PatchedSha256 = 'DC83663FBF8DEF6749296B84EAE66054D2C07530CC42A87CA4503ECF86AD3767'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x001486AF
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15081200004885c074104889c1ff154211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15020f0000488b4c2428e80348f0ffff15fa0e0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = 'af92144001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.17 helper DB8F4486 / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.818.3698.0'
    SkyVersion = '0.6.17-202608171537-pr-1300023-7efba775c041'
    OriginalSha256 = 'DB8F4486D527C91B80266FAF77FDC38266B1D3960EFBBA35D0A6AAB4CAAF6AEE'
    PatchedSha256 = '6495168DC16A35CDC33230E6512D64E660B56D13E99FE239426D228B9F86E157'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x001486AF
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15081200004885c074104889c1ff154211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15020f0000488b4c2428e80348f0ffff15fa0e0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = 'af92144001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.11 helper 7A95D14E / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.810.7004.0'
    SkyVersion = '0.6.11'
    OriginalSha256 = '7A95D14EBF992955D8AB8E6C57A75545ED7D18E864B0F5C1B9FE7F47685BD897'
    PatchedSha256 = 'E84A4ECB473CF9D3B4B65BB27A298DE6602AD8A1A11B21EE0BA7BC9209FE4DA9'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x0014868F
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15281200004885c074104889c1ff156211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15220f0000488b4c2428e82348f0ffff151a0f0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = '8f92144001000000'
      }
    )
  },
  [ordered]@{
    Name = '@oai/sky 0.6.11 helper DE07F17A / Windows 10 screenshot backend'
    ValidatedDesktopVersion = '26.810.6296.0'
    SkyVersion = '0.6.11'
    OriginalSha256 = 'DE07F17A7206588687A8F722E4EBFC5A4FB1BD87F91DF2C60BB5C777C6D5CDCD'
    PatchedSha256 = '40530E628C91EF510F81A02FD3394C18E0D322C3D68D4A0277F0B0C56A2D43CC'
    Regions = @(
      [ordered]@{
        Name = 'optional-border-interface'
        Offset = 0x00047E01
        OriginalHex = '4889c34189d6eb50'
        PatchedHex = 'e980000000909090'
      },
      [ordered]@{
        Name = 'frame-arrived-busy-return'
        Offset = 0x0004CF86
        OriginalHex = '0f85f5340000'
        PatchedHex = '0f85d8340000'
      },
      [ordered]@{
        Name = 'frame-arrived-once-flag'
        Offset = 0x0004CF97
        OriginalHex = '740d'
        PatchedHex = 'eb0d'
      },
      [ordered]@{
        Name = 'mta-worker-wrapper'
        Offset = 0x0014868F
        OriginalHex = ('cc' + (('00' * 174) -join ''))
        PatchedHex = '4883ec3848894c24304c8b510831c0b201f0410fb052117536488b01ff500831c931d24c8d05490000004c8b4c2430488364242000488364242800ff15281200004885c074104889c1ff156211000031c04883c438c3488b4c2430488b4108c6401100488b01ff5010b8054000804883c438c34883ec3848894c2428b901000000ff15220f0000488b4c2428e82348f0ffff151a0f0000488b4c2428488b01ff501031c04883c438c3c04883c438c3'
      },
      [ordered]@{
        Name = 'frame-arrived-vtable'
        Offset = 0x0014B128
        OriginalHex = '43db044001000000'
        PatchedHex = '8f92144001000000'
      }
    )
  }
)

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Convert-HexToBytes {
  param([string]$Hex)

  if ([string]::IsNullOrWhiteSpace($Hex) -or ($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') {
    throw 'invalid hexadecimal byte string'
  }

  $bytes = New-Object byte[] ($Hex.Length / 2)
  for ($index = 0; $index -lt $bytes.Length; $index += 1) {
    $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
  }
  return $bytes
}

function Convert-BytesToHex {
  param([byte[]]$Bytes)
  return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-Sha256FromBytes {
  param([byte[]]$Bytes)

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace '-', '')
  } finally {
    $sha256.Dispose()
  }
}

function Get-Sha256 {
  param([string]$Path)
  return Get-Sha256FromBytes ([IO.File]::ReadAllBytes($Path))
}

function Resolve-HelperPath {
  param([string]$RequestedPath)

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
      throw "Computer Use helper not found: $RequestedPath"
    }
    return [System.IO.Path]::GetFullPath($RequestedPath)
  }

  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  $candidates = @()
  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $candidates = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $path = Join-Path $_.FullName 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        Get-Item -LiteralPath $path
      }
    } | Sort-Object LastWriteTime -Descending)
  }

  if ($candidates.Count -eq 0) {
    throw "no Computer Use helper found under $runtimeRoot"
  }

  return $candidates[0].FullName
}

function Get-SkyVersion {
  param([string]$ResolvedHelperPath)

  $skyRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ResolvedHelperPath))
  $packagePath = Join-Path $skyRoot 'package.json'
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    return 'unknown'
  }

  return [string]((Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json).version)
}

function Get-WindowsBuild {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  if ($os -and $os.BuildNumber) {
    return [int]$os.BuildNumber
  }
  return [Environment]::OSVersion.Version.Build
}

function Get-DesktopVersion {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($package -and $package.Version) {
    return [string]$package.Version
  }
  return 'unknown-desktop'
}

function Get-BackupPath {
  param(
    [string]$SkyVersion,
    [string]$OriginalHash,
    [string]$DesktopVersion
  )

  $profileDirectory = "$DesktopVersion-sky-$SkyVersion-$($OriginalHash.Substring(0, 8))"
  return Join-Path (Join-Path $CodexHome 'backups\computer-use-helper') "$profileDirectory\codex-computer-use.exe.original"
}

function Resolve-OriginalBackupPath {
  param([string]$PreferredPath)

  if (Test-Path -LiteralPath $PreferredPath -PathType Leaf) {
    return $PreferredPath
  }

  $backupRoot = Join-Path $CodexHome 'backups\computer-use-helper'
  if (Test-Path -LiteralPath $backupRoot -PathType Container) {
    foreach ($candidate in @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'codex-computer-use.exe.original' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
      if ((Get-Sha256 $candidate.FullName) -eq $PatchProfile.OriginalSha256) {
        return $candidate.FullName
      }
    }
  }

  return $PreferredPath
}

function Assert-Regions {
  param(
    [byte[]]$FileBytes,
    [ValidateSet('Original', 'Patched')]
    [string]$State
  )

  foreach ($region in $PatchProfile.Regions) {
    $expectedHex = if ($State -eq 'Original') { $region.OriginalHex } else { $region.PatchedHex }
    $expected = Convert-HexToBytes $expectedHex
    if (($region.Offset + $expected.Length) -gt $FileBytes.Length) {
      throw "patch region is outside the helper: $($region.Name)"
    }

    $actual = New-Object byte[] $expected.Length
    [Array]::Copy($FileBytes, $region.Offset, $actual, 0, $actual.Length)
    if ((Convert-BytesToHex $actual) -ne $expectedHex.ToLowerInvariant()) {
      throw "helper bytes do not match the $State profile at $($region.Name) / 0x$('{0:X}' -f $region.Offset)"
    }
  }
}

function Set-PatchedRegions {
  param([byte[]]$FileBytes)

  foreach ($region in $PatchProfile.Regions) {
    $replacement = Convert-HexToBytes $region.PatchedHex
    [Array]::Copy($replacement, 0, $FileBytes, $region.Offset, $replacement.Length)
  }
}

function Stop-RunningHelper {
  param([string]$ResolvedHelperPath)

  $processes = @(Get-Process -Name 'codex-computer-use' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.Equals($ResolvedHelperPath, [System.StringComparison]::OrdinalIgnoreCase)
  })

  if ($processes.Count -gt 0) {
    Write-Log "stopping helper processes: $($processes.Id -join ', ')"
    $processes | Stop-Process -Force
    foreach ($process in $processes) {
      if (-not $process.WaitForExit(5000)) {
        throw "helper process did not exit: $($process.Id)"
      }
    }
  }
}

if ($Install -and $Rollback) {
  throw 'choose either -Install or -Rollback'
}
if ($ComputeCandidateHash -and ($Install -or $Rollback)) {
  throw '-ComputeCandidateHash cannot be combined with -Install or -Rollback'
}

$resolvedHelperPath = Resolve-HelperPath $HelperPath
$skyVersion = Get-SkyVersion $resolvedHelperPath
$windowsBuild = Get-WindowsBuild
$desktopVersion = Get-DesktopVersion
$currentHash = Get-Sha256 $resolvedHelperPath
$PatchProfile = $PatchProfiles | Where-Object {
  $currentHash -eq $_.OriginalSha256 -or $currentHash -eq $_.PatchedSha256
} | Select-Object -First 1
$preferredBackupPath = if ($PatchProfile) {
  Get-BackupPath $skyVersion $PatchProfile.OriginalSha256 $desktopVersion
} else {
  $null
}
$state = if (-not $PatchProfile) {
  'unsupported'
} elseif ($currentHash -eq $PatchProfile.OriginalSha256) {
  'original-patchable'
} elseif ($currentHash -eq $PatchProfile.PatchedSha256) {
  'patched'
} else {
  'unsupported'
}
$backupPath = if (-not $PatchProfile) {
  $null
} elseif ($state -eq 'patched') {
  Resolve-OriginalBackupPath $preferredBackupPath
} else {
  $preferredBackupPath
}

if ($ComputeCandidateHash) {
  if ($state -ne 'original-patchable') {
    throw "candidate hash requires an exact supported original helper; state=$state"
  }
  if ($skyVersion -ne $PatchProfile.SkyVersion) {
    throw "this profile requires @oai/sky $($PatchProfile.SkyVersion); detected $skyVersion"
  }

  $candidateBytes = [IO.File]::ReadAllBytes($resolvedHelperPath)
  Assert-Regions $candidateBytes 'Original'
  Set-PatchedRegions $candidateBytes
  $candidateHash = Get-Sha256FromBytes $candidateBytes
  if ($candidateHash -ne $PatchProfile.PatchedSha256) {
    throw "patched helper candidate hash mismatch: $candidateHash"
  }
  $candidateHash
  return
}

if (-not $Install -and -not $Rollback) {
  [pscustomobject]@{
    Profile = if ($PatchProfile) { $PatchProfile.Name } else { 'unrecognized helper' }
    HelperPath = $resolvedHelperPath
    CurrentDesktopVersion = $desktopVersion
    EndToEndValidatedDesktopVersion = if ($PatchProfile) { $PatchProfile.ValidatedDesktopVersion } else { $null }
    SkyVersion = $skyVersion
    WindowsBuild = $windowsBuild
    State = $state
    Sha256 = $currentHash
    BackupPath = $backupPath
  }
  return
}

if ($Install) {
  if ($state -eq 'patched') {
    Assert-Regions ([IO.File]::ReadAllBytes($resolvedHelperPath)) 'Patched'
    Write-Log "already patched: $resolvedHelperPath"
    return
  }
  if ($state -ne 'original-patchable') {
    throw "unsupported helper SHA-256: $currentHash"
  }
  if ($windowsBuild -ge 22000) {
    throw "this profile is limited to Windows 10; detected build $windowsBuild"
  }
  if ($skyVersion -ne $PatchProfile.SkyVersion) {
    throw "this profile requires @oai/sky $($PatchProfile.SkyVersion); detected $skyVersion"
  }

  $bytes = [IO.File]::ReadAllBytes($resolvedHelperPath)
  Assert-Regions $bytes 'Original'
  Set-PatchedRegions $bytes

  $tempPath = "$resolvedHelperPath.win10-screenshot-$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllBytes($tempPath, $bytes)
    $tempHash = Get-Sha256 $tempPath
    if ($tempHash -ne $PatchProfile.PatchedSha256) {
      throw "patched helper hash mismatch: $tempHash"
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedHelperPath, 'Install the hash-guarded Windows 10 screenshot backend patch')) {
      return
    }

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
      $backupHash = Get-Sha256 $backupPath
      if ($backupHash -ne $PatchProfile.OriginalSha256) {
        throw "existing helper backup has an unexpected SHA-256: $backupPath / $backupHash"
      }
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
      Copy-Item -LiteralPath $resolvedHelperPath -Destination $backupPath -Force
      if ((Get-Sha256 $backupPath) -ne $PatchProfile.OriginalSha256) {
        throw "helper backup verification failed: $backupPath"
      }
      Write-Log "original helper backup: $backupPath"
    }

    Stop-RunningHelper $resolvedHelperPath
    Copy-Item -LiteralPath $tempPath -Destination $resolvedHelperPath -Force
    if ((Get-Sha256 $resolvedHelperPath) -ne $PatchProfile.PatchedSha256) {
      throw "installed helper verification failed: $resolvedHelperPath"
    }
    Write-Log "installed and verified: $resolvedHelperPath"
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue -WhatIf:$false
  }
  return
}

if ($state -eq 'original-patchable') {
  Write-Log "already rolled back: $resolvedHelperPath"
  return
}
if ($state -ne 'patched') {
  throw "cannot roll back unsupported helper SHA-256: $currentHash"
}
if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
  throw "original helper backup not found: $backupPath"
}
if ((Get-Sha256 $backupPath) -ne $PatchProfile.OriginalSha256) {
  throw "original helper backup hash mismatch: $backupPath"
}

if ($PSCmdlet.ShouldProcess($resolvedHelperPath, 'Restore the original Computer Use helper')) {
  Stop-RunningHelper $resolvedHelperPath
  Copy-Item -LiteralPath $backupPath -Destination $resolvedHelperPath -Force
  if ((Get-Sha256 $resolvedHelperPath) -ne $PatchProfile.OriginalSha256) {
    throw "rollback verification failed: $resolvedHelperPath"
  }
  Write-Log "rolled back and verified: $resolvedHelperPath"
}
