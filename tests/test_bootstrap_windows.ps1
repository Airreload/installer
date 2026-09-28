Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$sourceRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content (Join-Path $sourceRoot 'install.ps1') -Raw
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ar-bootstrap-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null
$archiveRoot = Join-Path $testRoot 'archive'
$archiveInstaller = Join-Path $archiveRoot 'installer-main'
New-Item -ItemType Directory -Path $archiveInstaller | Out-Null
$archiveFile = Join-Path $testRoot 'fixture.zip'
$originalEnvironment = @{}
foreach ($name in @('TEMP', 'TMP', 'AIRRELOAD_TEST_BOOTSTRAP_RESULT', 'AIRRELOAD_TEST_BOOTSTRAP_FAIL')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$env:TEMP = $testRoot
$env:TMP = $testRoot
$env:AIRRELOAD_TEST_BOOTSTRAP_RESULT = Join-Path $testRoot 'result.json'
$env:AIRRELOAD_TEST_BOOTSTRAP_FAIL = $null
$script:downloadFailure = $false
$script:corruptArchive = $false
$script:downloadCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    Assert-True ($Uri -ceq 'https://github.com/Airreload/installer/archive/refs/heads/main.zip') 'bootstrap must download one official snapshot'
    $script:downloadCount++
    if ($script:downloadFailure) { throw 'Fixture download failure' }
    if ($script:corruptArchive) { Set-Content $OutFile 'not a zip'; return }
    Copy-Item -LiteralPath $archiveFile -Destination $OutFile
}
function Assert-Clean {
    Assert-True (@(Get-ChildItem $testRoot -Directory -Filter 'airreload-bootstrap-*').Count -eq 0) 'bootstrap temporary directories must be cleaned'
}
function New-FixtureArchive {
    Remove-Item -LiteralPath $archiveFile -ErrorAction SilentlyContinue
    $zip = [IO.Compression.ZipFile]::Open($archiveFile, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem $archiveInstaller -File) {
            # Match GitHub's slash-separated ZIP entry names on .NET Framework.
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, "installer-main/$($file.Name)") | Out-Null
        }
    } finally { $zip.Dispose() }
}
function Assert-Rejected {
    $rejected = $false
    try { Invoke-Expression $source } catch { $rejected = $true }
    Assert-True $rejected 'bootstrap failure must propagate'
    Assert-True (-not (Test-Path $env:AIRRELOAD_TEST_BOOTSTRAP_RESULT)) 'failure must not execute the installer'
    Assert-Clean
}

Set-Content (Join-Path $archiveInstaller 'install.ps1') @'
param([switch]$Replace, [switch]$NoPath, [switch]$PreserveData)
$ErrorActionPreference = 'Stop'
if ($env:AIRRELOAD_TEST_BOOTSTRAP_FAIL -eq '1') { exit 7 }
if ((Get-Content (Join-Path $PSScriptRoot 'versions.env') -Raw).Trim() -cne 'fixture manifest') { throw 'wrong manifest' }
@{ replace = [bool]$Replace; noPath = [bool]$NoPath; preserveData = [bool]$PreserveData } |
    ConvertTo-Json | Set-Content $env:AIRRELOAD_TEST_BOOTSTRAP_RESULT
'@
Set-Content (Join-Path $archiveInstaller 'versions.env') 'fixture manifest'
New-FixtureArchive
# A manifest in the current directory must never override the downloaded one.
Set-Content (Join-Path $testRoot 'versions.env') 'poisoned manifest'
Push-Location $testRoot
try {
    Invoke-Expression $source
    Assert-True ($script:downloadCount -eq 1) 'piped invocation must bootstrap'
    $result = Get-Content $env:AIRRELOAD_TEST_BOOTSTRAP_RESULT -Raw | ConvertFrom-Json
    Assert-True (-not $result.replace -and -not $result.noPath -and -not $result.preserveData) 'zero-argument invocation must work'
    Assert-Clean

    Set-Content (Join-Path $testRoot 'caller.ps1') 'Invoke-Expression $source'
    & (Join-Path $testRoot 'caller.ps1')
    Assert-True ($script:downloadCount -eq 2) 'IEX from a script must ignore its adjacent manifest'
    Assert-Clean

    & ([scriptblock]::Create($source)) -Replace -NoPath -PreserveData
    $result = Get-Content $env:AIRRELOAD_TEST_BOOTSTRAP_RESULT -Raw | ConvertFrom-Json
    Assert-True ($result.replace -and $result.noPath -and $result.preserveData) 'all options must reach child installer'
    Assert-Clean

    $standalone = Join-Path $testRoot 'standalone'
    New-Item -ItemType Directory -Path $standalone | Out-Null
    Set-Content (Join-Path $standalone 'install.ps1') $source
    & (Join-Path $standalone 'install.ps1') -NoPath
    $result = Get-Content $env:AIRRELOAD_TEST_BOOTSTRAP_RESULT -Raw | ConvertFrom-Json
    Assert-True ($result.noPath -and -not $result.replace) 'standalone script must bootstrap and forward options'
    Assert-Clean
    Remove-Item $env:AIRRELOAD_TEST_BOOTSTRAP_RESULT

    $script:downloadFailure = $true
    Assert-Rejected
    $script:downloadFailure = $false
    $script:corruptArchive = $true
    Assert-Rejected
    $script:corruptArchive = $false
    $env:AIRRELOAD_TEST_BOOTSTRAP_FAIL = '1'
    Assert-Rejected
    $env:AIRRELOAD_TEST_BOOTSTRAP_FAIL = $null

    Remove-Item (Join-Path $archiveInstaller 'versions.env')
    New-FixtureArchive
    Assert-Rejected
    Write-Host 'All Windows bootstrap tests passed.'
} finally {
    Pop-Location
    foreach ($name in $originalEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
