#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleans up stale Autodesk Revit Collaboration Cache files for every local user
    profile on a workstation.

.DESCRIPTION
    Scans each local user profile's Revit Collaboration Cache folder(s) and deletes
    files older than $MaxAgeDays; locked files are logged as warnings and skipped.
    $MinSpaceToFreeGB gates deletion: if less than that is reclaimable, nothing is
    deleted and the script exits 4 (0 = always clean). Set $ReportOnly to $true to log
    what would be freed without deleting anything (always exits 0). Otherwise exits 0 on
    success, 3 on partial failure, 1 on total failure, 2 on prerequisite errors.

.NOTES
    Cache path pattern cleaned:
        <ProfileRoot>\<profile>\AppData\Local\Autodesk\Revit\Autodesk Revit *\CollaborationCache

    <ProfileRoot> defaults to the system's configured ProfilesDirectory (normally
    C:\Users) and can be overridden with the $ProfileRoot configuration variable.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - edit these values before deploying
# ══════════════════════════════════════════════════════════════════════════════

# Path to write the cleanup log.
$LogPath = "C:\INS-Temp\Clear-RevitCache.log"

# Roll the log over to <LogPath>.1 once it exceeds this size.
$MaxLogSizeMB = 5

# Only delete cache files whose LastWriteTime is older than this many days.
$MaxAgeDays = 7

# When $true, measure and report what would be freed without deleting anything.
$ReportOnly = $false

# Only delete if at least this many GB can be reclaimed. 0 = always clean.
# Clearing the cache forces Revit to re-download from BIM 360, so this avoids
# churning the cache for a negligible gain. Fractional values (0.5) are allowed.
[double]$MinSpaceToFreeGB = 0

# Root folder containing user profiles. Leave empty to auto-detect.
$ProfileRoot = ''

# Profile folder names under the profile root to skip.
$ExcludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

# ── Exit codes ────────────────────────────────────────────────────────────────
$EXIT_SUCCESS         = 0
$EXIT_FAILURE         = 1
$EXIT_PREREQ          = 2
$EXIT_PARTIAL         = 3
$EXIT_BELOW_THRESHOLD = 4

$exitCode          = $EXIT_SUCCESS
$foldersProcessed  = 0
$filesAffected     = 0
$bytesFreed        = 0
$failed            = 0

# Set by the measure pass; stays $null when no measure pass runs.
$reclaimableBytes  = $null
$skippedBelowThreshold = $false

# Out-of-band return channel for Invoke-CachePass (see the note in that function).
$script:LastPassTotals = $null

$thresholdEnabled  = $MinSpaceToFreeGB -gt 0
$thresholdBytes    = $MinSpaceToFreeGB * 1GB

# ── Logging ───────────────────────────────────────────────────────────────────
# Runs before the main try/finally, so a failure here cannot be logged - report it
# on the error stream and exit with the prerequisite code.
$logDir = Split-Path $LogPath -Parent
try {
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
    }
    # New-Item can report success without creating anything (for example when a
    # parent path component is a file), so verify rather than trust it.
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        throw "directory does not exist after the creation attempt"
    }
    # Prove the log is actually writable now. Write-Log swallows errors by design,
    # so without this probe an unwritable log would disable logging silently.
    [IO.File]::AppendAllText($LogPath, '')
} catch {
    Write-Error "Cannot initialise logging at '$LogPath': $_"
    exit $EXIT_PREREQ
}

# Roll the log over once it outgrows the cap, keeping a single archive.
# Best-effort: rotation trouble must never block a cleanup run.
$logItem = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
if ($logItem -and $logItem.Length -gt ($MaxLogSizeMB * 1MB)) {
    Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp][$Level] $Message"
    # Logging is best-effort - a locked or unwritable log must not derail the run.
    # The failure is still diagnosable via -Debug; console output below is unaffected.
    try   { Add-Content -LiteralPath $LogPath -Value $entry -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Debug "Log write failed: $_" }
    switch ($Level) {
        'ERROR' { Write-Error   $Message }
        'WARN'  { Write-Warning $Message }
        'DEBUG' { Write-Verbose $Message }
        default { Write-Output  $Message }
    }
}

