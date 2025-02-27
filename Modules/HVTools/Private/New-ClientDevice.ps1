function New-ClientDevice {
    [cmdletBinding(SupportsShouldProcess)]
    param (
        [parameter(Position = 1, Mandatory = $true)]
        [ValidatePattern('^[a-zA-Z0-9\-_]+$')]  # Validate VM name format
        [string]$VMName,

        # Other parameters remain the same
        [parameter(Position = 2, Mandatory = $true)]
        [string]$ClientPath,

        [parameter(Position = 3, Mandatory = $true)]
        [string]$RefVHDX,

        [parameter(Position = 4, Mandatory = $true)]
        [string]$VSwitchName,

        [parameter(Position = 5, Mandatory = $false)]
        [string]$VLanId,

        [parameter(Position = 6, Mandatory = $true)]
        [string]$CPUCount,

        [parameter(Position = 7, Mandatory = $true)]
        [Int64]$VMMemory,

        [parameter(Position = 8, Mandatory = $false)]
        [switch]$skipAutoPilot
    )
    
    # Sanitize VM name to ensure it's compatible with Hyper-V
    $sanitizedVMName = $VMName -replace '[^\w\-]', '_'
    
    # Check if VM already exists
    if (Get-VM -Name $sanitizedVMName -ErrorAction SilentlyContinue) {
        Write-Error "A virtual machine with name '$sanitizedVMName' already exists."
        return
    }
    
    # Rest of your function with sanitized VM name
    Copy-Item -Path $RefVHDX -Destination "$ClientPath\$sanitizedVMName.vhdx"
    if (!($skipAutoPilot)) {
        Publish-AutoPilotConfig -vmName $sanitizedVMName -clientPath $ClientPath
    }

    New-VM -Name $sanitizedVMName -MemoryStartupBytes $VMMemory -VHDPath "$ClientPath\$sanitizedVMName.vhdx" -Generation 2 | Out-Null
    Enable-VMIntegrationService -vmName $sanitizedVMName -Name "Guest Service Interface"
    Set-VM -name $sanitizedVMName -CheckpointType Disabled
    Set-VMProcessor -VMName $sanitizedVMName -Count $CPUCount
    Set-VMFirmware -VMName $sanitizedVMName -EnableSecureBoot On
    Get-VMNetworkAdapter -vmName $sanitizedVMName | Connect-VMNetworkAdapter -SwitchName $VSwitchName | Set-VMNetworkAdapter -Name $VSwitchName -DeviceNaming On
    if ($VLanId) {
        Set-VMNetworkAdapterVlan -Access -VMName $sanitizedVMName -VlanId $VLanId
    }
    $owner = Get-HgsGuardian UntrustedGuardian -ErrorAction SilentlyContinue
    If (!$owner) {
        # Creating new UntrustedGuardian since it did not exist
        $owner = New-HgsGuardian -Name UntrustedGuardian -GenerateCertificates
    }
    $kp = New-HgsKeyProtector -Owner $owner -AllowUntrustedRoot
    Set-VMKeyProtector -VMName $sanitizedVMName -KeyProtector $kp.RawData
    Enable-VMTPM -VMName $sanitizedVMName
    Start-VM -Name $sanitizedVMName
    
    # Set VM Info with Serial number
    $vmSerial = (Get-CimInstance -Namespace root\virtualization\v2 -class Msvm_VirtualSystemSettingData | 
                Where-Object { ($_.VirtualSystemType -eq "Microsoft:Hyper-V:System:Realized") -and 
                              ($_.elementname -eq $sanitizedVMName) }).BIOSSerialNumber
    
    Get-VM -Name $sanitizedVMName | Set-VM -Notes "Serial# $vmSerial | Tenant: $VMName"
}