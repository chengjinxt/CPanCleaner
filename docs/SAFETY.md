# Safety Notes

CPanCleaner is intentionally conservative. A C drive cleaner can do real damage if it treats every large directory as disposable, so this project uses an allowlist-first model.

## Default Behavior

The default include set is `Default`, which maps to low-risk temporary and diagnostic/cache locations:

- Current user temp directory.
- `C:\Windows\Temp`.
- Windows Error Reporting cache.
- Debug symbol cache.
- Current-user Windows Internet cache.
- Current-user crash dumps.
- Old Codex runtime cache directories matching `codex-primary-runtime.previous-*`.

Cleaning those locations still defaults to dry-run mode. Real deletion requires `-Apply`.

## Administrator Targets

These targets require explicit opt-in and administrator rights:

- `WindowsUpdate`
- `DeliveryOptimization`
- `OldQuarantine`
- `DiagnosticsCache` entries that live under `C:\ProgramData`
- `NetLimiterStats`
- `VisualStudioPackageCache`

When not elevated, CPanCleaner reports `NeedsAdministrator` and skips the target. The wrapper supports `-Elevate`, which asks Windows UAC to open a new administrator PowerShell process.

## Windows Update Cache Handling

For Windows Update cleanup, the tool:

1. Attempts to stop `UsoSvc`, `wuauserv`, and `DoSvc` for the current cleanup run.
2. Clears children inside `C:\Windows\SoftwareDistribution\Download`.
3. Preserves parent folders.
4. Does not disable services permanently.
5. Does not delete BITS queue database files.
6. Does not touch `WinSxS` or Windows servicing package metadata.

## Protected Locations

The module blocks deletion candidates under known sensitive locations even if future code accidentally tries to pass them through:

- C drive root.
- Windows root.
- System32 and SysWOW64.
- WinSxS.
- Windows servicing folders.
- Program Files folders.
- Windows Defender data.
- User profile root.
- Desktop, Documents, Downloads, Pictures, Music, and Videos.

## Recycle Bin

The recycle bin is supported because it is a common source of recoverable space, but it is high risk: it may contain user files. It is never selected by `Default`.

Use it only after scanning:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include RecycleBin
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include RecycleBin -Apply
```

## NetLimiter Statistics

`NetLimiterStats` targets only one file:

```text
C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db
```

The target is high risk because deleting it removes NetLimiter historical traffic statistics. It is never selected by `Default`.

Real cleanup requires administrator rights. CPanCleaner attempts to stop `NLSvc`, delete `nlstats.db`, and restart `NLSvc` when it was originally running. If `NLSvc` is running and cannot be stopped, the database is not removed.

## Visual Studio Package Cache

`VisualStudioPackageCache` targets children under:

```text
C:\ProgramData\Microsoft\VisualStudio\Packages
```

The target is high risk because Visual Studio setup may need cached packages for repair, modify, or uninstall operations. It is never selected by `Default`. CPanCleaner preserves the parent directory and only removes children inside that explicit cache root.

## Prototype-Parity Low-Risk Caches

The modular project intentionally retains the useful safe targets from the original single-file prototype:

- `DiagnosticsCache`: `C:\ProgramData\Microsoft\Windows\WER` and `C:\ProgramData\Dbg\sym`.
- `InternetCache`: current-user `Microsoft\Windows\INetCache`.
- `CrashDumps`: current-user `CrashDumps`.
- `CodexRuntimeCache`: previous Codex runtime directories only, never the current runtime directory.

These are part of `Default` because they are cache or diagnostic data. ProgramData diagnostics entries may still require administrator rights and are skipped with `NeedsAdministrator` when not elevated.

## Reports

Each run writes a log and, when file-system targets are scanned or cleaned, a CSV report. The CSV defaults to the same basename as the log under `logs\`.

## Git And Conda Diagnostics

`-Action Diagnose` is read-only. It reports:

- Git background fetch or fsmonitor processes.
- Conda PowerShell initialization helper processes.
- Local repository `core.fsmonitor` and `core.untrackedCache` settings when a repository path is available.

The tool does not kill those processes or rewrite Git configuration automatically.
