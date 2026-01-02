# Avuz Conecta Windows Build Script
# Run from the repository root: .\admin\win\build-installer.ps1

param(
    [string]$CraftRoot = "C:\CraftRoot",
    [string]$BuildType = "Release",
    [switch]$SkipBuild,
    [switch]$SkipPackage,
    [switch]$CleanInstall
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$BuildDir = "$RepoRoot\build-release"
$BinDir = "$BuildDir\bin"

Write-Host "=== Avuz Conecta Build Script ===" -ForegroundColor Cyan
Write-Host "Repository: $RepoRoot"
Write-Host "Build Dir: $BuildDir"
Write-Host "CraftRoot: $CraftRoot"

# Step 0: Clean old installation data (optional)
if ($CleanInstall) {
    Write-Host "`n=== Step 0: Cleaning old installation data ===" -ForegroundColor Yellow

    # Kill running processes
    Write-Host "  Stopping running processes..."
    Get-Process *avuz* -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process *nextcloud* -ErrorAction SilentlyContinue | Stop-Process -Force

    # Remove app data
    Write-Host "  Removing app data..."
    Remove-Item "$env:LOCALAPPDATA\AvuzConecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Avuz Conecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\avuzconecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\AvuzConecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\Avuz Conecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\avuzconecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Nextcloud" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\Nextcloud" -Recurse -Force -ErrorAction SilentlyContinue

    # Remove Explorer sidebar entries
    Write-Host "  Removing Explorer sidebar entries..."
    Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = Get-ItemProperty $_.PSPath -Name "ApplicationName" -ErrorAction SilentlyContinue
        if ($name.ApplicationName -like "*Avuz*" -or $name.ApplicationName -like "*Nextcloud*") {
            Remove-Item $_.PSPath -Recurse -Force
        }
    }

    # Remove CLSID entries
    Get-ChildItem "HKCU:\Software\Classes\CLSID" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($name.'(default)' -like "*Avuz*" -or $name.'(default)' -like "*Nextcloud*") {
            Remove-Item $_.PSPath -Recurse -Force
        }
    }

    # Remove installed program
    Write-Host "  Removing installed program..."
    Remove-Item "C:\Program Files\Avuz Conecta" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Program Files\AvuzConecta" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Old installation data cleaned" -ForegroundColor Green
}

# Step 1: Build
if (-not $SkipBuild) {
    Write-Host "`n=== Step 1: Building ===" -ForegroundColor Yellow

    if (Test-Path $BuildDir) {
        Remove-Item -Recurse -Force $BuildDir
    }
    New-Item -ItemType Directory -Path $BuildDir | Out-Null

    Push-Location $BuildDir
    try {
        & cmake -G "Ninja" `
            -DCMAKE_PREFIX_PATH="$CraftRoot" `
            -DCMAKE_BUILD_TYPE="$BuildType" `
            -DNEXTCLOUD_DEV=OFF `
            ..

        if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

        & ninja
        if ($LASTEXITCODE -ne 0) { throw "Build failed" }
    }
    finally {
        Pop-Location
    }

    Write-Host "Build completed successfully" -ForegroundColor Green
}

# Step 2: Deploy Qt dependencies
Write-Host "`n=== Step 2: Deploying Qt dependencies ===" -ForegroundColor Yellow
& "$CraftRoot\bin\windeployqt.exe" --release "$BinDir\avuzconecta.exe"

# Step 3: Copy additional dependencies
Write-Host "`n=== Step 3: Copying additional dependencies ===" -ForegroundColor Yellow

# OpenSSL
Write-Host "  Copying OpenSSL..."
Copy-Item "$CraftRoot\bin\libcrypto-3-x64.dll" "$BinDir\" -Force
Copy-Item "$CraftRoot\bin\libssl-3-x64.dll" "$BinDir\" -Force

# KDE Frameworks
Write-Host "  Copying KDE Frameworks..."
Copy-Item "$CraftRoot\bin\KF6*.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue

# Qt Keychain
Write-Host "  Copying Qt Keychain..."
Copy-Item "$CraftRoot\bin\qt6keychain.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue

# Other libraries
Write-Host "  Copying other libraries..."
Copy-Item "$CraftRoot\bin\zlib*.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\sqlite3.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\libp11*.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\bz2*.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\liblzma*.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue

# WebEngine resources
Write-Host "  Copying WebEngine resources..."
Copy-Item "$CraftRoot\bin\icudtl.dat" "$BinDir\" -Force
Copy-Item "$CraftRoot\bin\qtwebengine_*.pak" "$BinDir\" -Force
Copy-Item "$CraftRoot\bin\v8_context_snapshot.bin" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\vk_swiftshader_icd.json" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\vk_swiftshader.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue
Copy-Item "$CraftRoot\bin\vulkan-1.dll" "$BinDir\" -Force -ErrorAction SilentlyContinue

# WebEngine locales
Write-Host "  Copying WebEngine locales..."
if (-not (Test-Path "$BinDir\translations")) {
    New-Item -ItemType Directory -Path "$BinDir\translations" | Out-Null
}
Copy-Item "$CraftRoot\translations\qtwebengine_locales" "$BinDir\translations\" -Recurse -Force -ErrorAction SilentlyContinue

# Client translations (for Portuguese and other languages)
# On Windows, translations must be in <app_dir>/i18n/ folder
Write-Host "  Copying client translations to i18n folder..."
if (-not (Test-Path "$BinDir\i18n")) {
    New-Item -ItemType Directory -Path "$BinDir\i18n" | Out-Null
}
Copy-Item "$BuildDir\src\gui\client_*.qm" "$BinDir\i18n\" -Force -ErrorAction SilentlyContinue
$translationCount = (Get-ChildItem "$BinDir\i18n\client_*.qm" -ErrorAction SilentlyContinue).Count
Write-Host "    Copied $translationCount client translation files to i18n/"

Write-Host "Dependencies copied successfully" -ForegroundColor Green

# Step 4: Test
Write-Host "`n=== Step 4: Quick test ===" -ForegroundColor Yellow
Write-Host "Testing if app launches..."
$testProc = Start-Process -FilePath "$BinDir\avuzconecta.exe" -PassThru
Start-Sleep -Seconds 3
if (-not $testProc.HasExited) {
    Write-Host "App launched successfully" -ForegroundColor Green
    Stop-Process -Id $testProc.Id -Force
} else {
    Write-Host "Warning: App may have crashed" -ForegroundColor Red
}

# Step 5: Build installer
if (-not $SkipPackage) {
    Write-Host "`n=== Step 5: Building installer ===" -ForegroundColor Yellow

    $InnoSetup = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    if (-not (Test-Path $InnoSetup)) {
        Write-Host "Inno Setup not found. Please install from https://jrsoftware.org/isdl.php" -ForegroundColor Red
        exit 1
    }

    & $InnoSetup "$RepoRoot\installer.iss"
    if ($LASTEXITCODE -ne 0) { throw "Installer build failed" }

    Write-Host "`nInstaller created: $RepoRoot\AvuzConecta-4.0.3-setup.exe" -ForegroundColor Green
}

Write-Host "`n=== Build completed ===" -ForegroundColor Cyan
Write-Host "Usage:"
Write-Host "  Full build:        .\admin\win\build-installer.ps1"
Write-Host "  Skip build:        .\admin\win\build-installer.ps1 -SkipBuild"
Write-Host "  Clean install:     .\admin\win\build-installer.ps1 -CleanInstall"
Write-Host "  Full clean build:  .\admin\win\build-installer.ps1 -CleanInstall"
