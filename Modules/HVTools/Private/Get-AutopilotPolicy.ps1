# Updated Get-AutopilotPolicy.ps1

$requiredModules = @(
    @{ModuleName = "Microsoft.Graph.Authentication"; MinimumVersion = "2.25.0" },
    @{ModuleName = "Microsoft.Graph.DeviceManagement"; MinimumVersion = "2.25.0" },
    @{ModuleName = "Microsoft.Graph.DeviceManagement.Enrollment"; MinimumVersion = "2.25.0" },
    @{ModuleName = "Microsoft.Graph.Identity.DirectoryManagement"; MinimumVersion = "2.11.1" }
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module.ModuleName | Where-Object { $_.Version -ge [version]$module.MinimumVersion })) {
        Write-Host "Installing $($module.ModuleName)..."
        Install-Module -Name $module.ModuleName -MinimumVersion $module.MinimumVersion -Force -AllowClobber
    }

    if (-not (Get-Module -Name $module.ModuleName)) {
        Write-Host "Importing $($module.ModuleName)..."
        Import-Module -Name $module.ModuleName -MinimumVersion $module.MinimumVersion -Force
    }
}
function Get-AutopilotPolicy {
    [cmdletbinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$FileDestination
    )
    try {
        # Connect to Microsoft Graph with all required permissions
        Write-Verbose "Connecting to Microsoft Graph..."
        Connect-MgGraph -Scopes @(
            "DeviceManagementServiceConfig.Read.All",
            "DeviceManagementConfiguration.Read.All",
            "Organization.Read.All",
            "Domain.Read.All"
        ) -NoWelcome

        $configFile = "AutopilotConfigurationFile.json"
        $configPath = Join-Path $FileDestination $configFile
        Write-Verbose "Config file path: $configPath"

        if (!(Test-Path $configPath -ErrorAction Continue)) {
            # Ensure directory exists
            if (!(Test-Path $FileDestination)) {
                New-Item -Path $FileDestination -ItemType Directory -Force | Out-Null
            }

            Write-Verbose "Getting Autopilot profiles..."
            $autopilotProfiles = Get-AutopilotProfile
            Write-Verbose "Found $($autopilotProfiles.Count) profiles"

            if (!($autopilotProfiles)) {
                Write-Warning "No Autopilot policies found.."
            }
            else {
                if ($autopilotProfiles.Count -gt 1) {
                    Write-Verbose "Multiple profiles found, showing selection dialog..."
                    $selectedProfile = $autopilotProfiles | Select-Object displayName, id, description |
                        Out-GridView -Title 'Select AutoPilot Profile' -PassThru
                }
                else {
                    Write-Verbose "Single profile found, using automatically"
                    $selectedProfile = $autopilotProfiles[0]
                }

                if ($selectedProfile) {
                    Write-Verbose "Converting profile to JSON config..."
                    $profileConfigJson = $selectedProfile | ConvertTo-AutopilotConfigurationJSON
                    Write-Verbose "Saving config to: $configPath"
                    $profileConfigJson | Out-File $configPath -Encoding ascii -Force
                    Write-Host "Autopilot profile saved: $($selectedProfile.displayName)" -ForegroundColor Green
                }
                else {
                    Write-Warning "No profile was selected"
                }
            }
        }
        else {
            Write-Host "Autopilot Configuration file found locally: $configPath" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Error occurred getting Autopilot policy: $_"
        throw
    }
}
# Define Get-AutopilotProfile function
function Get-AutopilotProfile {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $false)] $id
    )

    $graphApiVersion = "beta"
    $Resource = "deviceManagement/windowsAutopilotDeploymentProfiles"

    if ($id) {
        $uri = "https://graph.microsoft.com/$graphApiVersion/$Resource/$id"
    }
    else {
        $uri = "https://graph.microsoft.com/$graphApiVersion/$Resource"
    }

    Write-Verbose "GET $uri"

    try {
        $response = Invoke-MgGraphRequest -Uri $uri -Method Get
        if ($id) {
            $response
        }
        else {
            $devices = $response.value

            $devicesNextLink = $response."@odata.nextLink"

            while ($null -ne $devicesNextLink) {
                $devicesResponse = (Invoke-MgGraphRequest -Uri $devicesNextLink -Method Get)
                $devicesNextLink = $devicesResponse."@odata.nextLink"
                $devices += $devicesResponse.value
            }

            $devices
        }
    }
    catch {
        Write-Error $_.Exception
        break
    }
}

# Define ConvertTo-AutopilotConfigurationJSON function
function ConvertTo-AutopilotConfigurationJSON {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $True)]
        [Object] $profile
    )

    Begin {
        $script:TenantOrg = Get-MgOrganization
        $script:allDomains = Get-MgDomain -All
        foreach ($domain in $script:allDomains) {
            if ($domain.isDefault) {
                $script:TenantDomain = $domain.Id
            }
        }
    }

    Process {
        $oobeSetting = $profile.outOfBoxExperienceSetting

        $json = @{
            "Comment_File"     = "Profile $($_.displayName)"
            "Version"          = 2049
            "ZtdCorrelationId" = $_.id
        }

        if ($profile."@odata.type" -eq "#microsoft.graph.activeDirectoryWindowsAutopilotDeploymentProfile") {
            $json.Add("CloudAssignedDomainJoinMethod", 1)
        }
        else {
            $json.Add("CloudAssignedDomainJoinMethod", 0)
        }

        if ($profile.deviceNameTemplate) {
            $json.Add("CloudAssignedDeviceName", $_.deviceNameTemplate)
        }

        $oobeConfig = 8 + 256
        if ($oobeSetting.userType -eq 'standard') {
            $oobeConfig += 2
        }
        if ($oobeSetting.privacySettingsHidden -eq $true) {
            $oobeConfig += 4
        }
        if ($oobeSetting.eulaHidden -eq $true) {
            $oobeConfig += 16
        }
        if ($oobeSetting.keyboardSelectionPageSkipped -eq $true) {
            $oobeConfig += 1024
        }
        if ($_.locale) {
            $json.Add("CloudAssignedLanguage", $_.locale)
        }
        if ($oobeSetting.deviceUsageType -eq 'shared') {
            $oobeConfig += 32 + 64
        }
        $json.Add("CloudAssignedOobeConfig", $oobeConfig)

        if ($oobeSetting.escapeLinkHidden -eq $true) {
            $json.Add("CloudAssignedForcedEnrollment", 1)
        }
        else {
            $json.Add("CloudAssignedForcedEnrollment", 0)
        }

        $json.Add("CloudAssignedTenantId", $script:TenantOrg.id)
        $json.Add("CloudAssignedTenantDomain", $script:TenantDomain)
        $embedded = @{
            "CloudAssignedTenantDomain" = $script:TenantDomain
            "CloudAssignedTenantUpn"    = ""
        }
        if ($oobeSetting.escapeLinkHidden -eq $true) {
            $embedded.Add("ForcedEnrollment", 1)
        }
        else {
            $embedded.Add("ForcedEnrollment", 0)
        }
        $ztc = @{
            "ZeroTouchConfig" = $embedded
        }
        $json.Add("CloudAssignedAadServerData", (ConvertTo-JSON $ztc -Compress))

        if ($profile.hybridAzureADJoinSkipConnectivityCheck -eq $true) {
            $json.Add("HybridJoinSkipDCConnectivityCheck", 1)
        }

        $json.Add("CloudAssignedAutopilotUpdateDisabled", 1)
        $json.Add("CloudAssignedAutopilotUpdateTimeout", 1800000)

        ConvertTo-JSON $json
    }
}