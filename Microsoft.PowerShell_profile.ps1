# Updated on 2023-10-12
# Made changes to the profile to remove bad references and added neofetch, oh-my-posh, and other assets that I want to configure all my machines with.

function Get-VMIPAddresses {
[CmdletBinding()]
param
(
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
	[String]$Type,

	[Parameter(ValueFromPipelineByPropertyName=$true)]
	[Switch]$IgnoreAPIPA=$false
)

BEGIN {
	New-Variable -Name DefaultType -Value "Any" -Option Constant # Change to IPv4 or IPv6 if desired
}

PROCESS {
	if([String]::IsNullOrEmpty($Type))
	{
		$Type = $DefaultType
	}
	if($VM)
	{
		$ParameterSet = @{ 'VM'=$VM }
	}
	else
	{
		$ParameterSet = @{ 'VMName'="$Name"; 'ComputerName'="$ComputerName" }
	}
	$IPAddresses = (Get-VMNetworkAdapter @ParameterSet).IPAddresses
	switch($Type)
	{
		"IPv4" {
			$IPAddresses = $IPAddresses | where { $_ -match "\." }
		}
		"IPv6" {
			$IPAddresses = $IPAddresses | where { $_ -match ":" }
		}
	}
	if($IgnoreAPIPA)
	{
		$IPAddresses = $IPAddresses | where { $_ -notmatch "^(169.254)|(fe80)" }
	}
	$IPAddresses
}

END {}

}

