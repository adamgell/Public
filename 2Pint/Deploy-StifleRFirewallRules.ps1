#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys Windows Firewall rules for StifleR Server, Client, and BranchCache components.

.DESCRIPTION
    Creates inbound and outbound firewall rules based on 2Pint Software's official
    StifleR firewall port documentation. Rules are grouped by component:
      - StifleR Server (outbound)
      - StifleR Client (inbound + outbound)
      - BranchCache (inbound + outbound)

    All rules are created in the "StifleR" display group for easy management.

.PARAMETER Component
    Which component(s) to configure. Valid values: Server, Client, BranchCache, All.
    Default: All

.PARAMETER StifleRServerAddress
    IP address or hostname of the StifleR Server. Used for client outbound rules.
    Default: "Any"

.PARAMETER BeaconAddresses
    IP addresses or hostnames of StifleR Beacon servers. Used for client outbound rules.
    Default: "Any"

.PARAMETER RemoveExisting
    Remove all existing StifleR firewall rules before creating new ones.

.EXAMPLE
    .\Deploy-StifleRFirewallRules.ps1 -Component All

.EXAMPLE
    .\Deploy-StifleRFirewallRules.ps1 -Component Client -StifleRServerAddress "10.0.0.5"

.EXAMPLE
    .\Deploy-StifleRFirewallRules.ps1 -Component Client -RemoveExisting

.NOTES
    Author  : CDW / Adam
    Source  : 2Pint Software StifleR Documentation - Firewall Ports
    Version : 1.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Server', 'Client', 'BranchCache', 'All')]
    [string[]]$Component = 'All',

    [string]$StifleRServerAddress = 'Any',

    [string[]]$BeaconAddresses = @('Any'),

    [switch]$RemoveExisting
)

$ErrorActionPreference = 'Stop'
$RuleGroup = 'StifleR'

#region Helper Functions
function New-StifleRFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction,
        [Parameter(Mandatory)][ValidateSet('TCP', 'UDP')][string]$Protocol,
        [string]$LocalPort = 'Any',
        [string]$RemotePort = 'Any',
        [string]$LocalAddress = 'Any',
        [string]$RemoteAddress = 'Any',
        [string]$Program = 'Any',
        [string]$Description = ''
    )

    $ruleName = "StifleR - $DisplayName"

    # Check for existing rule
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "Rule already exists: $ruleName (skipping)"
        return
    }

    $params = @{
        DisplayName  = $ruleName
        Direction    = $Direction
        Protocol     = $Protocol
        Action       = 'Allow'
        Enabled      = 'True'
        Group        = $RuleGroup
        Profile      = 'Domain,Private'
        Description  = $Description
    }

    if ($LocalPort -ne 'Any')      { $params.LocalPort    = $LocalPort }
    if ($RemotePort -ne 'Any')     { $params.RemotePort   = $RemotePort }
    if ($LocalAddress -ne 'Any')   { $params.LocalAddress = $LocalAddress }
    if ($RemoteAddress -ne 'Any')  { $params.RemoteAddress = $RemoteAddress }
    if ($Program -ne 'Any')        { $params.Program      = $Program }

    if ($PSCmdlet.ShouldProcess($ruleName, 'Create firewall rule')) {
        New-NetFirewallRule @params | Out-Null
        Write-Host "  [+] Created: $ruleName" -ForegroundColor Green
    }
}
#endregion

#region Remove Existing Rules
if ($RemoveExisting) {
    Write-Host "`nRemoving existing StifleR firewall rules..." -ForegroundColor Yellow
    $existingRules = Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue
    if ($existingRules) {
        $existingRules | Remove-NetFirewallRule
        Write-Host "  Removed $($existingRules.Count) existing rule(s)." -ForegroundColor Yellow
    }
    else {
        Write-Host "  No existing StifleR rules found." -ForegroundColor Gray
    }
}
#endregion

$resolvedComponents = if ('All' -in $Component) { @('Server', 'Client', 'BranchCache') } else { $Component }

