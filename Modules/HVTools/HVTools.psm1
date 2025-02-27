#region Get public and private function definition files.
$Public = @(Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue)
$cfg = Get-Content "$env:USERPROFILE\.hvtoolscfgpath" -ErrorAction SilentlyContinue
$script:tick = [char]0x221a

if ($cfg) {
    $script:hvConfig = if (Get-Content -Path $cfg -raw -ErrorAction SilentlyContinue) {
        Get-Content -Path $cfg -raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    }
    else {
        $script:hvConfig = $null
    }
}
#endregion

#region Dot source the files
foreach ($import in @($Public + $Private)) {
    try {
        . $import.FullName
    }
    catch {
        Write-Error -Message "Failed to import function $($import.FullName): $_"
    }
}
#endregion

#region Export Public Functions
Export-ModuleMember -Function $Public.BaseName
#endregion