Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ar-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$repoRoot = Join-Path $testRoot 'installer'
$installRoot = Join-Path $testRoot 'install with spaces'
$pathFile = Join-Path $testRoot 'user-path'
$fixture = Join-Path $testRoot 'fixture.exe'
New-Item -ItemType Directory -Path $repoRoot | Out-Null
Copy-Item (Join-Path $sourceRoot 'install.ps1'), (Join-Path $sourceRoot 'uninstall.ps1') $repoRoot
$manifest = @(Get-Content (Join-Path $sourceRoot 'versions.env') | Where-Object { $_ -notmatch '^CLI_SHA256_' })
$tag = ($manifest | Where-Object { $_ -match '^CLI_TAG=' }).Substring(8)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

# A real executable exercises invocation, hashing and rollback without SDKs.
Add-Type -TypeDefinition @'
using System;
public class Fixture {
    public static int Main(string[] args) {
        if (args.Length != 1) return 2;
        if (args[0] == "version") {
            Console.WriteLine("Airreload " + (Environment.GetEnvironmentVariable("FAKE_CLI_VERSION") ?? Environment.GetEnvironmentVariable("AIRRELOAD_EXPECTED_CLI_VERSION")));
            return 0;
        }
        if (args[0] != "--help") return 2;
        if (Environment.GetEnvironmentVariable("FAKE_CLI_FAIL_HELP") == "1") return 1;
        if (Environment.GetEnvironmentVariable("FAKE_CLI_FAIL_FINAL_HELP") == "1" && !Environment.GetCommandLineArgs()[0].Contains(".airreload-install.")) return 1;
        Console.WriteLine("Airreload help");
        return 0;
    }
}
'@ -OutputAssembly $fixture -OutputType ConsoleApplication
$hash = (Get-FileHash $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content (Join-Path $repoRoot 'versions.env') -Value ($manifest + "CLI_SHA256_WINDOWS_X64=$hash") -Encoding Ascii

function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    Assert-True ($Uri -ceq "https://github.com/Airreload/cli/releases/download/$tag/airreload-windows-x64.exe") 'only the pinned CLI binary may be downloaded'
    if ($env:FAKE_DOWNLOAD_FAIL -eq '1') { throw 'Download failed' }
    Copy-Item -LiteralPath $fixture -Destination $OutFile
    if ($env:FAKE_CORRUPT_DOWNLOAD -eq '1') { Add-Content -LiteralPath $OutFile -Value 'corrupt' }
}
function git { throw 'Installer must not invoke Git' }
function dart { throw 'Installer must not invoke Dart' }
function flutter { throw 'Installer must not invoke Flutter' }

function Invoke-Installer {
    param([string[]]$Arguments = @())
    try {
        $parameters = @{}
        foreach ($argument in $Arguments) { $parameters[$argument.TrimStart('-')] = $true }
        & (Join-Path $repoRoot 'install.ps1') @parameters | Out-Host
        return 0
    } catch {
        $script:lastInstallError = $_.Exception.Message
        Write-Host "Installer rejected operation: $_"
        return 1
    }
}
function Invoke-Uninstaller {
    try {
        & (Join-Path $repoRoot 'uninstall.ps1') -Yes | Out-Host
        return 0
    } catch { return 1 }
}

