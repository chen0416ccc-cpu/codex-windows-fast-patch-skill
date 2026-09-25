# Validate actual uncompressed MSIX payload bytes against the signed block map.
# Does not extract files, modify the package, or change installed applications.
function Test-MsixPayload {
  param([Parameter(Mandatory = $true)][string]$Path)

  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
      if ($entry.FullName.EndsWith('/')) { continue }
      # MakeAppx uses OPC names: e.g. @scope is stored as %40scope in the ZIP.
      $name = [Uri]::UnescapeDataString($entry.FullName).Replace('/', '\')
      if ($entries.ContainsKey($name)) { throw "duplicate MSIX payload name: $name" }
      $entries.Add($name, $entry)
    }
    if (-not $entries.ContainsKey('AppxBlockMap.xml')) { throw 'MSIX block map is missing' }
    $reader = [IO.StreamReader]::new($entries['AppxBlockMap.xml'].Open())
    try {
      $map = [xml]::new()
      $map.XmlResolver = $null
      $map.LoadXml($reader.ReadToEnd())
    } finally { $reader.Dispose() }
    if ($map.DocumentElement.NamespaceURI -ne 'http://schemas.microsoft.com/appx/2010/blockmap' -or
        $map.DocumentElement.HashMethod -ne 'http://www.w3.org/2001/04/xmlenc#sha256') {
      throw 'unsupported MSIX block map format or hash method'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fileCount = 0
    $blockCount = 0
    $buffer = New-Object byte[] 65536
    foreach ($file in $map.DocumentElement.File) {
      $name = [string]$file.Name
      if (-not $seen.Add($name)) { throw "duplicate MSIX block map file: $name" }
      if (-not $entries.ContainsKey($name)) { throw "MSIX payload is missing: $name" }
      $entry = $entries[$name]
      $size = [long]$file.Size
      if ($size -lt 0 -or $entry.Length -ne $size) { throw "MSIX payload size mismatch: $name" }
      $stream = $entry.Open()
      try {
        $remaining = $size
        $index = 0
        foreach ($block in $file.Block) {
          if ($remaining -le 0) { throw "extra MSIX block: $name block=$index" }
          $length = [int][Math]::Min(65536, $remaining)
          $read = 0
          while ($read -lt $length) {
            $count = $stream.Read($buffer, $read, $length - $read)
            if ($count -eq 0) { throw "truncated MSIX payload: $name block=$index" }
            $read += $count
          }
          $actual = [Convert]::ToBase64String($sha.ComputeHash($buffer, 0, $length))
          if ($actual -cne [string]$block.Hash) { throw "MSIX block hash mismatch: $name block=$index" }
          $remaining -= $length
          $index++
          $blockCount++
        }
        if ($remaining -ne 0 -or $stream.ReadByte() -ne -1) { throw "incomplete MSIX block map: $name" }
      } finally { $stream.Dispose() }
      $fileCount++
    }
    if ($fileCount -eq 0) { throw 'MSIX block map contains no payload files' }
    foreach ($name in $entries.Keys) {
      if ($name -notin @('AppxBlockMap.xml', 'AppxSignature.p7x', '[Content_Types].xml', 'AppxMetadata\CodeIntegrity.cat') -and -not $seen.Contains($name)) {
        throw "unmapped MSIX payload: $name"
      }
    }
    [pscustomobject]@{ Files = $fileCount; Blocks = $blockCount }
  } finally {
    $sha.Dispose()
    $archive.Dispose()
  }
}
