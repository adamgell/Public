#Requires -Version 5.1
<#
.SYNOPSIS
    Win32 app detection rule: "installed" only when the device is fully upgraded to XtsAes256.
.DESCRIPTION
    Detected (exit 0 + stdout) requires: XtsAes256 cipher, 100% encrypted,
    ProtectionStatus On, and the recovery key escrowed to Entra. Checks are
    representation-robust (enum name or integer). Any intermediate state exits 1
    (not detected) so Intune keeps re-evaluating.
#>
$ErrorActionPreference = 'Stop'

if ($env:PROCESSOR_ARCHITEW6432 -and -not [Environment]::Is64BitProcess) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        & $sysnative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    }
}

# Intune runs a Win32 *script* detection rule standalone — the .intunewin payload
# is NOT extracted during detection, so Common is NOT co-located with this script.
# The installer stages Common to %ProgramData%; load it from there. Fall back to a
# sibling copy (manual testing from the Win32 folder). If neither exists, the app
# isn't installed -> "not detected" (exit 1).
if (-not (Get-Command Get-BLCipherStatus -ErrorAction SilentlyContinue)) {
    $commonPath = @(
        (Join-Path $env:ProgramData 'BitLockerCipherRemediation\BitLockerCipher.Common.ps1'),
        (Join-Path $PSScriptRoot 'BitLockerCipher.Common.ps1')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $commonPath) {
        Write-Host 'NOT DETECTED: BitLockerCipher.Common.ps1 not found in %ProgramData% or script dir (app not installed).'
        exit 1
    }
    . $commonPath
}

try {
    $status   = Get-BLCipherStatus -MountPoint 'C:'
    $recovery = Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector

    # Representation-robust: Get-BitLockerVolume enums can surface as names or as
    # integer strings depending on the OS/module build, so key "fully encrypted" off
    # the unambiguous EncryptionPercentage and accept either form for cipher/protection.
    $isXts    = (([string]$status.Method) -in @('XtsAes256', '7'))
    $isFull   = (([int]$status.EncryptionPercentage) -ge 100)
    $isOn     = (([string]$status.ProtectionStatus) -in @('On', '1'))
    $hasRec   = ($recovery.Count -gt 0)
    $escrowed = ($hasRec -and (Test-AllRecoveryProtectorsBackedUp -Protectors $recovery -MountPoint 'C:'))
    $done     = $isXts -and $isFull -and $isOn -and $escrowed

    $summary = "Method=$($status.Method) VolumeStatus=$($status.VolumeStatus) $($status.EncryptionPercentage)% Protection=$($status.ProtectionStatus) | XtsAes256=$isXts FullyEncrypted=$isFull ProtectionOn=$isOn RecoveryProtector=$hasRec KeyEscrowed=$escrowed"
    try { Write-CipherLog -Message "DETECT $summary -> done=$done" } catch {}

    if ($done) {
        # exit 0 + stdout = "detected" (Intune's rule). This is the ONLY stdout line.
        Write-Output 'Detected: OS drive C: is XtsAes256, fully encrypted, and recovery key escrowed'
        exit 0
    }
    # Not detected: exit 1. The diagnostic uses Write-Host (console/host, not the
    # stdout stream), and exit 1 means Intune ignores any output anyway.
    Write-Host "NOT DETECTED: $summary"
    exit 1
}
catch {
    Write-Host "NOT DETECTED (error): $($_.Exception.Message)"
    try { Write-CipherLog -Message "DETECT error: $($_.Exception.Message)" } catch {}
    exit 1
}
