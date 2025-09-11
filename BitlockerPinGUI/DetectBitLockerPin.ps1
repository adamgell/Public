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