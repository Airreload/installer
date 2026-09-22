Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = @{}
Get-Content -LiteralPath (Join-Path $repoRoot 'versions.env') | ForEach-Object {
    $name, $value = $_ -split '=', 2
    $manifest[$name] = $value
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "airreload-installer-tests.$([guid]::NewGuid().ToString('N'))"
$fakeBin = Join-Path $testRoot 'fake-bin'
$installRoot = Join-Path $testRoot 'install'
$pathFile = Join-Path $testRoot 'user-path'
New-Item -ItemType Directory -Path $fakeBin | Out-Null
Set-Content -LiteralPath $pathFile -Value 'C:\keep-me' -NoNewline

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Invoke-Installer {
    param([string[]]$Arguments = @())
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'install.ps1') @Arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-Uninstaller {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'uninstall.ps1') -Yes | Out-Host
    return $LASTEXITCODE
}

$fakeGit = @'
$ErrorActionPreference = 'Stop'
if ($args[0] -eq '-c' -and $args[1] -eq 'core.longpaths=true') {
    $args = @($args[2..($args.Count - 1)])
}
if ($args[0] -eq 'clone') {
    $destination = $args[-1]
    New-Item -ItemType Directory -Path (Join-Path $destination 'bin') -Force | Out-Null
    if ((Split-Path -Leaf $destination) -eq 'flutter') {
        $flutter = @"
@echo off
if "%~1"=="--version" if "%~2"=="--machine" goto machine
echo Flutter 3.47.5 ^(fake^)
exit /b 0
:machine
echo {"frameworkVersion":"3.47.5"}
exit /b 0
"@
        $dart = @"
@echo off
if "%~1"=="pub" if "%~2"=="get" goto pubget
set "last="
:next
if "%~1"=="" goto run
set "last=%~1"
shift
goto next
:run
if "%last%"=="version" echo Airreload 0.3.0-beta.1& exit /b 0
if "%last%"=="--help" echo Build and hot reload a Flutter Android app.& exit /b 0
if "%last%"=="doctor" goto doctor
exit /b 2
:doctor
if "%AIRRELOAD_FAKE_FAIL_DOCTOR%"=="1" exit /b 1
echo OK  fake doctor
exit /b 0
:pubget
if not exist ".dart_tool" mkdir ".dart_tool"
echo {}> ".dart_tool\package_config.json"
exit /b 0
"@
        Set-Content -LiteralPath (Join-Path $destination 'bin\flutter.bat') -Value $flutter -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $destination 'bin\dart.bat') -Value $dart -Encoding Ascii
    }
    else {
        Set-Content -LiteralPath (Join-Path $destination 'bin\airreload.dart') -Value 'void main() {}' -Encoding Ascii
    }
    exit 0
}
if ($args[0] -eq '-C' -and $args[2] -eq 'rev-parse' -and $args[3] -eq 'HEAD') {
    if ((Split-Path -Leaf $args[1]) -eq 'cli') {
        if ($env:AIRRELOAD_FAKE_CLI_COMMIT) { $env:AIRRELOAD_FAKE_CLI_COMMIT }
        else { $env:AIRRELOAD_EXPECTED_CLI_COMMIT }
    }
    else { $env:AIRRELOAD_EXPECTED_FLUTTER_COMMIT }
    exit 0
}
Write-Error "Unexpected fake git invocation: $args"
exit 2
'@
Set-Content -LiteralPath (Join-Path $fakeBin 'fake-git.ps1') -Value $fakeGit -Encoding UTF8
Set-Content -LiteralPath (Join-Path $fakeBin 'git.cmd') -Value '@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-git.ps1" %*' -Encoding Ascii

$oldPath = $env:Path
$env:Path = "$fakeBin;$env:Path"
$env:AIRRELOAD_INSTALL_ROOT = $installRoot
$env:AIRRELOAD_TEST_USER_PATH_FILE = $pathFile
$env:AIRRELOAD_EXPECTED_CLI_COMMIT = $manifest.CLI_COMMIT
$env:AIRRELOAD_EXPECTED_FLUTTER_COMMIT = $manifest.FLUTTER_COMMIT

try {
    Assert-True ((Invoke-Installer) -eq 0) 'initial install should succeed'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot '.airreload-installer')) 'ownership marker should exist'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'bin\airreload.cmd')) 'launcher should exist'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'cli\.dart_tool\package_config.json')) 'packages should be resolved'
    $binPath = Join-Path $installRoot 'bin'
    $pathEntries = (Get-Content -LiteralPath $pathFile -Raw) -split ';'
    Assert-True ((@($pathEntries | Where-Object { $_ -ieq $binPath })).Count -eq 1) 'PATH entry should be added once'

    Assert-True ((Invoke-Installer) -ne 0) 'install without -Replace should fail'
    Assert-True ((Invoke-Installer -Arguments @('-Replace')) -eq 0) 'replacement should succeed'
    $pathEntries = (Get-Content -LiteralPath $pathFile -Raw) -split ';'
    Assert-True ((@($pathEntries | Where-Object { $_ -ieq $binPath })).Count -eq 1) 'replacement should not duplicate PATH'

    Set-Content -LiteralPath (Join-Path $installRoot 'preserved') -Value 'preserve-me'
    $env:AIRRELOAD_FAKE_FAIL_DOCTOR = '1'
    Assert-True ((Invoke-Installer -Arguments @('-Replace')) -ne 0) 'failed validation should fail replacement'
    Remove-Item Env:\AIRRELOAD_FAKE_FAIL_DOCTOR
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'preserved')) 'failed replacement should preserve installation'

    Assert-True ((Invoke-Uninstaller) -eq 0) 'uninstall should succeed'
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'uninstall should remove installation'
    Assert-True ((Get-Content -LiteralPath $pathFile -Raw) -eq 'C:\keep-me') 'uninstall should preserve unrelated PATH entries'

    New-Item -ItemType Directory -Path $installRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $installRoot 'sentinel') -Value 'unrelated'
    Assert-True ((Invoke-Installer -Arguments @('-Replace')) -ne 0) 'installer should reject an unowned directory'
    Assert-True ((Invoke-Uninstaller) -ne 0) 'uninstaller should reject an unowned directory'
    Remove-Item -LiteralPath $installRoot -Recurse -Force

    $env:AIRRELOAD_FAKE_CLI_COMMIT = '0000000000000000000000000000000000000000'
    Assert-True ((Invoke-Installer) -ne 0) 'commit mismatch should fail'
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'failed install should clean staging data'

    Write-Host 'All Windows installer tests passed.'
}
finally {
    $env:Path = $oldPath
    Remove-Item Env:\AIRRELOAD_INSTALL_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\AIRRELOAD_TEST_USER_PATH_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\AIRRELOAD_EXPECTED_CLI_COMMIT -ErrorAction SilentlyContinue
    Remove-Item Env:\AIRRELOAD_EXPECTED_FLUTTER_COMMIT -ErrorAction SilentlyContinue
    Remove-Item Env:\AIRRELOAD_FAKE_CLI_COMMIT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
