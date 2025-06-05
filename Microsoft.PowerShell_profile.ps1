# PowerShell Profile - Cross-Platform (macOS/Windows)
# Auto-installs all dependencies for a complete environment setup
# Updated: 2024

#region Platform Detection
# Use automatic variables directly - they're built into PowerShell 6+
# No need to assign them
#endregion

#region Environment Reset Function
function Reset-PowerShellEnvironment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force
    )
    
    if ($Force -or $PSCmdlet.ShouldProcess("PowerShell Environment", "Reset and reinstall all components")) {
        Write-Host "`n=== Resetting PowerShell Environment ===" -ForegroundColor Magenta
        Write-Host "This will install/reinstall all dependencies" -ForegroundColor Yellow
        
        # Force reinstall all components
        $script:ForceInstall = $true
        
        # Reload profile
        . $PROFILE
        
        Write-Host "`n=== Environment Reset Complete ===" -ForegroundColor Green
        Write-Host "Please restart PowerShell for all changes to take effect" -ForegroundColor Cyan
    }
}
#endregion

#region Homebrew Installation (macOS)
if ($IsMacOS) {
    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
        Write-Host "Homebrew not found. Installing..." -ForegroundColor Yellow
        try {
            # Install Homebrew
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            
            # Add Homebrew to PATH for current session
            $brewPaths = @(
                "/opt/homebrew/bin",
                "/usr/local/bin"
            )
            
            foreach ($brewPath in $brewPaths) {
                if ((Test-Path "$brewPath/brew") -and ($env:PATH -notlike "*$brewPath*")) {
                    Write-Host "Adding Homebrew to PATH: $brewPath" -ForegroundColor Green
                    $env:PATH = "${brewPath}:${env:PATH}"
                }
            }
            
            Write-Host "Homebrew installed successfully!" -ForegroundColor Green
            Write-Host "You may need to restart PowerShell for full functionality" -ForegroundColor Yellow
        }
        catch {
            Write-Error "Failed to install Homebrew: $_"
            Write-Host "Please install manually from https://brew.sh" -ForegroundColor Red
            return
        }
    }
}
#endregion

#region macOS-specific PATH Management
if ($IsMacOS) {
    function Get-Path {
        [CmdletBinding()]
        param()
        
        $pathFiles = @('/etc/paths')
        $pathFiles += Get-ChildItem -Path /private/etc/paths.d -ErrorAction SilentlyContinue | 
                      Select-Object -ExpandProperty FullName
        
        $pathFiles | ForEach-Object {
            if (Test-Path $_) {
                Get-Content -Path $_ | Where-Object { $_.Trim() -ne '' }
            }
        }
    }

    function Add-Path {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )
        $env:PATH = "${env:PATH}:$Path"
    }

    function Update-Environment {
        [CmdletBinding()]
        param()
        
        $currentPaths = $env:PATH -split ':' | Where-Object { $_ -ne '' }
        Get-Path | ForEach-Object {
            if ($_ -notin $currentPaths) {
                Write-Verbose "Adding $_ to PATH"
                Add-Path -Path $_
            }
        }
    }

    # Sync macOS paths on profile load
    Update-Environment
}
#endregion

#region PowerShell Modules Installation
$modules = @(
    @{Name = 'Terminal-Icons'; Description = 'File and folder icons'},
    @{Name = 'PSReadLine'; Description = 'Enhanced command line editing'; MinVersion = '2.2.0'},
    @{Name = 'posh-git'; Description = 'Git integration for PowerShell'}
)

foreach ($module in $modules) {
    $installedModule = Get-Module -ListAvailable -Name $module.Name
    
    if (-not $installedModule -or $script:ForceInstall) {
        Write-Host "$($module.Description) module not found. Installing..." -ForegroundColor Yellow
        try {
            $installParams = @{
                Name = $module.Name
                Repository = 'PSGallery'
                Scope = 'CurrentUser'
                Force = $true
                AllowClobber = $true
            }
            
            if ($module.MinVersion) {
                $installParams['MinimumVersion'] = $module.MinVersion
            }
            
            Install-Module @installParams
            Write-Host "$($module.Name) installed successfully." -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to install $($module.Name): $_"
        }
    }
}

# Import modules
foreach ($module in $modules) {
    try {
        Import-Module -Name $module.Name -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to import $($module.Name): $_"
    }
}
#endregion

