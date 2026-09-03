# Tests

Regression suites for the scripts in this repo. They were written while building and
fixing those scripts — each one exists because it caught something real, and several are
written specifically to fail if a fixed bug ever comes back.

```powershell
.\Invoke-AllTests.ps1                      # everything safe for this session
.\Invoke-AllTests.ps1 -IncludeRealProfile  # full coverage, run elevated
.\Clear-RevitCache\Test-Guard.ps1          # one suite, full check-by-check table
```

Each suite exits with its failure count, so the runner just sums them. Run a suite
directly to see every individual check; the runner shows the roll-up.

---

## 1. How these tests work

They are **not** unit tests. There is no mocking framework and the scripts under test are
not modules — they are standalone `.ps1` files that VSA uploads and runs. So the suites use
three techniques:

**Patched copy, run as a child process.** The script is read, its `CONFIGURATION` block
string-replaced (`$ProfileRoot` → a temp tree, `$LogPath` → a temp file, `$ReportOnly`,
thresholds, guard settings), written to the workspace, and executed via
`powershell.exe -File`. This exercises the real script end to end — parameter validation,
control flow, exit codes, log output — rather than re-implementing its logic in the test.

**AST extraction, dot-sourced.** For testing one function in isolation, the function's
source text is pulled out of the script by walking the AST for its
`FunctionDefinitionAst`, then dot-sourced into the suite along with the scope variables it
reads. Needed because the scripts cannot be dot-sourced — they *run*, and they call `exit`.

**Stub injection.** Where a function reads live machine state that cannot be faked
(`Get-RevitInUseProfile` reads the process table), the suite injects a replacement
definition into the patched copy just before the call site, returning canned data. That
covers everything *downstream* of detection. Detection itself is covered separately
against real processes.

Common scaffolding lives in [`TestCommon.ps1`](TestCommon.ps1) — workspace creation,
`Add-TestCheck`/`Write-TestSummary`, child-process invocation, elevation checks. Unlike the
production scripts (deliberately self-contained so each can be uploaded to VSA alone), the
tests are never deployed, so sharing helpers here costs nothing.

### Safety

- All synthetic trees are created under `%TEMP%`, never in the repo, and removed in a
  `finally` block.
- Teardown removes reparse points with `rmdir` **before** `Remove-Item -Recurse`, because
  several suites deliberately create junctions to test the safety gate and
  `Remove-Item -Recurse` would follow one and delete the target.
- Every run of a cleanup script is `-ReportOnly` unless the suite is specifically testing
  deletion on its own synthetic files.
- `Test-TaskScripts.ps1` writes to the real production `$LogDir`. It records which files it
  created and removes exactly those, leaving pre-existing logs alone.
- `Test-GuardEndToEnd.ps1` is the only suite touching a real profile. It requires an
  explicit `-AllowRealProfile` switch and **aborts** if an `AppData\Local\Autodesk` tree
  already exists, so it can never plant into or delete from a real Autodesk installation.

---

## 2. The suites

| Suite | Checks | Needs |
|---|---|---|
| [`Clear-RevitCache\Test-Guard.ps1`](Clear-RevitCache/Test-Guard.ps1) | 86 | — |
| [`Clear-RevitCache\Test-GuardDetection.ps1`](Clear-RevitCache/Test-GuardDetection.ps1) | 13 | elevation |
| [`Clear-RevitCache\Test-GuardEndToEnd.ps1`](Clear-RevitCache/Test-GuardEndToEnd.ps1) | 12 | elevation + `-AllowRealProfile` |
| [`Invoke-DiskCleanup\Test-LogPollutionBugs.ps1`](Invoke-DiskCleanup/Test-LogPollutionBugs.ps1) | 15 | — |
| [`Invoke-DiskCleanup\Test-TaskScripts.ps1`](Invoke-DiskCleanup/Test-TaskScripts.ps1) | 70 | elevation recommended |

### Clear-RevitCache\Test-Guard.ps1 — behaviour suite

The broad one. Synthetic profile trees holding 2 MB + 1 MB of stale files and one 5 MB
fresh file per profile, so 8 MB total and 3 MB reclaimable — every assertion is an exact
byte count, not "roughly".

