<#
.SYNOPSIS
    Clear-RevitCache.ps1 - Revit-running detector, against LIVE processes. Needs elevation.

.DESCRIPTION
    Exercises Get-RevitInUseProfile for real: it maps a running process to a user profile
    by taking the process owner's SID (GetOwnerSid) and looking it up in
    Win32_UserProfile.LocalPath. Matching on SID rather than username matters because a
    profile folder is not reliably named after its user - duplicates become user.DOMAIN
    or user.000.

    powershell.exe stands in for Revit.exe: live PowerShell processes are owned by the
    current user, so the detector must resolve them to this profile.

    The function is extracted from the script by AST and dot-sourced. The script itself
    cannot be dot-sourced because it runs.

    WHY ELEVATION IS REQUIRED
    GetOwnerSid cannot query processes owned by other users without admin rights. Run
    unelevated, this suite would report dozens of "unattributable" processes and prove
    nothing about production behaviour - the script itself declares
    #Requires -RunAsAdministrator. Confirmed: svchost goes from 94 unattributable
    unelevated to 0 elevated.

    Reads process and profile state only. Deletes nothing, writes nothing.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

Assert-Elevated -SuiteName 'Test-GuardDetection'

$Src = Get-ScriptUnderTest 'Clear-RevitCache\Clear-RevitCache.ps1'

# ── Extract just the detector ─────────────────────────────────────────────────
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Src, [ref]$null, [ref]$null)
$fn  = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Get-RevitInUseProfile' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'Get-RevitInUseProfile not found - has the script changed?' }
. ([scriptblock]::Create($fn.Extent.Text))

$myProfile = $env:USERPROFILE.TrimEnd('\')

Reset-TestChecks

# ── Own processes resolve to this profile ─────────────────────────────────────
$r = Get-RevitInUseProfile -ProcessNames @('powershell.exe')
Add-TestCheck 'finds current profile'   $true ($r.InUsePaths.Contains($myProfile))
Add-TestCheck 'no unknown owners'       0     @($r.UnknownOwnerPids).Count
Add-TestCheck 'match is case-insensitive' $true ($r.InUsePaths.Contains($myProfile.ToUpper()))

# ── A name that does not exist is empty, not an error ────────────────────────
$r2 = Get-RevitInUseProfile -ProcessNames @('NoSuchProcess-zzz.exe')
Add-TestCheck 'bogus name: empty set'   0 $r2.InUsePaths.Count
Add-TestCheck 'bogus name: no unknowns' 0 @($r2.UnknownOwnerPids).Count

# ── Empty / null list short-circuits without touching CIM ────────────────────
Add-TestCheck 'empty name list: empty' 0 (Get-RevitInUseProfile -ProcessNames @()).InUsePaths.Count
Add-TestCheck 'null name list: empty'  0 (Get-RevitInUseProfile -ProcessNames $null).InUsePaths.Count

# ── Elevated attribution actually works ──────────────────────────────────────
# Pins the production assumption. If this regresses, exit 6 (owner unknown) would
# start firing on every machine and nothing would ever be cleaned.
#
# Asserted as a ratio, not an exact 0: there is an unavoidable race between
# enumerating Win32_Process and calling GetOwnerSid on each result. A short-lived
# svchost that exits in between cannot have its owner resolved, so the count
# legitimately flickers between 0 and 1-2 on a busy machine (observed across
# consecutive runs while the process count moved 107 -> 105).
#
# The 10% ceiling still catches what matters: run WITHOUT elevation this was 94 of
# 102 unattributable (92%), so loss of privilege fails this loudly.
$r5 = Get-RevitInUseProfile -ProcessNames @('svchost.exe')
$svcCount = @(Get-CimInstance Win32_Process -Filter "Name='svchost.exe'").Count
$unattributable = @($r5.UnknownOwnerPids).Count
$ratio = if ($svcCount -gt 0) { $unattributable / $svcCount } else { 1 }
Add-TestCheck 'svchost processes present'         $true ($svcCount -gt 0)
Add-TestCheck 'svchost attribution >=90% (elev.)' $true ($ratio -lt 0.10)
Add-TestCheck 'svchost resolves to profiles'      $true ($r5.InUsePaths.Count -gt 0)

# ── The fail-safe path is still reachable when elevated ──────────────────────
# PID 4 ('System') is a protected process whose owner lookup fails with ReturnValue=2
# even for an admin - so it exercises the exit-6 trigger in the real deployment
# context, unlike svchost which only failed because of missing privilege.
$r6 = Get-RevitInUseProfile -ProcessNames @('System')
Add-TestCheck 'protected process -> unknown'   $true (@($r6.UnknownOwnerPids).Count -gt 0)
Add-TestCheck 'protected process not "in use"' 0     $r6.InUsePaths.Count

# ── The detector must not log ────────────────────────────────────────────────
# Write-Log INFO writes to the success stream, so a logging function cannot cleanly
# return an object - the caller would get @(log lines..., $result). AST check, not a
# text search: the explanatory comment inside the function mentions the name.
$calls = $fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
         ForEach-Object { $_.GetCommandName() }
Add-TestCheck 'detector never calls Write-Log' $false ($calls -contains 'Write-Log')

Write-TestSummary -SuiteName 'Clear-RevitCache / Detection'
exit (Get-TestFailureCount)
