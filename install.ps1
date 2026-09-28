[CmdletBinding()]
param(
    [switch]$Replace,
    [switch]$NoPath,
    [switch]$PreserveData
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
$preservedPaths = @()

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

function Move-OwnedDirectory {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-OwnedDirectory -Path $Source)) { throw "Refusing to move unowned directory: $Source" }
    if (Test-Path -LiteralPath $Destination) { throw "Refusing to replace existing destination: $Destination" }
    [IO.Directory]::Move($Source, $Destination)
}

function Install-Binary {
    param([Parameter(Mandatory)][string]$Destination)

    $url = "https://github.com/Airreload/cli/releases/download/$cliTag/airreload-windows-x64.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 300
    $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $cliSha256) { throw 'Airreload binary checksum mismatch.' }
}

function Test-Installation {
    param([Parameter(Mandatory)][string]$Root)

    $launcher = Join-Path $Root 'bin\airreload.exe'
    $version = (& $launcher version) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or $version -cne "Airreload $($cliTag.Substring(1))") {
        throw "Airreload version validation failed: $version"
    }
    Write-Host $version
    & $launcher --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Airreload help validation failed.' }
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

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or
    $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
    throw 'Airreload currently supports Windows x64 only.'
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Version manifest not found: $manifestPath" }

$cliRepository = Get-ManifestValue -Name 'CLI_REPOSITORY'
$cliTag = Get-ManifestValue -Name 'CLI_TAG'
$cliCommit = Get-ManifestValue -Name 'CLI_COMMIT'
$cliSha256 = Get-ManifestValue -Name 'CLI_SHA256_WINDOWS_X64'

if ($cliRepository -cne 'https://github.com/Airreload/cli.git') { throw 'Unexpected CLI repository in versions.env.' }
if ($cliTag -cnotmatch '^v[0-9A-Za-z.+-]+$') { throw 'Invalid CLI release tag in versions.env.' }
if ($cliCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid CLI commit in versions.env.' }
if ($cliSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid binary SHA-256 checksum in versions.env.' }

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

$stageDirectory = Join-Path $installParent ".airreload-install.$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $installParent -Force | Out-Null
New-Item -ItemType Directory -Path $stageDirectory | Out-Null
Set-Content -LiteralPath (Join-Path $stageDirectory '.airreload-installer') -Value $markerContent -NoNewline

try {
    Write-Host "Installing Airreload into $installRoot"
    Write-Host "Downloading Airreload $cliTag..."
    New-Item -ItemType Directory -Path (Join-Path $stageDirectory 'bin') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stageDirectory 'cli') | Out-Null
    Install-Binary -Destination (Join-Path $stageDirectory 'bin\airreload.exe')

    Write-Host 'Validating staged installation...'
    Test-Installation -Root $stageDirectory

    if (Test-Path -LiteralPath $installRoot) {
        $backupDirectory = Join-Path $installParent ".airreload-backup.$([guid]::NewGuid().ToString('N'))"
        Move-OwnedDirectory -Source $installRoot -Destination $backupDirectory
    }
    Move-OwnedDirectory -Source $stageDirectory -Destination $installRoot
    $stageDirectory = $null
    $installCommitted = $true

    if ($PreserveData -and $backupDirectory) {
        foreach ($relative in @('cli\.airreload', 'sdks')) {
            $source = Join-Path $backupDirectory $relative
            if (Test-Path -LiteralPath $source) {
                $item = Get-Item -LiteralPath $source -Force
                if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to preserve non-directory data: $relative"
                }
                $destination = Join-Path $installRoot $relative
                if (Test-Path -LiteralPath $destination) { throw "Staged release unexpectedly contains user data: $relative" }
                [IO.Directory]::Move($source, $destination)
                $preservedPaths += $relative
            }
        }
    }

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
    if ($NoPath) { Write-Host "Run: $installRoot\bin\airreload.exe doctor" }
    else { Write-Host 'Open a new PowerShell window, then run: airreload doctor' }
}
catch {
    if ($pathChanged) { Set-UserPath -Value $originalUserPath }
    foreach ($relative in $preservedPaths) {
        $source = Join-Path $installRoot $relative
        $destination = Join-Path $backupDirectory $relative
        # A failed move stops rollback before either copy can be deleted.
        [IO.Directory]::Move($source, $destination)
    }
    if ($installCommitted -and (Test-OwnedDirectory -Path $installRoot)) { Remove-OwnedDirectory -Path $installRoot }
    if ($backupDirectory -and (Test-Path -LiteralPath $backupDirectory) -and -not (Test-Path -LiteralPath $installRoot)) {
        Move-OwnedDirectory -Source $backupDirectory -Destination $installRoot
        $backupDirectory = $null
    }
    throw
}
finally {
    if ($stageDirectory -and (Test-Path -LiteralPath $stageDirectory) -and (Test-OwnedDirectory -Path $stageDirectory)) {
        Remove-OwnedDirectory -Path $stageDirectory
    }
}
