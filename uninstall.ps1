[CmdletBinding()]
param([switch]$Yes)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$markerContent = 'airreload-installer-v1'

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

$installRoot = if ($env:AIRRELOAD_INSTALL_ROOT) { $env:AIRRELOAD_INSTALL_ROOT } else { Join-Path $env:USERPROFILE '.airreload' }
if (-not [IO.Path]::IsPathRooted($installRoot)) { throw 'AIRRELOAD_INSTALL_ROOT must be an absolute path.' }
$installRoot = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) { throw "Airreload is not installed at $installRoot." }
$rootItem = Get-Item -LiteralPath $installRoot -Force
$markerPath = Join-Path $installRoot '.airreload-installer'
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
    (Get-Content -LiteralPath $markerPath -Raw).Trim() -cne $markerContent) {
    throw "$installRoot is not owned by the Airreload installer; it was not changed."
}

if (-not $Yes) {
    $answer = Read-Host "Remove Airreload from $installRoot? [y/N]"
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Host 'Uninstall cancelled.'
        exit 0
    }
}

$binPath = Join-Path $installRoot 'bin'
$userPath = Get-UserPath
if ($null -eq $userPath) { $userPath = '' }
$updatedEntries = @($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $binPath.TrimEnd('\') })
Set-UserPath -Value ($updatedEntries -join ';')
Remove-Item -LiteralPath $installRoot -Recurse -Force
Write-Host 'Airreload was uninstalled.'
