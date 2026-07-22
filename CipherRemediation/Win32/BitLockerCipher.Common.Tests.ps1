BeforeAll {
    . (Join-Path (Split-Path -Parent $PSCommandPath) 'BitLockerCipher.Common.ps1')
}

Describe 'Get-CipherComplianceState' {
    It 'treats XtsAes256 as Compliant' { Get-CipherComplianceState 'XtsAes256' | Should -Be 'Compliant' }
    It 'treats None as OutOfScope'     { Get-CipherComplianceState 'None'      | Should -Be 'OutOfScope' }
    It 'treats empty as OutOfScope'    { Get-CipherComplianceState ''          | Should -Be 'OutOfScope' }
    It 'treats XtsAes128 as NonCompliant' { Get-CipherComplianceState 'XtsAes128' | Should -Be 'NonCompliant' }
    It 'treats Aes256 (CBC) as NonCompliant' { Get-CipherComplianceState 'Aes256' | Should -Be 'NonCompliant' }
}

Describe 'Get-RecoveryPasswordHash' {
    It 'is deterministic and never returns the input' {
        $pw = '111111-222222-333333-444444-555555-666666-777777-888888'
        $h1 = Get-RecoveryPasswordHash $pw
        $h2 = Get-RecoveryPasswordHash $pw
        $h1 | Should -Be $h2
        $h1 | Should -Not -Be $pw
        $h1.Length | Should -Be 64
    }
}

Describe 'Cipher state persistence' {
    BeforeEach {
        $env:CIPHER_WORKDIR_OVERRIDE = Join-Path $TestDrive ([guid]::NewGuid())
    }
    AfterEach { Remove-Item Env:CIPHER_WORKDIR_OVERRIDE -ErrorAction SilentlyContinue }

    It 'uses the override working directory' {
        Get-CipherWorkingDir | Should -Be $env:CIPHER_WORKDIR_OVERRIDE
    }

    It 'returns $null when no state file exists' {
        Read-CipherState | Should -BeNullOrEmpty
    }

    It 'round-trips a new state through write and read' {
        $s = New-CipherState -MountPoint 'C:' -NowUtc '2026-07-10T00:00:00.0000000Z'
        $s.Phase | Should -Be 'Init'
        Write-CipherState -State $s
        $loaded = Read-CipherState
        $loaded.Phase | Should -Be 'Init'
        # On pwsh 7 ConvertFrom-Json auto-types the ISO date to [DateTime]; on the
        # 5.1 target it stays a string. Normalize both to the canonical UTC 'o'
        # string so this round-trip assertion holds on either runtime.
        ([datetime]$loaded.FirstSeenUtc).ToUniversalTime().ToString('o') | Should -Be '2026-07-10T00:00:00.0000000Z'
    }

    It 'writes a log line to the working directory' {
        Write-CipherLog -Message 'hello'
        $log = Join-Path $env:CIPHER_WORKDIR_OVERRIDE 'remediation.log'
        (Get-Content -LiteralPath $log -Raw) | Should -Match 'hello'
    }
}