#region Package Management
if ($IsMacOS) {
    # Check for Homebrew and install packages
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        $brewPackages = @(
            @{Name = 'neofetch'; Description = 'System information tool'},
            @{Name = 'git'; Description = 'Version control system'},
            @{Name = 'oh-my-posh'; Description = 'Prompt theme engine'},
            @{Name = 'curl'; Description = 'Data transfer tool'},
            @{Name = 'wget'; Description = 'Network downloader'},
            @{Name = 'jq'; Description = 'JSON processor'},
            @{Name = 'tree'; Description = 'Directory listing'},
            @{Name = 'htop'; Description = 'Process viewer'},
            @{Name = 'ripgrep'; Description = 'Fast grep alternative'},
            @{Name = 'fzf'; Description = 'Fuzzy finder'}
        )
        
        Write-Host "`nChecking Homebrew packages..." -ForegroundColor Cyan
        
        foreach ($package in $brewPackages) {
            Write-Host "Checking $($package.Name) - $($package.Description)..." -NoNewline
            
            brew list $package.Name 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or $script:ForceInstall) {
                Write-Host " Installing..." -ForegroundColor Yellow
                brew install $package.Name
            } else {
                Write-Host " OK" -ForegroundColor Green
            }
        }
    }
}
elseif ($IsWindows) {
    # Windows package management with winget
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $wingetPackages = @(
            @{Id = 'Neofetch.Neofetch'; Name = 'Neofetch'},
            @{Id = 'Git.Git'; Name = 'Git'},
            @{Id = 'JanDeDobbeleer.OhMyPosh'; Name = 'Oh-My-Posh'},
            @{Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7+'}
        )
        
        Write-Host "`nChecking Windows packages..." -ForegroundColor Cyan
        
        foreach ($package in $wingetPackages) {
            Write-Host "Checking $($package.Name)..." -NoNewline
            
            $installed = winget list --id $package.Id 2>&1
            if ($LASTEXITCODE -ne 0 -or $installed -match "No installed package found" -or $script:ForceInstall) {
                Write-Host " Installing..." -ForegroundColor Yellow
                winget install --id $package.Id --silent --accept-package-agreements --accept-source-agreements
            } else {
                Write-Host " OK" -ForegroundColor Green
            }
        }
    } else {
        Write-Warning "Winget not found. Install App Installer from Microsoft Store"
    }
}
#endregion

#region Oh-My-Posh Configuration
# Wait a moment for oh-my-posh to be available in PATH after installation
if (-not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 500
    # Refresh PATH
    if ($IsMacOS) {
        Update-Environment
    }
}

# Configure Oh-My-Posh if available
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    # Cross-platform theme path
    $themePath = if ($IsMacOS) {
        # Try common macOS installation paths
        $paths = @(
            "$HOME/.config/oh-my-posh/themes/blue-owl.omp.json",
            "/usr/local/share/oh-my-posh/themes/blue-owl.omp.json",
            "/opt/homebrew/share/oh-my-posh/themes/blue-owl.omp.json",
            "/opt/homebrew/opt/oh-my-posh/themes/blue-owl.omp.json"
        )
        $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    } else {
        # Windows paths
        $paths = @(
            "$HOME/AppData/Local/Programs/oh-my-posh/themes/blue-owl.omp.json",
            "$env:LOCALAPPDATA/Programs/oh-my-posh/themes/blue-owl.omp.json",
            "$env:POSH_THEMES_PATH/blue-owl.omp.json"
        )
        $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    
    if ($themePath -and (Test-Path $themePath)) {
        Write-Verbose "Loading Oh-My-Posh with blue-owl theme..."
        oh-my-posh init pwsh --config $themePath | Invoke-Expression
    } else {
        # Use default theme if blue-owl not found
        Write-Verbose "Loading Oh-My-Posh with default theme..."
        oh-my-posh init pwsh | Invoke-Expression
    }
}
#endregion

#region Neofetch Display
if (Get-Command neofetch -ErrorAction SilentlyContinue) {
    if (-not $script:ForceInstall) {  # Don't show during reset
        neofetch
    }
} elseif ($IsMacOS -and (Get-Command screenfetch -ErrorAction SilentlyContinue)) {
    # Alternative for macOS
    if (-not $script:ForceInstall) {
        screenfetch
    }
}
#endregion

