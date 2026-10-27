$URL = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"

# Regex matched against each release asset's file name. Single-quote it so PowerShell
# does not expand the trailing '$' anchor as a variable.
$AssetPattern = '\.msixbundle$'

# GitHub's documented media type for the REST API. Selects the stable JSON
# representation instead of relying on the server default.
$Headers = @{
    'Accept' = 'application/vnd.github+json'
}

# Optional. Raises the rate limit from 60 to 5,000 requests/hour. Set the
# environment variable; never hardcode a token in this file. Deliberately not
# passed to the asset download below - that URL is pre-signed and rejects it.
if ($env:GITHUB_TOKEN) {
    $Headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}

$ErrorActionPreference = 'Stop'
try {
    $release = Invoke-RestMethod -Uri $URL -Headers $Headers -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No release asset matching '$AssetPattern' found at $URL" }
    $asset.browser_download_url
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile 'WinGetInstaller.msixbundle' -UseBasicParsing
}
catch {
    # Only web exceptions carry a Response. The asset-not-found throw above, and
    # DNS/TLS/disk failures, do not - fall through to the plain message for those.
    $resp = $_.Exception.Response
    if ($resp -and $resp.StatusCode) {
        $code  = [int]$resp.StatusCode
        $left  = $resp.Headers['x-ratelimit-remaining']
        $reset = $resp.Headers['x-ratelimit-reset']
        if (($code -eq 403 -or $code -eq 429) -and $left -eq '0') {
            $when = if ($reset) {
                [DateTimeOffset]::FromUnixTimeSeconds([int64]$reset).ToLocalTime().ToString('g')
            }
            else { 'an unknown time' }
            Write-Error "GitHub rate limit exhausted for this IP. Resets at $when. Set the GITHUB_TOKEN environment variable to raise the limit from 60 to 5,000 requests/hour."
        }
        else {
            Write-Error "HTTP $code from $URL -- $($_.Exception.Message)"
        }
    }
    else {
        Write-Error $_.Exception.Message
    }
    exit 1
}