Describe 'Environment wrappers' {
    It 'normalizes Get-BitLockerVolume into a status object' {
        function Get-BitLockerVolume { param($MountPoint)
            [pscustomobject]@{ EncryptionMethod='XtsAes256'; VolumeStatus='FullyEncrypted'
                ProtectionStatus='On'; EncryptionPercentage=100; KeyProtector=@() } }
        $s = Get-BLCipherStatus -MountPoint 'C:'
        $s.Method | Should -Be 'XtsAes256'
        $s.VolumeStatus | Should -Be 'FullyEncrypted'
        $s.EncryptionPercentage | Should -Be 100
    }

    It 'reads the FVE OS encryption method from the registry wrapper' {
        function Get-ItemProperty { param($Path,$Name,$ErrorAction)
            [pscustomobject]@{ EncryptionMethodWithXtsOs = 7 } }
        Get-FveOsEncryptionMethod | Should -Be 7
    }

    It 'returns $null when the FVE policy value is missing' {
        function Get-ItemProperty { param($Path,$Name,$ErrorAction) throw 'missing' }
        Get-FveOsEncryptionMethod | Should -BeNullOrEmpty
    }

    It 'treats a missing battery class as AC power' {
        function Get-CimInstance { param($Namespace,$ClassName,$ErrorAction) throw 'no battery' }
        Test-BLOnAcPower | Should -BeTrue
    }

    It 'reports on-battery when PowerOnline is false' {
        function Get-CimInstance { param($Namespace,$ClassName,$ErrorAction)
            [pscustomobject]@{ PowerOnline = $false } }
        Test-BLOnAcPower | Should -BeFalse
    }

    It 'reports TPM ready only when present and ready' {
        function Get-Tpm { [pscustomobject]@{ TpmPresent=$true; TpmReady=$true } }
        Test-BLTpmReady | Should -BeTrue
        function Get-Tpm { [pscustomobject]@{ TpmPresent=$true; TpmReady=$false } }
        Test-BLTpmReady | Should -BeFalse
    }

    It 'reports TPM not ready when Get-Tpm throws' {
        function Get-Tpm { throw 'no tpm' }
        Test-BLTpmReady | Should -BeFalse
    }

    It 'reports AC power when PowerOnline is true' {
        function Get-CimInstance { param($Namespace,$ClassName) [pscustomobject]@{ PowerOnline = $true } }
        Test-BLOnAcPower | Should -BeTrue
    }

    It 'treats a null battery result (no throw) as AC power' {
        function Get-CimInstance { param($Namespace,$ClassName) $null }
        Test-BLOnAcPower | Should -BeTrue
    }

    It 'converts remaining volume space to whole GB' {
        function Get-Volume { param($DriveLetter) [pscustomobject]@{ SizeRemaining = 53687091200 } }  # 50 GB
        Get-BLFreeSpaceGb -MountPoint 'C:' | Should -Be 50
    }
}

Describe 'Get-CipherGuardrailStatus' {
    BeforeEach {
        function Test-BLTpmReady { $true }
        function Test-BLOnAcPower { $true }
        function Get-BLFreeSpaceGb { param($MountPoint) 100 }
        # Define the fixture in BeforeEach (run phase), NOT the Describe body
        # (discovery phase) — Pester 5 does not carry discovery-phase variables
        # into It blocks, so a Describe-body $ok is $null when the It runs.
        $ok = [pscustomobject]@{ MountPoint='C:'; Method='XtsAes128' }
    }

    It 'passes when TPM ready, on AC, ample space' {
        (Get-CipherGuardrailStatus -CipherStatus $ok).Ok | Should -BeTrue
    }
    It 'hard-fails on a hardware self-encrypting drive' {
        $r = Get-CipherGuardrailStatus -CipherStatus ([pscustomobject]@{ MountPoint='C:'; Method='Hardware' })
        $r.Ok | Should -BeFalse; $r.Hard | Should -BeTrue
    }
    It 'hard-fails when TPM is not ready' {
        function Test-BLTpmReady { $false }
        $r = Get-CipherGuardrailStatus -CipherStatus $ok
        $r.Ok | Should -BeFalse; $r.Hard | Should -BeTrue
    }
    It 'soft-fails (transient) when on battery' {
        function Test-BLOnAcPower { $false }
        $r = Get-CipherGuardrailStatus -CipherStatus $ok
        $r.Ok | Should -BeFalse; $r.Hard | Should -BeFalse
        $r.Reason | Should -Match 'battery'
    }
    It 'soft-fails (transient) when free space is below the threshold' {
        function Get-BLFreeSpaceGb { param($MountPoint) 2 }
        $r = Get-CipherGuardrailStatus -CipherStatus $ok -MinFreeGb 10
        $r.Ok | Should -BeFalse; $r.Hard | Should -BeFalse
    }
}

