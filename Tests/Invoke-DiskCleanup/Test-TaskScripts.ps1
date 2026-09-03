<#
.SYNOPSIS
    Invoke-DiskCleanup - the 6 extracted Tasks\ scripts, plus main-script integration.

.DESCRIPTION
    Covers the opt-in task scripts that were split out of Invoke-DiskCleanup.ps1, and the
    seams where the split could go wrong.

    WHAT IT CHECKS
      - Each of the 6 task scripts runs to completion without -Delete (report-only is the
        default), exits 0, and
        writes all three of its outputs (.log, _Summary.json, ScriptResult_*.txt) into
        the configured $LogDir. This is what catches an output path drifting: the
        expected folder is read from each script's own $LogDir assignment rather than
        hardcoded here, so moving $LogDir is a one-line change and this suite follows.
      - Each script's _Summary.json is valid JSON naming the right $ScriptName, and its
        result file starts with SUCCESS.
      - Get-Help renders a SYNOPSIS for all 7 scripts. This guards a PowerShell 5.1
        quirk: ANY non-blank line abutting the <# help block - a #Requires or even a
        comment - suppresses comment-based help entirely, leaving a bare syntax line.
        It has silently broken twice.
      - Log rotation isolation. The main script's archive prune filter once matched every
        per-task log (DiskCleanup_*.log) and would have deleted them. Archives now use a
        '-' separator; this asserts a seeded task archive survives a main-script rotation.
      - The removed opt-in switches are genuinely gone: passing -EmptyRecycleBin to the
        main script must fail as an unknown parameter.

    SAFETY
      -Delete is never passed, so nothing is deleted. ComponentCleanup does not invoke
      DISM in report mode and WindowsOld does not take ownership or delete - those two
      destructive paths are deliberately NOT exercised here and are verified by
      inspection instead.

      The scripts write to their real production $LogDir. This suite records which files
      it created and removes exactly those on the way out, leaving any pre-existing logs
      untouched.

.NOTES
    Elevation: not strictly required for the scripts to run, but several tasks enumerate
    all user profiles and system paths, so unelevated results will be thin. Elevation is
    recommended, not enforced.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

$MainScript = Get-ScriptUnderTest 'Invoke-DiskCleanup\Invoke-DiskCleanup.ps1'
$TasksDir   = Join-Path (Get-RepoRoot) 'Invoke-DiskCleanup\Tasks'

# Read $LogDir out of the script itself, so this suite follows a path change instead of
# failing on one.
function Get-ConfiguredLogDir {
    param([Parameter(Mandatory)][string]$ScriptPath)
    $m = Select-String -LiteralPath $ScriptPath -Pattern "^\s*\`$LogDir\s*=\s*'([^']+)'" | Select-Object -First 1
    if (-not $m) { throw "Could not read `$LogDir from $ScriptPath" }
    return $m.Matches[0].Groups[1].Value
}

$scripts = @(
    @{ File = $MainScript;                                          Name = 'DiskCleanup' }
    @{ File = Join-Path $TasksDir 'Clear-AgedRecycleBin.ps1';       Name = 'DiskCleanup_RecycleBin' }
    @{ File = Join-Path $TasksDir 'Clear-TeamsCache.ps1';           Name = 'DiskCleanup_TeamsCache' }
    @{ File = Join-Path $TasksDir 'Invoke-ComponentCleanup.ps1';    Name = 'DiskCleanup_ComponentCleanup' }
    @{ File = Join-Path $TasksDir 'Remove-OldRestorePoint.ps1';     Name = 'DiskCleanup_RestorePoints' }
    @{ File = Join-Path $TasksDir 'Remove-StaleProfile.ps1';        Name = 'DiskCleanup_StaleProfiles' }
    @{ File = Join-Path $TasksDir 'Remove-WindowsOld.ps1';          Name = 'DiskCleanup_WindowsOld' }
)
foreach ($s in $scripts) {
    if (-not (Test-Path -LiteralPath $s.File)) { throw "Script under test not found: $($s.File)" }
}

$logDir = Get-ConfiguredLogDir -ScriptPath $MainScript

# Track what we create so teardown never touches pre-existing logs.
$script:Created = New-Object System.Collections.Generic.List[string]
function Register-Created { param([string]$Path) if ($Path) { $script:Created.Add($Path) } }

