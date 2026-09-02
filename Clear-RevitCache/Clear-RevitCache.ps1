# Keep the blank line between #Requires and the <# help block below. In Windows
# PowerShell 5.1 ANY non-blank line abutting the help block - a #Requires or even
# a comment - suppresses it, and Get-Help returns only a bare syntax line.
#Requires -Version 5.1
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

    Configuration variables (edit at the top of the script):
        $LogPath          Log file location.
        $MaxLogSizeMB     Roll the log to <LogPath>.1 once it exceeds this size.
        $MaxAgeDays       Delete cache files older than this. Minimum 1.
        $ReportOnly       Measure and report without deleting anything.
        $MinSpaceToFreeGB Only delete if at least this much is reclaimable. 0 = always.
        $ProfileRoot      Profile root folder. Empty = auto-detect from the registry
                          (the configured ProfilesDirectory, normally C:\Users).
        $ExcludedProfiles Profile folder names to skip.
        $SkipProfilesWithRevitRunning
                          Skip profiles whose user has Revit running, protecting live
                          workshared sessions. Other profiles are still cleaned.
        $RevitProcessNames
                          Process names that mark a profile as in use.

    Exit codes, in order of precedence (highest wins):
        6  A Revit process is running but its owner could not be determined, so no
           profile could be proven safe. Nothing was deleted.
        1  Total failure - every deletion failed.
        3  Partial failure - some files could not be deleted.
        5  One or more profiles were skipped because Revit was running for them.
        4  Below the $MinSpaceToFreeGB threshold; nothing was deleted.
        2  Prerequisite error (bad configuration, or logging could not start).
        0  Success, including "nothing to do". Report-only runs always exit 0.

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
$ReportOnly = $true

# Only delete if at least this many GB can be reclaimed. 0 = always clean.
# Clearing the cache forces Revit to re-download from BIM 360, so this avoids
# churning the cache for a negligible gain. Fractional values (0.5) are allowed.
[double]$MinSpaceToFreeGB = 3

# Root folder containing user profiles. Leave empty to auto-detect.
$ProfileRoot = ''

# Profile folder names under the profile root to skip.
$ExcludedProfiles = @('Public', 'Default', 'Default User', 'All Users')

# Skip profiles whose user currently has Revit running. The staleness filter is
# LastWriteTime, so a model open right now can have days-old cache files - deleting
# them risks corruption or lost unsynced work, not just a slow re-download.
$SkipProfilesWithRevitRunning = $true

# Process names that mark a profile as in use.
$RevitProcessNames = @('Revit.exe')

# ── Exit codes ────────────────────────────────────────────────────────────────
$EXIT_SUCCESS         = 0
$EXIT_FAILURE         = 1
$EXIT_PREREQ          = 2
$EXIT_PARTIAL         = 3
$EXIT_BELOW_THRESHOLD = 4
$EXIT_SKIPPED         = 5
$EXIT_OWNER_UNKNOWN   = 6

$exitCode          = $EXIT_SUCCESS
$foldersProcessed  = 0
$filesAffected     = 0
$bytesFreed        = 0
$failed            = 0

# Set by the measure pass; stays $null when no measure pass runs.
$reclaimableBytes  = $null
$skippedBelowThreshold = $false
$noCacheTargets        = $false

# Profiles the Revit-running guard held back, and PIDs it could not attribute.
$skippedProfiles   = @()
$ownerUnknownPids  = @()
$allTargetsSkipped = $false

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
        # VERBOSE routes to Write-Verbose, so those lines need -Verbose to appear
        # (not -Debug). INFO goes to the success stream, which is why callers must
        # select the summary object by type - see .NOTES.
        [ValidateSet('INFO', 'WARN', 'ERROR', 'VERBOSE')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp][$Level] $Message"
    # Logging is best-effort - a locked or unwritable log must not derail the run.
    # The failure itself is diagnosable via -Debug; console output below is unaffected.
    try   { Add-Content -LiteralPath $LogPath -Value $entry -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Debug "Log write failed: $_" }
    switch ($Level) {
        'ERROR'   { Write-Error   $Message }
        'WARN'    { Write-Warning $Message }
        'VERBOSE' { Write-Verbose $Message }
        default   { Write-Output  $Message }
    }
}

# ── Helper: bytes to MB, the unit used throughout the log ─────────────────────
function ConvertTo-MB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1MB, 1)
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

    # -LiteralPath throughout: profile names may legally contain [ ] * ?, which -Path
    # would interpret as wildcards and silently fail to match the real folder.
    $profiles = Get-ChildItem -LiteralPath $ProfileRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $ExcludedProfiles }

    foreach ($user in $profiles) {
        $revitRoot = Join-Path $user.FullName 'AppData\Local\Autodesk\Revit'
        if (-not (Test-Path -LiteralPath $revitRoot)) {
            continue
        }

        $versionDirs = Get-ChildItem -LiteralPath $revitRoot -Directory -Filter 'Autodesk Revit *' -ErrorAction SilentlyContinue
        foreach ($versionDir in $versionDirs) {
            $cachePath = Join-Path $versionDir.FullName 'CollaborationCache'
            if (Test-Path -LiteralPath $cachePath) {
                [PSCustomObject]@{
                    ProfileName = $user.Name
                    ProfilePath = $user.FullName
                    CachePath   = $cachePath
                }
            }
        }
    }
}

