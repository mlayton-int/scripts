<#
.SYNOPSIS
    Clear-RevitCache.ps1 behaviour suite - synthetic profile trees, no elevation needed.

.DESCRIPTION
    Exercises everything Clear-RevitCache does, against throwaway profile trees under
    TEMP. Never touches a real Revit cache.

    Technique: the script under test is copied to the workspace with its CONFIGURATION
    block string-replaced ($ProfileRoot, $LogPath, $ReportOnly, $MinSpaceToFreeGB,
    $MaxAgeDays, guard settings), then run as a child process. That exercises the real
    script end to end rather than re-implementing its logic.

    The Revit-running guard reads live process state, which cannot be faked from a
    synthetic tree. For guard-consumption tests the detector Get-RevitInUseProfile is
    replaced with a stub returning canned data, so the partitioning, exit-code precedence
    and gate-interaction logic are all covered here. The detector itself is covered by
    Test-GuardDetection.ps1 and Test-GuardEndToEnd.ps1.

.NOTES
    Each profile tree holds 2MB + 1MB of stale files and one 5MB fresh file that must
    always survive - so 8MB total, 3MB reclaimable, per profile.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

$Src = Get-ScriptUnderTest 'Clear-RevitCache\Clear-RevitCache.ps1'
$ws  = New-TestWorkspace -Label 'revitguard'

$Root   = Join-Path $ws 'FakeUsers'
$Log    = Join-Path $ws 'test.log'
$Run    = Join-Path $ws 'under-test.ps1'
$Marker = Join-Path $ws 'detector-called.marker'

$CACHE_TAIL    = 'AppData\Local\Autodesk\Revit\Autodesk Revit 2025\CollaborationCache'
$PROFILE_ALL   = 8MB
$PROFILE_STALE = 3MB
$script:Profiles = @('alice')

function Get-CacheDir { param($Name) Join-Path $Root (Join-Path $Name $CACHE_TAIL) }

function New-FakeTree {
    param([switch]$NoCache, [string[]]$Names = @('alice'))
    $script:Profiles = $Names
    if (Test-Path -LiteralPath $Root) { Remove-TestWorkspace -Path $Root }
    foreach ($n in $Names) {
        if ($NoCache) {
            New-Item -ItemType Directory -Path (Join-Path $Root "$n\AppData\Local") -Force | Out-Null
            continue
        }
        $cache = Join-Path (Get-CacheDir $n) 'sub'
        New-AgedFile -Path (Join-Path $cache 'a.dat')     -Bytes 2MB -AgeDays 30
        New-AgedFile -Path (Join-Path $cache 'b.dat')     -Bytes 1MB -AgeDays 30
        New-AgedFile -Path (Join-Path $cache 'fresh.dat') -Bytes 5MB
    }
}

