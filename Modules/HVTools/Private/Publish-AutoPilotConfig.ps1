function Publish-AutoPilotConfig {
    [cmdletBinding()]
    param (
        [parameter(Position = 1, Mandatory = $true)]
        [string]$VMName,

        [parameter(Position = 2, Mandatory = $true)]
        [string]$ClientPath,

        [parameter(Position = 3, Mandatory = $false)]
        [switch]$ValidateConfiguration
    )
    try {
        # Validate the configuration file exists
        $configPath = "$ClientPath\AutopilotConfigurationFile.json"
        if (!(Test-Path $configPath)) {
            throw "AutopilotConfigurationFile.json not found in $ClientPath"
        }

        # Validate the configuration if requested
        if ($ValidateConfiguration) {
            if (!(Test-AutopilotConfigurationSchema -JsonPath $configPath)) {
                throw "Invalid AutoPilot configuration detected"
            }
        }

        Write-Host "Mounting $VMName.vhdx.. " -ForegroundColor Cyan -NoNewline
        $vhdxPath = "$ClientPath\$VMName.vhdx"

        # Validate VHDX exists
        if (!(Test-Path $vhdxPath)) {
            throw "VHDX file not found: $vhdxPath"
        }

        $disk = Mount-VHD -Path $vhdxPath -Passthru |
                Get-Disk |
                Get-Partition |
                Where-Object { $_.Type -eq 'Basic' } |
                Select-Object -ExpandProperty DriveLetter

        if ($disk) {
            Write-Host $script:tick -ForegroundColor Green
            Write-Host "Publishing Autopilot config to $VMName.vhdx.. " -ForegroundColor Cyan -NoNewline

            $AutopilotFolder = "$disk`:\Windows\Provisioning\Autopilot"
            if (!(Test-Path -Path $AutopilotFolder -PathType Container)) {
                New-Item -Path $AutopilotFolder -ItemType Directory -Force | Out-Null
            }

            Copy-Item -Path $configPath -Destination "$AutopilotFolder\AutopilotConfigurationFile.json" -Force
            Write-Host $script:tick -ForegroundColor Green
            Write-Host "Config published successfully to $vhdxPath" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Error occurred during config publish: $_"
        throw
    }
    finally {
        if ($disk) {
            Write-Host "Dismounting $VMName.vhdx " -ForegroundColor Cyan -NoNewline
            Dismount-VHD $vhdxPath
            Write-Host $script:tick -ForegroundColor Green
        }
    }
}