# ── Helper: locate the profile root ───────────────────────────────────────────
function Get-ProfileRoot {
    # The profile root is not always C:\Users - it can be relocated, and the system
    # drive is not always C:. Fall back only if the registry lookup fails.
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $dir = (Get-ItemProperty -Path $key -Name 'ProfilesDirectory' -ErrorAction Stop).ProfilesDirectory
        # ProfilesDirectory is REG_EXPAND_SZ, normally '%SystemDrive%\Users'.
        return [Environment]::ExpandEnvironmentVariables($dir)
    } catch {
        return (Join-Path $env:SystemDrive 'Users')
    }
}

# ── Helper: find each profile's CollaborationCache folder(s) ─────────────────
function Get-RevitCollaborationCachePath {
    param(
        [Parameter(Mandatory)][string]$ProfileRoot,
        [string[]]$ExcludedProfiles
    )

    $profiles = Get-ChildItem -Path $ProfileRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $ExcludedProfiles }

    foreach ($user in $profiles) {
        $revitRoot = Join-Path $user.FullName 'AppData\Local\Autodesk\Revit'
        if (-not (Test-Path -LiteralPath $revitRoot)) {
            continue
        }

        $versionDirs = Get-ChildItem -Path $revitRoot -Directory -Filter 'Autodesk Revit *' -ErrorAction SilentlyContinue
        foreach ($versionDir in $versionDirs) {
            $cachePath = Join-Path $versionDir.FullName 'CollaborationCache'
            if (Test-Path -LiteralPath $cachePath) {
                [PSCustomObject]@{
                    ProfileName = $user.Name
                    CachePath   = $cachePath
                }
            }
        }
    }
}

# ── Helper: delete stale files under a cache folder ───────────────────────────
function Clear-CacheFolder {
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][int]$MaxAgeDays,
        [bool]$ReportOnly = $false
    )

    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    $result = [PSCustomObject]@{
        Files      = 0
        BytesFreed = 0
        Failed     = 0
    }

    # Containment guard. Verified on Windows PowerShell 5.1: -Recurse does NOT walk
    # into directory junctions, so the tree cannot escape that way. These two checks
    # cover the rest - a symlinked file (delete the link, never the target) and any
    # path that somehow resolves outside the cache folder.
    $containmentRoot = [IO.Path]::GetFullPath($CachePath).TrimEnd('\') + '\'

    $staleFiles = Get-ChildItem -Path $CachePath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoff -and
            -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and
            $_.FullName.StartsWith($containmentRoot, [StringComparison]::OrdinalIgnoreCase)
        }

    foreach ($file in $staleFiles) {
        $size = $file.Length

        # Report mode: measure only, nothing can fail, so $result.Failed stays 0.
        if ($ReportOnly) {
            $result.Files++
            $result.BytesFreed += $size
            continue
        }

        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $result.Files++
            $result.BytesFreed += $size
        } catch {
            Write-Log "  [$ProfileName] Could not delete '$($file.FullName)': $_" -Level WARN
            $result.Failed++
        }
    }

    return $result
}

