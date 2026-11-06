param(
    [string]$Destination = "dist",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    if (-not $SkipBuild) {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "Release build failed." }
    }

    $release = Join-Path $projectRoot "build/windows/x64/runner/Release"
    if (-not (Test-Path (Join-Path $release "sshairy.exe"))) {
        throw "No Windows x64 release build found."
    }
    $version = ((Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $name = "sshairy-$version-windows-x64-$stamp"
    $bundle = Join-Path $Destination $name
    $archive = "$bundle.zip"
    if ((Test-Path $bundle) -or (Test-Path $archive)) { throw "Output already exists: $bundle" }
    New-Item -ItemType Directory -Path $bundle | Out-Null
    Copy-Item -Path "$release/*" -Destination $bundle -Recurse
    Copy-Item -Path "README.md" -Destination $bundle
    if (Test-Path "LICENSE") { Copy-Item -Path "LICENSE" -Destination $bundle }
    & dart run tool/write_notices.dart (Join-Path $bundle "THIRD_PARTY_NOTICES.txt")
    if ($LASTEXITCODE -ne 0) { throw "Third-party license inventory failed. Bundle is incomplete: $bundle" }
    Compress-Archive -Path "$bundle/*" -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $archive -Leaf)" | Set-Content -Path "$archive.sha256" -Encoding ascii
    Write-Output "Created $archive"
    Write-Output "SHA256 $hash"
} finally {
    Pop-Location
}
