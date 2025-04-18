
function Get-TimeStamp {
    
    return "[{0:MM-dd-yyyy}][T{0:HH:mm:ss}]" -f (Get-Date)
    
}

Write-Host $(Get-TimeStamp)

# Check administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}