#Requires -RunAsAdministrator

# Check administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# Define log file
$logFile = "C:\INS-Temp\veeam_uninstall_log.txt"

function Log {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp - $args"
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

Log "`n`n========== Script Started =========="

do {
    $veeamPrograms = Get-VeeamPrograms -ExcludeKeywords $excludeList

    if ($veeamPrograms.Count -eq 0) {
        Write-Host "No matching Veeam-related programs found."
        Log "No matching Veeam-related programs found. Exiting."
        exit
    }

    Write-Host "`nFound the following Veeam-related programs:"
    $veeamPrograms | ForEach-Object {
        Write-Host "- $($_.DisplayName)"
    }

    Write-Host "`nOptions:"
    Write-Host "Y - Yes, uninstall all listed programs"
    Write-Host "N - No, cancel"
    Write-Host "E - Enter keywords to exclude and rerun the search"

    $choice = Read-Host "Enter your choice (Y/N/E)"

    if ($choice -match '^[Ee]$') {
        $excludeInput = Read-Host "Enter words to exclude (comma-separated)"
        $excludeList = $excludeInput -split "," | ForEach-Object { $_.Trim() }
        Write-Host "Excluding programs with keywords: $($excludeList -join ', ')"
    }

} until ($choice -match '^[YyNn]$')

if ($choice -match '^[Nn]$') {
    Write-Host "Aborted by user."
    Log "User aborted the uninstall operation."
    exit
}

# Proceed with uninstalling
foreach ($app in $veeamPrograms) {
    $displayName = $app.DisplayName
    $productCode = $app.PSChildName

    Write-Host "Uninstalling: $displayName"
    Log "Uninstalling: $displayName"

    try {
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $productCode /quiet /norestart" -Wait -ErrorAction Stop
        Log "SUCCESS: $displayName uninstalled"
    } catch {
        Log "ERROR: Failed to uninstall $displayName. $_"
        Write-Host "Failed to uninstall $displayName. See log for details."
    }
}

Log "========== Script Ended ==========`n"