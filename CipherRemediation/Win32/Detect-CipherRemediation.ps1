#Requires -Version 5.1
<#
.SYNOPSIS
    Win32 app detection rule: "installed" only when the device is fully upgraded to XtsAes256.
.DESCRIPTION
    Detected (exit 0 + stdout) requires: EncryptionMethod XtsAes256, VolumeStatus
    FullyEncrypted, ProtectionStatus On, and the recovery key escrowed to Entra.
    Any intermediate state exits 1 (not detected) so Intune keeps re-evaluating.
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
# The installer stages Common to %ProgramData%; load it from there. If it's absent,
# the app isn't installed yet -> report "not detected" (exit 1).
if (-not (Get-Command Get-BLCipherStatus -ErrorAction SilentlyContinue)) {
    $commonPath = Join-Path $env:ProgramData 'BitLockerCipherRemediation\BitLockerCipher.Common.ps1'
    if (-not (Test-Path -LiteralPath $commonPath)) { exit 1 }
    . $commonPath
}

try {
    $status = Get-BLCipherStatus -MountPoint 'C:'
    $recovery = Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector

    $done = $status.Method -eq 'XtsAes256' -and
            $status.VolumeStatus -eq 'FullyEncrypted' -and
            $status.ProtectionStatus -eq 'On' -and
            $recovery.Count -gt 0 -and
            (Test-AllRecoveryProtectorsBackedUp -Protectors $recovery -MountPoint 'C:')

    if ($done) {
        Write-Output 'Detected: OS drive C: is XtsAes256, fully encrypted, and recovery key escrowed'
        exit 0
    }
    exit 1
}
catch {
    Write-Warning "Cipher remediation detection failed: $($_.Exception.Message)"
    exit 1
}
