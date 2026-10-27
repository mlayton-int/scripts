$URL = "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/2600221996/AcroRdrDCx642600221996_MUI.exe1"
$WorkingDirectory = "C:\scripts\scripts\"
$InstallerPath = $WorkingDirectory + "AdobeSetup.exe"

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
