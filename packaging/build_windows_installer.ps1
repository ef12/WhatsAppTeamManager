$ErrorActionPreference = 'Stop'

$repository = Split-Path -Parent $PSScriptRoot
$releaseExe = Join-Path $repository 'flutter_app\build\windows\x64\runner\Release\rkavic_manager.exe'
if (-not (Test-Path -LiteralPath $releaseExe)) {
    throw 'Windows release build missing. Run flutter build windows --release in flutter_app first.'
}

$candidates = @()
if (${env:ProgramFiles(x86)}) {
    $candidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
}
if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
}
$compiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $compiler = $command.Source
}
if (-not $compiler) {
    throw 'Inno Setup 6 compiler (ISCC.exe) was not found.'
}

$pubspec = Get-Content (Join-Path $repository 'flutter_app\pubspec.yaml') -Raw
$version = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
if (-not $version) {
    throw 'Cannot read app version from flutter_app/pubspec.yaml.'
}

& $compiler "/DAppVersion=$version" (Join-Path $PSScriptRoot 'windows.iss')
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}

$installer = Join-Path $repository "flutter_app\build\installer\RKAVIC-Team-Manager-Windows-v$version-Setup.exe"
if (-not (Test-Path -LiteralPath $installer)) {
    throw "Installer was not created: $installer"
}
Write-Output $installer
