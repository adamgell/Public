#Requires -Version 5.1
<#
.SYNOPSIS
    Win32 uninstall: removes the cipher-upgrade scheduled task and working files.
.DESCRIPTION
    Does NOT decrypt or otherwise change the drive's encryption. It only stops the
    remediation machinery.
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
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    $workDir = Get-CipherWorkingDir
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output "Uninstalled: removed task '$TaskName' and working directory. Encryption unchanged."
    exit 0
}
catch {
    Write-Warning "Cipher remediation uninstall failed: $($_.Exception.Message)"
    exit 1
}