#region SSH Utilities
function Copy-SSHKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SSHHost,
        
        [string]$KeyPath = "$HOME/.ssh/id_rsa.pub"
    )
    
    if (-not (Test-Path $KeyPath)) {
        Write-Error "SSH public key not found at $KeyPath"
        Write-Host "Generate one with: ssh-keygen -t rsa -b 4096" -ForegroundColor Yellow
        
        if ($Host.UI.PromptForChoice("Generate SSH Key?", "Would you like to generate an SSH key now?", @("&Yes", "&No"), 1) -eq 0) {
            ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa"
        }
        return
    }
    
    try {
        $publicKey = Get-Content $KeyPath -Raw
        $command = "mkdir -p ~/.ssh && echo '$publicKey' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
        
        Write-Host "Copying SSH key to $SSHHost..." -ForegroundColor Cyan
        ssh $SSHHost $command
        Write-Host "SSH key copied successfully!" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to copy SSH key: $_"
    }
}

# Alias for traditional ssh-copy-id command
Set-Alias -Name ssh-copy-id -Value Copy-SSHKey
#endregion

#region Windows-specific Functions (Hyper-V)
if ($IsWindows) {
    function Get-VMIPAddresses {
        [CmdletBinding()]
        param(
            [Alias("VMName")]
            [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, ParameterSetName='ByName', Mandatory=$true, Position=1)]
            [String]$Name,

            [Alias("VMHost")]
            [Parameter(ValueFromPipelineByPropertyName=$true, Position=2, ParameterSetName='ByName')]
            [String]$ComputerName = $env:COMPUTERNAME,

            [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, ParameterSetName='ByVM')]
            [Microsoft.HyperV.PowerShell.VirtualMachine]$VM,

            [Parameter(ValueFromPipelineByPropertyName=$true)]
            [ValidateSet("Any", "IPv4", "IPv6")]
            [String]$Type = "Any",

            [Parameter(ValueFromPipelineByPropertyName=$true)]
            [Switch]$IgnoreAPIPA=$false
        )

        PROCESS {
            if($VM) {
                $ParameterSet = @{ 'VM'=$VM }
            } else {
                $ParameterSet = @{ 'VMName'=$Name; 'ComputerName'=$ComputerName }
            }
            
            $IPAddresses = (Get-VMNetworkAdapter @ParameterSet).IPAddresses
            
            switch($Type) {
                "IPv4" { $IPAddresses = $IPAddresses | Where-Object { $_ -match "\." } }
                "IPv6" { $IPAddresses = $IPAddresses | Where-Object { $_ -match ":" } }
            }
            
            if($IgnoreAPIPA) {
                $IPAddresses = $IPAddresses | Where-Object { $_ -notmatch "^(169.254)|(fe80)" }
            }
            
            $IPAddresses
        }
    }

    function Get-AllVMIPAddresses {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipelineByPropertyName=$true)]
            [ValidateSet("Any", "IPv4", "IPv6")]
            [String]$Type = "Any",
        
            [Parameter(ValueFromPipelineByPropertyName=$true)]
            [Switch]$IgnoreAPIPA=$false,
        
            [Parameter(ValueFromPipelineByPropertyName=$true)]
            [String]$ComputerName = $env:COMPUTERNAME
        )
        
        PROCESS {
            $VMs = Get-VM -ComputerName $ComputerName -ErrorAction SilentlyContinue
            
            foreach($VM in $VMs) {
                $IPAddresses = (Get-VMNetworkAdapter -VM $VM).IPAddresses
                
                switch($Type) {
                    "IPv4" { $IPAddresses = $IPAddresses | Where-Object { $_ -match "\." } }
                    "IPv6" { $IPAddresses = $IPAddresses | Where-Object { $_ -match ":" } }
                }
                
                if($IgnoreAPIPA) {
                    $IPAddresses = $IPAddresses | Where-Object { $_ -notmatch "^(169.254)|(fe80)" }
                }
                
                [PSCustomObject]@{
                    VMName = $VM.Name
                    State = $VM.State
                    IPAddresses = if($IPAddresses) { $IPAddresses -join ', ' } else { 'No IP Addresses' }
                }
            }
        }
    }
}
#endregion

#region Custom Aliases and Functions
# Add your custom aliases here
Set-Alias -Name ll -Value Get-ChildItem
Set-Alias -Name grep -Value Select-String

# Quick navigation
function .. { Set-Location .. }
function ... { Set-Location ../.. }
function .... { Set-Location ../../.. }