# ── Helper: run one pass (measure or delete) over every cache target ──────────
function Invoke-CachePass {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory)][int]$MaxAgeDays,
        # $true measures without deleting; $false deletes.
        [bool]$Measure = $false,
        # The gate's measure pass logs at DEBUG so a gated delete run does not
        # print two sets of per-folder lines.
        [ValidateSet('INFO', 'DEBUG')][string]$LogLevel = 'INFO'
    )

    $totals = [PSCustomObject]@{ Folders = 0; Files = 0; Bytes = 0; Failed = 0 }

    $scanVerb = if ($Measure) { 'Scanning' } else { 'Cleaning' }
    $fileVerb = if ($Measure) { 'Reclaimable from' } else { 'Deleted' }

    foreach ($target in $Targets) {
        Write-Log "[$($target.ProfileName)] ${scanVerb}: $($target.CachePath)" -Level $LogLevel

        $result = Clear-CacheFolder -ProfileName $target.ProfileName -CachePath $target.CachePath `
                                    -MaxAgeDays $MaxAgeDays -ReportOnly:$Measure

        $totals.Folders++
        $totals.Files  += $result.Files
        $totals.Bytes  += $result.BytesFreed
        $totals.Failed += $result.Failed

        $folderMB = [math]::Round($result.BytesFreed / 1MB, 1)
        Write-Log "  [$($target.ProfileName)] $fileVerb $($result.Files) file(s), ${folderMB}MB, $($result.Failed) failure(s)." -Level $LogLevel
    }

    # Write-Log emits INFO lines on the success stream, so returning $totals through
    # the pipeline would hand the caller [log strings..., $totals] rather than the
    # object. Pass it back out of band instead.
    $script:LastPassTotals = $totals
}

# ═════════════════════════════════════════════════════════════════════════════
$resolvedProfileRoot = if ($ProfileRoot) { $ProfileRoot } else { Get-ProfileRoot }

Write-Log "===== Clear-RevitCache started | Host: $env:COMPUTERNAME | User: $env:USERNAME ====="
Write-Log "LogPath        : $LogPath"
Write-Log "ProfileRoot    : $resolvedProfileRoot"
Write-Log "MaxAgeDays     : $MaxAgeDays"
Write-Log "ReportOnly     : $ReportOnly"
$thresholdLabel = if ($thresholdEnabled) { "${MinSpaceToFreeGB}GB" } else { 'disabled' }
Write-Log "MinSpaceToFree : $thresholdLabel"
if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - no files will be deleted ***" -Level WARN }

try {

    # ── Configuration validation ───────────────────────────────────────────────
    # MaxAgeDays = 0 puts the cutoff at "now", which selects essentially the whole
    # cache including files in active use. Use return, not throw (the catch would
    # rewrite it to EXIT_FAILURE) and not exit (which skips the finally's summary).
    if ($MaxAgeDays -lt 1) {
        Write-Log "MaxAgeDays must be 1 or greater (configured: $MaxAgeDays). Refusing to run." -Level ERROR
        $exitCode = $EXIT_PREREQ
        return
    }
    if ($MinSpaceToFreeGB -lt 0) {
        Write-Log "MinSpaceToFreeGB cannot be negative (configured: $MinSpaceToFreeGB). Refusing to run." -Level ERROR
        $exitCode = $EXIT_PREREQ
        return
    }

    $cacheTargets = @(Get-RevitCollaborationCachePath -ProfileRoot $resolvedProfileRoot `
                                                      -ExcludedProfiles $ExcludedProfiles)

    if ($cacheTargets.Count -eq 0) {
        # Deliberately ahead of the gate: a workstation with no Revit cache at all
        # should report "nothing to do", not "below threshold".
        Write-Log "No Revit Collaboration Cache folders found on this workstation." -Level WARN
        $exitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Found $($cacheTargets.Count) Collaboration Cache folder(s) across user profiles."

        # Measure pass - required when reporting (it IS the run) or to evaluate the
        # gate. Skipped entirely when the gate is off and we are deleting, so the
        # default configuration still makes exactly one pass.
        if ($ReportOnly -or $thresholdEnabled) {
            $measureLevel = if ($ReportOnly) { 'INFO' } else { 'DEBUG' }
            Invoke-CachePass -Targets $cacheTargets -MaxAgeDays $MaxAgeDays `
                             -Measure $true -LogLevel $measureLevel
            $measured = $script:LastPassTotals
            $reclaimableBytes = $measured.Bytes
        }

        if ($ReportOnly) {
            $foldersProcessed = $measured.Folders
            $filesAffected    = $measured.Files
            $bytesFreed       = $measured.Bytes
            $failed           = $measured.Failed

        } elseif ($thresholdEnabled -and $reclaimableBytes -lt $thresholdBytes) {
            # Gate closed - delete nothing.
            $skippedBelowThreshold = $true
            $foldersProcessed      = $measured.Folders

        } else {
            Invoke-CachePass -Targets $cacheTargets -MaxAgeDays $MaxAgeDays -Measure $false
            $pass = $script:LastPassTotals
            $foldersProcessed = $pass.Folders
            $filesAffected    = $pass.Files
            $bytesFreed       = $pass.Bytes
            $failed           = $pass.Failed
        }
    }

    # ── Summary ────────────────────────────────────────────────────────────────
    $freedMB       = [math]::Round($bytesFreed / 1MB, 1)
    $reclaimableGB = if ($null -ne $reclaimableBytes) { [math]::Round($reclaimableBytes / 1GB, 2) } else { $null }
    # Report reclaimable in MB like the rest of the script: rounding a few MB to GB
    # collapses to "0GB", which reads as "nothing to reclaim" when there is plenty.
    $reclaimableMB = if ($null -ne $reclaimableBytes) { [math]::Round($reclaimableBytes / 1MB, 1) } else { $null }

    Write-Log "-------------------------------------------"

    if ($skippedBelowThreshold) {
        Write-Log "Summary: Folders=$foldersProcessed | Reclaimable=${reclaimableMB}MB | Threshold=${MinSpaceToFreeGB}GB | Deleted=0"
        Write-Log "Reclaimable ${reclaimableMB}MB is below the ${MinSpaceToFreeGB}GB threshold - skipping deletion." -Level WARN
        $exitCode = $EXIT_BELOW_THRESHOLD

    } else {
        $freedLabel = if ($ReportOnly) { 'Reclaimable' } else { 'Freed' }
        $summary = "Summary: Folders=$foldersProcessed | Files=$filesAffected | ${freedLabel}=${freedMB}MB | Failed=$failed"
        if ($thresholdEnabled) { $summary += " | Threshold=${MinSpaceToFreeGB}GB" }
        Write-Log $summary

        # In report mode nothing is deleted, so no deletion can fail - always exit 0,
        # including when the threshold would not have been met.
        if ($ReportOnly) {
            Write-Log "Report-only scan completed. ${freedMB}MB in $filesAffected file(s) would be reclaimed."
            if ($thresholdEnabled) {
                if ($reclaimableBytes -ge $thresholdBytes) {
                    Write-Log "Would meet the ${MinSpaceToFreeGB}GB threshold (${reclaimableMB}MB reclaimable)."
                } else {
                    Write-Log "Would NOT meet the ${MinSpaceToFreeGB}GB threshold (${reclaimableMB}MB reclaimable)." -Level WARN
                }
            }
            $exitCode = $EXIT_SUCCESS
        } elseif ($failed -gt 0 -and $filesAffected -eq 0 -and $foldersProcessed -gt 0) {
            Write-Log "All deletions failed." -Level ERROR
            $exitCode = $EXIT_FAILURE
        } elseif ($failed -gt 0) {
            Write-Log "Partial success - $failed file(s) could not be deleted." -Level WARN
            $exitCode = $EXIT_PARTIAL
        } else {
            Write-Log "Cache cleanup completed successfully."
            $exitCode = $EXIT_SUCCESS
        }
    }

    # With the gate off there is nothing to fail, so the threshold counts as met.
    $thresholdMet = if (-not $thresholdEnabled)        { $true }
                    elseif ($null -ne $reclaimableBytes) { $reclaimableBytes -ge $thresholdBytes }
                    else                                 { $null }

    # Emit totals to the pipeline so callers need not parse the log.
    [PSCustomObject]@{
        ReportOnly            = [bool]$ReportOnly
        Folders               = $foldersProcessed
        Files                 = $filesAffected
        Bytes                 = $bytesFreed
        FreedMB               = $freedMB
        Failed                = $failed
        ThresholdGB           = $MinSpaceToFreeGB
        ReclaimableBytes      = $reclaimableBytes
        ReclaimableMB         = $reclaimableMB
        ReclaimableGB         = $reclaimableGB
        ThresholdMet          = $thresholdMet
        SkippedBelowThreshold = $skippedBelowThreshold
    }

} catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    Write-Log "===== Clear-RevitCache finished. Exit code: $exitCode ====="
    exit $exitCode
}
