#Requires -Version 5.1
<#
.SYNOPSIS
    Win32 install: stages the cipher-upgrade worker and registers its scheduled task.
.DESCRIPTION
    Returns 0 immediately. The actual decrypt/encrypt work runs later via the
    BitLockerCipherRemediation scheduled task. The Win32 detection rule
    (Detect-CipherRemediation.ps1) is the source of truth for completion.
#>
$ErrorActionPreference = 'Stop'

if ($env:PROCESSOR_ARCHITEW6432 -and -not [Environment]::Is64BitProcess) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnative) {
        & $sysnative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    }
}

if (-not (Get-Command Get-CipherWorkingDir -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'BitLockerCipher.Common.ps1')
}

$TaskName = 'BitLockerCipherRemediation'

try {
    $workDir = Get-CipherWorkingDir
    $null = New-Item -ItemType Directory -Path $workDir -Force

    foreach ($file in @('Invoke-CipherRemediationWorker.ps1', 'BitLockerCipher.Common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $workDir $file) -Force
    }

    if ($null -eq (Read-CipherState)) {
        Write-CipherState -State (New-CipherState -MountPoint 'C:')
    }

    $workerPath = Join-Path $workDir 'Invoke-CipherRemediationWorker.ps1'
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$workerPath`""
    $atStart = New-ScheduledTaskTrigger -AtStartup
    # -RepetitionDuration is required: without it the 15-min repetition stops firing
    # after its (build-dependent) default window, which is why a stuck device went
    # weeks without the worker running. [TimeSpan]::MaxValue serializes to an
    # out-of-range task-XML duration and Register-ScheduledTask rejects it, so use a
    # large finite duration (10 years) that Task Scheduler accepts and is effectively
    # indefinite for this remediation.
    $repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atStart, $repeat) -Principal $principal -Settings $settings -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    Write-Output "Installed: staged worker and registered scheduled task '$TaskName'."
    exit 0
}
catch {
    Write-Warning "Cipher remediation install failed: $($_.Exception.Message)"
    exit 1
}
