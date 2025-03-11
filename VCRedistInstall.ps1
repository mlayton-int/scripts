$WorkingDirectory = "C:\Github\scripts\VSRedistrib"
$vc_redistx64Uri = "https://aka.ms/vs/17/release/vc_redist.x64.exe"

# Test connection to download link
try
{
    $Response = Invoke-WebRequest -Uri $vc_redistx64Uri
    $StatusCode = $Response.StatusCode
} catch {
    $StatusCode = $_.Exception.Response
}

Write-Host "Connection Status:" $StatusCode

# Download installer file

Invoke-WebRequest -Uri $vc_redistx64Uri -OutFile "vc_redist.x64.exe"

.\vc_redist.x64.exe /install /norestart /log InstallLog.txt