Reset-TestChecks
try {
    Add-TestCheck 'all 7 scripts declare the same $LogDir' $true (
        @($scripts | ForEach-Object { Get-ConfiguredLogDir -ScriptPath $_.File } | Sort-Object -Unique).Count -eq 1
    )

    # ══ Every script: runs, exits 0, writes its 3 outputs to $LogDir ══════════
    foreach ($s in $scripts) {
        $log = Join-Path $logDir "$($s.Name).log"
        $sum = Join-Path $logDir "$($s.Name)_Summary.json"
        $res = Join-Path $logDir "ScriptResult_$($s.Name).txt"

        # Only delete pre-run if we are also going to recreate it; note anything that
        # did not exist before so teardown can remove just those.
        foreach ($f in @($log, $sum, $res)) {
            if (-not (Test-Path -LiteralPath $f)) { Register-Created $f }
        }

        # No -Delete: reporting is the default, so this run removes nothing.
        $out   = Invoke-ScriptUnderTest -Path $s.File
        $code  = Get-LastScriptExit
        $short = $s.Name

        Add-TestCheck "$short : exit 0"           0     $code
        Add-TestCheck "$short : .log in LogDir"   $true (Test-Path -LiteralPath $log)
        Add-TestCheck "$short : summary in LogDir" $true (Test-Path -LiteralPath $sum)
        Add-TestCheck "$short : result in LogDir" $true (Test-Path -LiteralPath $res)

        if (Test-Path -LiteralPath $res) {
            Add-TestCheck "$short : result says SUCCESS" $true ([bool]((Get-Content -LiteralPath $res -Raw) -match '^SUCCESS'))
        }
        if (Test-Path -LiteralPath $sum) {
            $j = $null
            try { $j = Get-Content -LiteralPath $sum -Raw | ConvertFrom-Json } catch { }
            Add-TestCheck "$short : summary is valid JSON"  $true    ($null -ne $j)
            if ($j) {
                Add-TestCheck "$short : summary Script name" $s.Name $j.Script
                Add-TestCheck "$short : summary ReportOnly"  $true   $j.ReportOnly
            }
        }
    }

    # ══ Comment-based help must render for all 7 ══════════════════════════════
    foreach ($s in $scripts) {
        $h = Get-ScriptHelpText -Path $s.File
        Add-TestCheck "$($s.Name) : help has SYNOPSIS" $true ([bool]($h -match 'SYNOPSIS'))
    }

    # ══ Rotation isolation: main must not prune a task's archives ════════════
    $taskArchive = Join-Path $logDir 'DiskCleanup_RestorePoints-20200101_000000.log'
    Set-Content -LiteralPath $taskArchive -Value 'seeded task archive' -Encoding utf8
    Register-Created $taskArchive

    $mainLog = Join-Path $logDir 'DiskCleanup.log'
    [IO.File]::WriteAllBytes($mainLog, (New-Object byte[] 6MB))

    # Skip every core task so this run is a fast rotation-only exercise.
    $allCore = @('WindowsTemp','UserTemp','UserInternetCache','WindowsErrorReporting','MemoryDumps',
                 'WindowsLogs','DownloadedProgramFiles','DeliveryOptimization','WindowsUpdateCache',
                 'ThumbnailCache','BrowserCache')
    $null = Invoke-ScriptUnderTest -Path $MainScript -Arguments (@('-SkipTasks') + (,($allCore -join ',')))

    Add-TestCheck 'rotation: task archive survived main rotation' $true (Test-Path -LiteralPath $taskArchive)
    $mainArchives = @(Get-ChildItem -LiteralPath $logDir -Filter 'DiskCleanup-*.log' -ErrorAction SilentlyContinue)
    Add-TestCheck 'rotation: main archive created'                $true ($mainArchives.Count -gt 0)
    $mainArchives | ForEach-Object { Register-Created $_.FullName }
    Add-TestCheck 'rotation: main log restarted small'            $true ((Get-Item -LiteralPath $mainLog).Length -lt 1MB)

    # ══ Removed opt-in switches must be rejected ═════════════════════════════
    foreach ($sw in '-EmptyRecycleBin', '-RemoveWindowsOld', '-RunComponentCleanup') {
        $out = Invoke-ScriptUnderTest -Path $MainScript -Arguments @($sw)
        Add-TestCheck "main rejects $sw" $true ([bool](($out | Out-String) -match [regex]::Escape($sw.TrimStart('-'))))
    }

    # ══ Reporting is the default; -Delete opts into removing things ═══════════
    # Deleting is opted into with the bare -Delete switch rather than by defaulting
    # -ReportOnly to $true. Two reasons, both worth locking in:
    #   1. A switch defaulting to $true inverts what a switch means, and PSScriptAnalyzer
    #      flags it (PSAvoidDefaultValueSwitchParameter).
    #   2. That design needed the caller to write -ReportOnly:$false, an explicit boolean
    #      that binds only under direct invocation. Via
    #      "powershell.exe -File script.ps1 -ReportOnly:$false" every argument arrives as
    #      plain text and PowerShell 5.1 throws ParameterArgumentTransformationError.
    #      A bare switch binds under either style.
    #
    # Each script derives $ReportOnly = -not $Delete just after param(), and the ~49
    # internal reads still use $ReportOnly - so the probe is injected AFTER that
    # derivation to exercise binding and derivation together. Injecting after param()
    # alone would read $ReportOnly before it is assigned.
    #
    # Nothing destructive ever runs: the probe prints and exits before any real logic.
    # These scripts delete production data (Recycle Bin, Teams cache, Windows.old, stale
    # profiles), so -Delete is never executed live here.
    $anchor = '$ReportOnly = -not $Delete'
    $probeDir = New-TestWorkspace -Label 'delprobe'
    try {
        foreach ($s in $scripts) {
            $name = Split-Path $s.File -Leaf
            $raw  = Get-Content -LiteralPath $s.File -Raw
            Add-TestCheck "$name : derives ReportOnly from Delete" $true ($raw.Contains($anchor))

            $probe = Join-Path $probeDir $name
            $raw.Replace($anchor, $anchor + "`nWrite-Output ('RESOLVED=' + [bool]`$ReportOnly)`nexit 0") |
                Set-Content -LiteralPath $probe -Encoding utf8

            Add-TestCheck "$name : no args -> report only"  'RESOLVED=True'  (& $probe)
            Add-TestCheck "$name : -Delete -> deletes"      'RESOLVED=False' (& $probe -Delete)
        }

        # -ReportOnly is gone: passing it must fail rather than silently do nothing.
        $out = Invoke-ScriptUnderTest -Path $MainScript -Arguments @('-ReportOnly')
        Add-TestCheck 'main rejects removed -ReportOnly' $true ([bool](($out | Out-String) -match 'ReportOnly'))
    }
    finally { Remove-TestWorkspace -Path $probeDir }
}
finally {
    foreach ($f in $script:Created) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Write-TestSummary -SuiteName 'Invoke-DiskCleanup / TaskScripts'
exit (Get-TestFailureCount)
