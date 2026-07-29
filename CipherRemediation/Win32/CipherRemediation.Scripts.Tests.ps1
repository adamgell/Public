BeforeAll {
    $script:Dir = Split-Path -Parent $PSCommandPath

    # Runs an entry script in a child pwsh with the given mock/setup preamble.
    #
    # HARNESS CONTRACT (verified on pwsh 7.6.1 / macOS — do not "simplify"):
    #   * exit codes ONLY propagate through & ([scriptblock]::Create(...)); a
    #     dot-source or &-on-path swallows `exit N` and the child returns 0.
    #   * $PSScriptRoot/$PSCommandPath are empty inside a created scriptblock, so
    #     they are PREPENDED into the scriptblock text (setting them in this
    #     scope does NOT reach the scriptblock). This lets the entry script
    #     dot-source real Common from $script:Dir.
    #   * Preamble shadows the OS-level cmdlets (Get-BitLockerVolume, Get-Tpm,
    #     Get-CimInstance, Get-Volume, *-ScheduledTask*, BackupToAAD-*, etc.) —
    #     NOT the Common wrapper functions — so dot-sourcing Common does not
    #     clobber them (Common's wrappers CALL these OS cmdlets).
    #   * Any DECLARED switch parameter in a shadow must be [switch] (a value
    #     param passed switch-style, e.g. -AtStartup, errors). Plain shadows
    #     already tolerate -ErrorAction / -Confirm / -WhatIf and undeclared args.
    function Invoke-EntryScript {
        param(
            [Parameter(Mandatory)][string]$ScriptName,
            [string]$Preamble = '',
            [hashtable]$EnvVars = @{}
        )
        $harnessPath = Join-Path $TestDrive "$([guid]::NewGuid()).ps1"
        $envLines = ($EnvVars.GetEnumerator() | ForEach-Object { "`$env:$($_.Key) = '$($_.Value)'" }) -join "`n"
        $target = Join-Path $script:Dir $ScriptName
        $harness = @"
$envLines
$Preamble
`$__prefix = '`$PSScriptRoot = ' + [char]39 + '$script:Dir' + [char]39 + '; `$PSCommandPath = ' + [char]39 + '$target' + [char]39 + '; '
`$__body = Get-Content -LiteralPath '$target' -Raw
& ([scriptblock]::Create(`$__prefix + `$__body))
"@
        Set-Content -Path $harnessPath -Value $harness -Encoding utf8
        $output = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { $_.ToString() }) -join "`n" }
    }
}

Describe 'Invoke-CipherRemediationWorker' {
    It 'creates state on first run and advances one phase' {
        $work = Join-Path $TestDrive 'work-worker'
        # Shadow OS cmdlets so real Common loads and its Init guardrails pass.
        $preamble = @'
function Get-BitLockerVolume { param($MountPoint) [pscustomobject]@{ EncryptionMethod="XtsAes128"; VolumeStatus="FullyEncrypted"; ProtectionStatus="On"; EncryptionPercentage=100; KeyProtector=@() } }
function Get-Tpm { [pscustomobject]@{ TpmPresent=$true; TpmReady=$true } }
function Get-CimInstance { param($Namespace,$ClassName) [pscustomobject]@{ PowerOnline=$true; IsEnabled_InitialValue=$true; IsActivated_InitialValue=$true } }
function Get-Volume { param($DriveLetter) [pscustomobject]@{ SizeRemaining=500GB } }
'@
        # CIPHER_WORKER_MAX_CYCLES=1: the worker is long-running (polls until Done/Aborted);
        # cap it to a single poll cycle so the test doesn't loop/sleep.
        $r = Invoke-EntryScript -ScriptName 'Invoke-CipherRemediationWorker.ps1' -Preamble $preamble -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work; CIPHER_WORKER_MAX_CYCLES = '1' }
        $r.ExitCode | Should -Be 0
        $state = Get-Content -LiteralPath (Join-Path $work 'state.json') -Raw | ConvertFrom-Json
        $state.Phase | Should -Be 'VerifyPolicy'
    }
}

Describe 'Install-CipherRemediation' {
    # $taskMocks in BeforeAll (run phase); a Describe-body variable is $null in It
    # blocks under Pester 5. Declared switch params MUST be [switch] (a value param
    # passed switch-style like -AtStartup errors). These shadow the OS
    # scheduled-task cmdlets. (The here-string body + closing '@ stay at column 0.)
    BeforeAll {
        $taskMocks = @'
function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{ Execute=$Execute; Argument=$Argument } }
function New-ScheduledTaskTrigger { param([switch]$AtStartup,[switch]$Once,$At,$RepetitionInterval,$RepetitionDuration) [pscustomobject]@{} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) [pscustomobject]@{} }
function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,$MultipleInstances) [pscustomobject]@{} }
function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) Add-Content -Path $env:REGISTER_LOG -Value $TaskName }
function Start-ScheduledTask { param($TaskName) }
'@
    }

    It 'stages files, creates Init state, and registers the task once' {
        $work = Join-Path $TestDrive 'work-install'
        $registerLog = Join-Path $TestDrive 'register.log'
        $r = Invoke-EntryScript -ScriptName 'Install-CipherRemediation.ps1' -Preamble $taskMocks -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work; REGISTER_LOG = $registerLog }
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $work 'Invoke-CipherRemediationWorker.ps1') | Should -BeTrue
        Test-Path (Join-Path $work 'BitLockerCipher.Common.ps1') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $work 'state.json') -Raw | ConvertFrom-Json).Phase | Should -Be 'Init'
        (Get-Content -LiteralPath $registerLog) | Should -Be 'BitLockerCipherRemediation'
    }

    It 'does not reset existing progress on re-install' {
        $work = Join-Path $TestDrive 'work-reinstall'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        '{"Phase":"Decrypt","MountPoint":"C:","AttemptCount":0,"FirstSeenUtc":"2026-07-10T00:00:00.0000000Z","LastUpdatedUtc":"2026-07-10T00:00:00.0000000Z","LastMessage":"x","AbortReason":null}' |
            Set-Content -LiteralPath (Join-Path $work 'state.json') -Encoding utf8
        $r = Invoke-EntryScript -ScriptName 'Install-CipherRemediation.ps1' -Preamble $taskMocks -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work; REGISTER_LOG = (Join-Path $TestDrive 'r2.log') }
        (Get-Content -LiteralPath (Join-Path $work 'state.json') -Raw | ConvertFrom-Json).Phase | Should -Be 'Decrypt'
    }
}