# Git configuration and shortcuts
if (Get-Command git -ErrorAction SilentlyContinue) {
    # Configure git if not already configured
    function Initialize-GitConfig {
        Write-Host "Configuring Git..." -ForegroundColor Cyan
        
        # Set nano as default editor
        $currentEditor = git config --global core.editor
        if ($currentEditor -ne 'nano') {
            Write-Host "  Setting nano as default git editor..." -ForegroundColor Yellow
            git config --global core.editor nano
        }
        
        # Check if user name and email are set
        $userName = git config --global user.name
        $userEmail = git config --global user.email
        
        if (-not $userName) {
            Write-Host "  Git user.name not set. Enter your name:" -ForegroundColor Yellow
            $userName = Read-Host
            if ($userName) {
                git config --global user.name $userName
            }
        }
        
        if (-not $userEmail) {
            Write-Host "  Git user.email not set. Enter your email:" -ForegroundColor Yellow
            $userEmail = Read-Host
            if ($userEmail) {
                git config --global user.email $userEmail
            }
        }
        
        # Set other useful defaults
        git config --global init.defaultBranch main
        git config --global pull.rebase false
        git config --global fetch.prune true
        git config --global diff.colorMoved zebra
        git config --global rebase.autoStash true
        
        # Better diff algorithm
        git config --global diff.algorithm histogram
        
        # Enable rerere (reuse recorded resolution)
        git config --global rerere.enabled true
        
        Write-Host "  Git configuration complete!" -ForegroundColor Green
    }
    
    # Run git config on first load or reset
    if ($script:ForceInstall -or -not (git config --global core.editor)) {
        Initialize-GitConfig
    }
    
    # Git shortcuts
    function gs { git status $args }
    function ga { git add $args }
    function gc { git commit -m $args }
    function gp { git push $args }
    function gl { git log --oneline -10 $args }
    function gco { git checkout $args }
    function gcb { git checkout -b $args }
    function gpl { git pull $args }
    function gd { git diff $args }
    function gdc { git diff --cached $args }
    function gb { git branch $args }
    function gf { git fetch $args }
    function gr { git rebase $args }
    function gri { git rebase -i $args }
    function gca { git commit --amend $args }
    function gcane { git commit --amend --no-edit $args }
    
    # Advanced git functions
    function git-undo {
        Write-Host "Undoing last commit (keeping changes)..." -ForegroundColor Yellow
        git reset HEAD~1
    }
    
    function git-unstage {
        git reset HEAD $args
    }
    
    function git-discard {
        param([string]$Path = ".")
        if ($Path -eq "." -or $Path -eq "*") {
            $response = Read-Host "Discard all changes? This cannot be undone! (y/N)"
            if ($response -eq 'y') {
                git checkout -- .
                git clean -fd
            }
        } else {
            git checkout -- $Path
        }
    }
    
    # Show git aliases
    function git-aliases {
        Write-Host "`nGit Aliases:" -ForegroundColor Cyan
        Write-Host "  gs    - git status" -ForegroundColor Gray
        Write-Host "  ga    - git add" -ForegroundColor Gray
        Write-Host "  gc    - git commit -m" -ForegroundColor Gray
        Write-Host "  gp    - git push" -ForegroundColor Gray
        Write-Host "  gl    - git log --oneline -10" -ForegroundColor Gray
        Write-Host "  gco   - git checkout" -ForegroundColor Gray
        Write-Host "  gcb   - git checkout -b" -ForegroundColor Gray
        Write-Host "  gpl   - git pull" -ForegroundColor Gray
        Write-Host "  gd    - git diff" -ForegroundColor Gray
        Write-Host "  gdc   - git diff --cached" -ForegroundColor Gray
        Write-Host "  gb    - git branch" -ForegroundColor Gray
        Write-Host "  gf    - git fetch" -ForegroundColor Gray
        Write-Host "  gr    - git rebase" -ForegroundColor Gray
        Write-Host "  gri   - git rebase -i" -ForegroundColor Gray
        Write-Host "  gca   - git commit --amend" -ForegroundColor Gray
        Write-Host "  gcane - git commit --amend --no-edit" -ForegroundColor Gray
        Write-Host "`nGit Functions:" -ForegroundColor Cyan
        Write-Host "  git-undo    - Undo last commit (keep changes)" -ForegroundColor Gray
        Write-Host "  git-unstage - Unstage files" -ForegroundColor Gray
        Write-Host "  git-discard - Discard changes (use with caution!)" -ForegroundColor Gray
        Write-Host "  git-aliases - Show this help" -ForegroundColor Gray
    }
}

# Utility functions
function mkcd {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Location -Path $Path
}