$originalEnvironment = @{}
$names = @('Path', 'AIRRELOAD_INSTALL_ROOT', 'AIRRELOAD_TEST_USER_PATH_FILE', 'AIRRELOAD_EXPECTED_CLI_VERSION', 'FAKE_CLI_VERSION', 'FAKE_CLI_FAIL_HELP', 'FAKE_CLI_FAIL_FINAL_HELP', 'FAKE_CORRUPT_DOWNLOAD', 'FAKE_DOWNLOAD_FAIL')
foreach ($name in $names) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$env:AIRRELOAD_INSTALL_ROOT = $installRoot
$env:AIRRELOAD_TEST_USER_PATH_FILE = $pathFile
$env:AIRRELOAD_EXPECTED_CLI_VERSION = $tag.Substring(1)
Set-Content $pathFile -Value 'C:\keep-me' -NoNewline
try {
    Assert-True ((Invoke-Installer) -eq 0) 'initial install should succeed'
    Assert-True (Test-Path (Join-Path $installRoot 'bin\airreload.exe')) 'native executable should exist'
    foreach ($path in @('flutter', 'sdks', 'cli\.dart_tool')) {
        Assert-True (-not (Test-Path (Join-Path $installRoot $path))) "install must not create $path"
    }
    Assert-True ((Invoke-Installer) -ne 0) 'install without -Replace should fail'
    Assert-True ((Invoke-Installer -Arguments @('-Replace')) -eq 0) 'replacement should succeed'
    $binPath = Join-Path $installRoot 'bin'
    $entries = (Get-Content $pathFile -Raw) -split ';'
    Assert-True (@($entries | Where-Object { $_ -ieq $binPath }).Count -eq 1) 'PATH should contain one entry'

    # Simulate an old source installation and preserve its state during migration.
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'cli\.airreload'), (Join-Path $installRoot 'sdks\cached'), (Join-Path $installRoot 'flutter') | Out-Null
    Set-Content (Join-Path $installRoot 'cli\.airreload\key') 'pairing-fixture'
    Set-Content (Join-Path $installRoot 'sdks\cached\sentinel') 'sdk-fixture'
    Assert-True ((Invoke-Installer -Arguments @('-Replace', '-NoPath', '-PreserveData')) -eq 0) 'migration should succeed'
    Assert-True (-not (Test-Path (Join-Path $installRoot 'flutter'))) 'migration should remove the bootstrap SDK'

    foreach ($failure in @('FAKE_CLI_FAIL_HELP', 'FAKE_CLI_FAIL_FINAL_HELP', 'FAKE_CORRUPT_DOWNLOAD', 'FAKE_DOWNLOAD_FAIL', 'FAKE_CLI_VERSION')) {
        [Environment]::SetEnvironmentVariable($failure, '1', 'Process')
        Assert-True ((Invoke-Installer -Arguments @('-Replace', '-PreserveData')) -ne 0) "$failure should reject replacement"
        if ($failure -eq 'FAKE_CORRUPT_DOWNLOAD') {
            Assert-True ($script:lastInstallError -match 'binary checksum mismatch') 'corrupt binary must be rejected before execution'
        }
        [Environment]::SetEnvironmentVariable($failure, $null, 'Process')
        Assert-True ((Get-Content (Join-Path $installRoot 'cli\.airreload\key') -Raw).Trim() -eq 'pairing-fixture') 'pairing state must survive failure'
        Assert-True ((Get-Content (Join-Path $installRoot 'sdks\cached\sentinel') -Raw).Trim() -eq 'sdk-fixture') 'SDK cache must survive failure'
    }
    Assert-True ((Invoke-Uninstaller) -eq 0) 'uninstall should succeed'
    Assert-True (-not (Test-Path $installRoot)) 'uninstall should remove installation'
    Assert-True ((Get-Content $pathFile -Raw) -eq 'C:\keep-me') 'uninstall should preserve unrelated PATH'

    New-Item -ItemType Directory -Path $installRoot | Out-Null
    Set-Content (Join-Path $installRoot 'sentinel') 'unrelated'
    Assert-True ((Invoke-Installer -Arguments @('-Replace')) -ne 0) 'unowned directory must be preserved'
    Assert-True ((Invoke-Uninstaller) -ne 0) 'uninstaller must reject unowned directory'
    Assert-True (Test-Path (Join-Path $installRoot 'sentinel')) 'unrelated files must survive'
    Remove-Item $installRoot -Recurse -Force
    $env:FAKE_CORRUPT_DOWNLOAD = '1'
    Assert-True ((Invoke-Installer) -ne 0) 'checksum mismatch should fail a fresh install'
    Assert-True (-not (Test-Path $installRoot)) 'failure must not install an executable'
    Assert-True (@(Get-ChildItem $testRoot -Force | Where-Object { $_.Name -match '^\.airreload-' }).Count -eq 0) 'staging and backups must be cleaned'
    Write-Host 'All Windows installer tests passed.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