Describe 'Detect-CipherRemediation (Win32 detection rule)' {
    It 'detects installed when fully XtsAes256, encrypted, protected, and escrowed' {
        $work = Join-Path $TestDrive 'work-detect-ok'
        $preamble = @'
function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint="C:"; Method="XtsAes256"; VolumeStatus="FullyEncrypted"; ProtectionStatus="On"; EncryptionPercentage=100; KeyProtector=@([pscustomobject]@{ KeyProtectorType="RecoveryPassword"; KeyProtectorId="{AAA}"; RecoveryPassword="p" }) } }
function Get-BLRecoveryProtectors { param($KeyProtector) @($KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }) }
function Test-AllRecoveryProtectorsBackedUp { param($Protectors,$MountPoint) $true }
'@
        $r = Invoke-EntryScript -ScriptName 'Detect-CipherRemediation.ps1' -Preamble $preamble -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'XtsAes256'
    }

    It 'is not detected while still encrypting' {
        $work = Join-Path $TestDrive 'work-detect-progress'
        $preamble = @'
function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint="C:"; Method="XtsAes256"; VolumeStatus="EncryptionInProgress"; ProtectionStatus="On"; EncryptionPercentage=40; KeyProtector=@([pscustomobject]@{ KeyProtectorType="RecoveryPassword"; KeyProtectorId="{AAA}"; RecoveryPassword="p" }) } }
function Get-BLRecoveryProtectors { param($KeyProtector) @($KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }) }
function Test-AllRecoveryProtectorsBackedUp { param($Protectors,$MountPoint) $true }
'@
        (Invoke-EntryScript -ScriptName 'Detect-CipherRemediation.ps1' -Preamble $preamble -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work }).ExitCode | Should -Be 1
    }

    It 'is not detected when the key is not yet escrowed' {
        $work = Join-Path $TestDrive 'work-detect-noescrow'
        $preamble = @'
function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint="C:"; Method="XtsAes256"; VolumeStatus="FullyEncrypted"; ProtectionStatus="On"; EncryptionPercentage=100; KeyProtector=@([pscustomobject]@{ KeyProtectorType="RecoveryPassword"; KeyProtectorId="{AAA}"; RecoveryPassword="p" }) } }
function Get-BLRecoveryProtectors { param($KeyProtector) @($KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }) }
function Test-AllRecoveryProtectorsBackedUp { param($Protectors,$MountPoint) $false }
'@
        (Invoke-EntryScript -ScriptName 'Detect-CipherRemediation.ps1' -Preamble $preamble -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work }).ExitCode | Should -Be 1
    }

    It 'reports not-detected (exit 1) when Common is not staged in ProgramData (app not installed)' {
        # No preamble -> the Get-BLCipherStatus guard trips -> the script looks for the
        # installer-staged Common under %ProgramData%. Point ProgramData at an empty dir
        # so it is absent, and assert a graceful exit 1 (not an unhandled crash).
        $emptyProgramData = Join-Path $TestDrive 'empty-programdata'
        New-Item -ItemType Directory -Path $emptyProgramData -Force | Out-Null
        $r = Invoke-EntryScript -ScriptName 'Detect-CipherRemediation.ps1' -EnvVars @{ ProgramData = $emptyProgramData }
        $r.ExitCode | Should -Be 1
    }
}

Describe 'Uninstall-CipherRemediation' {
    It 'unregisters the task and removes the working directory' {
        $work = Join-Path $TestDrive 'work-uninstall'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'state.json') -Value '{}' -Encoding utf8
        $unregLog = Join-Path $TestDrive 'unreg.log'
        $preamble = "function Unregister-ScheduledTask { param(`$TaskName,`$Confirm,`$ErrorAction) Add-Content -Path `$env:UNREG_LOG -Value `$TaskName }"
        $r = Invoke-EntryScript -ScriptName 'Uninstall-CipherRemediation.ps1' -Preamble $preamble -EnvVars @{ CIPHER_WORKDIR_OVERRIDE = $work; UNREG_LOG = $unregLog }
        $r.ExitCode | Should -Be 0
        Test-Path $work | Should -BeFalse
        (Get-Content -LiteralPath $unregLog) | Should -Be 'BitLockerCipherRemediation'
    }
}
