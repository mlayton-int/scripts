$WorkingDirectory = "C:\INS-Temp\VC_Redist"
$vc_redistx64Uri = "https://aka.ms/vs/17/release/vc_redist.x64.exe"

Set-Location $WorkingDirectory

Test-Path -Path  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"

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

.\vc_redist.x64.exe /install /passive /norestart /log InstallLog.txt