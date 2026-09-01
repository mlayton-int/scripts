#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleans up stale Autodesk Revit Collaboration Cache files for every local user
    profile on a workstation.

.DESCRIPTION
    Iterates over each local user profile under C:\Users (excluding Public, Default,
    Default User, and All Users), locates any installed Revit version's Collaboration
    Cache folder:

        <Profile>\AppData\Local\Autodesk\Revit\Autodesk Revit <version>\CollaborationCache

    and deletes cached files older than $MaxAgeDays. Files locked by a running Revit
    session are logged as warnings and skipped rather than aborting the run.

    Set the $ReportOnly configuration variable to $true to perform the identical
    discovery and staleness filter, report how much space would be reclaimed, and delete
    nothing. A report-only run always exits 0.

    Exits with code 0 on full success, 3 on partial failure (some files could not be
    deleted), 1 on total failure, and 2 on prerequisite errors.

.NOTES
    Cache path pattern cleaned:
        C:\Users\<profile>\AppData\Local\Autodesk\Revit\Autodesk Revit *\CollaborationCache
#>

[CmdletBinding()]
param()

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - edit these values before deploying
# ══════════════════════════════════════════════════════════════════════════════

# Path to write the cleanup log.
$LogPath = "C:\INS-Temp\Clear-RevitCache.log"

# Only delete cache files whose LastWriteTime is older than this many days.
$MaxAgeDays = 1

# When $true, measure and report what would be freed without deleting anything.
$ReportOnly = $false

# Profile folder names under C:\Users to skip.
$ExcludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

# ── Exit codes ────────────────────────────────────────────────────────────────
$EXIT_SUCCESS      = 0
$EXIT_FAILURE      = 1
$EXIT_PARTIAL      = 3

$exitCode          = $EXIT_SUCCESS
$foldersProcessed  = 0
$filesAffected     = 0
$bytesFreed        = 0
$failed            = 0

# ── Logging ───────────────────────────────────────────────────────────────────
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
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

Write-Log "===== Clear-RevitCache started | Host: $env:COMPUTERNAME | User: $env:USERNAME ====="
Write-Log "LogPath    : $LogPath"
Write-Log "MaxAgeDays : $MaxAgeDays"
Write-Log "ReportOnly : $ReportOnly"
if ($ReportOnly) { Write-Log "*** REPORT ONLY MODE - no files will be deleted ***" -Level WARN }

# ── Helper: find each profile's CollaborationCache folder(s) ─────────────────
function Get-RevitCollaborationCachePath {
    param([string[]]$ExcludedProfiles)

    $profiles = Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue |
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

    $staleFiles = Get-ChildItem -Path $CachePath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }

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

# ═════════════════════════════════════════════════════════════════════════════
try {

    $cacheTargets = @(Get-RevitCollaborationCachePath -ExcludedProfiles $ExcludedProfiles)

    if ($cacheTargets.Count -eq 0) {
        Write-Log "No Revit Collaboration Cache folders found on this workstation." -Level WARN
        $exitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Found $($cacheTargets.Count) Collaboration Cache folder(s) across user profiles."

        $processedProfiles = New-Object System.Collections.Generic.HashSet[string]

        $scanVerb = if ($ReportOnly) { 'Scanning' } else { 'Cleaning' }
        $fileVerb = if ($ReportOnly) { 'Reclaimable from' } else { 'Deleted' }

        foreach ($target in $cacheTargets) {
            Write-Log "[$($target.ProfileName)] ${scanVerb}: $($target.CachePath)"
            $null = $processedProfiles.Add($target.ProfileName)

            $result = Clear-CacheFolder -ProfileName $target.ProfileName -CachePath $target.CachePath -MaxAgeDays $MaxAgeDays -ReportOnly:$ReportOnly

            $foldersProcessed++
            $filesAffected += $result.Files
            $bytesFreed    += $result.BytesFreed
            $failed        += $result.Failed

            $folderMB = [math]::Round($result.BytesFreed / 1MB, 1)
            Write-Log "  [$($target.ProfileName)] $fileVerb $($result.Files) file(s), ${folderMB}MB, $($result.Failed) failure(s)."
        }

    }

    # ── Summary ────────────────────────────────────────────────────────────────
    $freedMB   = [math]::Round($bytesFreed / 1MB, 1)
    $freedLabel = if ($ReportOnly) { 'Reclaimable' } else { 'Freed' }
    Write-Log "-------------------------------------------"
    Write-Log "Summary: Folders=$foldersProcessed | Files=$filesAffected | ${freedLabel}=${freedMB}MB | Failed=$failed"

    # In report mode nothing is deleted, so no deletion can fail - always exit 0.
    if ($ReportOnly) {
        Write-Log "Report-only scan completed. ${freedMB}MB in $filesAffected file(s) would be reclaimed."
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

    # Emit totals to the pipeline so callers need not parse the log.
    [PSCustomObject]@{
        ReportOnly = [bool]$ReportOnly
        Folders    = $foldersProcessed
        Files      = $filesAffected
        Bytes      = $bytesFreed
        FreedMB    = $freedMB
        Failed     = $failed
    }

} catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    Write-Log "===== Clear-RevitCache finished. Exit code: $exitCode ====="
    exit $exitCode
}
