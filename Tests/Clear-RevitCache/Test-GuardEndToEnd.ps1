<#
.SYNOPSIS
    Clear-RevitCache.ps1 - true end-to-end guard test. Needs elevation AND -AllowRealProfile.

.DESCRIPTION
    The only suite that exercises the whole chain with nothing stubbed: real profile
    discovery, real SID-to-profile attribution, real skip decision. Test-Guard.ps1 covers
    the consumption logic with a canned detector; this proves the detector actually drives
    it in a real run.

    Because the guard matches a cache folder's profile path against
    Win32_UserProfile.LocalPath, a synthetic tree under TEMP can never match. So this test
    plants a synthetic cache inside the CURRENT USER'S REAL PROFILE:

        $env:USERPROFILE\AppData\Local\Autodesk\Revit\Autodesk Revit 2025\CollaborationCache

    powershell.exe stands in for Revit.exe, since live PowerShell processes are owned by
    the current user and resolve to a real profile.

    Two paired cases, which together prove the skip is caused by live detection rather
    than by accident:
      - $RevitProcessNames = @('powershell.exe')      -> profile skipped, files untouched, exit 5
      - $RevitProcessNames = @('NoSuchProcess-zzz')   -> same cache cleaned, exit 0

    SAFETY
      - Requires -AllowRealProfile. It will not run by accident.
      - ABORTS if AppData\Local\Autodesk already exists, so it can never plant into, or
        delete from, a real Autodesk installation's data. On a machine with Revit
        installed this suite simply refuses to run.
      - Only ever touches files it created; teardown removes the whole Autodesk subtree
        it made and verifies the removal, reporting a FAIL if anything is left behind.

.PARAMETER AllowRealProfile
    Required. Acknowledges that the test writes into the current user's profile.
#>

[CmdletBinding()]
param([switch]$AllowRealProfile)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

if (-not $AllowRealProfile) {
    Write-Warning @"
ABORT: this suite plants a synthetic Revit cache under `$env:USERPROFILE and then removes it.
Re-run with -AllowRealProfile to acknowledge that. See the help in this file for the safety
guarantees, or run Test-Guard.ps1 instead, which is fully synthetic.
"@
    exit 1
}

Assert-Elevated -SuiteName 'Test-GuardEndToEnd'

$Src = Get-ScriptUnderTest 'Clear-RevitCache\Clear-RevitCache.ps1'
$ws  = New-TestWorkspace -Label 'revite2e'
$Run = Join-Path $ws 'under-test.ps1'
$Log = Join-Path $ws 'e2e.log'

# ── Safety gate ───────────────────────────────────────────────────────────────
$autodeskRoot = Join-Path $env:USERPROFILE 'AppData\Local\Autodesk'
if (Test-Path -LiteralPath $autodeskRoot) {
    Remove-TestWorkspace -Path $ws
    throw "ABORT: '$autodeskRoot' already exists. Refusing to plant test data into a real Autodesk tree."
}

$cache = Join-Path $autodeskRoot 'Revit\Autodesk Revit 2025\CollaborationCache\sub'
$ALL   = 8MB
$STALE = 3MB

function New-PlantedCache {
    if (Test-Path -LiteralPath $autodeskRoot) { Remove-Item -LiteralPath $autodeskRoot -Recurse -Force }
    New-AgedFile -Path (Join-Path $cache 'a.dat')     -Bytes 2MB -AgeDays 30
    New-AgedFile -Path (Join-Path $cache 'b.dat')     -Bytes 1MB -AgeDays 30
    New-AgedFile -Path (Join-Path $cache 'fresh.dat') -Bytes 5MB
}

function New-TestScriptCopy {
    param([string]$ProcNames)
    # #Requires lines are deliberately LEFT INTACT - we are elevated, so this runs the
    # script exactly as deployed. $ProfileRoot stays empty to exercise real auto-detect.
    $t = (Get-Content $Src -Raw)
    $t = $t.Replace('"C:\INS-Temp\Clear-RevitCache.log"', '"' + $Log + '"')
    $t = $t.Replace('$ReportOnly = $true',  '$ReportOnly = $false')
    $t = $t.Replace('$ReportOnly = $false', '$ReportOnly = $false')
    $t = $t -replace '\[double\]\$MinSpaceToFreeGB = [\d.]+', '[double]$MinSpaceToFreeGB = 0'
    $t = $t.Replace("`$RevitProcessNames = @('Revit.exe')", "`$RevitProcessNames = $ProcNames")
    $t | Set-Content -LiteralPath $Run -Encoding utf8
}

Reset-TestChecks
try {
    # ── Revit "running" for this user -> profile skipped ─────────────────────
    New-PlantedCache
    New-TestScriptCopy -ProcNames "@('powershell.exe')"
    $o1 = Invoke-ScriptUnderTest -Path $Run
    Add-TestCheck 'in use: found exactly one cache' $true ([bool]($o1 -match 'Found 1 Collaboration Cache folder'))
    Add-TestCheck 'in use: profile skipped'         $true ([bool]($o1 -match 'SKIPPED: Revit is running for this user'))
    Add-TestCheck 'in use: files UNTOUCHED'         $ALL  (Get-TreeBytes -Path $cache)
    Add-TestCheck 'in use: summary Skipped=1'       $true ([bool]($o1 -match 'Skipped=1'))
    Add-TestCheck 'in use: exit 5'                  5     (Get-LastScriptExit)
    Add-TestCheck 'in use: named the real profile'  $true ([bool]($o1 -match [regex]::Escape("[$env:USERNAME]")))

    # ── Nothing in use -> the SAME cache is cleaned ──────────────────────────
    New-TestScriptCopy -ProcNames "@('NoSuchProcess-zzz.exe')"
    $o2 = Invoke-ScriptUnderTest -Path $Run
    # Match the specific log line: -match is case-insensitive and the summary object
    # renders property names like SkippedProfiles, so a bare 'SKIPPED' matches even
    # when nothing was skipped.
    Add-TestCheck 'not in use: no skip logged'    $false          ([bool]($o2 -match 'SKIPPED: Revit is running'))
    Add-TestCheck 'not in use: no Skipped= count' $false          ([bool]($o2 -match 'Skipped=\d'))
    Add-TestCheck 'not in use: stale deleted'     ($ALL - $STALE) (Get-TreeBytes -Path $cache)
    Add-TestCheck 'not in use: fresh survived'    $true           (Test-Path -LiteralPath (Join-Path $cache 'fresh.dat'))
    Add-TestCheck 'not in use: exit 0'            0               (Get-LastScriptExit)
}
finally {
    # ── Teardown: remove only the subtree this test created ─────────────────
    if (Test-Path -LiteralPath $autodeskRoot) {
        Remove-Item -LiteralPath $autodeskRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-TestCheck 'teardown: planted tree removed' $true (-not (Test-Path -LiteralPath $autodeskRoot))
    Remove-TestWorkspace -Path $ws
}

Write-TestSummary -SuiteName 'Clear-RevitCache / EndToEnd'
exit (Get-TestFailureCount)
