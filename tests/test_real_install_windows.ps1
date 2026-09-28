# Destructive to this user's PATH while running: use only on disposable CI runners.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Installed', 'Removed')][string]$Phase = 'Install',
    [switch]$Web
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($Phase -eq 'Installed') {
    $expected = Join-Path $env:AIRRELOAD_INSTALL_ROOT 'bin\airreload.exe'
    $command = Get-Command airreload -CommandType Application -ErrorAction Stop
    if ($command.Source -ine $expected) { throw "Resolved unexpected launcher: $($command.Source)" }
    foreach ($argument in @('version', '--help', 'doctor')) {
        & airreload $argument
        if ($LASTEXITCODE -ne 0) { throw "airreload $argument failed ($LASTEXITCODE)." }
    }
    exit 0
}
if ($Phase -eq 'Removed') {
    if (Get-Command airreload -ErrorAction SilentlyContinue) { throw 'airreload still resolves after uninstall.' }
    exit 0
}

$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$gitDirectory = Split-Path -Parent (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$systemPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem;$(Split-Path -Parent $powerShell)"
# RUNNER_TEMP is shorter than the user-profile TEMP path on hosted Windows.
$temporaryBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$testRoot = Join-Path $temporaryBase "ar smoke $([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $testRoot | Out-Null
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$environmentNames = @('Path', 'AIRRELOAD_INSTALL_ROOT', 'AIRRELOAD_TEST_USER_PATH_FILE', 'PUB_CACHE', 'GIT_CONFIG_GLOBAL', 'AIRRELOAD_TEST_WEB_SCRIPT', 'TEMP', 'TMP')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Invoke-FreshPathCheck {
    param([string]$CheckPhase)
    # Windows children inherit PATH. Explicitly reload the persisted user value;
    # never reuse the installer process's PATH or manually append its bin directory.
    $env:Path = "$systemPath;$gitDirectory;$([Environment]::GetEnvironmentVariable('Path', 'User'))"
    & $powerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Phase $CheckPhase
    if ($LASTEXITCODE -ne 0) { throw "Fresh-process $CheckPhase check failed." }
}

try {
    $env:AIRRELOAD_INSTALL_ROOT = Join-Path $testRoot 'install with spaces'
    Remove-Item Env:\AIRRELOAD_TEST_USER_PATH_FILE -ErrorAction SilentlyContinue
    $env:PUB_CACHE = Join-Path $testRoot 'pub-cache'
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'git-config'
    $sentinelPath = Join-Path $testRoot 'unrelated-bin'
    [Environment]::SetEnvironmentVariable('Path', $sentinelPath, 'User')
    $env:Path = $systemPath
    if (Get-Command git -ErrorAction SilentlyContinue) { throw 'Missing-Git isolation failed.' }
    foreach ($tool in @('git', 'dart', 'flutter', 'pwsh', 'openssl')) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) { throw "Unexpected preinstalled tool on restricted PATH: $tool" }
    }
    Write-Host "Testing $env:ImageOS / $env:ImageVersion with Windows PowerShell $($PSVersionTable.PSVersion)"
    Write-Host "Allowed PATH: $env:Path"
    Write-Host 'Installing the pinned native CLI without Git, Dart, or Flutter...'
    if ($Web) {
        $env:AIRRELOAD_TEST_WEB_SCRIPT = Join-Path $repoRoot 'install.ps1'
        $env:TEMP = $testRoot
        $env:TMP = $testRoot
        # Feed this revision's script through IEX, exactly as the web command
        # does. The bootstrap then fetches the real public snapshot and binary.
        $output = & $powerShell -NoProfile -Command 'Get-Content -LiteralPath $env:AIRRELOAD_TEST_WEB_SCRIPT -Raw | Invoke-Expression'
        $output | Out-Host
        if (-not ($output -match 'Downloading the Airreload installer')) { throw 'Web invocation did not bootstrap.' }
        if (Get-ChildItem $testRoot -Directory -Filter 'airreload-bootstrap-*') { throw 'Bootstrap temporary files remain.' }
    } else {
        & $powerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'install.ps1')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Real installation failed.' }
    foreach ($path in @('flutter', 'sdks', 'cli\.dart_tool')) {
        if (Test-Path (Join-Path $env:AIRRELOAD_INSTALL_ROOT $path)) { throw "Installation unexpectedly created $path" }
    }
    $binPath = Join-Path $env:AIRRELOAD_INSTALL_ROOT 'bin'
    $savedEntries = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
    if (@($savedEntries | Where-Object { $_ -ieq $binPath }).Count -ne 1 -or $savedEntries -notcontains $sentinelPath) {
        throw 'Installer did not register its bin exactly once while preserving unrelated user PATH.'
    }
    Invoke-FreshPathCheck -CheckPhase Installed

    & $powerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'uninstall.ps1') -Yes
    if ($LASTEXITCODE -ne 0) { throw 'Uninstall failed.' }
    if (Test-Path -LiteralPath $env:AIRRELOAD_INSTALL_ROOT) { throw 'Install root was not removed.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $sentinelPath) { throw 'Uninstall did not restore unrelated user PATH.' }
    if (Get-ChildItem -LiteralPath $testRoot -Force | Where-Object { $_.Name -match '^\.airreload-(install|backup)\.' }) {
        throw 'Staging or backup directory was left behind.'
    }
    Invoke-FreshPathCheck -CheckPhase Removed
    Write-Host 'Real Windows installation, saved PATH, and uninstall checks passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