Describe 'BitLocker action wrappers and AAD backup' {
    BeforeEach {
        $env:CIPHER_WORKDIR_OVERRIDE = Join-Path $TestDrive ([guid]::NewGuid())
        # Fixture in BeforeEach (run phase); a Describe-body variable is $null in
        # It blocks under Pester 5 (discovery vs run phase).
        $protectors = @(
            [pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'
                RecoveryPassword='111111-222222-333333-444444-555555-666666-777777-888888' }
        )
    }
    AfterEach  { Remove-Item Env:CIPHER_WORKDIR_OVERRIDE -ErrorAction SilentlyContinue }

    It 'invokes Disable-BitLocker on decrypt' {
        function Disable-BitLocker { param($MountPoint,$ErrorAction) $script:decrypted=$MountPoint }
        Invoke-BLDecrypt -MountPoint 'C:'
        $script:decrypted | Should -Be 'C:'
    }

    It 'invokes Enable-BitLocker with XtsAes256 and a TPM protector' {
        $script:enableArgs = $null; $script:enableTpm = $false
        function Enable-BitLocker { param($MountPoint,$EncryptionMethod,[switch]$SkipHardwareTest,[switch]$TpmProtector,$ErrorAction)
            $script:enableArgs = $EncryptionMethod; $script:enableTpm = [bool]$TpmProtector }
        Invoke-BLEncryptXtsAes256 -MountPoint 'C:'
        $script:enableArgs | Should -Be 'XtsAes256'
        $script:enableTpm | Should -BeTrue
    }

    It 'detects recovery protectors and filters out non-recovery ones' {
        $mixed = @(
            [pscustomobject]@{ KeyProtectorType='Tpm'; KeyProtectorId='{T}'; RecoveryPassword=$null }
        ) + $protectors
        (Get-BLRecoveryProtectors -KeyProtector $mixed).Count | Should -Be 1
    }

    It 'backs up to AAD and records a hashed marker (never plaintext)' {
        $script:aadCalls = @()
        function BackupToAAD-BitLockerKeyProtector { param($MountPoint,$KeyProtectorId,$ErrorAction)
            $script:aadCalls += "$MountPoint|$KeyProtectorId" }
        Backup-BLRecoveryProtectorToAad -Protectors $protectors -MountPoint 'C:' -NowUtc '2026-07-10T00:00:00.0000000Z'
        $script:aadCalls | Should -Be @('C:|{AAA}')
        Test-AllRecoveryProtectorsBackedUp -Protectors $protectors -MountPoint 'C:' | Should -BeTrue
        $markerRaw = Get-Content -LiteralPath (Get-CipherMarkerPath -MountPoint 'C:') -Raw
        $markerRaw | Should -Not -Match '111111-222222'
    }
}

Describe 'Step engine: Init and VerifyPolicy' {
    BeforeEach {
        $env:CIPHER_WORKDIR_OVERRIDE = Join-Path $TestDrive ([guid]::NewGuid())
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes128'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; EncryptionPercentage=100; KeyProtector=@() } }
        function Test-BLTpmReady { $true }; function Test-BLOnAcPower { $true }
        function Get-BLFreeSpaceGb { param($MountPoint) 100 }
        function Get-FveOsEncryptionMethod { 7 }
        # $now in BeforeEach (run phase); a Describe-body var is $null in It under Pester 5.
        $now = '2026-07-10T00:00:00.0000000Z'
    }
    AfterEach { Remove-Item Env:CIPHER_WORKDIR_OVERRIDE -ErrorAction SilentlyContinue }

    It 'Init -> VerifyPolicy when guardrails pass' {
        $s = New-CipherState -NowUtc $now
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'VerifyPolicy'
    }
    It 'Init stays Init (transient) when on battery, below max age' {
        function Test-BLOnAcPower { $false }
        $s = New-CipherState -NowUtc $now
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'Init'
    }
    It 'Init -> Aborted (hard) when no TPM' {
        function Test-BLTpmReady { $false }
        $s = New-CipherState -NowUtc $now
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $r.Phase | Should -Be 'Aborted'; $r.AbortReason | Should -Match 'TPM'
    }
    It 'Init -> Aborted when transient condition persists past max age' {
        function Test-BLOnAcPower { $false }
        $s = New-CipherState -NowUtc $now
        $later = '2026-07-30T00:00:00.0000000Z'
        (Invoke-CipherRemediationStep -State $s -NowUtc $later -MaxAgeDays 7).Phase | Should -Be 'Aborted'
    }
    It 'VerifyPolicy -> Decrypt when policy is 7 (XtsAes256)' {
        $s = New-CipherState -NowUtc $now; $s.Phase = 'VerifyPolicy'
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'Decrypt'
    }
    It 'VerifyPolicy waits (transient) when policy is missing' {
        function Get-FveOsEncryptionMethod { $null }
        $s = New-CipherState -NowUtc $now; $s.Phase = 'VerifyPolicy'
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'VerifyPolicy'
    }
    It 'VerifyPolicy waits when policy is a weaker cipher (6 = XtsAes128)' {
        function Get-FveOsEncryptionMethod { 6 }
        $s = New-CipherState -NowUtc $now; $s.Phase = 'VerifyPolicy'
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'VerifyPolicy'
    }
}

