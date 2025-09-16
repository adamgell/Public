# add detection for TPM PIN and file in C:\ProgramData\Bitlocker\SetBitLockerPin.log

$logFile = "C:\ProgramData\Bitlocker\SetBitLockerPin.log"
$hasTpmPin = $(Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector | Where { $_.KeyProtectorType -eq 'TpmPin' }

if ($hasTpmPin -and (Test-Path -Path $logFile)) {
    Write-Output "TPM PIN protector is present and log file exists at $logFile."
}
elseif ($hasTpmPin) {
    Write-Output "TPM PIN protector is present, but log file does not exist."
}
elseif (Test-Path -Path $logFile) {
    Write-Output "Log file exists at $logFile, but TPM PIN protector is not present."
}
else {
    Write-Output "Neither TPM PIN protector is present nor log file exists."
}

# PowerShell using Shell.Application COM object
$shell = New-Object -ComObject Shell.Application
$bitLockerStatus = $shell.NameSpace("C:").Self.ExtendedProperty("System.Volume.BitLockerProtection")
if ($bitLockerStatus -eq 1) {
    Write-Output "BitLocker is enabled on the C: drive."
} else {
    Write-Output "BitLocker is not enabled on the C: drive."
}

<#

0 = Unencryptable
1 = BitLocker enabled
2 = BitLocker disabled
3 = BitLocker encrypting
4 = BitLocker decrypting
5 = BitLocker suspended
6 = BitLocker enabled and locked
8 = BitLocker waiting for activation vbscript - .vbs script that echo's the Bitlocker status of the C Drive - Stack Overflow

#>