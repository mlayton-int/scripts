# Creating time stamps
function Get-TimeStamp {
    
    return "[{0:MM-dd-yyyy}][T{0:HH:mm:ss}]" -f (Get-Date)
    
}

Write-Host $(Get-TimeStamp)

# Define log file
$logFile = "C:\INS-Temp\veeam_uninstall_log.txt"

function Log {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "$timestamp - $args"
    Write-Host $args
}


# Check administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

# Check administrator privileges & prompt to rerun as admin if needed
function ElevationCheck {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        Write-Host "This script requires administrator privileges." -ForegroundColor Yellow
        $response = Read-Host "Do you want to restart this script as Administrator? (Y/N)"
        
        if ($response -match '^[Yy]$') {
            # Get the current script path
            $scriptPath = $MyInvocation.MyCommand.Definition

            # Start a new PowerShell process as admin
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs

            # Exit the current non-admin script
            exit
        }
        else {
            Write-Host "Exiting script. Please run as Administrator if required." -ForegroundColor Red
            exit 1
        }
    }
}

Select-Object