#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers and state machine for the BitLocker XtsAes256 cipher upgrade Win32 app.
.DESCRIPTION
    Dot-source this file. All Windows-only operations (BitLocker, TPM, registry,
    scheduled tasks) are isolated in thin wrapper functions so the decision logic
    is unit-testable on any OS.
#>

# ---------------------------------------------------------------------------
# Compliance
# ---------------------------------------------------------------------------
function Test-IsXtsAes256 {
    param([string]$Method)
    $Method -eq 'XtsAes256'
}

function Get-CipherComplianceState {
    param([string]$Method)
    if ($Method -eq 'XtsAes256') { return 'Compliant' }
    if ([string]::IsNullOrWhiteSpace($Method) -or $Method -eq 'None') { return 'OutOfScope' }
    'NonCompliant'
}

# ---------------------------------------------------------------------------
# Secret handling (recovery password is only ever compared/stored as a hash)
# ---------------------------------------------------------------------------
function Get-RecoveryPasswordHash {
    param([Parameter(Mandatory)][string]$RecoveryPassword)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RecoveryPassword)
        ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally {
        $sha256.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Working directory, state, logging
# ---------------------------------------------------------------------------
function Get-CipherWorkingDir {
    if ($env:CIPHER_WORKDIR_OVERRIDE) { return $env:CIPHER_WORKDIR_OVERRIDE }
    Join-Path $env:ProgramData 'BitLockerCipherRemediation'
}

function Get-CipherStatePath {
    Join-Path (Get-CipherWorkingDir) 'state.json'
}

function New-CipherState {
    param([string]$MountPoint = 'C:', [string]$NowUtc)
    if ([string]::IsNullOrWhiteSpace($NowUtc)) {
        $NowUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    [pscustomobject]@{
        Phase          = 'Init'
        MountPoint     = $MountPoint
        AttemptCount   = 0
        FirstSeenUtc   = $NowUtc
        LastUpdatedUtc = $NowUtc
        LastMessage    = 'Initialized'
        AbortReason    = $null
    }
}

function Read-CipherState {
    $path = Get-CipherStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
}

function Write-CipherState {
    param([Parameter(Mandatory)]$State)
    $dir = Get-CipherWorkingDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-CipherStatePath) -Encoding utf8
}

function Write-CipherLog {
    param([Parameter(Mandatory)][string]$Message)
    $dir = Get-CipherWorkingDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $line = '[{0}] {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    Add-Content -LiteralPath (Join-Path $dir 'remediation.log') -Value $line
}

# ---------------------------------------------------------------------------
# Environment wrappers (Windows-only cmdlets isolated here)
# ---------------------------------------------------------------------------
function Get-BLCipherStatus {
    param([string]$MountPoint = 'C:')
    $v = Get-BitLockerVolume -MountPoint $MountPoint
    [pscustomobject]@{
        MountPoint           = $MountPoint
        Method               = [string]$v.EncryptionMethod
        VolumeStatus         = [string]$v.VolumeStatus
        ProtectionStatus     = [string]$v.ProtectionStatus
        EncryptionPercentage = [int]$v.EncryptionPercentage
        KeyProtector         = $v.KeyProtector
    }
}

# ---------------------------------------------------------------------------
# Representation-robust state predicates.
# Get-BitLockerVolume enum properties can surface as names ('FullyEncrypted',
# 'On', 'XtsAes256') OR as their integer values ('1', '1', '7') depending on the
# OS/BitLocker-module build. And a policy-managed drive reports
# EncryptionMethod=XtsAes256 even while fully decrypted at 0%. So decide
# encryption progress from the unambiguous EncryptionPercentage, and accept
# either representation for the cipher/protection enums.
# ---------------------------------------------------------------------------
function Test-BLIsXtsAes256      { param($Status) ([string]$Status.Method) -in @('XtsAes256', '7') }
function Test-BLIsProtectionOn   { param($Status) ([string]$Status.ProtectionStatus) -in @('On', '1') }
function Test-BLIsFullyEncrypted { param($Status) ([int]$Status.EncryptionPercentage) -ge 100 }
function Test-BLIsFullyDecrypted { param($Status) ([int]$Status.EncryptionPercentage) -le 0 }

function Get-FveOsEncryptionMethod {
    try {
        $val = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name 'EncryptionMethodWithXtsOs' -ErrorAction Stop
        [int]$val.EncryptionMethodWithXtsOs
    }
    catch { $null }
}

function Test-BLOnAcPower {
    try {
        $bs = Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryStatus' -ErrorAction Stop
        if (-not $bs) { return $true }          # no battery => desktop/VM => on AC
        [bool](@($bs)[0].PowerOnline)
    }
    catch { $true }                              # battery class unavailable => treat as AC
}

function Get-BLFreeSpaceGb {
    param([string]$MountPoint = 'C:')
    $driveLetter = $MountPoint.TrimEnd(':', '\')
    $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    [math]::Round($vol.SizeRemaining / 1GB, 2)
}

function Get-BLTpmState {
    # Returns 'Ready' | 'NotReady' | 'Absent'.
    # Get-Tpm can fail with 0x80284005 ("output buffer too small") on some virtual
    # TPMs even when the TPM is present and ready, so query the Win32_Tpm WMI class
    # first and fall back to Get-Tpm. An ambiguous/erroring query returns 'NotReady'
    # (a transient state the guardrail waits on) rather than 'Absent', so a flaky TPM
    # query never permanently aborts a device that actually has a TPM.
    try {
        $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if ($tpm) {
            if ($tpm.IsEnabled_InitialValue -and $tpm.IsActivated_InitialValue) { return 'Ready' }
            return 'NotReady'
        }
    }
    catch { }
    try {
        $g = Get-Tpm -ErrorAction Stop
        if (-not $g.TpmPresent) { return 'Absent' }
        if ($g.TpmReady) { return 'Ready' }
        return 'NotReady'
    }
    catch { return 'NotReady' }
}

# ---------------------------------------------------------------------------
# Guardrails (order: hard fails first, then transient waits)
# ---------------------------------------------------------------------------
function Get-CipherGuardrailStatus {
    param(
        [Parameter(Mandatory)]$CipherStatus,
        [double]$MinFreeGb = 10
    )
    if ($CipherStatus.Method -eq 'Hardware') {
        return [pscustomobject]@{ Ok=$false; Hard=$true;  Reason='Hardware self-encrypting drive is not supported' }
    }
    $tpmState = Get-BLTpmState
    if ($tpmState -eq 'Absent') {
        return [pscustomobject]@{ Ok=$false; Hard=$true;  Reason='No TPM present' }
    }
    if ($tpmState -eq 'NotReady') {
        # Transient: a TPM can be present but still initializing (e.g. right after
        # provisioning), or the query was flaky. Wait and retry instead of aborting.
        return [pscustomobject]@{ Ok=$false; Hard=$false; Reason='TPM present but not ready yet (waiting)' }
    }
    if (-not (Test-BLOnAcPower)) {
        return [pscustomobject]@{ Ok=$false; Hard=$false; Reason='Device is on battery power' }
    }
    if ((Get-BLFreeSpaceGb -MountPoint $CipherStatus.MountPoint) -lt $MinFreeGb) {
        return [pscustomobject]@{ Ok=$false; Hard=$false; Reason="Less than $MinFreeGb GB free" }
    }
    [pscustomobject]@{ Ok=$true; Hard=$false; Reason='All guardrails passed' }
}

# ---------------------------------------------------------------------------
# BitLocker actions
# ---------------------------------------------------------------------------
# All BitLocker actions below log their attempt + result/error and are NON-FATAL:
# the state machine re-reads the real drive state on the next run and retries, so a
# single failed cmdlet must never kill the worker or stall progress.
function Invoke-BLDecrypt {
    param([string]$MountPoint = 'C:')
    Write-CipherLog -Message "ACTION Disable-BitLocker $MountPoint (start decryption) ..."
    try { Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null; Write-CipherLog -Message "ACTION OK: Disable-BitLocker $MountPoint" }
    catch { Write-CipherLog -Message "ACTION non-fatal FAILURE: Disable-BitLocker $MountPoint -> $($_.Exception.Message)" }
}

function Invoke-BLEncryptXtsAes256 {
    param([string]$MountPoint = 'C:')
    # Starting encryption on the OS drive is finicky, so try several starters
    # non-fatally (each logged) — one of them starts the conversion:
    #
    # 1) Enable-BitLocker -TpmProtector: provisions + starts on a FRESH volume, but
    #    throws "only one key protector of this type is allowed" once a TPM protector
    #    already exists (the armed-but-decrypted case).
    Write-CipherLog -Message "ACTION Enable-BitLocker $MountPoint XtsAes256 -TpmProtector ..."
    try { Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod XtsAes256 -SkipHardwareTest -TpmProtector -ErrorAction Stop | Out-Null; Write-CipherLog -Message "ACTION OK: Enable-BitLocker $MountPoint" }
    catch { Write-CipherLog -Message "ACTION non-fatal FAILURE: Enable-BitLocker $MountPoint -> $($_.Exception.Message)" }
    # 2) manage-bde -on: reliably STARTS the conversion using the existing protectors —
    #    it works when Enable-BitLocker threw on a protector conflict AND when
    #    Resume-BitLocker no-ops on a provisioned-but-not-started (0% / Protection Off)
    #    volume, which is exactly the state that was stalling. Full-disk first; thin-
    #    provisioned storage (VMs, some SANs) rejects full-disk with 0x803100a5 and only
    #    supports Used Space Only encryption -> retry that way.
    Write-CipherLog -Message "ACTION manage-bde -on $MountPoint (start conversion, full disk) ..."
    try {
        $mbde = Join-Path $env:WINDIR 'System32\manage-bde.exe'
        $out  = & $mbde -on $MountPoint -SkipHardwareTest 2>&1
        $code = $LASTEXITCODE
        Write-CipherLog -Message ("manage-bde -on exit={0}: {1}" -f $code, (($out | Out-String).Trim() -replace '\s*\r?\n\s*', ' | '))
        if ($code -ne 0 -and (($out | Out-String) -match '0x803100a5|Used Space Only')) {
            Write-CipherLog -Message "ACTION manage-bde -on $MountPoint -UsedSpaceOnly (thin-provisioned storage) ..."
            $out2 = & $mbde -on $MountPoint -UsedSpaceOnly -SkipHardwareTest 2>&1
            Write-CipherLog -Message ("manage-bde -on -UsedSpaceOnly exit={0}: {1}" -f $LASTEXITCODE, (($out2 | Out-String).Trim() -replace '\s*\r?\n\s*', ' | '))
        }
    }
    catch { Write-CipherLog -Message "ACTION non-fatal FAILURE: manage-bde -on $MountPoint -> $($_.Exception.Message)" }
    # 3) Resume-BitLocker: resume a suspended/paused conversion (harmless otherwise).
    Write-CipherLog -Message "ACTION Resume-BitLocker $MountPoint (resume if suspended) ..."
    try { Resume-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null; Write-CipherLog -Message "ACTION OK: Resume-BitLocker $MountPoint" }
    catch { Write-CipherLog -Message "ACTION non-fatal FAILURE: Resume-BitLocker $MountPoint -> $($_.Exception.Message)" }
}

function Test-BLHasProtectorType {
    param($KeyProtector, [string]$Type)
    @($KeyProtector | Where-Object { $_.KeyProtectorType -eq $Type }).Count -gt 0
}

function Add-BLTpmProtectorIfMissing {
    param([string]$MountPoint = 'C:')
    $status = Get-BLCipherStatus -MountPoint $MountPoint
    if (-not (Test-BLHasProtectorType -KeyProtector $status.KeyProtector -Type 'Tpm')) {
        Write-CipherLog -Message "ACTION Add TPM protector $MountPoint ..."
        try { Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmProtector -ErrorAction Stop | Out-Null; Write-CipherLog -Message "ACTION OK: Add TPM protector $MountPoint" }
        catch { Write-CipherLog -Message "ACTION non-fatal FAILURE: Add TPM protector $MountPoint -> $($_.Exception.Message)" }
    }
}

function Add-BLRecoveryProtector {
    param([string]$MountPoint = 'C:')
    # Idempotent: only add a recovery-password protector if the volume has none.
    # Adding duplicates would break escrow verification (the marker records one
    # protector, but Test-AllRecoveryProtectorsBackedUp requires ALL current ones
    # to be recorded), which would stall detection.
    $status = Get-BLCipherStatus -MountPoint $MountPoint
    if ((Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector).Count -eq 0) {
        Write-CipherLog -Message "ACTION Add recovery protector $MountPoint ..."
        try { Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop | Out-Null; Write-CipherLog -Message "ACTION OK: Add recovery protector $MountPoint" }
        catch { Write-CipherLog -Message "ACTION non-fatal FAILURE: Add recovery protector $MountPoint -> $($_.Exception.Message)" }
    }
}

function Get-BLRecoveryProtectors {
    param([Parameter(Mandatory)]$KeyProtector)
    @(
        $KeyProtector | Where-Object {
            $_.KeyProtectorType -eq 'RecoveryPassword' -and
            -not [string]::IsNullOrWhiteSpace($_.KeyProtectorId) -and
            -not [string]::IsNullOrWhiteSpace($_.RecoveryPassword)
        }
    )
}

# ---------------------------------------------------------------------------
# AAD escrow marker (mirrors the existing recovery-key-backup scheme)
# ---------------------------------------------------------------------------
function Get-CipherMarkerPath {
    param([string]$MountPoint = 'C:')
    $safe = ($MountPoint -replace '[^a-zA-Z0-9]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Volume' }
    Join-Path (Get-CipherWorkingDir) "$safe.marker.json"
}

function Read-CipherMarker {
    param([string]$MountPoint = 'C:')
    $path = Get-CipherMarkerPath -MountPoint $MountPoint
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
}

function Write-CipherMarker {
    param(
        [Parameter(Mandatory)][object[]]$Protectors,
        [string]$MountPoint = 'C:',
        [string]$NowUtc
    )
    if ([string]::IsNullOrWhiteSpace($NowUtc)) { $NowUtc = (Get-Date).ToUniversalTime().ToString('o') }
    $path = Get-CipherMarkerPath -MountPoint $MountPoint
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
    $records = @(
        foreach ($p in $Protectors) {
            [pscustomobject]@{
                KeyProtectorId       = $p.KeyProtectorId
                RecoveryPasswordHash = Get-RecoveryPasswordHash -RecoveryPassword $p.RecoveryPassword
                BackedUpAtUtc        = $NowUtc
            }
        }
    )
    [pscustomobject]@{ MountPoint=$MountPoint; ProtectorBackups=$records; UpdatedAtUtc=$NowUtc } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
}

function Test-RecoveryProtectorBackedUp {
    param([Parameter(Mandatory)]$Protector, $Marker)
    if ($null -eq $Marker -or $null -eq $Marker.ProtectorBackups) { return $false }
    $hash = Get-RecoveryPasswordHash -RecoveryPassword $Protector.RecoveryPassword
    @(
        $Marker.ProtectorBackups | Where-Object {
            $_.KeyProtectorId -eq $Protector.KeyProtectorId -and $_.RecoveryPasswordHash -eq $hash
        }
    ).Count -gt 0
}

function Test-AllRecoveryProtectorsBackedUp {
    param([Parameter(Mandatory)][object[]]$Protectors, [string]$MountPoint = 'C:')
    $marker = Read-CipherMarker -MountPoint $MountPoint
    foreach ($p in $Protectors) {
        if (-not (Test-RecoveryProtectorBackedUp -Protector $p -Marker $marker)) { return $false }
    }
    $true
}

function Backup-BLRecoveryProtectorToAad {
    param(
        [Parameter(Mandatory)][object[]]$Protectors,
        [string]$MountPoint = 'C:',
        [string]$NowUtc
    )
    $allOk = $true
    foreach ($p in $Protectors) {
        Write-CipherLog -Message "ACTION BackupToAAD-BitLockerKeyProtector $MountPoint $($p.KeyProtectorId) ..."
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $p.KeyProtectorId -ErrorAction Stop
            Write-CipherLog -Message "ACTION OK: BackupToAAD $($p.KeyProtectorId)"
        }
        catch {
            # Non-fatal: escrow can fail if the device isn't Entra-joined yet or AAD is
            # briefly unreachable. Don't write the marker (so detection stays not-done and
            # the worker retries every run); just log why.
            $allOk = $false
            Write-CipherLog -Message "ACTION non-fatal FAILURE: BackupToAAD $($p.KeyProtectorId) -> $($_.Exception.Message)"
        }
    }
    if ($allOk) {
        Write-CipherMarker -Protectors $Protectors -MountPoint $MountPoint -NowUtc $NowUtc
        Write-CipherLog -Message "Escrow recorded (marker written) for $MountPoint"
    }
    else {
        Write-CipherLog -Message "Escrow incomplete for $MountPoint; marker NOT written, will retry next run."
    }
}

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
function Get-CipherStateAgeDays {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$NowUtc)
    ([datetime]$NowUtc - [datetime]$State.FirstSeenUtc).TotalDays
}

