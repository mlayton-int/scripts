$WorkingDirectory = "C:\INS-Temp\VC_Redist"
$VCRx64Uri = "https://aka.ms/vs/17/release/vc_redist.x64.exe"

# CD to working directory
Set-Location $WorkingDirectory

# Download VCR installer and returns connection status
try
{
    $Response = Invoke-WebRequest -Uri $VCRx64Uri
    $StatusCode = "$($Response.StatusCode) $($Response.StatusDescription)"
} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
}

Write-Host "Connection Status:" "$StatusCode"

# Check if the registry key for VCR already exists. If so, check if the "Installed" value of the key is true
$X64RegKeyExist = Test-Path -Path  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"

switch ($X64RegKeyExist) {
    False { Write-Host "VCR is not installed";     $IsInstalled = 0;     break }
    True { $IsInstalled = Get-ItemPropertyValue -Path  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" -Name Installed}
}

# Determine whether to update existing install, or if lastest is already installed
if ($IsInstalled -eq 1) {
    # Get the version of the installer
    $InstallerVersion = (Get-ItemProperty .\vc_redist.x64.exe).VersionInfo.FileVersion
    Write-Host "Version of installer file:" $InstallerVersion
    # Get the version number of existing installation
    $ExistingVersion = Get-ItemPropertyValue -Path  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" -Name Version
    # Remove leading "v" from the version number so we can compare versions properly later
    $ExistingVersion = $ExistingVersion.Substring(1)
    # Since the method we use to pull the version number of the existing installation can add an extra to the end (eg. "14.42.00" instead of "14.42.0") we have to match the lengths to compare versions properly
    $VersionLengthDif = $ExistingVersion.Length - $InstallerVersion.Length
    if ($VersionLengthDif -gt 0) {
        $ExistingVersion = $ExistingVersion.Substring(0, $ExistingVersion.Length - $VersionLengthDif)
    }

}

switch ($true) {
    ($ExistingVersion -eq $InstallerVersion) { 
        Write-Host "Latest version is already installed."
        Break
    }

    ($ExistingVersion -gt $InstallerVersion) {
        Write-Host "A newer version of VCR is already installed."
        Break
    }
    
    ($ExistingVersion -lt $InstallerVersion) { 
        Write-Host "A newer version of VCR is available to install. Beginning installation.."
        .\vc_redist.x64.exe /install /quiet /norestart /log InstallLog.txt
        Break
    }

    ($IsInstalled -eq 0) {
        Write-Host "No existing installation found. Beginning installation.."
        .\vc_redist.x64.exe /install /quiet /norestart /log InstallLog.txt
        Break
    }
}
