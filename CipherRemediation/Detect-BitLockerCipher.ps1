#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Proactive Remediation detection: flags OS drives not encrypted with XtsAes256.
.DESCRIPTION
    Exit 0 = compliant (XtsAes256, or not encrypted = out of scope).
    Exit 1 = non-compliant (128-bit / CBC / legacy / hardware) or error.
#>
$ErrorActionPreference = 'Stop'

# Relaunch under 64-bit PowerShell if running 32-bit on a 64-bit OS (BitLocker module is 64-bit only).
if ($env:PROCESSOR_ARCHITEW6432 -and -not [Environment]::Is64BitProcess) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        & $sysnative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    }
}

$MountPoint = 'C:'

try {
    $volume = Get-BitLockerVolume -MountPoint $MountPoint
    $method = [string]$volume.EncryptionMethod

    if ($method -eq 'XtsAes256') {
        Write-Output "Compliant: OS drive $MountPoint is $method"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($method) -or $method -eq 'None') {
        Write-Output "Compliant: OS drive $MountPoint is not encrypted ($method); cipher upgrade not applicable"
        exit 0
    }

    Write-Output "Non-compliant: OS drive $MountPoint is $method (needs XtsAes256)"
    exit 1
}
catch {
    Write-Warning "BitLocker cipher detection failed: $($_.Exception.Message)"
    exit 1
}