function touch {
    param([string]$Path)
    if (Test-Path $Path) {
        (Get-Item $Path).LastWriteTime = Get-Date
    } else {
        New-Item -ItemType File -Path $Path
    }
}

# Show all colors
function Show-Colors {
    $colors = [enum]::GetValues([System.ConsoleColor])
    Foreach ($bgcolor in $colors) {
        Foreach ($fgcolor in $colors) { 
            Write-Host "$fgcolor|" -ForegroundColor $fgcolor -BackgroundColor $bgcolor -NoNewline
        }
        Write-Host " on $bgcolor"
    }
}
#endregion

#region Completion and Key Bindings
# Configure PSReadLine if available
if (Get-Module -Name PSReadLine) {
    # Set prediction source
    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -PredictionViewStyle ListView
    
    # Key bindings
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    
    # Colors
    Set-PSReadLineOption -Colors @{
        Command = 'Cyan'
        Parameter = 'Gray'
        Operator = 'Gray'
        Variable = 'Green'
        String = 'Yellow'
        Number = 'Magenta'
        Type = 'Gray'
        Comment = 'DarkGray'
    }
}
#endregion

#region FZF Integration
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    # Set FZF default options
    $env:FZF_DEFAULT_OPTS = '--height 40% --layout=reverse --border'
    
    # Fuzzy file finder
    function ff {
        param([string]$Pattern = "")
        Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*$Pattern*" } |
            ForEach-Object { $_.FullName } |
            fzf
    }
    
    # Fuzzy directory finder
    function fd {
        param([string]$Pattern = "")
        Get-ChildItem -Recurse -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*$Pattern*" } |
            ForEach-Object { $_.FullName } |
            fzf | Set-Location
    }
}
#endregion

#region macOS Default Shell Setup
if ($IsMacOS) {
    function Set-PowerShellAsDefaultShell {
        [CmdletBinding(SupportsShouldProcess)]
        param([switch]$Force)
        
        $pwshPath = (Get-Command pwsh).Source
        
        # Check if pwsh is in /etc/shells
        $shells = Get-Content /etc/shells -ErrorAction SilentlyContinue
        if ($shells -notcontains $pwshPath) {
            Write-Host "PowerShell not found in /etc/shells. Adding it..." -ForegroundColor Yellow
            
            if ($PSCmdlet.ShouldProcess("/etc/shells", "Add PowerShell")) {
                try {
                    # Need elevated permissions
                    sudo sh -c "echo '$pwshPath' >> /etc/shells"
                    Write-Host "PowerShell added to /etc/shells" -ForegroundColor Green
                }
                catch {
                    Write-Error "Failed to add PowerShell to /etc/shells. Run with sudo or as admin."
                    return
                }
            }
        }
        
        # Get current shell
        $currentShell = $env:SHELL
        if ($currentShell -eq $pwshPath -and -not $Force) {
            Write-Host "PowerShell is already your default shell." -ForegroundColor Green
            return
        }
        
        # Change shell
        if ($Force -or $PSCmdlet.ShouldProcess($env:USER, "Change default shell to PowerShell")) {
            Write-Host "Changing default shell to PowerShell..." -ForegroundColor Cyan
            try {
                chsh -s $pwshPath
                Write-Host "Default shell changed to PowerShell!" -ForegroundColor Green
                Write-Host "Log out and back in for the change to take effect." -ForegroundColor Yellow
            }
            catch {
                Write-Error "Failed to change shell: $_"
            }
        }
    }
    
    # Check if we should suggest making PowerShell the default
    if ($env:SHELL -ne (Get-Command pwsh).Source) {
        Write-Host "`nTip: To make PowerShell your default shell, run:" -ForegroundColor DarkCyan
        Write-Host "  Set-PowerShellAsDefaultShell" -ForegroundColor Cyan
    }
}
#endregion

#region Final Setup
# Clean up any temporary variables
Remove-Variable -Name ForceInstall -Scope Script -ErrorAction SilentlyContinue

if (-not $script:ForceInstall) {
    Write-Host "`nPowerShell Profile Loaded - $($PSVersionTable.PSVersion)" -ForegroundColor Green
    Write-Host "Platform: $(if($IsMacOS){'macOS'}elseif($IsWindows){'Windows'}else{'Unix'})" -ForegroundColor Cyan
    Write-Host "Run 'Reset-PowerShellEnvironment' to reinstall all components" -ForegroundColor DarkGray
}
#endregion