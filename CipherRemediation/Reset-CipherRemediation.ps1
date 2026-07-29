#Requires -Version 5.1
<#
.SYNOPSIS
    LAB/TEST reset for the BitLocker cipher remediation: decrypt C:, wipe the
    remediation state, re-arm the scheduled task, and run it again from scratch.

.DESCRIPTION
    For testing only — run elevated. It:
      1. Decrypts the OS drive (Disable-BitLocker), unless -SkipDecrypt.
      2. Deletes the worker state (state.json), escrow marker (C.marker.json) and
         remediation.log from %ProgramData%\BitLockerCipherRemediation.
      3. Re-registers the scheduled task (the worker self-deletes it on Done) by
         re-running Install-CipherRemediation.ps1, or reuses the existing task.
      4. Starts the task so the worker begins a fresh Init -> ... -> Done cycle.

    NOT part of the deployed Win32 package — a bench utility.

.PARAMETER MountPoint
    OS drive to reset. Default C:.

.PARAMETER SkipDecrypt
    Don't decrypt — just wipe state and re-run (e.g. the drive is already decrypted,
    or you only want to reset the state machine).

.PARAMETER WaitForDecrypt
    Block until decryption reaches 0% before continuing (otherwise the worker picks
    up the in-progress decryption on its own).

.EXAMPLE
    .\Reset-CipherRemediation.ps1
.EXAMPLE
    .\Reset-CipherRemediation.ps1 -WaitForDecrypt
.EXAMPLE
    .\Reset-CipherRemediation.ps1 -SkipDecrypt
#>
[CmdletBinding()]
param(
    [string]$MountPoint = 'C:',
    [switch]$SkipDecrypt,
    [switch]$WaitForDecrypt
)
$ErrorActionPreference = 'Stop'

function Say { param([string]$Message, [string]$Color = 'Cyan') Write-Host "[reset] $Message" -ForegroundColor $Color }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'Run this elevated (Administrator).'
}

$workDir  = Join-Path $env:ProgramData 'BitLockerCipherRemediation'
$taskName = 'BitLockerCipherRemediation'

# 1) Decrypt the OS drive ------------------------------------------------------
if ($SkipDecrypt) {
    Say 'Skipping decrypt (-SkipDecrypt).'
}
else {
    $v = Get-BitLockerVolume -MountPoint $MountPoint
    Say ("Current: {0} {1}% Protection={2}" -f $v.EncryptionMethod, [int]$v.EncryptionPercentage, $v.ProtectionStatus)
    if ([int]$v.EncryptionPercentage -gt 0 -and ([string]$v.VolumeStatus) -ne 'DecryptionInProgress') {
        Say "Decrypting $MountPoint (Disable-BitLocker)..."
        Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null
    }
    else {
        Say "$MountPoint is already decrypted or decrypting — nothing to start."
    }
    if ($WaitForDecrypt) {
        do {
            Start-Sleep -Seconds 15
            $v = Get-BitLockerVolume -MountPoint $MountPoint
            Say ("  decrypting... {0}% ({1})" -f [int]$v.EncryptionPercentage, $v.VolumeStatus)
        } while ([int]$v.EncryptionPercentage -gt 0)
        Say 'Fully decrypted.' 'Green'
    }
}

# 2) Wipe the remediation state ------------------------------------------------
foreach ($file in 'state.json', 'C.marker.json', 'remediation.log') {
    $path = Join-Path $workDir $file
    if (Test-Path -LiteralPath $path) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop; Say "removed $file" }
        catch { Say "could NOT remove $file ($($_.Exception.Message)) — close it if it's open in a log viewer" 'Yellow' }
    }
}

# 3) Re-arm the scheduled task (the worker self-deletes it on Done) ------------
$installer = @(
    (Join-Path $PSScriptRoot 'Install-CipherRemediation.ps1'),
    (Join-Path $PSScriptRoot 'Win32\Install-CipherRemediation.ps1')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if ($installer) {
    Say "re-running installer to re-stage + re-register: $installer"
    & $installer
}
elseif (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Say 'Install-CipherRemediation.ps1 not found nearby; reusing the existing scheduled task.'
}
else {
    Say 'No installer found and no existing task — deploy/install the app first.' 'Yellow'
    return
}

# 4) Kick it off now -----------------------------------------------------------
Say 'starting the scheduled task...'
Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Say ("watch it:  Get-Content '{0}\remediation.log' -Wait -Tail 20" -f $workDir) 'Green'
