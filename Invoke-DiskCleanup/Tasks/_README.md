# Invoke-DiskCleanup — Opt-in task scripts

**Platform:** Kaseya VSA X agent procedure · **Context:** SYSTEM · **PowerShell:** 5.1

These six scripts were split out of `Invoke-DiskCleanup.ps1`. Each performs one cleanup
task that trades a recovery option for disk space, which is why none of them is part of the
always-safe parent run.

Each script is **fully self-contained** — no shared library, no dot-sourcing. Upload one
file to VSA and it works. The cost of that choice is duplication: the logging, formatting,
free-space and result-reporting helpers exist in all six files, so a change to that common
code has to be applied to each.

---

## 1. The scripts

| Script | Task name | What it trades away |
|---|---|---|
| `Clear-AgedRecycleBin.ps1` | `RecycleBin` | Recovery of anything deleted longer ago than the age gate. |
| `Clear-TeamsCache.ps1` | `TeamsCache` | May force a Teams re-login on some builds. Cache only. |
| `Remove-WindowsOld.ps1` | `WindowsOld` | The ability to roll back the last Windows upgrade. |
| `Invoke-ComponentCleanup.ps1` | `ComponentCleanup` | Little in recovery terms, but CPU-heavy and long-running. |
| `Remove-StaleProfile.ps1` | `StaleProfiles` | Everything in the removed profiles. No undo. |
| `Remove-OldRestorePoint.ps1` | `RestorePoints` | System Restore points and Previous Versions. |

Every script accepts `-ReportOnly` and `-MaxRuntimeMinutes` (default 45) in addition to its
own parameters below.

`Clear-AgedRecycleBin` is named to avoid colliding with PowerShell 5.1's built-in
`Clear-RecycleBin` cmdlet, which cannot reach other users' bins from SYSTEM.

---

## 2. Parameters

| Script | Parameter | Default | Notes |
|---|---|---|---|
| `Clear-AgedRecycleBin` | `-RecycleBinAgeDays` | `30` | Only items deleted longer ago than this are removed. |
| `Remove-WindowsOld` | `-WindowsOldAgeDays` | `30` | Windows' own rollback window is 10 days; 30 is deliberately conservative. |
| `Invoke-ComponentCleanup` | `-ComponentCleanupTimeoutMin` | `30` | DISM is terminated past this and the task reports `TIMEOUT`. |
| `Remove-StaleProfile` | `-ProfileAgeDays` | `120` | Minimum days since `LastUseTime`. |
| `Remove-StaleProfile` | `-MaxProfilesToRemove` | `5` | Per-run cap, oldest first. A misconfiguration damages five profiles, not fifty. |
| `Remove-OldRestorePoint` | `-KeepRestorePoints` | `1` | Newest N shadow copies retained. |
| `Clear-TeamsCache` | `-ProtectedExtensions` | see below | Never deleted, wherever encountered. |

---

## 3. Notes on the riskier ones

- **`RecycleBin`** determines each item's deletion date from the `LastWriteTime` of its `$I`
  metadata file, then removes both the `$R` payload and the `$I` record. This works across
  all users' bins from SYSTEM. Age-aware on purpose: a blanket empty destroys a user's most
  recent safety net.
- **`WindowsOld`** is the only task that uses `takeown`/`icacls`, because those trees are
  owned by TrustedInstaller. It refuses to act inside the rollback window and logs why.
  Usually the largest single reclaim available on a recently upgraded machine.
- **`ComponentCleanup`** runs DISM at `BelowNormal` priority with its own timeout. On
  timeout the process is terminated and the task reports `TIMEOUT`; DISM's transaction
  handling means a killed run is resumable. Exit codes 0 and 3010 are success. Skipped if a
  servicing operation is already in flight. **Not measurable under `-ReportOnly`** — it
  reports `SKIPPED` there. `/ResetBase` is deliberately never used, as it permanently blocks
  uninstalling installed updates.
