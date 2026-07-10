BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Detect-BitLockerCipher.ps1'

    function Invoke-DetectionScript {
        param([Parameter(Mandatory)][string]$EncryptionMethod)

        $harnessPath = Join-Path $TestDrive "$([guid]::NewGuid()).ps1"
        # scriptblock-create (not dot-source): only this propagates the script's
        # `exit N` as the child pwsh exit code on pwsh 7.x. The 64-bit relaunch
        # guard is inert here (no $env:PROCESSOR_ARCHITEW6432 off Windows).
        $harness = @"
function Get-BitLockerVolume {
    param([string]`$MountPoint)
    [pscustomobject]@{ MountPoint = 'C:'; EncryptionMethod = '$EncryptionMethod' }
}
& ([scriptblock]::Create((Get-Content -LiteralPath '$script:ScriptPath' -Raw)))
"@
        Set-Content -Path $harnessPath -Value $harness -Encoding utf8
        $output = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = @($output | ForEach-Object { $_.ToString() }) -join "`n"
        }
    }
}

Describe 'Detect-BitLockerCipher' {
    It 'passes when the OS drive is XtsAes256' {
        $r = Invoke-DetectionScript -EncryptionMethod 'XtsAes256'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Compliant'
    }

    It 'fails when the OS drive is XtsAes128' {
        $r = Invoke-DetectionScript -EncryptionMethod 'XtsAes128'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'XtsAes128'
    }

    It 'fails when the OS drive is Aes128' {
        (Invoke-DetectionScript -EncryptionMethod 'Aes128').ExitCode | Should -Be 1
    }

    It 'fails when the OS drive is Aes256 (CBC, not XTS)' {
        (Invoke-DetectionScript -EncryptionMethod 'Aes256').ExitCode | Should -Be 1
    }

    It 'passes (out of scope) when the OS drive is not encrypted' {
        $r = Invoke-DetectionScript -EncryptionMethod 'None'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'not encrypted'
    }
}
