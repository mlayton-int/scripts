# Define log file
$logFile = "C:\INS-Temp\veeam_uninstall_log.txt"

function Log {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp - $args"
    Write-Host $args
}
function Get-VeeamPrograms {
    param (
        [string[]]$ExcludeKeywords = @()
    )

    $uninstallPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $programs = @()

    foreach ($path in $uninstallPaths) {
        $found = Get-ItemProperty $path | Where-Object { $_.DisplayName -like "*veeam*" }

        if ($ExcludeKeywords.Count -gt 0) {
            $found = $found | Where-Object {
                $excludeMatch = $false
                foreach ($kw in $ExcludeKeywords) {
                    if ($_.DisplayName -like "*$kw*") {
                        $excludeMatch = $true
                        break
                    }
                }
                return -not $excludeMatch
            }
        }

        $programs += $found
    }

    return $programs
}

# Begin main script

$excludeList = @()

Log "`n`n Script Started: "
Log "Searching for Veeam services to disable."

$services = Get-WmiObject -Class Win32_Service |
    Where-Object { $_.State -eq 'Running' -and $_.Description -like '*Veeam*' }

if ($services.Count -eq 0) {
    Log "No running services found with 'Veeam' in the description."
}
else {
    # List all matching services
    Log "`nFound the following running services with 'Veeam' in the description:"
    $services | ForEach-Object {
        Log "Name: $($_.Name)"
    }

    # Prompt once
    $response = Read-Host "Do you want to stop ALL of these services? (Y/N)"

    if ($response -match '^[Yy]$') {
        foreach ($svc in $services) {
            Log "Stopping service: $($svc.Name)..."
            try {
                $result = $svc.StopService()
                if ($result.ReturnValue -eq 0) {
                    Log "Successfully stopped: $($svc.Name)"
                } 
                else {
                    Log "Failed to stop: $($svc.Name) (ReturnValue: $($result.ReturnValue))"
                }
            } catch {
                Log "Error stopping service $($svc.Name): $($_.Exception.Message)"
            }
        }
    } 
    else {
        Log "No services were stopped."
    }
}

Log "Beginning uninstall process.."

do {
    $veeamPrograms = Get-VeeamPrograms -ExcludeKeywords $excludeList

    if ($veeamPrograms.Count -eq 0) {
        Log "No matching Veeam-related programs found. Exiting."
        exit
    }

    Log "`nFound the following Veeam-related programs:"
    $veeamPrograms | ForEach-Object {
        Log "- $($_.DisplayName)"
    }

    Write-Host "`nOptions:"
    Write-Host "Y - Yes, uninstall all listed programs"
    Write-Host "N - No, cancel"
    Write-Host "E - Enter keywords to exclude and rerun the search"

    $choice = Read-Host "Enter your choice (Y/N/E)"

    if ($choice -match '^[Ee]$') {
        $excludeInput = Read-Host "Enter words to exclude (comma-separated)"
        $excludeList = $excludeInput -split "," | ForEach-Object { $_.Trim() }
        Log "Excluding programs with keywords: $($excludeList -join ', ')"
    }

} until ($choice -match '^[YyNn]$')

if ($choice -match '^[Nn]$') {
    Log "User aborted the uninstall operation."
    exit
}

# Proceed with uninstalling
foreach ($app in $veeamPrograms) {
    $displayName = $app.DisplayName
    $productCode = $app.PSChildName

    Log "Uninstalling: $displayName"

    try {
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $productCode /quiet /norestart" -Wait -ErrorAction Stop
        Log "SUCCESS: $displayName uninstalled"
    } catch {
        Log "ERROR: Failed to uninstall $displayName. $_"
    }
}

Log "Script End`n"