function New-ISOFile {
  <#
  .SYNOPSIS
      Create an ISO file from a source folder.

  .DESCRIPTION
      Create an ISO file from a source folder.
      Optionally speicify a boot image and media type.

      Based on original function by Chris Wu.
      https://gallery.technet.microsoft.com/scriptcenter/New-ISOFile-function-a8deeffd (link appears to be no longer valid.)

      Changes:
          - Updated to work with PowerShell 7
          - Added a bit more error handling and verbose output.
          - Features removed to simplify code:
              * Clipboard support.
              * Pipeline input.

  .PARAMETER source
      The source folder to add to the ISO.

  .PARAMETER destinationIso
      The ISO file to create.

  .PARAMETER bootFile
      Optional. Boot file to add to the ISO.

  .PARAMETER media
      Optional. The media type of the resulting ISO (BDR, CDR etc). Defaults to DVDPLUSRW_DUALLAYER.

  .PARAMETER title
      Optional. Title of the ISO file. Defaults to "untitled".

  .PARAMETER force
      Optional. Force overwrite of an existing ISO file.

  .INPUTS
      None.

  .OUTPUTS
      None.

  .EXAMPLE
      New-ISOFile -source c:\forIso\ -destinationIso C:\ISOs\testiso.iso

      Simple example. Create testiso.iso with the contents from c:\forIso

  .EXAMPLE
      New-ISOFile -source f:\ -destinationIso C:\ISOs\windowsServer2019Custom.iso -bootFile F:\efi\microsoft\boot\efisys.bin -title "Windows2019"

      Example building Windows media. Add the contents of f:\ to windowsServer2019Custom.iso. Use efisys.bin to make the disc bootable.

  .LINK

  .NOTES
      01           Alistair McNair          Initial version.

  #>
  [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="Low")]
  Param
  (
      [parameter(Mandatory=$true,ValueFromPipeline=$false)]
      [string]$source,
      [parameter(Mandatory=$true,ValueFromPipeline=$false)]
      [string]$destinationIso,
      [parameter(Mandatory=$false,ValueFromPipeline=$false)]
      [string]$bootFile = $null,
      [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
      [ValidateSet("CDR","CDRW","DVDRAM","DVDPLUSR","DVDPLUSRW","DVDPLUSR_DUALLAYER","DVDDASHR","DVDDASHRW","DVDDASHR_DUALLAYER","DISK","DVDPLUSRW_DUALLAYER","BDR","BDRE")]
      [string]$media = "DVDPLUSRW_DUALLAYER",
      [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
      [string]$title = "untitled",
      [Parameter(Mandatory=$false,ValueFromPipeline=$false)]
      [switch]$force
    )

  begin {

      Write-Verbose ("Function start.")

  } # begin

  process {

      Write-Verbose ("Processing nested system " + $vmName)

      ## Set type definition
      Write-Verbose ("Adding ISOFile type.")

      $typeDefinition = @'
      public class ISOFile  {
          public unsafe static void Create(string Path, object Stream, int BlockSize, int TotalBlocks) {
              int bytes = 0;
              byte[] buf = new byte[BlockSize];
              var ptr = (System.IntPtr)(&bytes);
              var o = System.IO.File.OpenWrite(Path);
              var i = Stream as System.Runtime.InteropServices.ComTypes.IStream;

              if (o != null) {
                  while (TotalBlocks-- > 0) {
                      i.Read(buf, BlockSize, ptr); o.Write(buf, 0, bytes);
                  }

                  o.Flush(); o.Close();
              }
          }
      }
'@

      ## Create type ISOFile, if not already created. Different actions depending on PowerShell version
      if (!('ISOFile' -as [type])) {

          ## Add-Type works a little differently depending on PowerShell version.
          ## https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/add-type
          switch ($PSVersionTable.PSVersion.Major) {

              ## 7 and (hopefully) later versions
              {$_ -ge 7} {
                  Write-Verbose ("Adding type for PowerShell 7 or later.")
                  Add-Type -CompilerOptions "/unsafe" -TypeDefinition $typeDefinition
              } # PowerShell 7

              ## 5, and only 5. We aren't interested in previous versions.
              5 {
                  Write-Verbose ("Adding type for PowerShell 5.")
                  $compOpts = New-Object System.CodeDom.Compiler.CompilerParameters
                  $compOpts.CompilerOptions = "/unsafe"

                  Add-Type -CompilerParameters $compOpts -TypeDefinition $typeDefinition
              } # PowerShell 5

              default {
                  ## If it's not 7 or later, and it's not 5, then we aren't doing it.
                  throw ("Unsupported PowerShell version.")

              } # default

          } # switch

      } # if


      ## Add boot file to image
      if ($bootFile) {

          Write-Verbose ("Optional boot file " + $bootFile + " has been specified.")

          ## Display warning if Blu Ray media is used with a boot file.
          ## Not sure why this doesn't work.
          if(@('BDR','BDRE') -contains $media) {
                  Write-Warning ("Selected boot image may not work with BDR/BDRE media types.")
          } # if

          if (!(Test-Path -Path $bootFile)) {
              throw ($bootFile + " is not valid.")
          } # if

          ## Set stream type to binary and load in boot file
          Write-Verbose ("Loading boot file.")

          try {
              $stream = New-Object -ComObject ADODB.Stream -Property @{Type=1} -ErrorAction Stop
              $stream.Open()
              $stream.LoadFromFile((Get-Item -LiteralPath $bootFile).Fullname)

              Write-Verbose ("Boot file loaded.")
          } # try
          catch {
              throw ("Failed to open boot file. " + $_.exception.message)
          } # catch


          ## Apply the boot image
          Write-Verbose ("Applying boot image.")

          try {
              $boot = New-Object -ComObject IMAPI2FS.BootOptions -ErrorAction Stop
              $boot.AssignBootImage($stream)

              Write-Verbose ("Boot image applied.")
          } # try
          catch {
              throw ("Failed to apply boot file. " + $_.exception.message)
          } # catch


          Write-Verbose ("Boot file applied.")

      }  # if

      ## Build array of media types
      $mediaType = @(
          "UNKNOWN",
          "CDROM",
          "CDR",
          "CDRW",
          "DVDROM",
          "DVDRAM",
          "DVDPLUSR",
          "DVDPLUSRW",
          "DVDPLUSR_DUALLAYER",
          "DVDDASHR",
          "DVDDASHRW",
          "DVDDASHR_DUALLAYER",
          "DISK",
          "DVDPLUSRW_DUALLAYER",
          "HDDVDROM",
          "HDDVDR",
          "HDDVDRAM",
          "BDROM",
          "BDR",
          "BDRE"
      )

      Write-Verbose ("Selected media type is " + $media + " with value " + $mediaType.IndexOf($media))

      ## Initialise image
      Write-Verbose ("Initialising image object.")
      try {
          $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage -Property @{VolumeName=$title} -ErrorAction Stop
          $image.ChooseImageDefaultsForMediaType($mediaType.IndexOf($media))

          Write-Verbose ("initialised.")
      } # try
      catch {
          throw ("Failed to initialise image. " + $_.exception.Message)
      } # catch


      ## Create target ISO, throw if file exists and -force parameter is not used.
      if ($PSCmdlet.ShouldProcess($destinationIso)) {

          if (!($targetFile = New-Item -Path $destinationIso -ItemType File -Force:$Force -ErrorAction SilentlyContinue)) {
              throw ("Cannot create file " + $destinationIso + ". Use -Force parameter to overwrite if the target file already exists.")
          } # if

      } # if


      ## Get source content from specified path
      Write-Verbose ("Fetching items from source directory.")
      try {
          $sourceItems = Get-ChildItem -LiteralPath $source -ErrorAction Stop
          Write-Verbose ("Got source items.")
      } # try
      catch {
          throw ("Failed to get source items. " + $_.exception.message)
      } # catch


      ## Add these to our image
      Write-Verbose ("Adding items to image.")

      foreach($sourceItem in $sourceItems) {

          try {
              $image.Root.AddTree($sourceItem.FullName, $true)
          } # try
          catch {
              throw ("Failed to add " + $sourceItem.fullname + ". " + $_.exception.message)
          } # catch

      } # foreach

      ## Add boot file, if specified
      if ($boot) {
          Write-Verbose ("Adding boot image.")
          $Image.BootImageOptions = $boot
      }

      ## Write out ISO file
      Write-Verbose ("Writing out ISO file to " + $targetFile)

      try {
          $result = $image.CreateResultImage()
          [ISOFile]::Create($targetFile.FullName,$result.ImageStream,$result.BlockSize,$result.TotalBlocks)
      } # try
      catch {
          throw ("Failed to write ISO file. " + $_.exception.Message)
      } # catch

      Write-Verbose ("File complete.")

      ## Return file details
      return $targetFile

  } # process

  end {
      Write-Verbose ("Function complete.")
  } # end

} 

function Get-AllVMIPAddresses {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [ValidateSet("Any", "IPv4", "IPv6")]
        [String]$Type,
    
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [Switch]$IgnoreAPIPA=$false,
    
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [String]$ComputerName = $env:COMPUTERNAME
    )
    
    BEGIN {
        New-Variable -Name DefaultType -Value "Any" -Option Constant
    }
    
    PROCESS {
        if([String]::IsNullOrEmpty($Type)) {
            $Type = $DefaultType
        }
    
        # Get all VMs
        $VMs = Get-VM -ComputerName $ComputerName
    
        foreach($VM in $VMs) {
            $IPAddresses = (Get-VMNetworkAdapter -VM $VM).IPAddresses
    
            # Filter IPs based on type
            switch($Type) {
                "IPv4" {
                    $IPAddresses = $IPAddresses | Where-Object { $_ -match "\." }
                }
                "IPv6" {
                    $IPAddresses = $IPAddresses | Where-Object { $_ -match ":" }
                }
            }
    
            # Filter out APIPA addresses if specified
            if($IgnoreAPIPA) {
                $IPAddresses = $IPAddresses | Where-Object { $_ -notmatch "^(169.254)|(fe80)" }
            }
    
            # Create custom object for output
            [PSCustomObject]@{
                VMName = $VM.Name
                State = $VM.State
                IPAddresses = if($IPAddresses) { $IPAddresses -join ', ' } else { 'No IP Addresses' }
            }
        }
    }
    
    END {}
    }
