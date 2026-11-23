param(
    [string]$Destination = "dist"
)

$ErrorActionPreference = "Stop"

function Get-Sha256([string]$Path) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace("-", "").ToLowerInvariant()
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha256.Dispose()
    }
}

$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    $version = ((Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()
    $stamp = [Environment]::GetEnvironmentVariable("SSHAIRY_BUILD_STAMP")
    $suffix = if ($null -eq $stamp) { "-" + (Get-Date -Format "yyyyMMdd-HHmmss") } elseif ($stamp) { "-$stamp" } else { "" }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $outDir = "build/app/outputs/flutter-apk"

    function Export-Apk([string]$SourceName, [string]$AbiLabel) {
        $src = Join-Path $outDir $SourceName
        if (-not (Test-Path $src)) { throw "Expected APK not found: $src" }
        $name = "sshairy-$version-android-$AbiLabel$suffix.apk"
        $dst = Join-Path $Destination $name
        Copy-Item -Path $src -Destination $dst -Force
        $hash = Get-Sha256 $dst
        "$hash  $name" | Set-Content -Path "$dst.sha256" -Encoding ascii
        $mb = [math]::Round((Get-Item $dst).Length / 1MB, 2)
        Write-Output "Created $dst ($mb MB)"
        Write-Output "SHA256 $hash"
    }

    & flutter build apk --release --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw "Split-ABI APK build failed." }
    foreach ($abi in @("arm64-v8a", "armeabi-v7a", "x86_64")) {
        Export-Apk "app-$abi-release.apk" $abi
    }
} finally {
    Pop-Location
}
