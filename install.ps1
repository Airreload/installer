[CmdletBinding()]
param(
    [switch]$Replace,
    [switch]$NoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$markerContent = 'airreload-installer-v1'
$manifestPath = Join-Path $PSScriptRoot 'versions.env'
$stageDirectory = $null
$backupDirectory = $null
$installCommitted = $false
$pathChanged = $false
$originalUserPath = $null

function Get-ManifestValue {
    param([Parameter(Mandatory)][string]$Name)

    $matches = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ -match "^$([regex]::Escape($Name))=(.*)$" })
    if ($matches.Count -ne 1) { throw "Invalid $Name in versions.env." }
    return $matches[0].Substring($Name.Length + 1)
}

function Test-OwnedDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $marker = Join-Path $Path '.airreload-installer'
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or
        -not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    return (Get-Content -LiteralPath $marker -Raw).Trim() -ceq $markerContent
}

function Remove-OwnedDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-OwnedDirectory -Path $Path)) { throw "Refusing to remove unowned directory: $Path" }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Invoke-GitClone {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Depth
    )

    & git -c core.longpaths=true clone --quiet --filter=blob:none --depth $Depth --single-branch --branch $Tag -- $Repository $Destination
    if ($LASTEXITCODE -ne 0) { throw "Failed to clone $Repository at $Tag." }
    $actualCommit = (& git -c core.longpaths=true -C $Destination rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $ExpectedCommit) {
        throw "$Repository tag $Tag resolved to $actualCommit, expected $ExpectedCommit."
    }
}

function Write-Launcher {
    param([Parameter(Mandatory)][string]$Path)

    $content = @'
@echo off
setlocal
set "AIRRELOAD_ROOT=%~dp0.."
call "%AIRRELOAD_ROOT%\flutter\bin\dart.bat" "--packages=%AIRRELOAD_ROOT%\cli\.dart_tool\package_config.json" "%AIRRELOAD_ROOT%\cli\bin\airreload.dart" %*
exit /b %ERRORLEVEL%
'@
    Set-Content -LiteralPath $Path -Value $content -Encoding Ascii
}

function Test-Installation {
    param([Parameter(Mandatory)][string]$Root)

    $flutter = Join-Path $Root 'flutter\bin\flutter.bat'
    $launcher = Join-Path $Root 'bin\airreload.cmd'
    $versionJson = (& $flutter --version --machine) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw 'Flutter version validation failed.' }
    try { $frameworkVersion = ($versionJson | ConvertFrom-Json).frameworkVersion }
    catch { throw 'Flutter returned invalid version information.' }
    if ($frameworkVersion -notmatch '^\d+\.\d+\.\d+\S*$' -or $frameworkVersion -eq '0.0.0-unknown') {
        throw "Flutter returned an invalid framework version: $frameworkVersion"
    }
    & $launcher version
    if ($LASTEXITCODE -ne 0) { throw 'Airreload version validation failed.' }
    & $launcher --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Airreload help validation failed.' }
    & $launcher doctor
    if ($LASTEXITCODE -ne 0) { throw 'Airreload doctor validation failed.' }
}

