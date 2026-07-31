BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Requirements-CipherRemediation.ps1'

    function Invoke-RequirementScript {
        param(
            [Parameter(Mandatory)][string]$EncryptionMethod,
            [int]$EncryptionPercentage = 100,
            [object]$EncryptionFlags = $null
        )

        $harnessPath = Join-Path $TestDrive "$([guid]::NewGuid()).ps1"
        $flagsLiteral = if ($null -eq $EncryptionFlags) { '$null' } else { [string][int]$EncryptionFlags }
        # scriptblock-create (not dot-source): only this propagates the script's
        # `exit N` as the child pwsh exit code on pwsh 7.x. The 64-bit relaunch
        # guard is inert here (no $env:PROCESSOR_ARCHITEW6432 off Windows).
        $harness = @"
function Get-BitLockerVolume {
    param([string]`$MountPoint)
    [pscustomobject]@{
        MountPoint           = 'C:'
        EncryptionMethod     = '$EncryptionMethod'
        EncryptionPercentage = $EncryptionPercentage
    }
}
function Get-CimInstance {
    param([string]`$Namespace, [string]`$ClassName, [string]`$Filter)
    [pscustomobject]@{ DriveLetter = 'C:' }
}
function Invoke-CimMethod {
    param(`$InputObject, [string]`$MethodName, [hashtable]`$Arguments)
    [pscustomobject]@{
        EncryptionMethod     = '$EncryptionMethod'
        EncryptionPercentage = $EncryptionPercentage
        ConversionStatus     = 1
        EncryptionFlags      = $flagsLiteral
    }
}
& ([scriptblock]::Create((Get-Content -LiteralPath '$script:ScriptPath' -Raw)))
"@
        Set-Content -Path $harnessPath -Value $harness -Encoding utf8
        $output = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Lines    = @($output | ForEach-Object { $_.ToString() })
        }
    }
}

Describe 'Requirements-CipherRemediation' {
    It 'is applicable for XtsAes128' {
        $r = Invoke-RequirementScript -EncryptionMethod 'XtsAes128'
        $r.ExitCode | Should -Be 0
        $r.Lines | Should -Be @('Applicable')
    }

    It 'is applicable for Aes128' {
        (Invoke-RequirementScript -EncryptionMethod 'Aes128').Lines | Should -Be @('Applicable')
    }

    It 'is applicable for Aes256 (CBC, not XTS)' {
        (Invoke-RequirementScript -EncryptionMethod 'Aes256').Lines | Should -Be @('Applicable')
    }

    It 'is applicable for a numeric legacy method (6 = XtsAes128)' {
        (Invoke-RequirementScript -EncryptionMethod '6').Lines | Should -Be @('Applicable')
    }

    It 'is applicable for XtsAes256 with Used-Space-Only conversion (EncryptionFlags 1)' {
        $r = Invoke-RequirementScript -EncryptionMethod 'XtsAes256' -EncryptionFlags 1
        $r.ExitCode | Should -Be 0
        $r.Lines | Should -Be @('Applicable')
    }

    It 'is NOT applicable for full-disk XtsAes256 (EncryptionFlags 0)' {
        (Invoke-RequirementScript -EncryptionMethod 'XtsAes256' -EncryptionFlags 0).Lines | Should -Be @('NotApplicable')
    }

    It 'is NOT applicable when the drive is not encrypted' {
        (Invoke-RequirementScript -EncryptionMethod 'None' -EncryptionPercentage 0).Lines | Should -Be @('NotApplicable')
    }

    It 'is NOT applicable for a hardware self-encrypting drive' {
        (Invoke-RequirementScript -EncryptionMethod 'Hardware').Lines | Should -Be @('NotApplicable')
    }

    It 'emits exactly one line of output (Intune string comparison)' {
        (Invoke-RequirementScript -EncryptionMethod 'XtsAes128').Lines.Count | Should -Be 1
        (Invoke-RequirementScript -EncryptionMethod 'XtsAes256' -EncryptionFlags 0).Lines.Count | Should -Be 1
    }
}