#region StifleR Server Rules (Outbound)
if ('Server' -in $resolvedComponents) {
    Write-Host "`n=== StifleR Server - Outbound Rules ===" -ForegroundColor Cyan

    New-StifleRFirewallRule `
        -DisplayName 'Server - Global Catalog LDAP (Out)' `
        -Direction Outbound -Protocol TCP `
        -LocalPort 3268 -RemotePort 3268 `
        -Description 'StifleR Server LDAP Global Catalog for domain account lookups'

    New-StifleRFirewallRule `
        -DisplayName 'Server - HTTPS Dashboard (Out)' `
        -Direction Outbound -Protocol TCP `
        -LocalPort 443 -RemotePort 443 `
        -Description 'StifleR Server HTTPS connection for dashboard'

    New-StifleRFirewallRule `
        -DisplayName 'Server - SQL Service Broker (Out)' `
        -Direction Outbound -Protocol TCP `
        -LocalPort 4022 -RemotePort 4022 `
        -Description 'StifleR Server SQL Service Broker (only if SQL is enabled)'

    New-StifleRFirewallRule `
        -DisplayName 'Server - SQL Server Service (Out)' `
        -Direction Outbound -Protocol UDP `
        -LocalPort 1433 -RemotePort 1433 `
        -Description 'StifleR Server SQL Server service (only if SQL is enabled)'
}
#endregion