function Get-UserPath {
    if ($env:AIRRELOAD_TEST_USER_PATH_FILE) {
        if (Test-Path -LiteralPath $env:AIRRELOAD_TEST_USER_PATH_FILE) {
            return (Get-Content -LiteralPath $env:AIRRELOAD_TEST_USER_PATH_FILE -Raw).TrimEnd("`r", "`n")
        }
        return ''
    }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPath {
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ($env:AIRRELOAD_TEST_USER_PATH_FILE) {
        Set-Content -LiteralPath $env:AIRRELOAD_TEST_USER_PATH_FILE -Value $Value -NoNewline
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Required command not found: git' }
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Version manifest not found: $manifestPath" }

$cliRepository = Get-ManifestValue -Name 'CLI_REPOSITORY'
$cliTag = Get-ManifestValue -Name 'CLI_TAG'
$cliCommit = Get-ManifestValue -Name 'CLI_COMMIT'
$flutterRepository = Get-ManifestValue -Name 'FLUTTER_REPOSITORY'
$flutterTag = Get-ManifestValue -Name 'FLUTTER_TAG'
$flutterCommit = Get-ManifestValue -Name 'FLUTTER_COMMIT'

if ($cliRepository -cne 'https://github.com/Airreload/cli.git') { throw 'Unexpected CLI repository in versions.env.' }
if ($flutterRepository -cne 'https://github.com/Airreload/flutter.git') { throw 'Unexpected Flutter repository in versions.env.' }
if ($cliTag -notmatch '^[A-Za-z0-9._-]+$' -or $flutterTag -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid release tag in versions.env.' }
if ($cliCommit -notmatch '^[0-9a-f]{40}$' -or $flutterCommit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid commit in versions.env.' }

$installRoot = if ($env:AIRRELOAD_INSTALL_ROOT) { $env:AIRRELOAD_INSTALL_ROOT } else { Join-Path $env:USERPROFILE '.airreload' }
if (-not [IO.Path]::IsPathRooted($installRoot)) { throw 'AIRRELOAD_INSTALL_ROOT must be an absolute path.' }
$installRoot = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')
$installParent = Split-Path -Parent $installRoot
if (-not $installParent -or $installRoot -eq [IO.Path]::GetPathRoot($installRoot)) { throw 'Refusing to use a drive root.' }
if (Test-Path -LiteralPath $installRoot) {
    $rootItem = Get-Item -LiteralPath $installRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The installation root may not be a symbolic link or junction.' }
    if (-not $Replace) { throw "$installRoot already exists. Re-run with -Replace to replace an installer-owned installation." }
    if (-not (Test-OwnedDirectory -Path $installRoot)) { throw "$installRoot is not owned by the Airreload installer; it was not changed." }
}

New-Item -ItemType Directory -Path $installParent -Force | Out-Null
$stageDirectory = Join-Path $installParent ".airreload-install.$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stageDirectory | Out-Null
Set-Content -LiteralPath (Join-Path $stageDirectory '.airreload-installer') -Value $markerContent -NoNewline

try {
    Write-Host "Installing Airreload into $installRoot"
    Write-Host "Cloning CLI $cliTag..."
    Invoke-GitClone -Repository $cliRepository -Tag $cliTag -ExpectedCommit $cliCommit -Destination (Join-Path $stageDirectory 'cli') -Depth 1
    Write-Host "Cloning Flutter $flutterTag..."
    Invoke-GitClone -Repository $flutterRepository -Tag $flutterTag -ExpectedCommit $flutterCommit -Destination (Join-Path $stageDirectory 'flutter') -Depth 2

    Write-Host 'Bootstrapping Flutter and Dart...'
    & (Join-Path $stageDirectory 'flutter\bin\flutter.bat') --version
    if ($LASTEXITCODE -ne 0) { throw 'Flutter bootstrap failed.' }
    Push-Location (Join-Path $stageDirectory 'cli')
    try {
        & (Join-Path $stageDirectory 'flutter\bin\dart.bat') pub get
        if ($LASTEXITCODE -ne 0) { throw 'Dart package resolution failed.' }
    }
    finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $stageDirectory 'bin') | Out-Null
    Write-Launcher -Path (Join-Path $stageDirectory 'bin\airreload.cmd')

    Write-Host 'Validating staged installation...'
    Test-Installation -Root $stageDirectory

    if (Test-Path -LiteralPath $installRoot) {
        $backupDirectory = Join-Path $installParent ".airreload-backup.$([guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $installRoot -Destination $backupDirectory
    }
    Move-Item -LiteralPath $stageDirectory -Destination $installRoot
    $stageDirectory = $null
    $installCommitted = $true

    if (-not $NoPath) {
        $binPath = Join-Path $installRoot 'bin'
        $originalUserPath = Get-UserPath
        if ($null -eq $originalUserPath) { $originalUserPath = '' }
        $pathEntries = @($originalUserPath -split ';' | Where-Object { $_ })
        if (-not ($pathEntries | Where-Object { $_.TrimEnd('\') -ieq $binPath.TrimEnd('\') })) {
            Set-UserPath -Value ((@($pathEntries) + $binPath) -join ';')
            $pathChanged = $true
        }
        if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $binPath.TrimEnd('\') })) {
            $env:Path = "$env:Path;$binPath"
        }
    }

    Write-Host 'Validating installed command...'
    Test-Installation -Root $installRoot

    if ($backupDirectory) {
        Remove-OwnedDirectory -Path $backupDirectory
        $backupDirectory = $null
    }
    $installCommitted = $false
    Write-Host ''
    Write-Host 'Airreload is installed.'
    if ($NoPath) { Write-Host "Run: $installRoot\bin\airreload.cmd doctor" }
    else { Write-Host 'Open a new PowerShell window, then run: airreload doctor' }
}
catch {
    if ($pathChanged) { Set-UserPath -Value $originalUserPath }
    if ($installCommitted -and (Test-OwnedDirectory -Path $installRoot)) { Remove-OwnedDirectory -Path $installRoot }
    if ($backupDirectory -and (Test-Path -LiteralPath $backupDirectory) -and -not (Test-Path -LiteralPath $installRoot)) {
        Move-Item -LiteralPath $backupDirectory -Destination $installRoot
        $backupDirectory = $null
    }
    throw
}
finally {
    if ($stageDirectory -and (Test-Path -LiteralPath $stageDirectory) -and (Test-OwnedDirectory -Path $stageDirectory)) {
        Remove-OwnedDirectory -Path $stageDirectory
    }
}
