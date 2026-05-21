#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys Microsoft 365 Apps (Outlook Classic) via the Office Deployment Tool (ODT).

.DESCRIPTION
    Downloads (or uses a local copy of) the Office Deployment Tool, writes a
    configuration XML scoped to Outlook Classic only, runs a silent Click-to-Run
    install, then sets registry keys to make Classic Outlook the default and
    suppress the "Try the new Outlook" toggle prompt.

    New Outlook remains available but is not set as the default.

    Exit codes:
        0    = Success
        1    = General failure
        2    = Prerequisite error (ODT not found, download failed)
        3    = Partial success (install OK but registry tuning failed)
        1603 = ODT install failed

.NOTES
    Author:  Deploy Automation
    Version: 1.0.1
    Tested:  Windows 10 21H2+, Windows 11

    References:
        ODT config reference : https://learn.microsoft.com/en-us/deployoffice/office-deployment-tool-configuration-options
        New Outlook registry  : https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/outlook-for-ios-and-android/new-outlook-for-windows
#>

# ==============================================================================
# CONFIGURATION -- edit these values before deploying
# ==============================================================================

# Path to setup.exe from the Office Deployment Tool.
# Download ODT from: https://www.microsoft.com/en-us/download/details.aspx?id=49117
# If the file does not exist at this path the script will attempt to download it.
$OdtSetupPath = Join-Path $PSScriptRoot "setup.exe"

# Path to the ODT configuration XML file.
# Place OutlookClassicInst.xml in the same folder as this script, or update the path.
$ConfigXmlPath = Join-Path $PSScriptRoot "OutlookClassicInst.xml"

# Path to write the deployment log.
$LogPath = "C:\INS-Temp\Logs\Install-OutlookClassic.log"

# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EXIT_SUCCESS      = 0
$EXIT_FAILURE      = 1
$EXIT_PREREQ_ERROR = 2
$EXIT_PARTIAL      = 3
$EXIT_ODT_FAILED   = 1603

$exitCode = $EXIT_SUCCESS
$tempDir  = $null

# -- Logging -------------------------------------------------------------------
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
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

Write-Log "===== Install-OutlookClassic started | Host: $env:COMPUTERNAME | User: $env:USERNAME ====="
Write-Log "OdtSetupPath  : $OdtSetupPath"
Write-Log "ConfigXmlPath : $ConfigXmlPath"

# -- Helper: check if Outlook is already installed ----------------------------
function Get-OutlookInstall {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $regPaths) {
        $found = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like "*Microsoft Outlook*" -or
                                $_.DisplayName -like "*Microsoft 365*" -or
                                $_.DisplayName -like "*Office 365*" }
        if ($found) { return $found }
    }
    return $null
}

# -- Helper: set registry value, creating key path if needed ------------------
function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = 'DWord'
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Write-Log "  Registry set: $Path\$Name = $Value ($Type)"
}

# -- Helper: apply Classic Outlook as default, suppress New Outlook prompt ----
function Set-ClassicOutlookDefault {
    try {
        Write-Log "Configuring Classic Outlook as default..."

        # Disable the auto-migration to New Outlook (0 = stay on Classic)
        Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\Options\General' `
                     -Name 'HideNewOutlookToggle' -Value 0 -Type DWord

        # Suppress "Try the new Outlook" toggle in the title bar (per-machine policy)
        Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Outlook\Options\General' `
                     -Name 'HideNewOutlookToggle' -Value 1 -Type DWord

        # Prevent automatic switch to New Outlook on first launch
        Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\Options\General' `
                     -Name 'DoNewOutlookAutoMigration' -Value 0 -Type DWord

        # Block New Outlook from being set as default via policy
        Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Outlook\Options\General' `
                     -Name 'DoNewOutlookAutoMigration' -Value 0 -Type DWord

        Write-Log "Classic Outlook registry configuration applied."
        return $true
    } catch {
        Write-Log "Failed to apply Classic Outlook registry settings: $_" -Level ERROR
        return $false
    }
}