# Check if Terminal-Icons module is installed and install if not installed
if (-not (Get-Module -ListAvailable -Name Terminal-Icons)) {
    Write-Host "Terminal-Icons module not found. Installing..."
    Install-Module -Name Terminal-Icons -Repository PSGallery -Scope CurrentUser -Force
} else {
    Write-Host "Terminal-Icons module is already installed."
}
Import-Module -Name Terminal-Icons

# Check if winget packages are installed and install if not installed
$packages = @("NeoFetch", "git.git")
foreach ($package in $packages) {
    Write-Host "Checking if $package is installed..." -ForegroundColor Cyan
    if (-not (winget list --source winget | Select-String -Pattern $package)) {
        Write-Host "Installing $package..."
        winget install $package --source winget | Out-Null
    } else {
        Write-Host "$package is already installed." -ForegroundColor Green
    }
}

# Check if neofetch is installed and install if not installed
neofetch.exe

# Check if oh-my-posh is installed and install if not installed
oh-my-posh --init --shell pwsh --config ~/AppData/Local/Programs/oh-my-posh/themes/blue-owl.omp.json | Invoke-Expression


# Note:
#   This function assumes that the local SSH public key is located at ~/.ssh/id_rsa.pub.
#   Ensure that SSH is installed and configured on both the local and remote machines.
function ssh-copy-id([string]$sshHost)
{
    cat ~/.ssh/id_rsa.pub | ssh "$sshHost" "mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod -R go= ~/.ssh && cat >> ~/.ssh/authorized_keys"
}





