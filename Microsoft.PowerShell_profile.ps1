winfetch
# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

Import-Module -Name Terminal-Icons

oh-my-posh --init --shell pwsh --config ~/AppData/Local/Programs/oh-my-posh/themes/1_shell.omp.json | Invoke-Expression

function ssh-copy-id([string]$sshHost)
{
    cat ~/.ssh/id_rsa.pub | ssh "$sshHost" "mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod -R go= ~/.ssh && cat >> ~/.ssh/authorized_keys"
}

function Reset-PowerShellSession {
  [CmdletBinding()]
  param(
      [Parameter()]
      [switch]$Force
  )

  # Get all loaded assemblies
  $loadedAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies()

  # Get all modules
  $loadedModules = Get-Module

  Write-Host "Currently loaded assemblies: $($loadedAssemblies.Count)" -ForegroundColor Yellow
  Write-Host "Currently loaded modules: $($loadedModules.Count)" -ForegroundColor Yellow

  if ($Force -or $PSCmdlet.ShouldContinue("Are you sure you want to reset the PowerShell session?", "Reset Session")) {
      # Remove all modules
      $loadedModules | Remove-Module -Force

      # Clear the assembly cache
      [System.AppDomain]::CurrentDomain.SetData("AssemblyCache", $null)
      [System.GC]::Collect()
      [System.GC]::WaitForPendingFinalizers()

      Write-Host "Session reset complete. You may need to restart PowerShell for all changes to take effect." -ForegroundColor Green
  }
}

function Reset-DevModule {
  [CmdletBinding()]
  param (
      [Parameter(Mandatory = $false)]
      [string]$ModulePath = "C:\Path\To\Your\Module",  # Set your default path here

      [Parameter(Mandatory = $false)]
      [switch]$Force
  )

  if (Test-Path $ModulePath\dev-loader.ps1) {
      Write-Host "Reloading development module..." -ForegroundColor Cyan
      . $ModulePath\dev-loader.ps1 -Force:$Force
  }
  else {
      Write-Error "Development loader not found at: $ModulePath\dev-loader.ps1"
  }
}

# Create an alias for even quicker access
Set-Alias -Name rdev -Value Reset-DevModule