#region StifleR Client Rules (Inbound)
if ('Client' -in $resolvedComponents) {
    Write-Host "`n=== StifleR Client - Inbound Rules ===" -ForegroundColor Cyan

    # Blue/Green Leader executables path - adjust if installed elsewhere
    $blueGreenExe = '%ProgramFiles%\2Pint Software\StifleR Client\TwoPint.PeerDist.BlueGreenLeader.exe'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Data from Remote Peer (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort 1337 `
        -Program $blueGreenExe `
        -Description 'Blue Leader receiving data from remote peer'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Green Leader Peer Data (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort '1337,1339' `
        -Program $blueGreenExe `
        -Description 'Green Leader receiving peer data'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Peer Data Local Subnet (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort 1338 `
        -RemoteAddress 'LocalSubnet' `
        -Program $blueGreenExe `
        -Description 'Blue Leader receiving peer data from local subnet'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Peer Probes WSD (In)' `
        -Direction Inbound -Protocol UDP `
        -LocalPort 3702 `
        -RemoteAddress 'LocalSubnet' `
        -Program $blueGreenExe `
        -Description 'Peer discovery probes via WSD on local subnet'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Peer Probe Match (In)' `
        -Direction Inbound -Protocol UDP `
        -RemotePort 3702 `
        -Program $blueGreenExe `
        -Description 'Blue Leader peer probe match response'

    New-StifleRFirewallRule `
        -DisplayName 'Client - mDNS (In)' `
        -Direction Inbound -Protocol UDP `
        -LocalPort 5353 `
        -RemoteAddress 'LocalSubnet' `
        -Program $blueGreenExe `
        -Description 'mDNS discovery on local subnet'

    New-StifleRFirewallRule `
        -DisplayName 'Client - StifleR Service SignalR (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort 1414 `
        -Description 'StifleR Client receiving connections from StifleR Service'

    #region StifleR Client Rules (Outbound)
    Write-Host "`n=== StifleR Client - Outbound Rules ===" -ForegroundColor Cyan

    $beaconRemote = if ($BeaconAddresses -contains 'Any') { 'Any' } else { $BeaconAddresses -join ',' }

    New-StifleRFirewallRule `
        -DisplayName 'Client - Beacon iPerf Packets (Out)' `
        -Direction Outbound -Protocol UDP `
        -RemotePort 5201 `
        -RemoteAddress $beaconRemote `
        -Description 'iPerf bandwidth measurement packets to StifleR Beacons'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Beacon FastPing (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 5200 `
        -RemoteAddress $beaconRemote `
        -Description 'FastPing latency measurement to StifleR Beacons'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Data to Requesting Peer (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1338 `
        -Description 'Blue Leader sending data to requesting peer'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Data from Remote Peer (Out)' `
        -Direction Outbound -Protocol TCP `
        -LocalPort 1337 `
        -Program $blueGreenExe `
        -Description 'Blue Leader outbound data exchange with remote peer'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Green Leader Peer Data (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort '1337,1339' `
        -Program $blueGreenExe `
        -Description 'Green Leader outbound peer data'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Peer Data Local Subnet (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1338 `
        -RemoteAddress 'LocalSubnet' `
        -Program $blueGreenExe `
        -Description 'Blue Leader sending peer data to local subnet'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Peer Probes WSD (Out)' `
        -Direction Outbound -Protocol UDP `
        -LocalPort 3702 `
        -RemoteAddress 'LocalSubnet' `
        -Program $blueGreenExe `
        -Description 'Peer discovery probes via WSD on local subnet'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Peer Probe Match (Out)' `
        -Direction Outbound -Protocol UDP `
        -RemotePort 3702 `
        -Program $blueGreenExe `
        -Description 'Blue Leader outbound peer probe match'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Blue Leader Probe Port (Out)' `
        -Direction Outbound -Protocol UDP `
        -LocalPort 3703 -RemotePort 3703 `
        -Program $blueGreenExe `
        -Description 'Blue Leader probe port for peer discovery'

    New-StifleRFirewallRule `
        -DisplayName 'Client - mDNS (Out)' `
        -Direction Outbound -Protocol UDP `
        -RemotePort 5353 `
        -Program $blueGreenExe `
        -Description 'mDNS outbound discovery'

    # StifleR Client service connections
    $stiflerClientExe = '%ProgramFiles%\2Pint Software\StifleR Client\Stifler.Client.exe'
    $remoteToolsExe = '%ProgramFiles%\2Pint Software\StifleR Client\Twopint.remotetools.host.exe'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Access StifleR Service UDP (Out)' `
        -Direction Outbound -Protocol UDP `
        -RemotePort 1414 `
        -RemoteAddress $StifleRServerAddress `
        -Program $stiflerClientExe `
        -Description 'StifleR Client UDP connection to StifleR Service'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Access StifleR Service TCP (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1414 `
        -RemoteAddress $StifleRServerAddress `
        -Program $stiflerClientExe `
        -Description 'StifleR Client TCP connection to StifleR Service'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Remote Tools to Service UDP (Out)' `
        -Direction Outbound -Protocol UDP `
        -RemotePort 1415 `
        -Program $remoteToolsExe `
        -Description 'Remote Tools host UDP connection to StifleR Service and Action Hubs'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Remote Tools to Service TCP (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1415 `
        -Program $remoteToolsExe `
        -Description 'Remote Tools host TCP connection to StifleR Service and Action Hubs'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Dashboard Access Port 9000 (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 9000 `
        -RemoteAddress $StifleRServerAddress `
        -Description 'Browser access to StifleR Dashboard on port 9000'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Dashboard SignalR Port 1414 (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1414 `
        -RemoteAddress $StifleRServerAddress `
        -Description 'Browser SignalR connection to StifleR Service'

    New-StifleRFirewallRule `
        -DisplayName 'Client - Dashboard ActionHub Port 1415 (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1415 `
        -Description 'Browser connection to StifleR Action Hubs'
}
#endregion

#region BranchCache Rules (Inbound)
if ('BranchCache' -in $resolvedComponents) {
    Write-Host "`n=== BranchCache - Inbound Rules ===" -ForegroundColor Cyan

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Content Retrieval HTTP (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort 1337 `
        -Description 'BranchCache content retrieval via HTTP'

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Hosted Cache Server HTTP (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort '1339,443' `
        -Description 'BranchCache Hosted Cache Server HTTP inbound'

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Peer Discovery WSD (In)' `
        -Direction Inbound -Protocol TCP `
        -LocalPort 3702 `
        -RemoteAddress 'LocalSubnet' `
        -Program '%SYSTEMROOT%\system32\svchost.exe' `
        -Description 'BranchCache peer discovery via WSD on local subnet'

    #region BranchCache Rules (Outbound)
    Write-Host "`n=== BranchCache - Outbound Rules ===" -ForegroundColor Cyan

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Content Retrieval HTTP (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort 1337 `
        -Description 'BranchCache content retrieval via HTTP outbound'

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Hosted Cache Client HTTP (Out)' `
        -Direction Outbound -Protocol TCP `
        -RemotePort '1339,443' `
        -Description 'BranchCache Hosted Cache Client HTTP outbound'

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Hosted Cache Server HTTP (Out)' `
        -Direction Outbound -Protocol TCP `
        -LocalPort '1339,443' `
        -Description 'BranchCache Hosted Cache Server HTTP outbound'

    New-StifleRFirewallRule `
        -DisplayName 'BranchCache - Peer Discovery WSD (Out)' `
        -Direction Outbound -Protocol UDP `
        -RemotePort 3702 `
        -RemoteAddress 'LocalSubnet' `
        -Program '%SYSTEMROOT%\system32\svchost.exe' `
        -Description 'BranchCache peer discovery via WSD outbound on local subnet'
}
#endregion

#region Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$allRules = Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue
if ($allRules) {
    $inbound  = ($allRules | Where-Object Direction -eq 'Inbound').Count
    $outbound = ($allRules | Where-Object Direction -eq 'Outbound').Count
    Write-Host "  Total StifleR rules: $($allRules.Count) (Inbound: $inbound, Outbound: $outbound)" -ForegroundColor Green
    Write-Host "  Group name: '$RuleGroup' - use Get-NetFirewallRule -Group '$RuleGroup' to manage" -ForegroundColor Gray
}
else {
    Write-Host "  No rules found (WhatIf mode or error occurred)." -ForegroundColor Yellow
}
#endregion
