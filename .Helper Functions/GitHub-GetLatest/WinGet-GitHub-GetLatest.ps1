$URL = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"

# Regex matched against each release asset's file name. Single-quote it so PowerShell
# does not expand the trailing '$' anchor as a variable.
$AssetPattern = '\.msixbundle$'

$ErrorActionPreference = 'Stop'
#[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    $release = Invoke-RestMethod -Uri $URL -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No release asset matching '$AssetPattern' found at $URL" }
    $asset.browser_download_url
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile 'WinGetInstaller.msixbundle' -UseBasicParsing
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}