Describe 'Step engine: Decrypt and Encrypt' {
    BeforeEach {
        $env:CIPHER_WORKDIR_OVERRIDE = Join-Path $TestDrive ([guid]::NewGuid())
        $script:decryptCalled = 0; $script:encryptCalled = 0; $script:tpmCalled = 0; $script:recoveryCalled = 0
        function Invoke-BLDecrypt { param($MountPoint) $script:decryptCalled++ }
        function Invoke-BLEncryptXtsAes256 { param($MountPoint) $script:encryptCalled++ }
        function Add-BLTpmProtectorIfMissing { param($MountPoint) $script:tpmCalled++ }
        function Add-BLRecoveryProtector { param($MountPoint) $script:recoveryCalled++ }
        # Decrypt re-asserts the policy gate before the first Disable; default it to 7
        # (XtsAes256 present) so the happy-path Decrypt tests still start decryption.
        function Get-FveOsEncryptionMethod { 7 }
        # $now + helper in BeforeEach (run phase); Describe-body definitions are $null/undefined in It under Pester 5.
        $now = '2026-07-10T00:00:00.0000000Z'
        function New-Decrypting { param($s) $s.Phase='Decrypt'; $s }
    }
    AfterEach { Remove-Item Env:CIPHER_WORKDIR_OVERRIDE -ErrorAction SilentlyContinue }

    It 'Decrypt starts decryption when the drive is still encrypted' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes128'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; EncryptionPercentage=100; KeyProtector=@() } }
        $s = New-Decrypting (New-CipherState -NowUtc $now)
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:decryptCalled | Should -Be 1
        $r.Phase | Should -Be 'Decrypt'
    }
    It 'Decrypt returns to VerifyPolicy WITHOUT decrypting when policy is no longer XtsAes256' {
        function Get-FveOsEncryptionMethod { $null }   # policy rolled back during the wait
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes128'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; EncryptionPercentage=100; KeyProtector=@() } }
        $s = New-Decrypting (New-CipherState -NowUtc $now)
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:decryptCalled | Should -Be 0
        $r.Phase | Should -Be 'VerifyPolicy'
    }
    It 'Decrypt -> Encrypt once fully decrypted, without calling Disable again' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='None'
            VolumeStatus='FullyDecrypted'; ProtectionStatus='Off'; EncryptionPercentage=0; KeyProtector=@() } }
        $s = New-Decrypting (New-CipherState -NowUtc $now)
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:decryptCalled | Should -Be 0
        $r.Phase | Should -Be 'Encrypt'
    }
    It 'Decrypt short-circuits to Encrypt when already XtsAes256' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; EncryptionPercentage=100; KeyProtector=@() } }
        $s = New-Decrypting (New-CipherState -NowUtc $now)
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'Encrypt'
        $script:decryptCalled | Should -Be 0
    }
    It 'Encrypt (fresh) starts XtsAes256 encryption and adds a recovery protector, then -> BackupKey' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='None'
            VolumeStatus='FullyDecrypted'; ProtectionStatus='Off'; EncryptionPercentage=0; KeyProtector=@() } }
        $s = New-CipherState -NowUtc $now; $s.Phase='Encrypt'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:encryptCalled | Should -Be 1        # Enable-BitLocker -TpmProtector makes the TPM protector...
        $script:tpmCalled | Should -Be 0            # ...so Add-BLTpmProtectorIfMissing is NOT called on the fresh path
        $script:recoveryCalled | Should -Be 1
        $r.Phase | Should -Be 'BackupKey'
    }

    It 'Encrypt starts encryption when the drive is decrypted but reports Method=XtsAes256 (policy-armed, 0%)' {
        # Regression (device DESKTOP-UR90I8C): a policy-managed drive reports
        # EncryptionMethod=XtsAes256 even while FullyDecrypted at 0%. The old fresh-path
        # guard `Method -ne 'XtsAes256'` was false here, so Enable-BitLocker was never
        # called and encryption never started. Must key off encryption state, not Method.
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='FullyDecrypted'; ProtectionStatus='Off'; EncryptionPercentage=0
            KeyProtector=@([pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'; RecoveryPassword='p' }) } }
        $s = New-CipherState -NowUtc $now; $s.Phase='Encrypt'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:encryptCalled | Should -Be 1      # encryption MUST be started
        $r.Phase | Should -Be 'BackupKey'
    }

    It 'Encrypt (resuming, protectors missing) ensures TPM + recovery without re-running Enable' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='EncryptionInProgress'; ProtectionStatus='On'; EncryptionPercentage=30; KeyProtector=@() } }
        $s = New-CipherState -NowUtc $now; $s.Phase='Encrypt'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:encryptCalled | Should -Be 0
        $script:tpmCalled | Should -Be 1
        $script:recoveryCalled | Should -Be 1
        $r.Phase | Should -Be 'BackupKey'
    }
}

