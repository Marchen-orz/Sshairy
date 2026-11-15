param(
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [string]$Destination = "dist",
    [switch]$SkipBuild,
    [switch]$SkipInstaller
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
function Get-PeMachine([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -le 0 -or $offset -ge $stream.Length - 6) { throw "Not a PE file: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Not a PE file: $Path" }
        return $reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
if ($Arch -ne $hostArch) { throw "Build $Arch packages on a $Arch host; Flutter builds for the host architecture." }
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    if (-not $SkipBuild) {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "Release build failed." }
    }

    $exe = Get-ChildItem -Path "build/windows" -Recurse -File -Filter "sshairy.exe" |
        Where-Object { $_.FullName -match "\\runner\\Release\\sshairy\.exe$" } |
        Select-Object -First 1
    if (-not $exe) { throw "No Windows release build found." }
    $expectedMachine = if ($Arch -eq "arm64") { 0xAA64 } else { 0x8664 }
    $machine = Get-PeMachine $exe.FullName
    if ($machine -ne $expectedMachine) {
        $message = "sshairy.exe has PE machine 0x{0:X4}, expected 0x{1:X4} for {2}. The Flutter SDK only builds for its own architecture, so this build cannot be shipped as $Arch." -f $machine, $expectedMachine, $Arch
        throw $message
    }
    $release = $exe.Directory.FullName

    $version = ((Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()
    $stamp = [Environment]::GetEnvironmentVariable("SSHAIRY_BUILD_STAMP")
    $suffix = if ($null -eq $stamp) { "-" + (Get-Date -Format "yyyyMMdd-HHmmss") } elseif ($stamp) { "-$stamp" } else { "" }
    $base = "sshairy-$version-windows-$Arch$suffix"

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $bundle = Join-Path $Destination $base
    if (Test-Path $bundle) { throw "Output already exists: $bundle" }
    New-Item -ItemType Directory -Path $bundle | Out-Null
    Copy-Item -Path "$release/*" -Destination $bundle -Recurse
    Copy-Item -Path "README.md" -Destination $bundle
    if (Test-Path "LICENSE") { Copy-Item -Path "LICENSE" -Destination $bundle }
    & dart run tool/write_notices.dart (Join-Path $bundle "THIRD_PARTY_NOTICES.txt")
    if ($LASTEXITCODE -ne 0) { throw "Third-party license inventory failed. Bundle is incomplete: $bundle" }

    $created = @()
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("sshairy-portable-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $payload = Join-Path $temp "payload.zip"
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($bundle, $payload)
        $payloadHash = Get-Sha256 $payload

        $digits = [regex]::Matches($version, "\d+") | ForEach-Object { $_.Value }
        $fileVersion = ($digits | Select-Object -First 4) -join "."
        while (($fileVersion -split "\.").Count -lt 3) { $fileVersion += ".0" }
        $info = Join-Path $temp "BuildInfo.cs"
        @"
using System.Reflection;
[assembly: AssemblyInformationalVersion("$version")]
[assembly: AssemblyFileVersion("$fileVersion")]
[assembly: AssemblyProduct("Sshairy")]
[assembly: AssemblyTitle("Sshairy")]
[assembly: AssemblyCompany("Sshairy")]
internal static class BuildInfo {
    internal const string PayloadHash = "$payloadHash";
}
"@ | Set-Content -Path $info -Encoding ascii

        $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
        if (-not (Test-Path $csc)) { throw "csc.exe (.NET Framework) not found." }
        $framework = Split-Path $csc -Parent
        $portable = Join-Path $Destination "$base-portable.exe"
        $cscArguments = @(
            "/nologo", "/target:winexe", "/optimize+", "/platform:anycpu",
            "/win32icon:$(Join-Path $projectRoot "windows/runner/resources/app_icon.ico")",
            "/resource:$payload,sshairy.payload",
            "/reference:$(Join-Path $framework "System.dll")",
            "/reference:$(Join-Path $framework "System.Core.dll")",
            "/reference:$(Join-Path $framework "System.IO.Compression.dll")",
            "/reference:$(Join-Path $framework "System.IO.Compression.FileSystem.dll")",
            "/reference:$(Join-Path $framework "System.Windows.Forms.dll")",
            "/out:$portable",
            (Join-Path $PSScriptRoot "portable/Launcher.cs"),
            $info
        )
        & $csc $cscArguments
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $portable)) { throw "Portable launcher compilation failed." }
        $created += $portable
    } finally {
        Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($SkipInstaller) {
        Write-Output "Skipped the Inno Setup installer."
    } else {
        $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        if (-not $iscc) {
            $uninstallKeys = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($item in Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue) {
                if ($item.DisplayName -like "Inno Setup*" -and $item.InstallLocation) {
                    $candidate = Join-Path $item.InstallLocation "ISCC.exe"
                    if (Test-Path $candidate) { $iscc = $candidate; break }
                }
            }
        }
        if (-not $iscc) {
            foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA "Programs"))) {
                if (-not $root) { continue }
                $candidate = Join-Path $root "Inno Setup 6/ISCC.exe"
                if (Test-Path $candidate) { $iscc = $candidate; break }
            }
        }
        if (-not $iscc) { throw "Inno Setup 6 (ISCC.exe) not found. Install it or pass -SkipInstaller." }
        $env:SSHAIRY_ARCH = $Arch
        $env:SSHAIRY_VERSION = $version
        $env:SSHAIRY_PAYLOAD = (Resolve-Path $bundle).Path
        $env:SSHAIRY_OUTPUT = (Resolve-Path $Destination).Path
        $env:SSHAIRY_OUTPUT_NAME = "$base-setup"
        & $iscc (Join-Path $PSScriptRoot "inno/sshairy.iss")
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Destination "$base-setup.exe"))) {
            throw "Inno Setup failed."
        }
        $created += Join-Path $Destination "$base-setup.exe"
    }

    foreach ($file in $created) {
        $hash = Get-Sha256 $file
        "$hash  $(Split-Path $file -Leaf)" | Set-Content -Path "$file.sha256" -Encoding ascii
        Write-Output "Created $file"
        Write-Output "SHA256 $hash"
    }
} finally {
    Pop-Location
}
