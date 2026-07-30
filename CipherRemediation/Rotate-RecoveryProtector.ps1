#Requires -Version 5.1
<#
.SYNOPSIS
    LAB/OPS tool: rotate the BitLocker recovery-password protector on a volume and
    re-escrow the new one to Entra.

.DESCRIPTION
    Use when a recovery password may have been exposed (e.g. the state.json
    plaintext leak fixed in commit b516ee8). Run elevated. It:
      1. Loads BitLockerCipher.Common.ps1 (sibling Win32\ copy, or the staged
         %ProgramData% copy) for the status read, escrow, and marker helpers.
      2. Records the current recovery-password protector IDs.
      3. Adds a NEW recovery-password protector.
      4. Removes the OLD recovery-password protector(s) — the compromised password
         stops working immediately.
      5. Escrows the new protector to Entra (BackupToAAD) and rewrites the escrow
         marker so Detect-CipherRemediation passes against the NEW protector.
      6. Scrubs state.json if it contains leaked plaintext recovery-password data
         (the worker recreates a clean state file on its next run).

    If the Entra escrow fails (e.g. not Entra-joined, transient network), the new
    protector still exists locally and the marker is NOT written — detection stays
    red and the worker/this script can retry.

.PARAMETER MountPoint
    Volume to rotate. Default C:.

.EXAMPLE
    .\Rotate-RecoveryProtector.ps1
#>
[CmdletBinding()]
param(
    [string]$MountPoint = 'C:'
)
$ErrorActionPreference = 'Stop'

function Say { param([string]$Message, [string]$Color = 'Cyan') Write-Host "[rotate] $Message" -ForegroundColor $Color }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'Run this elevated (Administrator).'
}

# 1) Load Common (sibling Win32\ first, then the staged ProgramData copy) -------
$common = @(
    (Join-Path $PSScriptRoot 'Win32\BitLockerCipher.Common.ps1'),
    (Join-Path $PSScriptRoot 'BitLockerCipher.Common.ps1'),
    (Join-Path $env:ProgramData 'BitLockerCipherRemediation\BitLockerCipher.Common.ps1')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $common) { throw 'BitLockerCipher.Common.ps1 not found (Win32\ sibling or ProgramData).' }
. $common
Say "loaded $common"

$nowUtc = (Get-Date).ToUniversalTime().ToString('o')

# 2) Current recovery protectors ------------------------------------------------
$status = Get-BLCipherStatus -MountPoint $MountPoint
$old = @(Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector)
Say ("current state: {0} {1}% Protection={2}; {3} recovery protector(s)" -f `
    $status.Method, $status.EncryptionPercentage, $status.ProtectionStatus, $old.Count)
if ($old.Count -eq 0) { Say 'no existing recovery protector — will just add + escrow a fresh one.' 'Yellow' }

# 3) Add the NEW protector FIRST (never leave the drive without one) ------------
Say 'adding new recovery-password protector...'
Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector | Out-Null

$status = Get-BLCipherStatus -MountPoint $MountPoint
$new = @(Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector |
    Where-Object { $_.KeyProtectorId -notin @($old | ForEach-Object { $_.KeyProtectorId }) })
if ($new.Count -ne 1) { throw "Expected exactly 1 new recovery protector, found $($new.Count) — aborting before touching the old one." }
Say ("new protector: {0}" -f $new[0].KeyProtectorId) 'Green'

# 4) Remove the OLD (compromised) protector(s) ----------------------------------
foreach ($p in $old) {
    Say ("removing old protector {0} ..." -f $p.KeyProtectorId)
    try { Remove-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $p.KeyProtectorId | Out-Null; Say "  removed." }
    catch { Say ("  could NOT remove {0}: {1}" -f $p.KeyProtectorId, $_.Exception.Message) 'Yellow' }
}

# 5) Escrow the new protector + rewrite the marker ------------------------------
# Backup-BLRecoveryProtectorToAad logs every attempt and only writes the marker
# when ALL passed protectors escrow successfully.
Say 'escrowing new protector to Entra (BackupToAAD)...'
Backup-BLRecoveryProtectorToAad -Protectors $new -MountPoint $MountPoint -NowUtc $nowUtc
$status = Get-BLCipherStatus -MountPoint $MountPoint
$current = @(Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector)
if (Test-AllRecoveryProtectorsBackedUp -Protectors $current -MountPoint $MountPoint) {
    Say 'escrow confirmed; marker matches the new protector.' 'Green'
}
else {
    Say 'escrow NOT confirmed (see remediation.log) — new protector exists locally; re-run this script or let the worker retry.' 'Yellow'
}

# 6) Scrub a leaked state.json --------------------------------------------------
$statePath = Join-Path (Get-CipherWorkingDir) 'state.json'
if (Test-Path -LiteralPath $statePath) {
    $raw = Get-Content -LiteralPath $statePath -Raw
    if ($raw -match '"RecoveryPassword":\s*"\d{6}-') {
        Say 'state.json contains plaintext recovery-password data — deleting it (worker recreates it clean).' 'Yellow'
        try { Remove-Item -LiteralPath $statePath -Force; Say '  state.json deleted.' }
        catch { Say ("  could NOT delete state.json: {0}" -f $_.Exception.Message) 'Yellow' }
    }
}

Say 'done. verify protectors:  manage-bde -protectors -get C:' 'Green'