- **`StaleProfiles`** requires the profile to be non-Special, **not loaded**, under
  `C:\Users`, with a `LastUseTime` older than `-ProfileAgeDays`, a name not in the exclusion
  list (`Administrator`, `Admin`, `Public`, `Default`, `defaultuser0`,
  `WDAGUtilityAccount`), and not belonging to the currently logged-on user. Removal goes
  through `Remove-CimInstance` on the `Win32_UserProfile` object, which cleans the registry
  `ProfileList` entry too rather than orphaning it by deleting the folder.
- **`RestorePoints`** and **`ComponentCleanup`** cannot self-report bytes, so they measure
  free-space delta before and after, clamped at zero. That figure is noisier than a
  file-by-file total — other activity on the machine lands in it.

### Safety model — `Clear-TeamsCache` only

It is the only one of the six that walks user profile trees, so it carries the parent
script's full deletion engine: allow-listed paths only, every path through
`Test-SafeCleanupPath`, reparse points never traversed or deleted, protected extensions
(`.pst`, `.ost`, `.vhdx`, `.kdbx`, `.pfx`, …) never deleted, and locked files failing closed
as skips rather than being force-unlocked. The other five have their own narrow deletion
logic and do not need it.

---

## 4. Outputs

Each script writes its own three files, so per-task VSA procedures never overwrite each
other's results:

```
C:\INS-Temp\Logs\DiskCleanup_<Task>.log
C:\INS-Temp\Logs\DiskCleanup_<Task>_Summary.json
C:\INS-Temp\Logs\ScriptResult_DiskCleanup_<Task>.txt
```

`<Task>` is the task name from §1 — for example `DiskCleanup_RecycleBin.log`.

Logs rotate past 5 MB to `DiskCleanup_<Task>-<timestamp>.log`, keeping 5 archives. The
archive separator is `-`, not `_`, specifically so the parent script's prune filter cannot
match a task log and delete it.

**Exit codes:** `0` = success, including a task that reported `SKIPPED` or `TIMEOUT` (both
are logged). `1` = fatal error; the result file starts with `FAILURE:`.

---

## 5. VSA X deployment

One procedure per task. Upload the single `.ps1`, run it as SYSTEM:

```
powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File "<path>\Clear-AgedRecycleBin.ps1" -RecycleBinAgeDays 30
```

Capture the result with a *Get Variable* step reading
`C:\INS-Temp\Logs\ScriptResult_DiskCleanup_<Task>.txt`, or branch on the exit code.
Optionally collect the `_Summary.json` for fleet reporting.

For `Invoke-ComponentCleanup`, set the procedure timeout above
`-ComponentCleanupTimeoutMin` plus headroom (e.g. script 30, procedure 40) so the script's
own timeout fires first and you still get a summary.

Switches are passed by including or omitting the switch text; there is no `-Switch:$true`.

### Suggested scheduling

- **On low-disk alert:** `Remove-WindowsOld` then `Clear-AgedRecycleBin` — the best
  space-per-risk ratio.
- **Quarterly / change window:** `Invoke-ComponentCleanup` and `Remove-OldRestorePoint`.
- **Rarely, deliberately:** `Remove-StaleProfile`. Read a `-ReportOnly` candidate list
  first, every time.
- **`Clear-TeamsCache`** is low risk and can run on a normal maintenance cadence, though it
  only yields anything when Teams is closed.

---

## 6. Rollout

Run each with `-ReportOnly` first and read the log. `Invoke-ComponentCleanup` is the
exception — it cannot measure in advance, so pilot it on a single machine instead.

Introduce them one at a time, in ascending order of risk:

`Remove-WindowsOld` → `Invoke-ComponentCleanup` → `Clear-AgedRecycleBin` →
`Remove-StaleProfile` → `Remove-OldRestorePoint`

`Clear-AgedRecycleBin` and `Remove-StaleProfile` are the two that generate help desk
tickets. Both are age-gated and `Remove-StaleProfile` is capped per run, but the age gate is
the only thing standing between a user and a lost file they expected to still be in the bin.

**Rollback:** there is none, by design — deleted files are gone. This is why `-ReportOnly`
exists and why these tasks are separate, individually approved procedures. Recovery for
anything genuinely lost is via your backup product.
