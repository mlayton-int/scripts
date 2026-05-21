$URL = "https://downloadplugins.citrix.com/ReceiverUpdates/Prod/Receiver/Win/CitrixWorkspaceApp24.2.3001.9.exe1"
$WorkingDirectory = "C:\scripts\scripts\"
$InstallerPath = $WorkingDirectory + "CitrixWorkspaceApp.exe"
$RegKeyPath = "HKLM:\SOFTWARE\Citrix\Secure Access Endpoint Analysis"


try {
    $Response = (Invoke-WebRequest -Uri $URL -Method Head -UseBasicParsing -ErrorAction Stop) | Select-Object -Property StatusCode, StatusDescription
    Write-Host "Connecting to download URL returned $($Response.StatusCode) $($Response.StatusDescription)"
}
catch { 
    Write-Host "Error when connecting to download URL: $($_.Exception.Response.StatusCode.value__) $($_.Exception.Response.StatusDescription.value__)"
    exit 1
}



$webClient = New-Object System.Net.WebClient
$webClient.DownloadFile($URL, $InstallerPath)

# Move to working directory if not already there
if ($PWD.Path -ne $WorkingDirectory) {
    Set-Location -Path $WorkingDirectory
}

# Check if program is already installed 
$X64RegKeyExist = Test-Path -Path $RegKeyPath

switch ($X64RegKeyExist) {
    False { Write-Host "VCR is not installed";     $IsInstalled = 0;     break }
    True { Write-Host "VCR is installed";     $IsInstalled = 1;     $InstalledVersion = Get-ItemPropertyValue -Path  $RegKeyPath -Name ProductVersion;     Write-Host $InstalledVersion}
}


