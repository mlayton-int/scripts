#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets the machine-wide interactive logon inactivity lock timeout.

.DESCRIPTION
    Sets HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs
    to the configured number of seconds. Creates the registry key/value if they don't already
    exist, and safely updates the value if it does.

    Exits with code 0 on success, 1 on failure.

.NOTES
    Registry key set:
        HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs
#>

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - edit these values before deploying
# ══════════════════════════════════════════════════════════════════════════════

$RegPath        = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$ValueName      = "InactivityTimeoutSecs"
$TimeoutSeconds = 0

# Path to write the deployment log.
$LogPath = "C:\INS-Temp\SetScreenLock.log"

# ── Exit codes ────────────────────────────────────────────────────────────────
$EXIT_SUCCESS = 0
$EXIT_FAILURE = 1

$exitCode = $EXIT_SUCCESS

# ── Logging ───────────────────────────────────────────────────────────────────
$logDir = Split-Path $LogPath -Parent
try {
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
} catch {
    Write-Error "Failed to create log directory '$logDir': $_"
    exit $EXIT_FAILURE
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Error   $Message }
        'WARN'  { Write-Warning $Message }
        'DEBUG' { Write-Verbose $Message }
        default { Write-Output  $Message }
    }
}

Write-Log "===== SetScreenLock started | Host: $env:COMPUTERNAME | User: $env:USERNAME ====="
Write-Log "RegPath        : $RegPath"
Write-Log "ValueName      : $ValueName"
Write-Log "TimeoutSeconds : $TimeoutSeconds"

# ── Helper: set registry value, creating key path if needed ──────────────────
function Set-RegValue {
    param([string]$Path, [string]$Name, [object]$Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Write-Log "  Registry set: $Path\$Name = $Value ($Type)"
}

# ═════════════════════════════════════════════════════════════════════════════
try {
    $ErrorActionPreference = 'Stop'

    if (Test-Path $RegPath) {
        Write-Log "Registry key already exists: $RegPath"
    } else {
        Write-Log "Registry key does not exist, will be created: $RegPath"
    }

    $existing = Get-ItemProperty -Path $RegPath -Name $ValueName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-Log "Value '$ValueName' does not exist, creating with $TimeoutSeconds."
    } elseif ($existing.$ValueName -eq $TimeoutSeconds) {
        Write-Log "Value '$ValueName' already set to $TimeoutSeconds. No change needed."
    } else {
        Write-Log "Value '$ValueName' currently $($existing.$ValueName), updating to $TimeoutSeconds."
    }

    Set-RegValue -Path $RegPath -Name $ValueName -Value $TimeoutSeconds -Type DWord
    Write-Log "Interactive logon: Machine inactivity limit set to $TimeoutSeconds seconds."

    Invoke-GPUpdate -Force
 
    $exitCode = $EXIT_SUCCESS

} catch {
    Write-Log "Failed to set inactivity timeout: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    Write-Log "===== SetScreenLock finished. Exit code: $exitCode ====="
    exit $exitCode
}