function New-TestScriptCopy {
    param(
        [string]$ReportOnly = 'false',
        [string]$Threshold  = '0',
        [string]$MaxAge     = '7',
        [string]$LogOverride = '',
        [string]$Guard      = 'true',
        [string]$ProcNames  = "@('Revit.exe')",
        [string[]]$InUse,
        [int[]]$Unknown,
        [switch]$Stub
    )
    $useLog = if ($LogOverride) { $LogOverride } else { $Log }

    # #Requires lines are stripped so the suite runs unelevated. The elevated suites
    # deliberately leave them intact.
    $t = (Get-Content $Src -Raw)
    $t = $t -replace '#Requires -RunAsAdministrator', ''
    $t = $t -replace '#Requires -Version 5\.1', ''
    $t = $t.Replace('"C:\INS-Temp\Clear-RevitCache.log"', '"' + $useLog + '"')
    $t = $t.Replace("`$ProfileRoot = ''", "`$ProfileRoot = '" + $Root + "'")
    # Both spellings: the shipped default has flipped between runs.
    $t = $t.Replace('$ReportOnly = $true',  '$ReportOnly = $' + $ReportOnly)
    $t = $t.Replace('$ReportOnly = $false', '$ReportOnly = $' + $ReportOnly)
    $t = $t -replace '\[double\]\$MinSpaceToFreeGB = [\d.]+', ('[double]$MinSpaceToFreeGB = ' + $Threshold)
    $t = $t -replace '\$MaxAgeDays = -?\d+', ('$MaxAgeDays = ' + $MaxAge)
    $t = $t.Replace('$SkipProfilesWithRevitRunning = $true', '$SkipProfilesWithRevitRunning = $' + $Guard)
    $t = $t.Replace("`$RevitProcessNames = @('Revit.exe')", "`$RevitProcessNames = $ProcNames")

    if ($Stub) {
        $adds = ($InUse | ForEach-Object { "    [void]`$s.Add('$_')" }) -join "`n"
        $unk  = if ($Unknown) { $Unknown -join ',' } else { '' }
        $stubText = @"
function Get-RevitInUseProfile {
    param([string[]]`$ProcessNames)
    Set-Content -LiteralPath '$Marker' -Value 'called' -Encoding utf8
    `$s = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$adds
    return [PSCustomObject]@{ InUsePaths = `$s; UnknownOwnerPids = @($unk) }
}
"@
        # ASCII-only anchor. A box-drawing anchor would break if PowerShell reads this
        # file as ANSI, which is how the same class of bug bit the scripts themselves.
        $anchor = '    if ($MaxAgeDays -lt 1) {'
        if (-not $t.Contains($anchor)) { throw 'stub anchor not found - has the script changed?' }
        $t = $t.Replace($anchor, "$stubText`n$anchor")
    }
    $t | Set-Content -LiteralPath $Run -Encoding utf8
}

function Get-CacheBytes  { param($Name) Get-TreeBytes -Path (Get-CacheDir $Name) }
function Get-TotalBytes  { ($script:Profiles | ForEach-Object { Get-CacheBytes $_ } | Measure-Object -Sum).Sum }

Reset-TestChecks
try {
    # ══ Threshold gate ════════════════════════════════════════════════════════
    New-FakeTree; New-TestScriptCopy -Threshold '2'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'gate blocks: exit 4'        4            (Get-LastScriptExit)
    Add-TestCheck 'gate blocks: untouched'     $PROFILE_ALL (Get-TotalBytes)
    Add-TestCheck 'gate blocks: WARN logged'   $true ([bool]($o -match 'below the 2GB threshold'))
    Add-TestCheck 'gate blocks: MB not "0GB"'  $true ([bool]($o -match 'Reclaimable 3MB'))

    New-FakeTree; New-TestScriptCopy -Threshold '0.001'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'gate opens: exit 0'         0 (Get-LastScriptExit)
    Add-TestCheck 'gate opens: stale removed'  ($PROFILE_ALL - $PROFILE_STALE) (Get-TotalBytes)

    New-FakeTree; New-TestScriptCopy -Threshold '0.5'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'fractional threshold: exit 4'      4            (Get-LastScriptExit)
    Add-TestCheck 'fractional threshold: untouched'   $PROFILE_ALL (Get-TotalBytes)
    Add-TestCheck 'fractional threshold: 0.5GB label' $true ([bool]($o -match 'MinSpaceToFree : 0\.5GB'))

    # ══ Gate disabled - must make exactly one pass ════════════════════════════
    New-FakeTree; New-TestScriptCopy -Threshold '0'
    $o = Invoke-ScriptUnderTest -Path $Run -VerboseRun
    Add-TestCheck 'gate off: exit 0'            0 (Get-LastScriptExit)
    Add-TestCheck 'gate off: stale removed'     ($PROFILE_ALL - $PROFILE_STALE) (Get-TotalBytes)
    Add-TestCheck 'gate off: NO measure pass'   $false ([bool]($o -match 'Scanning:'))
    Add-TestCheck 'gate off: shows "disabled"'  $true  ([bool]($o -match 'MinSpaceToFree : disabled'))
    Add-TestCheck 'gate off: banner logged'     $true  ([bool]($o -match 'Clear-RevitCache started'))

    # ══ Report mode ═══════════════════════════════════════════════════════════
    New-FakeTree; New-TestScriptCopy -ReportOnly 'true' -Threshold '2'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'report: exit 0'              0            (Get-LastScriptExit)
    Add-TestCheck 'report: nothing deleted'     $PROFILE_ALL (Get-TotalBytes)
    Add-TestCheck 'report: would-not-meet line' $true ([bool]($o -match 'Would NOT meet the 2GB threshold'))

    # ══ Locked file -> partial failure ════════════════════════════════════════
    New-FakeTree; New-TestScriptCopy -Threshold '0.001'
    $fs = [IO.File]::Open((Join-Path (Get-CacheDir 'alice') 'sub\a.dat'), 'Open', 'ReadWrite', 'None')
    try   { $o = Invoke-ScriptUnderTest -Path $Run } finally { $fs.Close(); $fs.Dispose() }
    Add-TestCheck 'locked file: exit 3 (partial)' 3 (Get-LastScriptExit)

    # ══ Config validation ═════════════════════════════════════════════════════
    foreach ($bad in '0', '-1') {
        New-FakeTree; New-TestScriptCopy -MaxAge $bad
        $o = Invoke-ScriptUnderTest -Path $Run
        Add-TestCheck "MaxAgeDays=$bad : exit 2"    2            (Get-LastScriptExit)
        Add-TestCheck "MaxAgeDays=$bad : untouched" $PROFILE_ALL (Get-TotalBytes)
        Add-TestCheck "MaxAgeDays=$bad : reason"    $true ([bool]($o -match 'MaxAgeDays must be 1 or greater'))
    }

    New-FakeTree; New-TestScriptCopy -Threshold '-1'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'negative threshold: exit 2'    2            (Get-LastScriptExit)
    Add-TestCheck 'negative threshold: untouched' $PROFILE_ALL (Get-TotalBytes)

    # ══ Logging prerequisites ═════════════════════════════════════════════════
    # A file as a parent path component: New-Item -Force reports success without
    # creating anything, so the script must verify rather than trust it.
    New-FakeTree
    $blocker = Join-Path $ws 'blocker.txt'
    Set-Content -LiteralPath $blocker -Value 'x' -Encoding utf8
    New-TestScriptCopy -LogOverride (Join-Path $blocker 'sub\x.log')
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'unwritable log dir: exit 2'    2            (Get-LastScriptExit)
    Add-TestCheck 'unwritable log dir: message'   $true ([bool]($o -match 'Cannot initialise logging'))
    Add-TestCheck 'unwritable log dir: untouched' $PROFILE_ALL (Get-TotalBytes)
    Remove-Item -LiteralPath $blocker -Force

    # ══ Containment: a junction must not be followed ══════════════════════════
    New-FakeTree
    $sentinelDir = Join-Path $ws 'SENTINEL'
    New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
    $sentinelFile = Join-Path $sentinelDir 'DO-NOT-TOUCH.dat'
    New-AgedFile -Path $sentinelFile -Bytes 4MB -AgeDays 30
    cmd /c mklink /J "$(Join-Path (Get-CacheDir 'alice') 'escape')" "$sentinelDir" | Out-Null
    New-TestScriptCopy -Threshold '0'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'junction: sentinel survives'  $true (Test-Path -LiteralPath $sentinelFile)
    Add-TestCheck 'junction: sentinel intact'    4MB   ([int64](Get-Item -LiteralPath $sentinelFile).Length)
    Add-TestCheck 'junction: absent from totals' $true ([bool]($o -match 'Freed=3MB'))
    cmd /c rmdir "$(Join-Path (Get-CacheDir 'alice') 'escape')" 2>&1 | Out-Null
    Remove-Item -LiteralPath $sentinelDir -Recurse -Force

    # ══ Profile root discovery ════════════════════════════════════════════════
    New-FakeTree; New-TestScriptCopy -Threshold '0'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'ProfileRoot override honoured' $true ([bool]($o -match [regex]::Escape("ProfileRoot    : $Root")))
    $auto = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory).ProfilesDirectory
    Add-TestCheck 'ProfileRoot autodetect resolves' $true ([bool]([Environment]::ExpandEnvironmentVariables($auto)))

    # Profile names may legally contain [ ] * ? - -Path would treat them as wildcards.
    New-FakeTree -Names @('John[Doe]'); New-TestScriptCopy -Threshold '0'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'wildcard profile name: found'   $true ([bool]($o -match 'Found 1 Collaboration Cache'))
    Add-TestCheck 'wildcard profile name: cleaned' ($PROFILE_ALL - $PROFILE_STALE) (Get-TotalBytes)
    Add-TestCheck 'wildcard profile name: exit 0'  0 (Get-LastScriptExit)

    # ══ Log rotation ══════════════════════════════════════════════════════════
    New-FakeTree
    if (Test-Path -LiteralPath $Log)     { Remove-Item -LiteralPath $Log -Force }
    if (Test-Path -LiteralPath "$Log.1") { Remove-Item -LiteralPath "$Log.1" -Force }
    [IO.File]::WriteAllBytes($Log, (New-Object byte[] 6MB))
    New-TestScriptCopy -Threshold '0'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'rotation: archive created'   $true (Test-Path -LiteralPath "$Log.1")
    Add-TestCheck 'rotation: live log restarted' $true ((Get-Item -LiteralPath $Log).Length -lt 1MB)
    Add-TestCheck 'rotation: archive is the 6MB' 6MB   ([int64](Get-Item -LiteralPath "$Log.1").Length)
    [IO.File]::WriteAllBytes($Log, (New-Object byte[] 6MB))
    New-FakeTree; $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'rotation: no .2 stacking'    $false (Test-Path -LiteralPath "$Log.2")

    # ══ No cache folders at all ═══════════════════════════════════════════════
    New-FakeTree -NoCache; New-TestScriptCopy -Threshold '2'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'no folders: exit 0'          0 (Get-LastScriptExit)
    Add-TestCheck 'no folders: WARN not gate'   $true ([bool]($o -match 'No Revit Collaboration Cache folders found'))

    New-FakeTree -NoCache; New-TestScriptCopy -ReportOnly 'true' -Threshold '2'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'no folders + report: exit 0'         0      (Get-LastScriptExit)
    Add-TestCheck 'no folders + report: no would-not'   $false ([bool]($o -match 'Would NOT meet'))
    Add-TestCheck 'no folders + report: no empty "MB"'  $false ([bool]($o -match '\(\s*MB reclaimable\)'))

    New-FakeTree -NoCache; New-TestScriptCopy -Threshold '0'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'no folders: no bogus success'  $false ([bool]($o -match 'Cache cleanup completed successfully'))
    Add-TestCheck 'no folders: nothing-to-do'     $true  ([bool]($o -match 'nothing to do'))

    # ══ VERBOSE level routes to Write-Verbose ═════════════════════════════════
    New-FakeTree; New-TestScriptCopy -Threshold '0.001'
    $o = Invoke-ScriptUnderTest -Path $Run -VerboseRun
    Add-TestCheck '-Verbose shows measure pass' $true  ([bool]($o -match 'Scanning:'))
    New-FakeTree; $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'quiet hides measure pass'    $false ([bool]($o -match 'Scanning:'))

    # ══ Summary object on the success stream ══════════════════════════════════
    # Select by -isnot [string], NOT -is [PSCustomObject]: pipeline items are
    # PSObject-wrapped, so the latter matches every log line too.
    New-FakeTree; New-TestScriptCopy -Threshold '0'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = & $Run
    $ErrorActionPreference = $old
    $obj = @($raw | Where-Object { $_ -isnot [string] })
    Add-TestCheck 'summary: exactly one object'    1     $obj.Count
    Add-TestCheck 'summary: FreedMB correct'       3     ([double]$obj[0].FreedMB)
    Add-TestCheck 'summary: has gate fields'       $true ($null -ne $obj[0].SkippedBelowThreshold)
    Add-TestCheck 'summary: last item is a string' $true (@($raw)[-1] -is [string])

    # ══ Comment-based help must render ════════════════════════════════════════
    $h = Get-ScriptHelpText -Path $Run
    Add-TestCheck 'help: SYNOPSIS present'   $true ([bool]($h -match 'SYNOPSIS'))
    Add-TestCheck 'help: lists config vars'  $true (([bool]($h -match 'MinSpaceToFreeGB')) -and ([bool]($h -match 'ProfileRoot')))

    # ══ Revit guard - consumption logic, canned detector ══════════════════════
    $TWO      = @('alice','bob')
    $TWO_ALL  = 16MB
    $aliceDir = Join-Path $Root 'alice'
    $bobDir   = Join-Path $Root 'bob'

    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0' -Stub -InUse @($aliceDir)
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'guard: in-use profile untouched' $PROFILE_ALL                    (Get-CacheBytes 'alice')
    Add-TestCheck 'guard: other profile cleaned'    ($PROFILE_ALL - $PROFILE_STALE) (Get-CacheBytes 'bob')
    Add-TestCheck 'guard: skip logged'              $true ([bool]($o -match '\[alice\] SKIPPED: Revit is running'))
    Add-TestCheck 'guard: summary Skipped=1'        $true ([bool]($o -match 'Skipped=1'))
    Add-TestCheck 'guard: exit 5'                   5     (Get-LastScriptExit)

    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0' -Stub -InUse @($aliceDir, $bobDir)
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'guard: all in use, nothing deleted' $TWO_ALL (Get-TotalBytes)
    Add-TestCheck 'guard: all-in-use message'          $true  ([bool]($o -match 'Every profile with a cache has Revit running'))
    Add-TestCheck 'guard: not "nothing to do"'         $false ([bool]($o -match 'nothing to do'))
    Add-TestCheck 'guard: all in use, exit 5'          5      (Get-LastScriptExit)

    # Proves the guard filters BEFORE the measure pass: 0.005GB = 5.24MB, which 6MB
    # (both profiles) would clear but 3MB (one profile) must not.
    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0.005' -Stub -InUse @($aliceDir)
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'guard+gate: gate stayed closed'  $TWO_ALL (Get-TotalBytes)
    Add-TestCheck 'guard+gate: below-threshold msg' $true ([bool]($o -match 'below the 0.005GB threshold'))
    Add-TestCheck 'guard+gate: exit 5 (precedence)' 5     (Get-LastScriptExit)

    # Deletion failure (3) must outrank a skip (5).
    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0' -Stub -InUse @($aliceDir)
    $fs = [IO.File]::Open((Join-Path (Get-CacheDir 'bob') 'sub\a.dat'), 'Open', 'ReadWrite', 'None')
    try   { $o = Invoke-ScriptUnderTest -Path $Run } finally { $fs.Close(); $fs.Dispose() }
    Add-TestCheck 'precedence: exit 3 not 5'    3     (Get-LastScriptExit)
    Add-TestCheck 'precedence: skip still logged' $true ([bool]($o -match '\[alice\] SKIPPED'))

    # Unattributable process: fail safe in delete mode, informational in report mode.
    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0' -Stub -InUse @() -Unknown @(4242)
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'unknown owner: exit 6'         6        (Get-LastScriptExit)
    Add-TestCheck 'unknown owner: nothing deleted' $TWO_ALL (Get-TotalBytes)
    Add-TestCheck 'unknown owner: names the PID'  $true    ([bool]($o -match 'PID\(s\) 4242'))

    New-FakeTree -Names $TWO; New-TestScriptCopy -ReportOnly 'true' -Threshold '0' -Stub -InUse @() -Unknown @(4242)
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'unknown owner + report: exit 0'    0        (Get-LastScriptExit)
    Add-TestCheck 'unknown owner + report: no delete' $TWO_ALL (Get-TotalBytes)
    Add-TestCheck 'unknown owner + report: warning'   $true    ([bool]($o -match 'A live run would refuse'))

    # Guard off: the detector must not even be invoked.
    New-FakeTree -Names $TWO
    if (Test-Path -LiteralPath $Marker) { Remove-Item -LiteralPath $Marker -Force }
    New-TestScriptCopy -Threshold '0' -Guard 'false' -Stub -InUse @($aliceDir)
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'guard off: detector NOT called' $false (Test-Path -LiteralPath $Marker)
    Add-TestCheck 'guard off: both cleaned'        (($PROFILE_ALL - $PROFILE_STALE) * 2) (Get-TotalBytes)
    Add-TestCheck 'guard off: shows "off"'         $true ([bool]($o -match 'RevitGuard     : off'))
    Add-TestCheck 'guard off: exit 0'              0     (Get-LastScriptExit)

    # Guard on with no process names: real detector, warns, skips nothing.
    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0' -ProcNames '@()'
    $o = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'empty process names: warning' $true ([bool]($o -match 'no process names are configured'))
    Add-TestCheck 'empty process names: cleaned' (($PROFILE_ALL - $PROFILE_STALE) * 2) (Get-TotalBytes)
    Add-TestCheck 'empty process names: exit 0'  0     (Get-LastScriptExit)

    New-FakeTree -Names $TWO; New-TestScriptCopy -Threshold '0' -Stub -InUse @($aliceDir)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = & $Run
    $ErrorActionPreference = $old
    $obj = @($raw | Where-Object { $_ -isnot [string] })[0]
    Add-TestCheck 'summary: GuardEnabled'        $true   $obj.GuardEnabled
    Add-TestCheck 'summary: SkippedProfileCount' 1       $obj.SkippedProfileCount
    Add-TestCheck 'summary: SkippedProfiles'     'alice' ($obj.SkippedProfiles -join ',')
}
finally {
    Remove-TestWorkspace -Path $ws
}

Write-TestSummary -SuiteName 'Clear-RevitCache / Guard'
exit (Get-TestFailureCount)