# ==============================================================================
try {

    # 1. Check for existing Outlook install ------------------------------------
    $existing = Get-OutlookInstall
    if ($existing) {
        Write-Log "Existing Office/Outlook detected: $($existing.DisplayName) $($existing.DisplayVersion)"
        Write-Log "Proceeding to apply Classic Outlook registry settings only."

        $regOk = Set-ClassicOutlookDefault
        $exitCode = if ($regOk) { $EXIT_SUCCESS } else { $EXIT_PARTIAL }
        exit $exitCode
    }

    # 2. Locate or download ODT setup.exe --------------------------------------
    if (-not (Test-Path -LiteralPath $OdtSetupPath -PathType Leaf)) {
        Write-Log "ODT setup.exe not found at: $OdtSetupPath" -Level WARN
        Write-Log "Attempting to download ODT from Microsoft..."

        # The ODT self-extracts; we download the self-extractor then run it
        $odtDownloadUrl = "https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_19929-20062.exe"
        $tempDir = Join-Path $env:TEMP ("ODT_" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $odtDownloadPath = Join-Path $tempDir "odtsetup.exe"

        try {
            Write-Log "Downloading ODT to: $odtDownloadPath"
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($odtDownloadUrl, $odtDownloadPath)
            Write-Log "Download complete."
        } catch {
            Write-Log "Failed to download ODT: $_" -Level ERROR
            Write-Log "Please download setup.exe from https://www.microsoft.com/en-us/download/details.aspx?id=49117 and place it at: $OdtSetupPath"
            $exitCode = $EXIT_PREREQ_ERROR
            exit $exitCode
        }

        # Extract ODT self-extractor to temp dir
        Write-Log "Extracting ODT self-extractor..."
        $extractArgs = "/quiet /extract:`"$tempDir`""
        $extractProc = Start-Process -FilePath $odtDownloadPath -ArgumentList $extractArgs -Wait -PassThru -NoNewWindow
        if ($extractProc.ExitCode -ne 0) {
            Write-Log "ODT extraction failed. Exit code: $($extractProc.ExitCode)" -Level ERROR
            $exitCode = $EXIT_PREREQ_ERROR
            exit $exitCode
        }

        $OdtSetupPath = Join-Path $tempDir "setup.exe"
        if (-not (Test-Path $OdtSetupPath)) {
            Write-Log "setup.exe not found after ODT extraction in: $tempDir" -Level ERROR
            $exitCode = $EXIT_PREREQ_ERROR
            exit $exitCode
        }
        Write-Log "ODT setup.exe ready at: $OdtSetupPath"
    } else {
        Write-Log "ODT setup.exe found at: $OdtSetupPath"
    }

    # 3. Verify ODT configuration XML exists -----------------------------------
    if (-not (Test-Path -LiteralPath $ConfigXmlPath -PathType Leaf)) {
        Write-Log "ODT configuration XML not found: $ConfigXmlPath" -Level ERROR
        Write-Log "Place OutlookClassicInst.xml in the same folder as this script, or update ConfigXmlPath." -Level ERROR
        $exitCode = $EXIT_PREREQ_ERROR
        exit $exitCode
    }
    Write-Log "ODT configuration XML found: $ConfigXmlPath"

    # 4. Run ODT install -------------------------------------------------------
    Write-Log "Starting ODT install. This may take 10-20 minutes depending on connection speed..."
    $odtArgs = "/configure `"$ConfigXmlPath`""
    Write-Log "ODT command: $OdtSetupPath $odtArgs"

    $odtLog   = "C:\INS-Temp\Logs\ODT-Install.log"
    $procParams = @{
        FilePath     = $OdtSetupPath
        ArgumentList = $odtArgs
        Wait         = $true
        PassThru     = $true
        NoNewWindow  = $true
        ErrorAction  = 'Stop'
    }

    $proc     = Start-Process @procParams
    $odtExit  = $proc.ExitCode

    Write-Log "ODT process exited with code: $odtExit"

    if ($odtExit -ne 0) {
        Write-Log "ODT install failed (exit $odtExit). Check ODT log at: $odtLog" -Level ERROR
        Write-Log "Common causes: no internet access, existing incompatible Office install, or disk space." -Level ERROR
        $exitCode = $EXIT_ODT_FAILED
        exit $exitCode
    }

    Write-Log "ODT install completed successfully."

    # 5. Verify Outlook installed ----------------------------------------------
    Write-Log "Verifying installation..."
    $outlookExe = "${env:ProgramFiles}\Microsoft Office\root\Office16\OUTLOOK.EXE"
    if (Test-Path $outlookExe) {
        $ver = (Get-Item $outlookExe).VersionInfo.FileVersion
        Write-Log "Outlook Classic verified: $outlookExe (version $ver)"
    } else {
        Write-Log "OUTLOOK.EXE not found at expected path: $outlookExe" -Level WARN
        Write-Log "Install may have used a different path - check manually." -Level WARN
    }

    # 6. Set Classic Outlook as default ----------------------------------------
    $regOk = Set-ClassicOutlookDefault
    if (-not $regOk) {
        Write-Log "Install succeeded but registry tuning failed." -Level WARN
        $exitCode = $EXIT_PARTIAL
    } else {
        Write-Log "All steps completed successfully."
        $exitCode = $EXIT_SUCCESS
    }

} catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    # Cleanup temp ODT download dir if we created one
    if ($null -ne $tempDir -and (Test-Path $tempDir)) {
        try {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Temp directory cleaned up: $tempDir"
        } catch {
            Write-Log "Could not remove temp dir: $_" -Level WARN
        }
    }

    Write-Log "===== Install-OutlookClassic finished. Exit code: $exitCode ====="
    exit $exitCode
}