Describe 'Step engine: BackupKey and Done' {
    BeforeEach {
        $env:CIPHER_WORKDIR_OVERRIDE = Join-Path $TestDrive ([guid]::NewGuid())
        $script:aadCalled = 0; $script:unregistered = 0
        function Backup-BLRecoveryProtectorToAad { param($Protectors,$MountPoint,$NowUtc) $script:aadCalled++ }
        function Test-AllRecoveryProtectorsBackedUp { param($Protectors,$MountPoint) $script:aadCalled -gt 0 }
        function Unregister-CipherScheduledTask { param($TaskName) $script:unregistered++ }
        # $now in BeforeEach (run phase); a Describe-body var is $null in It under Pester 5.
        $now = '2026-07-10T00:00:00.0000000Z'
    }
    AfterEach { Remove-Item Env:CIPHER_WORKDIR_OVERRIDE -ErrorAction SilentlyContinue }

    It 'escrows the key but stays in BackupKey while encryption is still running' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='EncryptionInProgress'; ProtectionStatus='On'; EncryptionPercentage=42
            KeyProtector=@([pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'; RecoveryPassword='111111-222222-333333-444444-555555-666666-777777-888888' }) } }
        $s = New-CipherState -NowUtc $now; $s.Phase='BackupKey'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $script:aadCalled | Should -Be 1
        $r.Phase | Should -Be 'BackupKey'
        $script:unregistered | Should -Be 0
    }

    It 'reaches Done and unregisters the task when fully encrypted, protected, and escrowed' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; EncryptionPercentage=100
            KeyProtector=@([pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'; RecoveryPassword='111111-222222-333333-444444-555555-666666-777777-888888' }) } }
        $s = New-CipherState -NowUtc $now; $s.Phase='BackupKey'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $r.Phase | Should -Be 'Done'
        $script:unregistered | Should -Be 1
    }

    It 'reaches Done at 100% even when the status enums stringify to integers' {
        # Regression: Get-BitLockerVolume enums can surface as integer strings on some
        # OS/module builds ("1" not "FullyEncrypted", "1" not "On", "7" not "XtsAes256").
        # The completion gate is percentage-based + representation-robust, so it still
        # recognizes a fully-encrypted, protected 256-bit drive as Done.
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='7'
            VolumeStatus='1'; ProtectionStatus='1'; EncryptionPercentage=100
            KeyProtector=@([pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'; RecoveryPassword='111111-222222-333333-444444-555555-666666-777777-888888' }) } }
        $s = New-CipherState -NowUtc $now; $s.Phase='BackupKey'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $r.Phase | Should -Be 'Done'
        $script:unregistered | Should -Be 1
    }

    It 'falls back to Encrypt when no recovery protector exists yet' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='EncryptionInProgress'; ProtectionStatus='On'; EncryptionPercentage=10; KeyProtector=@() } }
        $s = New-CipherState -NowUtc $now; $s.Phase='BackupKey'
        (Invoke-CipherRemediationStep -State $s -NowUtc $now).Phase | Should -Be 'Encrypt'
    }

    # Mutation-proof the safety-critical completion gate: it must require all three of
    # Method / VolumeStatus / ProtectionStatus, not just VolumeStatus.
    It 'stays in BackupKey when Method is not XtsAes256 (even if FullyEncrypted + On)' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes128'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; EncryptionPercentage=100
            KeyProtector=@([pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'; RecoveryPassword='p' }) } }
        $s = New-CipherState -NowUtc $now; $s.Phase='BackupKey'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $r.Phase | Should -Be 'BackupKey'
        $script:unregistered | Should -Be 0
    }

    It 'stays in BackupKey when ProtectionStatus is Off (even if XtsAes256 + FullyEncrypted)' {
        function Get-BLCipherStatus { param($MountPoint) [pscustomobject]@{ MountPoint='C:'; Method='XtsAes256'
            VolumeStatus='FullyEncrypted'; ProtectionStatus='Off'; EncryptionPercentage=100
            KeyProtector=@([pscustomobject]@{ KeyProtectorType='RecoveryPassword'; KeyProtectorId='{AAA}'; RecoveryPassword='p' }) } }
        $s = New-CipherState -NowUtc $now; $s.Phase='BackupKey'
        $r = Invoke-CipherRemediationStep -State $s -NowUtc $now
        $r.Phase | Should -Be 'BackupKey'
        $script:unregistered | Should -Be 0
    }
}
