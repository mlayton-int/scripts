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

    Supports -WhatIf / -Confirm to preview what would be deleted.

    Exits with code 0 on full success, 3 on partial failure (some files could not be
    deleted), 1 on total failure, and 2 on prerequisite errors.

.NOTES
    Cache path pattern cleaned:
        C:\Users\<profile>\AppData\Local\Autodesk\Revit\Autodesk Revit *\CollaborationCache
#>

[CmdletBinding(SupportsShouldProcess)]
param()

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION - edit these values before deploying
# ══════════════════════════════════════════════════════════════════════════════

# Path to write the cleanup log.
$LogPath = "C:\INS-Temp\Clear-RevitCache.log"

# Only delete cache files whose LastWriteTime is older than this many days.
$MaxAgeDays = 1

# Profile folder names under C:\Users to skip.
$ExcludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

# ── Exit codes ────────────────────────────────────────────────────────────────
$EXIT_SUCCESS      = 0
$EXIT_FAILURE      = 1
$EXIT_PREREQ_ERROR = 2
$EXIT_PARTIAL      = 3

$exitCode          = $EXIT_SUCCESS
$foldersCleared    = 0
$filesDeleted      = 0
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

# ── Helper: find each profile's CollaborationCache folder(s) ─────────────────
function Get-RevitCollaborationCachePaths {
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
        [Parameter(Mandatory)][int]$MaxAgeDays
    )

    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    $result = [PSCustomObject]@{
        FilesDeleted = 0
        BytesFreed   = 0
        Failed       = 0
    }

    $staleFiles = Get-ChildItem -Path $CachePath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }

    foreach ($file in $staleFiles) {
        if (-not $PSCmdlet.ShouldProcess($file.FullName, 'Remove stale Revit cache file')) {
            continue
        }
        try {
            $size = $file.Length
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $result.FilesDeleted++
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

    $cacheTargets = @(Get-RevitCollaborationCachePaths -ExcludedProfiles $ExcludedProfiles)

    if ($cacheTargets.Count -eq 0) {
        Write-Log "No Revit Collaboration Cache folders found on this workstation." -Level WARN
        $exitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Found $($cacheTargets.Count) Collaboration Cache folder(s) across user profiles."

        $processedProfiles = New-Object System.Collections.Generic.HashSet[string]

        foreach ($target in $cacheTargets) {
            Write-Log "[$($target.ProfileName)] Cleaning: $($target.CachePath)"
            $null = $processedProfiles.Add($target.ProfileName)

            $result = Clear-CacheFolder -ProfileName $target.ProfileName -CachePath $target.CachePath -MaxAgeDays $MaxAgeDays

            $foldersCleared++
            $filesDeleted += $result.FilesDeleted
            $bytesFreed   += $result.BytesFreed
            $failed       += $result.Failed

            Write-Log "  [$($target.ProfileName)] Deleted $($result.FilesDeleted) file(s), $($result.Failed) failure(s)."
        }

    }

    # ── Summary ────────────────────────────────────────────────────────────────
    $freedMB = [math]::Round($bytesFreed / 1MB, 1)
    Write-Log "-------------------------------------------"
    Write-Log "Summary: Folders=$foldersCleared | FilesDeleted=$filesDeleted | Freed=${freedMB}MB | Failed=$failed"

    if ($failed -gt 0 -and $filesDeleted -eq 0 -and $foldersCleared -gt 0) {
        Write-Log "All deletions failed." -Level ERROR
        $exitCode = $EXIT_FAILURE
    } elseif ($failed -gt 0) {
        Write-Log "Partial success - $failed file(s) could not be deleted." -Level WARN
        $exitCode = $EXIT_PARTIAL
    } else {
        Write-Log "Cache cleanup completed successfully."
        $exitCode = $EXIT_SUCCESS
    }

} catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    Write-Log "===== Clear-RevitCache finished. Exit code: $exitCode ====="
    exit $exitCode
}
