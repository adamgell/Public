#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 requirement script: the cipher-upgrade app is applicable ONLY to
    OS drives that actually need it.
.DESCRIPTION
    Outputs exactly ONE line — 'Applicable' or 'NotApplicable' — and always exits 0
    (Intune compares the string output; extra output would break the comparison).

    Applicable when the OS drive is encrypted AND either:
      - the cipher is anything other than XtsAes256 (XtsAes128 / Aes128 / Aes256
        CBC / legacy), or
      - the cipher is already XtsAes256 but the conversion is Used-Space-Only
        (EncryptionFlags bit 0x1, aka DataOnly) — full-disk policy demands Full.

    NotApplicable when the drive is unencrypted (a separate encryption baseline
    handles those), a hardware self-encrypting drive, already full-disk XtsAes256,
    or the state cannot be read (conservative: never install on unknown state —
    the daily Proactive Remediation detection still reports those devices).

    Wire in Intune as: requirement script, run as SYSTEM, 64-bit, signature check
    off, rule = string output EQUALS 'Applicable'.
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

function ConvertTo-CipherMethodName {
    # Get-BitLockerVolume/CIM can surface the method as a friendly name OR its
    # integer value depending on OS/module build; normalize to names.
    param($Method)
    switch ([string]$Method) {
        '0'     { 'None' }
        '1'     { 'Aes128Diffuser' }
        '2'     { 'Aes256Diffuser' }
        '3'     { 'Aes128' }
        '4'     { 'Aes256' }
        '5'     { 'Hardware' }
        '6'     { 'XtsAes128' }
        '7'     { 'XtsAes256' }
        default { [string]$Method }
    }
}

try {
    $method = $null
    $percentage = $null
    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint
        $method = ConvertTo-CipherMethodName -Method $volume.EncryptionMethod
        $percentage = [int]$volume.EncryptionPercentage
    }
    catch {
        # CIM fallback (Get-BitLockerVolume can throw under the SYSTEM host).
        $ev = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
            -ClassName 'Win32_EncryptableVolume' -Filter "DriveLetter='$MountPoint'"
        if (-not $ev) { throw "No Win32_EncryptableVolume for $MountPoint" }
        $method = ConvertTo-CipherMethodName -Method (Invoke-CimMethod -InputObject $ev -MethodName 'GetEncryptionMethod').EncryptionMethod
        $percentage = [int](Invoke-CimMethod -InputObject $ev -MethodName 'GetConversionStatus' -Arguments @{ PrecisionFactor = [uint32]4 }).EncryptionPercentage
    }

    if ($percentage -le 0 -or [string]::IsNullOrWhiteSpace($method) -or $method -eq 'None') {
        Write-Output 'NotApplicable'    # unencrypted = out of scope
        exit 0
    }
    if ($method -eq 'Hardware') {
        Write-Output 'NotApplicable'    # hardware SED: the worker skips these anyway
        exit 0
    }
    if ($method -ne 'XtsAes256') {
        Write-Output 'Applicable'       # 128-bit / CBC / legacy cipher
        exit 0
    }

    # Cipher is already XtsAes256 — applicable only if the conversion is
    # Used-Space-Only (EncryptionFlags bit 0x1 = DataOnly; full policy wants Full).
    $usedSpaceOnly = $false
    $flagsRead = $false
    try {
        $ev = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' `
            -ClassName 'Win32_EncryptableVolume' -Filter "DriveLetter='$MountPoint'"
        if ($ev) {
            $conversion = Invoke-CimMethod -InputObject $ev -MethodName 'GetConversionStatus' -Arguments @{ PrecisionFactor = [uint32]4 }
            if ($conversion.PSObject.Properties['EncryptionFlags'] -and $null -ne $conversion.EncryptionFlags) {
                $usedSpaceOnly = (([int]$conversion.EncryptionFlags) -band 1) -eq 1
                $flagsRead = $true
            }
        }
    }
    catch { }
    if (-not $flagsRead) {
        # Last resort: parse manage-bde text (en-US wording).
        try {
            $statusText = & (Join-Path $env:WINDIR 'System32\manage-bde.exe') -status $MountPoint 2>&1 | Out-String
            if ($statusText -match 'Used Space Only') { $usedSpaceOnly = $true }
        }
        catch { }
    }

    if ($usedSpaceOnly) { Write-Output 'Applicable' } else { Write-Output 'NotApplicable' }
    exit 0
}
catch {
    Write-Output 'NotApplicable'        # unreadable state: never install blind
    exit 0
}
