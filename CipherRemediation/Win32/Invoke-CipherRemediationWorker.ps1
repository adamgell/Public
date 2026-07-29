#Requires -Version 5.1
<#
.SYNOPSIS
    Advances the BitLocker XtsAes256 cipher-upgrade state machine by one phase.
.DESCRIPTION
    Runs as SYSTEM from the BitLockerCipherRemediation scheduled task. One phase
    per invocation; the task re-runs on a schedule until the state reaches Done.
#>
$ErrorActionPreference = 'Stop'

# 64-bit relaunch guard.
if ($env:PROCESSOR_ARCHITEW6432 -and -not [Environment]::Is64BitProcess) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        & $sysnative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    }
}

# Load shared helpers (real Common) unless already loaded in this session.
if (-not (Get-Command Get-BLCipherStatus -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'BitLockerCipher.Common.ps1')
}

# Log every invocation (whoami + bitness) so the scheduled-task run is visible in
# remediation.log — if this line never appears, the task isn't running the worker.
try {
    Write-CipherLog -Message ("--- Worker invoked (user={0}, 64bit={1}) ---" -f `
        [Environment]::UserName, [Environment]::Is64BitProcess)
} catch {}

$mutex = New-Object System.Threading.Mutex($false, 'Global\BitLockerCipherRemediation')
$acquired = $false
try {
    # A prior run hard-killed while holding the mutex (e.g. Task Scheduler
    # terminating a long poll) throws AbandonedMutexException on the next
    # WaitOne — but it also grants ownership, so treat it as acquired and
    # recover. Without this, the exception would propagate unhandled and the
    # mutex would be re-abandoned on every run until the next reboot.
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
        Write-CipherLog -Message 'Previous remediation run was abandoned; recovering ownership.'
    }

    if (-not $acquired) {
        Write-CipherLog -Message 'Another remediation run is in progress; exiting (mutex held).'
        Write-Output 'Another remediation run is in progress; exiting.'
        exit 0
    }

    $state = Read-CipherState
    if ($null -eq $state) { $state = New-CipherState -MountPoint 'C:' }

    if ($state.Phase -in @('Done', 'Aborted')) {
        Write-CipherLog -Message "Terminal phase '$($state.Phase)'; nothing to do."
        Write-Output "Terminal phase '$($state.Phase)'; nothing to do."
        exit 0
    }

    # Long-running: the worker stays alive and drives the state machine all the way to
    # Done/Aborted, polling the drive during the decrypt/encrypt waits, instead of doing
    # one hop and exiting to wait for the next 15-min task tick. The scheduled task's job
    # is just to keep ONE worker running (the mutex + the task's IgnoreNew setting enforce
    # single-instance); it relaunches a worker only if the previous one exited before Done
    # (crash, reboot, or the lifetime cap below).
    #
    # Each poll cycle advances every INSTANT transition (each phase runs at most once per
    # cycle via $visited, so it can't spin), then sleeps while genuinely waiting on the
    # drive. Env overrides (CIPHER_WORKER_POLL_SECONDS / CIPHER_WORKER_MAX_CYCLES) exist
    # for testing.
    $pollSeconds = if ($env:CIPHER_WORKER_POLL_SECONDS) { [int]$env:CIPHER_WORKER_POLL_SECONDS } else { 30 }
    $maxCycles   = if ($env:CIPHER_WORKER_MAX_CYCLES)   { [int]$env:CIPHER_WORKER_MAX_CYCLES }   else { 0 }
    $deadline    = (Get-Date).AddHours(24)
    $cycle = 0
    while ($state.Phase -notin @('Done', 'Aborted')) {
        $cycle++
        $visited = @{}
        while ($state.Phase -notin @('Done', 'Aborted') -and -not $visited.ContainsKey($state.Phase)) {
            $visited[$state.Phase] = $true
            $state = Invoke-CipherRemediationStep -State $state
            Write-CipherState -State $state
        }
        if ($state.Phase -in @('Done', 'Aborted')) { break }
        if ($maxCycles -gt 0 -and $cycle -ge $maxCycles) { break }
        if ((Get-Date) -gt $deadline) {
            Write-CipherLog -Message '24h worker lifetime reached; exiting (task relaunches to continue).'
            break
        }
        Start-Sleep -Seconds $pollSeconds
    }
    Write-Output "Phase is now '$($state.Phase)': $($state.LastMessage)"
    exit 0
}
catch {
    # Surface the failure in remediation.log (not just the warning stream) so a
    # scheduled-task run's error is never silent.
    try {
        Write-CipherLog -Message ("WORKER ERROR: {0} | {1}" -f `
            $_.Exception.Message, ($_.ScriptStackTrace -replace '\r?\n', ' / '))
    } catch {}
    Write-Warning "Cipher remediation worker failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