Covers: the `$MinSpaceToFreeGB` threshold gate (blocks, opens, fractional values,
`0` = disabled making exactly **one** pass); `$ReportOnly`; locked files producing exit 3;
`$MaxAgeDays` validation rejecting `0`/`-1` with exit 2; logging prerequisites; junction
containment; profile-root discovery and override; log rotation and archive pruning; the
"no cache folders at all" outcome; the `VERBOSE` log level routing to `Write-Verbose`; and
the summary object on the success stream.

Then the Revit-running guard's consumption logic with a canned detector: one-of-two
profiles skipped, all-profiles-skipped, exit-code precedence, the guard filtering
*before* the measure pass, unattributable-process handling in both delete and report mode,
guard disabled, and empty process-name list.

### Clear-RevitCache\Test-GuardDetection.ps1 — the detector, live

Exercises `Get-RevitInUseProfile` against the real process table, using `powershell.exe`
as a stand-in for `Revit.exe`. Proves the SID → `Win32_UserProfile.LocalPath` mapping
resolves to the correct profile.

**Elevation is mandatory** and that is the point: `GetOwnerSid` cannot query other users'
processes without admin, so unelevated this suite reports dozens of "unattributable"
processes and proves nothing about production. Measured: svchost went from **94 of 102
unattributable** unelevated to **0** elevated.

Two assertions worth knowing about:

- The elevated-attribution check is a **ratio** (≥ 90% attributable), not an exact zero.
  There is an unavoidable race between enumerating `Win32_Process` and calling
  `GetOwnerSid` on each result — a short-lived svchost that exits in between cannot have
  its owner resolved, so the count legitimately flickers by 1–2. The 10% ceiling still
  fails loudly on loss of privilege (92% unattributable).
- The fail-safe path is exercised with PID 4 (`System`), a protected process whose owner
  lookup fails **even for an admin**. That keeps the exit-6 trigger under test in the real
  deployment context rather than as a privilege artifact.

### Clear-RevitCache\Test-GuardEndToEnd.ps1 — nothing stubbed

The only suite where the whole chain runs for real: profile discovery → live SID
attribution → skip decision, with `#Requires -RunAsAdministrator` left intact so the
script runs exactly as deployed.

Because the guard matches a cache folder against `Win32_UserProfile.LocalPath`, a temp
tree can never match — so it plants a synthetic cache inside the current user's real
profile. Two **paired** cases, which together prove the skip is caused by live detection
rather than by accident:

- `@('powershell.exe')` → profile skipped, files untouched, exit 5
- `@('NoSuchProcess-zzz')` → the *same* cache cleaned, exit 0

### Invoke-DiskCleanup\Test-LogPollutionBugs.ps1 — the important one

Guards a bug class that once affected four functions simultaneously, one of which
**silently defeated the path safety gate**.

`Write-Log` routes INFO *and* WARN to `Write-Output` — the success stream. So any function
that logged *and* returned a value actually returned `@(log strings…, realValue)`. What
that did in the shipped script:

- **`Test-SafeCleanupPath`** logged a WARN before returning `$false` in 6 of its 8
  rejection paths. `-not @(str, $false)` is `$false`, so the gate did not fire and
  deletion **proceeded on paths it had just rejected**, while the log said "Path
  rejected". The reachable trigger was the reparse-point rejection: a junctioned cleanup
  target got walked through — precisely the hazard the documented safety model promises to
  prevent.
- **`Test-TaskEnabled`** did the same, so **`-SkipTasks` logged "skipped" and then ran the
  task anyway**. The deadline and free-space-target gates were equally inert.
- **`Clear-PathAgedFiles`** logged when preserving a protected extension, so the caller's
  `$r.Bytes` **threw** under `Set-StrictMode -Version Latest`. A `.bak` in a temp folder
  was enough to kill the task.
- **`Get-UserProfilePath`** logged in its CIM-failure fallback, injecting log strings into
  `$profilePaths`, which were then treated as profile paths.