function Set-CipherPhase {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Phase,
        [string]$Message,
        [Parameter(Mandatory)][string]$NowUtc,
        [string]$AbortReason
    )
    $State.Phase = $Phase
    if ($PSBoundParameters.ContainsKey('Message'))     { $State.LastMessage = $Message }
    if ($PSBoundParameters.ContainsKey('AbortReason')) { $State.AbortReason = $AbortReason }
    $State.LastUpdatedUtc = $NowUtc
    Write-CipherLog -Message "[$Phase] $($State.LastMessage)"
    $State
}

function Unregister-CipherScheduledTask {
    param([string]$TaskName = 'BitLockerCipherRemediation')
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

function Invoke-CipherRemediationStep {
    param(
        [Parameter(Mandatory)]$State,
        [string]$NowUtc,
        [double]$MinFreeGb  = 10,
        [double]$MaxAgeDays = 7
    )
    if ([string]::IsNullOrWhiteSpace($NowUtc)) { $NowUtc = (Get-Date).ToUniversalTime().ToString('o') }
    $mount  = $State.MountPoint
    $status = Get-BLCipherStatus -MountPoint $mount
    Write-CipherLog -Message ("[{0}] read: Method={1} VolumeStatus={2} {3}% Protection={4}" -f `
        $State.Phase, $status.Method, $status.VolumeStatus, $status.EncryptionPercentage, $status.ProtectionStatus)

    switch ($State.Phase) {
        'Init' {
            $guard = Get-CipherGuardrailStatus -CipherStatus $status -MinFreeGb $MinFreeGb
            if ($guard.Ok)   { return Set-CipherPhase -State $State -Phase 'VerifyPolicy' -Message 'Guardrails passed' -NowUtc $NowUtc }
            if ($guard.Hard) { return Set-CipherPhase -State $State -Phase 'Aborted' -Message $guard.Reason -AbortReason $guard.Reason -NowUtc $NowUtc }
            if ((Get-CipherStateAgeDays -State $State -NowUtc $NowUtc) -ge $MaxAgeDays) {
                return Set-CipherPhase -State $State -Phase 'Aborted' -Message "Gave up after $MaxAgeDays days: $($guard.Reason)" -AbortReason $guard.Reason -NowUtc $NowUtc
            }
            return Set-CipherPhase -State $State -Phase 'Init' -Message "Waiting: $($guard.Reason)" -NowUtc $NowUtc
        }
        'VerifyPolicy' {
            if ((Get-FveOsEncryptionMethod) -eq 7) {
                return Set-CipherPhase -State $State -Phase 'Decrypt' -Message 'Intune policy XtsAes256 confirmed' -NowUtc $NowUtc
            }
            if ((Get-CipherStateAgeDays -State $State -NowUtc $NowUtc) -ge $MaxAgeDays) {
                return Set-CipherPhase -State $State -Phase 'Aborted' -Message "Gave up after $MaxAgeDays days waiting for XtsAes256 policy" -AbortReason 'XtsAes256 policy not delivered' -NowUtc $NowUtc
            }
            return Set-CipherPhase -State $State -Phase 'VerifyPolicy' -Message 'Waiting for XtsAes256 policy to land' -NowUtc $NowUtc
        }
        'Decrypt' {
            if ((Test-BLIsXtsAes256 -Status $status) -and (Test-BLIsFullyEncrypted -Status $status)) {
                return Set-CipherPhase -State $State -Phase 'Encrypt' -Message 'Already XtsAes256; ensuring protectors/escrow' -NowUtc $NowUtc
            }
            if (Test-BLIsFullyDecrypted -Status $status) {
                return Set-CipherPhase -State $State -Phase 'Encrypt' -Message 'Volume fully decrypted' -NowUtc $NowUtc
            }
            if ($status.VolumeStatus -ne 'DecryptionInProgress') {
                # Re-assert the policy gate immediately before the FIRST Disable-BitLocker:
                # the XtsAes256 policy may have been rolled back during the wait since
                # VerifyPolicy. Never decrypt while policy != 7. (Only re-checked BEFORE
                # decryption starts; once DecryptionInProgress we must let it finish —
                # aborting mid-decrypt would leave the drive worse off.)
                if ((Get-FveOsEncryptionMethod) -ne 7) {
                    return Set-CipherPhase -State $State -Phase 'VerifyPolicy' -Message 'XtsAes256 policy no longer present before decrypt; returning to VerifyPolicy' -NowUtc $NowUtc
                }
                Invoke-BLDecrypt -MountPoint $mount
                return Set-CipherPhase -State $State -Phase 'Decrypt' -Message 'Started decryption' -NowUtc $NowUtc
            }
            return Set-CipherPhase -State $State -Phase 'Decrypt' -Message "Decrypting ($($status.EncryptionPercentage)%)" -NowUtc $NowUtc
        }
        'Encrypt' {
            if (Test-BLIsFullyDecrypted -Status $status) {
                # Drive is decrypted (0%) — START the XtsAes256 conversion. Do NOT gate on
                # $status.Method: a policy-managed drive reports Method=XtsAes256 even while
                # fully decrypted, which previously skipped Enable-BitLocker entirely and
                # left the drive "armed but never converting". Invoke-BLEncryptXtsAes256
                # falls back to Resume-BitLocker when the volume is already armed.
                Invoke-BLEncryptXtsAes256 -MountPoint $mount
                Add-BLRecoveryProtector -MountPoint $mount
                return Set-CipherPhase -State $State -Phase 'BackupKey' -Message 'Started XtsAes256 full-disk encryption' -NowUtc $NowUtc
            }
            # Already XtsAes256 / mid-encryption: make sure both protectors exist (do not re-run Enable).
            Add-BLTpmProtectorIfMissing -MountPoint $mount
            if ((Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector).Count -eq 0) {
                Add-BLRecoveryProtector -MountPoint $mount
            }
            return Set-CipherPhase -State $State -Phase 'BackupKey' -Message 'Ensured protectors' -NowUtc $NowUtc
        }
        'BackupKey' {
            $recovery = Get-BLRecoveryProtectors -KeyProtector $status.KeyProtector
            if ($recovery.Count -eq 0) {
                return Set-CipherPhase -State $State -Phase 'Encrypt' -Message 'No recovery protector yet; returning to Encrypt' -NowUtc $NowUtc
            }
            if (Test-BLIsFullyDecrypted -Status $status) {
                # Encryption stalled or reverted (drive is fully decrypted while in BackupKey)
                # — return to Encrypt to (re)start it rather than waiting forever for an
                # encryption that isn't running.
                return Set-CipherPhase -State $State -Phase 'Encrypt' -Message 'Drive is decrypted; restarting encryption' -NowUtc $NowUtc
            }
            if (-not (Test-AllRecoveryProtectorsBackedUp -Protectors $recovery -MountPoint $mount)) {
                Backup-BLRecoveryProtectorToAad -Protectors $recovery -MountPoint $mount -NowUtc $NowUtc
            }
            if ((Test-BLIsXtsAes256 -Status $status) -and (Test-BLIsFullyEncrypted -Status $status) -and (Test-BLIsProtectionOn -Status $status)) {
                Unregister-CipherScheduledTask
                return Set-CipherPhase -State $State -Phase 'Done' -Message 'Device fully XtsAes256 compliant; recovery key escrowed' -NowUtc $NowUtc
            }
            return Set-CipherPhase -State $State -Phase 'BackupKey' -Message "Key escrowed; waiting for full encryption ($($status.EncryptionPercentage)%)" -NowUtc $NowUtc
        }
        'Done'    { return $State }
        'Aborted' { return $State }
        default   { return Set-CipherPhase -State $State -Phase 'Aborted' -Message "Unknown phase '$($State.Phase)'" -AbortReason 'Unknown phase' -NowUtc $NowUtc }
    }
}