# ── Helper: which profiles currently have Revit running ───────────────────────
function Get-RevitInUseProfile {
    <#
        Returns the profile folders that own a running Revit process, plus the PIDs of
        any Revit process whose owner could not be determined.

        Deliberately does no logging: Write-Log INFO writes to the success stream, so a
        function that logs cannot cleanly return an object. The caller does the logging.
    #>
    param([string[]]$ProcessNames)

    $inUse = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $unknown = @()

    if (-not $ProcessNames -or $ProcessNames.Count -eq 0) {
        return [PSCustomObject]@{ InUsePaths = $inUse; UnknownOwnerPids = $unknown }
    }

    # Map SID -> profile folder. Matching on SID rather than username avoids assuming
    # the profile folder is named after the user; duplicates become user.DOMAIN or
    # user.000.
    $sidToPath = @{}
    foreach ($prof in (Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue)) {
        if ($prof.SID -and $prof.LocalPath) { $sidToPath[$prof.SID] = $prof.LocalPath }
    }

    # One enumeration, filtered in PowerShell. Building a WQL -Filter from a
    # config-supplied name would need quote escaping for no benefit.
    $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $ProcessNames -contains $_.Name }

    foreach ($proc in $procs) {
        $sid = $null
        try {
            $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop
            if ($owner.ReturnValue -eq 0) { $sid = $owner.Sid }
        } catch {
            Write-Debug "GetOwnerSid failed for PID $($proc.ProcessId): $_"
        }

        if ($sid -and $sidToPath.ContainsKey($sid)) {
            [void]$inUse.Add($sidToPath[$sid].TrimEnd('\'))
        } else {
            $unknown += $proc.ProcessId
        }
    }

    return [PSCustomObject]@{ InUsePaths = $inUse; UnknownOwnerPids = $unknown }
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

    $staleFiles = Get-ChildItem -LiteralPath $CachePath -File -Recurse -ErrorAction SilentlyContinue |
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
        # The gate's measure pass logs at VERBOSE so a gated delete run does not
        # print two sets of per-folder lines.
        [ValidateSet('INFO', 'VERBOSE')][string]$LogLevel = 'INFO'
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

        $folderMB = ConvertTo-MB $result.BytesFreed
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
$guardLabel = if ($SkipProfilesWithRevitRunning) { "on ($($RevitProcessNames -join ', '))" } else { 'off' }
Write-Log "RevitGuard     : $guardLabel"
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
        $noCacheTargets = $true
        $exitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Found $($cacheTargets.Count) Collaboration Cache folder(s) across user profiles."

        # ── Revit-running guard ────────────────────────────────────────────────
        # Runs before the measure pass on purpose: the reclaimable total must cover
        # only profiles that will actually be cleaned, or the gate could open on
        # space this run is never going to reclaim.
        if ($SkipProfilesWithRevitRunning) {
            if (-not $RevitProcessNames -or $RevitProcessNames.Count -eq 0) {
                Write-Log "RevitGuard is enabled but no process names are configured - it cannot match anything." -Level WARN
            }

            $inUse = Get-RevitInUseProfile -ProcessNames $RevitProcessNames
            $ownerUnknownPids = @($inUse.UnknownOwnerPids)

            if ($ownerUnknownPids.Count -gt 0) {
                $pidList = $ownerUnknownPids -join ', '
                if ($ReportOnly) {
                    # Nothing is being deleted, so there is no safety issue. Finish the
                    # scan and note that a real run would refuse - report mode never alarms.
                    Write-Log "Revit is running (PID(s) $pidList) but the owner could not be determined. A live run would refuse to delete anything." -Level WARN
                } else {
                    Write-Log "Revit is running (PID(s) $pidList) but the owner could not be determined - no profile can be proven safe, so nothing was deleted." -Level ERROR
                    $exitCode = $EXIT_OWNER_UNKNOWN
                    return
                }
            }

            if ($inUse.InUsePaths.Count -gt 0) {
                $keep = @()
                foreach ($target in $cacheTargets) {
                    if ($inUse.InUsePaths.Contains($target.ProfilePath.TrimEnd('\'))) {
                        if ($target.ProfileName -notin $skippedProfiles) {
                            $skippedProfiles += $target.ProfileName
                            Write-Log "[$($target.ProfileName)] SKIPPED: Revit is running for this user." -Level WARN
                        }
                    } else {
                        $keep += $target
                    }
                }
                $cacheTargets = @($keep)
            }
        }

        if ($cacheTargets.Count -eq 0) {
            # Distinct from "no cache found": caches exist, every one is in use.
            $allTargetsSkipped = $true
        }
    }

    if (-not $noCacheTargets -and -not $allTargetsSkipped) {

        # Measure pass - required when reporting (it IS the run) or to evaluate the
        # gate. Skipped entirely when the gate is off and we are deleting, so the
        # default configuration still makes exactly one pass.
        if ($ReportOnly -or $thresholdEnabled) {
            $measureLevel = if ($ReportOnly) { 'INFO' } else { 'VERBOSE' }
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
    $freedMB       = ConvertTo-MB $bytesFreed
    $reclaimableGB = if ($null -ne $reclaimableBytes) { [math]::Round($reclaimableBytes / 1GB, 2) } else { $null }
    # Report reclaimable in MB like the rest of the script: rounding a few MB to GB
    # collapses to "0GB", which reads as "nothing to reclaim" when there is plenty.
    $reclaimableMB = if ($null -ne $reclaimableBytes) { ConvertTo-MB $reclaimableBytes } else { $null }

    Write-Log "-------------------------------------------"

    if ($noCacheTargets) {
        # No cache anywhere: not a cleanup, not a threshold miss. Report one outcome
        # rather than following up the discovery warning with "completed successfully".
        Write-Log "Summary: No Revit Collaboration Cache folders present - nothing to do."
        $exitCode = $EXIT_SUCCESS

    } elseif ($allTargetsSkipped) {
        # Distinct from "no cache found": caches exist, but Revit is running for every
        # profile that has one.
        Write-Log "Summary: Folders=0 | Skipped=$($skippedProfiles.Count) | Deleted=0"
        Write-Log "Every profile with a cache has Revit running - nothing was cleaned." -Level WARN
        $exitCode = $EXIT_SUCCESS

    } elseif ($skippedBelowThreshold) {
        $gateSummary = "Summary: Folders=$foldersProcessed | Reclaimable=${reclaimableMB}MB | Threshold=${MinSpaceToFreeGB}GB | Deleted=0"
        if ($skippedProfiles.Count -gt 0) { $gateSummary += " | Skipped=$($skippedProfiles.Count)" }
        Write-Log $gateSummary
        Write-Log "Reclaimable ${reclaimableMB}MB is below the ${MinSpaceToFreeGB}GB threshold - skipping deletion." -Level WARN
        $exitCode = $EXIT_BELOW_THRESHOLD

    } else {
        $freedLabel = if ($ReportOnly) { 'Reclaimable' } else { 'Freed' }
        $summary = "Summary: Folders=$foldersProcessed | Files=$filesAffected | ${freedLabel}=${freedMB}MB | Failed=$failed"
        if ($thresholdEnabled) { $summary += " | Threshold=${MinSpaceToFreeGB}GB" }
        if ($skippedProfiles.Count -gt 0) { $summary += " | Skipped=$($skippedProfiles.Count)" }
        Write-Log $summary

        # In report mode nothing is deleted, so no deletion can fail - always exit 0,
        # including when the threshold would not have been met.
        if ($ReportOnly) {
            Write-Log "Report-only scan completed. ${freedMB}MB in $filesAffected file(s) would be reclaimed."
            # $null -ne guard: a null $reclaimableBytes would coerce to 0 and always
            # report "would not meet", with an empty number in the message.
            if ($thresholdEnabled -and $null -ne $reclaimableBytes) {
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

    # Exit precedence: 6 > 1 > 3 > 5 > 4 > 0. Skipping outranks the gate decision -
    # "we did not examine everything" is more actionable than "what we examined was
    # not worth cleaning" - but real deletion failures (1/3) outrank both. Report mode
    # is excluded so a scan never alarms.
    if (-not $ReportOnly -and $skippedProfiles.Count -gt 0 -and
        $exitCode -notin @($EXIT_FAILURE, $EXIT_PARTIAL)) {
        $exitCode = $EXIT_SKIPPED
    }

    # With the gate off there is nothing to fail, so the threshold counts as met.
    $thresholdMet = if (-not $thresholdEnabled)        { $true }
                    elseif ($null -ne $reclaimableBytes) { $reclaimableBytes -ge $thresholdBytes }
                    else                                 { $null }

    # Summary object for in-process callers. Write-Log INFO lines share the success
    # stream, and the finally block logs after this, so it is neither the only nor
    # the last item. Select it with -isnot [string]; -is [PSCustomObject] does not
    # discriminate here because pipeline items are PSObject-wrapped.
    #     & .\Clear-RevitCache.ps1 | Where-Object { $_ -isnot [string] }
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
        GuardEnabled          = [bool]$SkipProfilesWithRevitRunning
        SkippedProfiles       = $skippedProfiles
        SkippedProfileCount   = $skippedProfiles.Count
        OwnerUnknownPids      = $ownerUnknownPids
    }

} catch {
    Write-Log "Unhandled exception: $_" -Level ERROR
    $exitCode = $EXIT_FAILURE

} finally {
    Write-Log "===== Clear-RevitCache finished. Exit code: $exitCode ====="
    exit $exitCode
}