The suite sets `Set-StrictMode -Version Latest` because the real script does — without it,
member enumeration over a polluted return silently succeeds and the fault is invisible.
That detail matters: an earlier version of this test passed against broken code for
exactly that reason.

### Invoke-DiskCleanup\Test-TaskScripts.ps1 — the extracted task scripts

Covers the six opt-in scripts split out of `Invoke-DiskCleanup.ps1`, and the seams where
that split could break:

- All 7 scripts run under `-ReportOnly`, exit 0, and write all three outputs
  (`.log`, `_Summary.json`, `ScriptResult_*.txt`) into the configured `$LogDir`. The
  expected folder is **read from each script's own `$LogDir` assignment**, not hardcoded —
  so moving the output directory stays a one-line change and this suite follows it. It
  also asserts all 7 agree on the same `$LogDir`.
- Each `_Summary.json` is valid JSON naming the right `$ScriptName`.
- `Get-Help` renders a SYNOPSIS for all 7. This guards a PowerShell 5.1 quirk that has
  silently broken twice: **any** non-blank line abutting the `<#` help block — a
  `#Requires`, or even a comment — suppresses comment-based help entirely, leaving a bare
  syntax line. It took `Invoke-DiskCleanup.ps1` from 11,100 characters of help to 650.
- Log-rotation isolation: the main script's prune filter once matched every per-task log
  (`DiskCleanup_*.log`) and would have deleted them. A seeded task archive must survive a
  main-script rotation.
- The removed opt-in switches are genuinely gone — passing `-EmptyRecycleBin` must fail as
  an unknown parameter.

`ComponentCleanup` and `WindowsOld` are destructive and slow; their deletion paths are
deliberately **not** exercised (report mode neither invokes DISM nor takes ownership) and
were verified by inspection instead.

---

## 3. Adding a suite

Drop a `Test-*.ps1` under a subfolder; the runner discovers it automatically. Convention:

```powershell
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\TestCommon.ps1')

$Src = Get-ScriptUnderTest 'Folder\Script.ps1'   # throws if it has moved
$ws  = New-TestWorkspace -Label 'mysuite'

Reset-TestChecks
try   { Add-TestCheck 'what it should do' $expected $actual }
finally { Remove-TestWorkspace -Path $ws }

Write-TestSummary -SuiteName 'Folder / MySuite'
exit (Get-TestFailureCount)
```

Gating is inferred from the file's text, so no manifest to maintain: call
`Assert-Elevated` and the runner skips the suite when unelevated; take an
`-AllowRealProfile` switch and it is skipped unless `-IncludeRealProfile` is passed.

### A note on PSScriptAnalyzer

The production scripts hold a zero-findings bar. The test code deliberately does **not**,
because a few of its findings are the point:

| Finding | Why it stays |
|---|---|
| `PSAvoidOverwritingBuiltInCmdlets` | `Test-LogPollutionBugs.ps1` shadows `Get-CimInstance` on purpose, to force `Get-UserProfilePath` down its fallback branch. |
| `PSUseDeclaredVarsMoreThanAssignments` | The scope variables consumed by AST-dot-sourced functions. PSSA cannot see that usage. |
| `PSUseShouldProcessForStateChangingFunctions` | `New-TestWorkspace` / `Remove-TestWorkspace` etc. `ShouldProcess` on a test helper would be noise. |
| `PSUseSingularNouns` | Cosmetic, on helpers like `Get-TreeBytes`. |
| `PSAvoidUsingEmptyCatchBlock` | One `try { ConvertFrom-Json } catch { }` used as a validity probe. |

Don't "fix" the first two — they would break the tests.

Two traps worth avoiding, both of which bit these files during development:

- **Do not build a result set with `$rows = foreach {...}`** if you also `Write-Output`
  progress inside the loop — the progress strings get captured into `$rows`. Use an
  explicit `List` and `.Add()`. This is the same success-stream pollution the suites exist
  to catch.
- **Save with a UTF-8 BOM** if the file contains box-drawing characters. Without one,
  PowerShell 5.1 may read it as ANSI and mangle them — which corrupted a string-replace
  anchor in one of these harnesses. Prefer ASCII-only anchors for string replacement
  regardless.
