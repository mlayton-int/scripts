# Invoke-DiskCleanup.ps1 — Documentation

**Version:** 1.0
**Target:** Windows 10 / Windows 11 workstations (AD-joined, Azure AD-joined, Hybrid, Workgroup)
**Platform:** Kaseya VSA X agent procedure
**Execution context:** SYSTEM (required)
**PowerShell:** 5.1 baseline

---

## 1. Summary

`Invoke-DiskCleanup.ps1` reclaims disk space on managed workstations, unattended, without
interrupting whoever is logged in at the time.

It removes genuine junk — temp files, crash dumps, servicing logs, browser caches, Windows Update
download payloads, Delivery Optimization cache — using an explicit allow-list of paths, age filters,
and a path-safety gate that refuses to operate on anything resembling user data or critical system
state. Riskier reclamation (Recycle Bin, `Windows.old`, WinSxS cleanup, stale profiles, restore
points) lives in **separate opt-in scripts** under [`Tasks\`](Tasks/README.md), each deployed and
approved as its own procedure.

It never kills a process, never shows a UI, never reboots, and never forces a locked file open.
It reports by default: without `-Delete` it performs the full measurement pass and removes
nothing.

**Typical yield:** 2–15 GB on a neglected workstation with this script's safe tasks. Machines with
`Windows.old` present or a bloated component store can yield considerably more via the
[`Tasks\`](Tasks/README.md) scripts.

---

## 2. What it will not touch

These are deliberate refusals, documented so nobody "fixes" them later:

| Path / target | Why it's excluded |
|---|---|
| `C:\Windows\Installer` | Orphaned-patch cleanup breaks repair and uninstall for installed MSI apps. |
| `C:\ProgramData\Package Cache` | Required by Visual Studio / VC++ redistributable repair and uninstall. |
| `C:\Windows\Prefetch` | Negligible space, measurable boot and app-launch penalty. |
| `SoftwareDistribution\DataStore` | The Windows Update database itself — not a cache. |
| User `Desktop`, `Documents`, `Downloads`, `Pictures` | User data. Structurally blocked, not just skipped. |
| Browser cookies, logins, history, bookmarks | Cache subfolders only; profile data is never enumerated. |
| DISM `/ResetBase` | Permanently blocks uninstalling installed updates. Not offered as an option. |
| `C:\Windows\Fonts`, `WinSxS`, `System32\config` | Protected system state. |

---

## 3. How it works, step by step

### 3.1 Initialisation

1. **Log rotation.** `C:\INS-Temp\Logs\DiskCleanup.log` is rotated if it exceeds 5 MB;
   the five most recent archives are retained, older ones deleted.
2. **Process priority** is dropped to `BelowNormal` so the run doesn't compete with the user's
   foreground work.
3. **Join type** is detected via `dsregcmd /status` (AD / AAD / Hybrid / Local) and logged. The
   cleanup logic itself is join-agnostic, but the value is logged for correlation when a fleet-wide
   pattern emerges.
4. **Identity** is logged — expect `NT AUTHORITY\SYSTEM`. If it says anything else, the profile
   enumeration and system-path cleanup will be incomplete.
5. **Runtime deadline** is set (`-MaxRuntimeMinutes`, default 45). Every task and every directory
   loop checks it and aborts cleanly rather than being killed mid-delete.
6. **Free space is measured** via `Win32_LogicalDisk`.
7. **Early exit check.** If `-RunOnlyIfFreeSpaceBelowGB` is set and the machine already has more
   free space than that, the script exits 0 immediately with a "skipped" result. This is what keeps
   a fleet-wide schedule cheap.
8. **User profiles are enumerated** via `Win32_UserProfile` (excluding `Special` profiles), falling
   back to a directory listing of `C:\Users` if WMI fails.

### 3.2 The safety gate — `Test-SafeCleanupPath`

Every path handed to the deletion engine passes through this first. It returns `$false`, logs a
warning, and skips the target if any of the following is true:

- The path is empty, unparseable, shorter than four characters, or a bare drive root (`C:`).
- The path exactly matches a protected path (`C:\Windows`, `C:\Users`, `C:\Program Files`,
  `C:\Windows\Installer`, `C:\ProgramData\Package Cache`, `C:\ProgramData\Kaseya`, and others).
- The path is an **ancestor** of a protected path. This is the one that catches a bad edit: pass it
  `C:\` or `C:\Windows` in any form and it refuses, because a protected path lives beneath it.
- The path is under `C:\Users\` but **not** inside `AppData\Local`, `AppData\LocalLow`, or
  `AppData\Roaming`. This is a structural guarantee that no cleanup task can reach a user's
  Documents, Desktop, or Downloads regardless of what someone adds to the task list later.
- The path doesn't exist, isn't a directory, or **is a reparse point** (junction/symlink).

### 3.3 The deletion engine — `Clear-PathAgedFiles`

A manual, stack-based directory walk rather than `Get-ChildItem -Recurse`. The reason matters:
`-Recurse` in PowerShell 5.1 will follow junctions such as the legacy `AppData\Local\Application Data`
loop and can wander outside the intended tree. This walker checks the `ReparsePoint` attribute on
every entry and neither descends into nor deletes it.

For each file found, deletion requires **all** of the following:

- `LastWriteTime` older than the task's age threshold.
- Extension not in `-ProtectedExtensions` (`.pst`, `.ost`, `.nst`, `.edb`, `.vhd`, `.vhdx`, `.avhdx`,
  `.vhdpmem`, `.kdbx`, `.pfx`, `.p12`, `.key`, `.psafe3`, `.bak`). A preserved file is logged by name.
- The `System` file attribute is not set.
- The name matches `-IncludeFilter`, when a task supplies one (e.g. thumbnail caches only match
  `thumbcache_*.db` and `iconcache_*.db`).

Deletion is per-file inside a `try/catch`. **Locked, in-use, or ACL-denied files are counted as
skipped and left in place** — there is no handle-closing, no `takeown` on general content, no retry
loop. Directories that end up empty are pruned deepest-first; the task's root folder is never removed.

Without `-Delete`, the engine performs the identical walk and filter logic but records sizes
instead of deleting, so the report reflects exactly what a live run would remove.

### 3.4 Task isolation

Each task runs inside `Invoke-CleanupTask`, which wraps it in `try/catch`. A task that throws is
logged as `FAILED` with its detail recorded in the summary, and the run continues. One broken task
never costs you the rest of the cleanup — or the reporting.

Before each task, `Test-TaskEnabled` checks three things: whether the task name appears in
`-SkipTasks`, whether the runtime deadline has passed, and whether `-StopWhenFreeSpaceGB` has
already been reached. Any of those skips the task with a logged reason.

### 3.5 The tasks, in execution order

**Default (always run unless named in `-SkipTasks`):**

| # | Task | What it clears | Age gate |
|---|---|---|---|
| 1 | `WindowsTemp` | `C:\Windows\Temp` | `-TempFileAgeDays` (2) |
| 2 | `UserTemp` | `AppData\Local\Temp` in every profile | `-TempFileAgeDays` (2) |
| 3 | `UserInternetCache` | Legacy WinINET/IE caches, `WebCache` | `-TempFileAgeDays` (2) |
| 4 | `WindowsErrorReporting` | WER `ReportQueue`, `ReportArchive`, `Temp` (machine + per-user) | `-DumpFileAgeDays` (7) |
| 5 | `MemoryDumps` | `MEMORY.DMP`, `Minidump`, `LiveKernelReports`, per-user `CrashDumps` | `-DumpFileAgeDays` (7) |
| 6 | `WindowsLogs` | `Logs\CBS`, `Logs\DISM`, `Logs\MoSetup`, `Logs\WindowsUpdate`, `Panther` | `-LogFileAgeDays` (14) |
| 7 | `DownloadedProgramFiles` | Legacy ActiveX/Java payloads | `-LogFileAgeDays` (14) |
| 8 | `DeliveryOptimization` | DO peer cache via `Delete-DeliveryOptimizationCache` | n/a |
| 9 | `WindowsUpdateCache` | `SoftwareDistribution\Download` | `-UpdateCacheAgeDays` (10) |
| 10 | `ThumbnailCache` | `thumbcache_*.db`, `iconcache_*.db` | `-TempFileAgeDays` (2) |
| 11 | `BrowserCache` | Chrome, Edge, Brave, Firefox — cache folders only | none (cache is disposable) |

Three of these have extra interlocks worth knowing:

- **`WindowsUpdateCache`** skips entirely if `TiWorker`, `TrustedInstaller`, or `wusa` is running,
  or if a reboot is pending — in both cases the cached payloads are still needed. Otherwise it stops
  `wuauserv`, `bits`, `dosvc`, and `usosvc`, records which were running, cleans, and restarts them in
  a `finally` block so a mid-task failure still leaves Windows Update functional. Service state is
  transparent to the user.
- **`ThumbnailCache`** is skipped when `explorer.exe` is running, because the cache databases are
  held open by the active session. This is reported as a skip, not a failure.
- **`BrowserCache`** skips any browser whose process is running, per browser, rather than the whole
  task. It only ever touches named cache subfolders (`Cache`, `Code Cache`, `GPUCache`,
  `Service Worker\CacheStorage`, `ShaderCache`, and Firefox's `cache2`), and it iterates Chromium
  profile folders (`Default`, `Profile 1`, …) so multi-profile users are covered. Cookies, saved
  logins, history, and bookmarks are never enumerated.

**Opt-in tasks are separate scripts.**

Everything that trades a recovery option for space now lives in [`Tasks\`](Tasks/README.md)
as its own self-contained script, run from its own VSA procedure with its own log, summary and
result file. This script performs only the always-safe cleanup above.

| Script | Task | Trade-off |
|---|---|---|
| `Tasks\Clear-AgedRecycleBin.ps1` | `RecycleBin` | Removes the user's own undo. Age-gated. |
| `Tasks\Clear-TeamsCache.ps1` | `TeamsCache` | May force a Teams re-login on some builds. |
| `Tasks\Remove-WindowsOld.ps1` | `WindowsOld` | Removes OS rollback. Age-gated. |
| `Tasks\Invoke-ComponentCleanup.ps1` | `ComponentCleanup` | CPU-heavy DISM WinSxS cleanup. No `/ResetBase`. |
| `Tasks\Remove-StaleProfile.ps1` | `StaleProfiles` | Deletes unloaded profiles. Capped per run. |
| `Tasks\Remove-OldRestorePoint.ps1` | `RestorePoints` | Deletes shadow copies beyond the keep count. |

See [`Tasks\README.md`](Tasks/README.md) for their parameters, safety notes, deployment and
rollout order.

Tasks that can't self-report bytes (`DeliveryOptimization`) measure free-space delta before and
after, clamped at zero. That figure is noisier than a file-by-file
count because other processes are writing to disk concurrently.

### 3.6 Reporting and exit

The script writes a JSON summary to `C:\INS-Temp\Logs\DiskCleanup_Summary.json`
(machine details, before/after free space, per-task results), logs the final totals, and emits a
single result string capped at 480 characters:

- `SUCCESS: …` — the run completed, including runs where individual tasks failed or were skipped
  (those appear in the log and JSON). **Exit code 0.**
- `FAILURE: <exception>` — an unhandled error outside any task wrapper. **Exit code 1.**

The result string is written to `C:\INS-Temp\Logs\ScriptResult_DiskCleanup.txt` and to stdout.

---

## 4. Parameter reference

### Age thresholds

| Parameter | Default | Description |
|---|---|---|
| `-TempFileAgeDays` | `2` | Minimum age for temp, internet cache, and thumbnail cache files. Don't go below 1 — files written earlier the same day may still be in use by an installer. |
| `-LogFileAgeDays` | `14` | Minimum age for servicing and setup logs. Keep at least 7 if you ever troubleshoot upgrade failures. |
| `-DumpFileAgeDays` | `7` | Minimum age for crash and memory dumps. Raise on machines under active BSOD investigation. |
| `-UpdateCacheAgeDays` | `10` | Minimum age for Windows Update download payloads. |

Age gates for the opt-in tasks are parameters of their own scripts — see
[`Tasks\README.md`](Tasks/README.md).

### Run control

| Parameter | Default | Description |
|---|---|---|
| `-Delete` | off | Actually delete. Omit it for a full measurement pass with no deletions. |
| `-RunOnlyIfFreeSpaceBelowGB` | `0` | Exit 0 immediately if free space already exceeds this. `0` = always run. |
| `-StopWhenFreeSpaceGB` | `0` | Stop starting new tasks once free space reaches this. `0` = run everything. |
| `-MaxRuntimeMinutes` | `45` | Hard runtime cap. Set below your VSA procedure timeout. |
| `-SkipTasks` | `@()` | Task names to skip. Valid: `WindowsTemp`, `UserTemp`, `UserInternetCache`, `WindowsErrorReporting`, `MemoryDumps`, `WindowsLogs`, `DownloadedProgramFiles`, `DeliveryOptimization`, `WindowsUpdateCache`, `ThumbnailCache`, `BrowserCache`. |
| `-ProtectedExtensions` | see §3.3 | Never deleted, wherever encountered. Add site-specific formats here. |

### Opt-in tasks

Not parameters of this script. Each is a separate procedure — see
[`Tasks\README.md`](Tasks/README.md).

### Suggested profiles

Reporting is the default. Every line below that is meant to actually reclaim space passes
`-Delete`.

```powershell
# Pilot / audit — deletes nothing (the default)
.\Invoke-DiskCleanup.ps1

# Fleet-wide scheduled maintenance (safe defaults, no-ops on healthy machines)
.\Invoke-DiskCleanup.ps1 -RunOnlyIfFreeSpaceBelowGB 20 -MaxRuntimeMinutes 30 -Delete

# Targeted remediation for a low-disk alert
.\Invoke-DiskCleanup.ps1 -StopWhenFreeSpaceGB 25 -Delete

# Then, if that was not enough, the opt-in tasks as their own procedures.
# Audit first, then run for real:
.\Tasks\Remove-WindowsOld.ps1
.\Tasks\Remove-WindowsOld.ps1 -Delete
```

---

## 5. Sample output

### 5.1 Result string (what the VSA procedure captures)

Success, safe defaults:

```
SUCCESS: Reclaimed 8.42 GB. Free 11.30 GB -> 19.72 GB of 237.15 GB. Top: WindowsUpdateCache 3.91 GB, BrowserCache 2.14 GB, UserTemp 1.28 GB.
```

Skipped because the machine is healthy:

```
SUCCESS: Skipped - free space 84.11 GB already above 20 GB threshold.
```

Stopped early once the target was met:

```
SUCCESS: Reclaimed 14.02 GB. Free 6.10 GB -> 20.14 GB of 237.15 GB. Top: WindowsOld 9.77 GB, WindowsUpdateCache 2.88 GB, WindowsTemp 812.4 MB. Stopped early: free space target reached.
```

Report-only:

```
SUCCESS: Reclaimable 6.88 GB. Free 11.30 GB -> 11.30 GB of 237.15 GB. Top: BrowserCache 2.61 GB, WindowsUpdateCache 2.05 GB, UserTemp 1.44 GB.
```

Fatal error:

```
FAILURE: Cannot find drive. A drive with the name 'C' does not exist.
```

### 5.2 Log file excerpt

`C:\INS-Temp\Logs\DiskCleanup.log`

```
[2026-08-20 02:14:03][INFO] === DiskCleanup v1.0 START ===
[2026-08-20 02:14:03][INFO] Join type detected: Hybrid
[2026-08-20 02:14:03][INFO] Running as: NT AUTHORITY\SYSTEM
[2026-08-20 02:14:04][INFO] Free space before: 11.30 GB of 237.15 GB
[2026-08-20 02:14:05][INFO] User profiles in scope: 3
[2026-08-20 02:14:05][INFO] --- Task start: WindowsTemp
[2026-08-20 02:14:41][INFO] WindowsTemp: Reclaimed 812.4 MB from 3,204 items (17 skipped/locked). Files older than 2 day(s).
[2026-08-20 02:14:41][INFO] --- Task start: UserTemp
[2026-08-20 02:15:18][INFO] Protected extension preserved: C:\Users\jsmith\AppData\Local\Temp\archive_backup.pst
[2026-08-20 02:15:52][INFO] UserTemp: Reclaimed 1.28 GB from 8,911 items (43 skipped/locked). Across 3 profile(s), older than 2 day(s).
[2026-08-20 02:15:52][INFO] --- Task start: UserInternetCache
[2026-08-20 02:16:09][INFO] UserInternetCache: Reclaimed 96.2 MB from 1,442 items (6 skipped/locked). 
[2026-08-20 02:16:09][INFO] --- Task start: WindowsErrorReporting
[2026-08-20 02:16:14][INFO] WindowsErrorReporting: Reclaimed 244.8 MB from 187 items (0 skipped/locked). Reports older than 7 day(s).
[2026-08-20 02:16:14][INFO] --- Task start: MemoryDumps
[2026-08-20 02:16:16][INFO] MemoryDumps: Reclaimed 1.02 GB from 4 items (0 skipped/locked). Dumps older than 7 day(s).
[2026-08-20 02:16:16][INFO] --- Task start: WindowsLogs
[2026-08-20 02:16:33][INFO] WindowsLogs: Reclaimed 318.7 MB from 926 items (2 skipped/locked). Logs older than 14 day(s).
[2026-08-20 02:16:33][INFO] --- Task start: DownloadedProgramFiles
[2026-08-20 02:16:33][INFO] DownloadedProgramFiles: Reclaimed 0 B from 0 items (0 skipped/locked). 
[2026-08-20 02:16:33][INFO] --- Task start: DeliveryOptimization
[2026-08-20 02:16:44][INFO] DeliveryOptimization: Reclaimed 610.3 MB from 0 items (0 skipped/locked). Measured by free-space delta.
[2026-08-20 02:16:44][INFO] --- Task start: WindowsUpdateCache
[2026-08-20 02:16:45][INFO] Stopped service 'wuauserv' for update cache cleanup.
[2026-08-20 02:16:46][INFO] Stopped service 'bits' for update cache cleanup.
[2026-08-20 02:17:29][INFO] WindowsUpdateCache: Reclaimed 3.91 GB from 2,048 items (0 skipped/locked). Payloads older than 10 day(s).
[2026-08-20 02:17:30][INFO] Restarted service 'wuauserv'.
[2026-08-20 02:17:31][INFO] Restarted service 'bits'.
[2026-08-20 02:17:31][INFO] --- Task start: ThumbnailCache
[2026-08-20 02:17:31][INFO] ThumbnailCache: Reclaimed 0 B from 0 items (3 skipped/locked). Skipped: an interactive session is active (cache files are locked).
[2026-08-20 02:17:31][INFO] --- Task start: BrowserCache
[2026-08-20 02:18:47][INFO] BrowserCache: Reclaimed 2.14 GB from 24,183 items (91 skipped/locked). Cache folders only - cookies, passwords, history and bookmarks untouched. Skipped (running): Chrome.
[2026-08-20 02:18:48][INFO] Free space after: 19.72 GB (delta 8.42 GB; tasks reported 8.42 GB)
[2026-08-20 02:18:48][INFO] === DiskCleanup COMPLETE ===
```

A rejected path looks like this — worth grepping for after any edit to the task list:

```
[2026-08-20 02:14:05][WARN] Path rejected (user profile data outside AppData): C:\Users\jsmith\Downloads
[2026-08-20 02:14:05][WARN] Path rejected (reparse point): C:\Users\jsmith\AppData\Local\Application Data
```

### 5.3 JSON summary

`C:\INS-Temp\Logs\DiskCleanup_Summary.json` (abridged)

```json
{
  "Script": "DiskCleanup",
  "Version": "1.0",
  "Computer": "WKS-FIN-014",
  "JoinType": "Hybrid",
  "TimestampUtc": "2026-08-20T02:18:48",
  "ReportOnly": false,
  "DriveTotalGB": 237.15,
  "FreeBeforeGB": 11.3,
  "FreeAfterGB": 19.72,
  "ReclaimedGB": 8.42,
  "FreeSpaceDeltaGB": 8.42,
  "StoppedEarly": false,
  "StopReason": "",
  "Tasks": [
    { "Task": "WindowsTemp", "Bytes": 851884032, "Items": 3204, "Failed": 17, "Status": "OK", "Detail": "Files older than 2 day(s)." },
    { "Task": "UserTemp", "Bytes": 1374389534, "Items": 8911, "Failed": 43, "Status": "OK", "Detail": "Across 3 profile(s), older than 2 day(s)." },
    { "Task": "WindowsUpdateCache", "Bytes": 4198154240, "Items": 2048, "Failed": 0, "Status": "OK", "Detail": "Payloads older than 10 day(s)." },
    { "Task": "ThumbnailCache", "Bytes": 0, "Items": 0, "Failed": 3, "Status": "OK", "Detail": "Skipped: an interactive session is active (cache files are locked)." },
    { "Task": "BrowserCache", "Bytes": 2297659392, "Items": 24183, "Failed": 91, "Status": "OK", "Detail": "Cache folders only - cookies, passwords, history and bookmarks untouched. Skipped (running): Chrome." }
  ]
}
```

The `Failed` count is expected to be non-zero on a machine with an active session. It counts files
that were in use and left alone — that's the safety model working, not an error.

---

## 6. VSA X deployment

### 6.1 Procedure setup

1. **Upload** `Invoke-DiskCleanup.ps1` to the VSA X script/file repository.
2. **Create an automation task** targeting Windows workstations.
3. **Execution context:** SYSTEM. The script will run under a user account but will silently miss
   other profiles and most system paths — check the `Running as:` log line if results look thin.
4. **Command.** VSA X runs the script directly inside an existing PowerShell session, so
   invoke it by path — there is no need to shell out to `powershell.exe`:

   ```powershell
   # Audit — reporting is the default
   .\Invoke-DiskCleanup.ps1 -RunOnlyIfFreeSpaceBelowGB 20

   # Actually reclaim space
   .\Invoke-DiskCleanup.ps1 -RunOnlyIfFreeSpaceBelowGB 20 -Delete
   ```

   Do not set the execution policy inside the script; VSA handles it.

   `-Delete` is a plain switch, so it binds the same way under any invocation style. That
   is deliberate: an earlier design used `-ReportOnly:$false` to opt into deleting, which
   works when the script is invoked directly but fails under
   `powershell.exe -File script.ps1 -ReportOnly:$false` — there every argument arrives as
   plain text and PowerShell 5.1 rejects it with `ParameterArgumentTransformationError`.
   A bare switch has no such trap.
5. **Timeout:** set the procedure timeout above `-MaxRuntimeMinutes` plus a few minutes of headroom
   (e.g. script 45, procedure 55). The script's own deadline should always fire first — that way you
   get a summary and a result string instead of a killed process.
6. **Capture the result** with a *Get Variable* step reading
   `C:\INS-Temp\Logs\ScriptResult_DiskCleanup.txt`, or branch on the exit code (0 / 1).
7. **Optionally collect** `C:\INS-Temp\Logs\DiskCleanup_Summary.json` for fleet reporting.

### 6.2 Scheduling

Safe defaults are non-disruptive enough to run during business hours — the run is `BelowNormal`
priority, skips locked files, and skips running browsers. In practice, scheduling it overnight or at
login gets better yield, because `BrowserCache` and `ThumbnailCache` only produce results when those
processes are closed.

A reasonable pattern:

- **Weekly, fleet-wide:** safe defaults with `-RunOnlyIfFreeSpaceBelowGB 20`. Most machines exit in
  under two seconds.
- **On low-disk alert:** targeted profile with `-StopWhenFreeSpaceGB` set to your alert clear
  threshold, so it stops as soon as the alert would clear.
- **Quarterly / change window:** the opt-in task procedures, particularly
  `Tasks\Invoke-ComponentCleanup.ps1`. See [`Tasks\README.md`](Tasks/README.md).

Passing switch parameters from VSA is done by including or omitting the switch text in the argument
string; there is no `-Switch:$true` needed. If you build the argument line from a VSA variable,
confirm the expanded command in the agent procedure log before rolling out.

---

## 7. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `FAILURE:` with a WMI/CIM error | WMI repository corruption on the endpoint | Run `winmgmt /verifyrepository`. The script depends on `Win32_LogicalDisk` and `Win32_UserProfile`. |
| Reclaimed far less than expected | Ran as a user, not SYSTEM | Check the `Running as:` line in the log. |
| Reclaimed far less than expected, running as SYSTEM | Active session locking caches | Check `Skipped (running):` in the `BrowserCache` detail and the `ThumbnailCache` skip reason. Reschedule outside session hours. |
| High `Failed` counts | Files in use — expected | Not an error. Investigate only if `Failed` vastly exceeds `Items` on a machine with no logged-on user. |
| `Path rejected (…)` warnings | The safety gate did its job | Expected for reparse points. If it names a path you deliberately added to a task, the path is wrong — do not weaken the gate. |
| `WindowsUpdateCache` always skipped | Reboot pending, or servicing active | Check the detail text. Clear the pending reboot and rerun. |
| `wuauserv` not running after a run | Restart failed in the `finally` block | Look for `Failed to restart service` at ERROR level. `Start-Service wuauserv` manually and investigate the endpoint. |
| `ComponentCleanup` reports `TIMEOUT` | Large component store or slow disk | Raise `-ComponentCleanupTimeoutMin`, or run it in a dedicated window. Safe to rerun; DISM resumes. |
| `StaleProfiles` finds candidates but removes none | Profile still registered as loaded, or CIM removal denied | Check the per-profile WARN lines. Confirm the user is genuinely signed out. |
| Script exits instantly, `SUCCESS: Skipped` | `-RunOnlyIfFreeSpaceBelowGB` threshold not met | Working as designed. Lower the threshold or drop the parameter for a forced run. |
| Nothing in the log at all | Script never started, or `C:\INS-Temp\Logs` not writable | Check the VSA procedure log and the agent's own error output. |

**Rollback:** there is none, by design — deleted files are gone. This is why `-Delete` must be
opted into and why the destructive tasks are separate scripts. Recovery for anything genuinely lost
is via your backup product.

---

## 8. Pilot and rollout plan

### Phase 1 — Audit (recommended: 1 week, 10–20 machines)

Run without `-Delete` across a representative sample: a heavy browser user, a developer machine, a
shared/kiosk workstation, a laptop that's been through a feature update, and a machine currently
low on disk. Collect the JSON summaries.

**What you're looking for:**
- Which tasks actually produce meaningful bytes in *your* environment. That determines whether the
  opt-ins are worth the risk conversation at all.
- Any `Path rejected` warnings that suggest an environment-specific layout (folder redirection,
  FSLogix, non-standard profile paths).
- Any `Protected extension preserved` lines — these tell you where users are storing real data in
  places they shouldn't, which is worth knowing independently.

### Phase 2 — Safe defaults (2 weeks, one department)

Deploy with defaults and `-RunOnlyIfFreeSpaceBelowGB 20`. Verify against the exit-code and result
capture. Confirm zero user-reported issues before widening. Specifically confirm Windows Update
still functions on machines where `WindowsUpdateCache` ran.

### Phase 3 — Fleet-wide safe defaults

Schedule weekly. Trend `FreeAfterGB` from the JSON summaries to identify machines that need the
opt-ins or a bigger disk.

### Phase 4 — Opt-in tasks, individually

Introduce one task procedure at a time, each with its own pilot. Suggested order and the
per-task caveats are in [`Tasks\README.md`](Tasks/README.md) §6.

`Clear-AgedRecycleBin` and `Remove-StaleProfile` are the two that generate help desk tickets.
Both deserve a user-facing communication before they go fleet-wide.

### Change-control notes

Points a change board will ask about, answered:

- **Blast radius:** one workstation per execution; no shared or server resources touched. No network
  or domain dependencies — behaviour is identical across AD, AAD, Hybrid, and workgroup machines.
- **User impact during execution:** none by design. No process termination, no UI, no reboot,
  `BelowNormal` priority. The only service interruption is a brief stop/start of Windows Update
  services, which is transparent to the user and restored in a `finally` block.
- **Reversibility:** file deletion is irreversible. Mitigated by report-only piloting, age gates,
  extension protection, per-run caps, and opt-in gating of everything destructive.
- **Data-loss risk:** user document folders are structurally unreachable — the path gate rejects
  anything under `C:\Users` outside `AppData`, so it cannot be reached by adding a task, only by
  editing the gate itself. Treat `Test-SafeCleanupPath` as the control and review any change to it.
- **Detection of failure:** non-zero exit code, `FAILURE:` result string, per-task status in JSON.
- **Backout:** remove the scheduled task. There is no persistent change to the endpoint — the script
  installs nothing, sets no registry values, and creates no scheduled tasks or services.

---

## 9. Maintenance notes

- **Adding a cleanup target:** add it as a new `Invoke-CleanupTask` block with an explicit path and
  an age gate. Do not bypass `Clear-PathAgedFiles`, and do not add exceptions to
  `Test-SafeCleanupPath` to make a new path work — if the gate rejects it, that's the answer.
- **Vendor-specific caches** (CAD, Adobe, Autodesk, EDA tooling) are the highest-yield additions in
  most environments and are intentionally absent here because they're site-specific. Confirm what
  each cache is used for before adding it; some "caches" are licence state.
- **`-ProtectedExtensions`** is the cheapest safety improvement available. Add any file type your
  users create that would be painful to lose.
- **Known deviation from the VSA PowerShell skill template:** `Write-Log` calls
  `Write-Error $Message -ErrorAction Continue` rather than plain `Write-Error`. With
  `$ErrorActionPreference = 'Stop'`, the template version throws a terminating error whenever the
  script logs at ERROR level — including inside the final `catch`, which would skip
  `Write-VSAResult` and the `exit 1`. The skill's own template should be corrected.
