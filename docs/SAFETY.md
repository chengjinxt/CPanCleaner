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

When not elevated, CPanCleaner reports `NeedsAdministrator` and skips the target. The wrapper supports `-Elevate`, which asks Windows UAC to open a new administrator PowerShell process.

## Windows Update Cache Handling

For Windows Update cleanup, the tool:

1. Attempts to stop `UsoSvc`, `wuauserv`, and `DoSvc` for the current cleanup run.
2. Clears children inside `C:\Windows\SoftwareDistribution\Download`.
3. Preserves parent folders.
4. Does not disable services permanently.
5. Does not delete BITS queue database files.
6. Does not touch `WinSxS` or Windows servicing package metadata.

## Windows Update Automatic Download Control

`DisableWindowsUpdate` is a system-control action, not a file cleanup target. It defaults to dry-run mode; real changes require `-Apply` and administrator rights.

The action applies an allowlist of explicit controls:

- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\AUOptions=2`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\DisableWindowsUpdateAccess=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\SetDisableUXWUAccess=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\DoNotConnectToWindowsUpdateInternetLocations=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ExcludeWUDriversInQualityUpdate=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode=0`.
- Configure `UsoSvc`, `wuauserv`, `DoSvc`, and `WaaSMedicSvc` with `Start=4`.
- Request stop for `UsoSvc`, `wuauserv`, `DoSvc`, and `WaaSMedicSvc`.
- Reset BITS jobs with `bitsadmin /reset /allusers`, while leaving the shared BITS service enabled.
- Best-effort disable selected Windows Update, UpdateOrchestrator, and WaaSMedic scheduled tasks.
- Run a temporary SYSTEM scheduled task when normal administrator APIs cannot disable protected UpdateOrchestrator/WaaSMedic tasks or protected service start values.
- Install persistent SYSTEM task `\CPanCleaner\WindowsUpdateGuard` so boot-time or periodic self-healing cannot silently leave `wuauserv` enabled again.

This action does not delete Windows Update payloads, `SoftwareDistribution\DataStore`, `C:\ProgramData\Microsoft\Network\Downloader`, update logs, `WinSxS`, or servicing package metadata. Use the existing Windows Update cleanup targets separately when cache removal is desired.

Protected scheduled tasks may return `Access is denied` even from an administrator process. CPanCleaner records that result, then uses the temporary SYSTEM task only for the allowlisted Windows Update hardening operations. The temporary task is removed after it finishes. The persistent guard task runs allowlisted `reg.exe add` actions directly; it re-applies Windows Update policy values and service start values. It does not reset BITS, delete files, or repeatedly modify scheduled tasks.

If `NoAutoUpdate=1` and Delivery Optimization policy still exist but new files appear under `C:\Windows\SoftwareDistribution\Download`, inspect the service and task chain first. On 2026-07-12, `wuauserv`, `UsoSvc`, and `DoSvc` had resumed running while policy keys remained set; several UpdateOrchestrator tasks and `WaaSMedic\PerformRemediation` were still enabled. That state can produce fresh hash-named download/cache entries despite policy keys being present.

The 2026-07-12 event log showed `UsoSvc` changing from Disabled to Automatic at 08:47:34, then Windows Update downloads and installations for Microsoft Defender intelligence and a Lenovo driver update. That is the recurrence pattern this action is designed to block.

The same machine later showed `wuauserv` changing from Disabled to Manual at 16:04:52 after the first hardening pass. That is why the persistent guard task exists.

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

NetLimiter is a Windows network traffic monitoring and control tool. In normal use it can show upload and download activity by application, process, connection, or rule, and it may keep long-term traffic history so users can inspect past usage. That history is useful operational data, not a generic temporary cache.

`NetLimiterStats` targets only one file:

```text
C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db
```

The target is high risk because deleting it removes NetLimiter historical traffic statistics. Depending on how NetLimiter is used, that may reset historical per-application, per-process, per-connection, or time-based usage views. It is never selected by `Default`.

CPanCleaner does not uninstall NetLimiter and does not intentionally remove NetLimiter program files, drivers, services, traffic rules, license data, or broader configuration directories. The allowlist for this target is intentionally narrow: only the explicit `nlstats.db` database is a valid deletion candidate. NetLimiter may recreate a fresh statistics database after the service starts again.

Real cleanup requires administrator rights. CPanCleaner attempts to stop `NLSvc`, delete `nlstats.db`, and restart `NLSvc` when it was originally running. If `NLSvc` is running and cannot be stopped, the database is not removed.

## Performance Optimization

`OptimizePerformance` is a temporary CPU-relief action, not a broad process killer. It defaults to dry-run mode; real changes require `-Apply`.

The action is intentionally narrow:

- Stop stale Git background work matching `fsmonitor--daemon run`, `git fetch`, `git remote-http`, or `git remote-https`.
- Stop `TGitCache.exe` when stale Git background work is found or when a lightweight CPU sample shows TortoiseGit shell caching is already consuming about 5% or more of total CPU, so Explorer shell status caching can restart cleanly instead of continuing a scan loop.
- Stop stuck Conda PowerShell helpers matching `conda-script.py shell.powershell hook/activate`.
- Flush DNS resolver cache with `Clear-DnsClientCache` and `ipconfig /flushdns`.
- Set known noisy network/sync/vendor/helper priorities to `BelowNormal`: `NLSvc`, `FlClash`, `FlClashCore`, `SDPProxyClient`, `CmicSDPAccessAgent*`, `Lenovo.Modern.ImController*`, `UsbClientService`, `vss-service-x64`, `vmware-authd`, `SmpHelp`, `MSPCManager*`, `NTFSWatcher`, `NutstoreDriverSvc`, `AweSun`, `awesun_guard`, `WXWorkWeb`, `WeMail`, `Codex`, `wps`, `wpspdf`, `et`, `wpscloudsvr`, `mCloud`, `mountSpace`, `uploadDownload`, `backupDisk`, `MirrorServer`, `SyncMirrorServer`, `syncDisk`, and `SpaceAgent`.
- Disable `core.fsmonitor` and `core.untrackedCache` in the current `-RepositoryPath` repository and same-parent repositories that already have `.git\fsmonitor--daemon` state. Repositories without daemon state are not bulk-modified.

It does not terminate `System`, `svchost`, `WmiPrvSE`, Codex, chat apps, active TortoiseGit command windows, or unknown user processes. It does not disable services, delete files, or change global Git configuration.

## Performance Spike Prevention

`PreventPerformanceSpikes` is a persistent prevention action for machines where Explorer/TortoiseGit, Git fsmonitor, proxy, NetLimiter, and sync helpers repeatedly combine into high CPU. It defaults to dry-run mode; real changes require `-Apply`.

The action may:

- Set current-user global Git config `core.fsmonitor=false` and `core.untrackedCache=false`.
- Set the same two local Git config values for the current `-RepositoryPath` repository and same-parent repositories that already have `.git\fsmonitor--daemon` state.
- Set TortoiseGit current-user registry values under `HKCU\Software\TortoiseGit`: `TGitCacheCheckContentMaxSize=0`, `BlockStatus=1`, `CacheSave=0`, and `ModifyExplorerTitle=0`.
- Install `\CPanCleaner\PerformanceGuard`, a SYSTEM scheduled task that runs at startup and every 5 minutes to set known background helpers to `BelowNormal` priority.
- Stop only Codex/OpenAI plugin Git probes whose command line explicitly contains `github.com/openai/plugins.git`; ordinary user Git operations are left alone.
- Restart `TGitCache.exe` once during apply so the new TortoiseGit cache settings can take effect.

It does not disable TortoiseGit, Git, NetLimiter, FlClash, CmicSDP, WPS, Windows services, or Explorer. It does not remove files and does not change global Windows service startup policy.

## Visual Studio Package Cache

CPanCleaner does not expose a Visual Studio package cache cleanup target. The protected path is:

```text
C:\ProgramData\Microsoft\VisualStudio\Packages
```

This directory is not just disposable package data. Visual Studio setup also keeps instance metadata beneath this tree, and removing it can make installed C++ workloads appear missing, break project loading, and interfere with repair, modify, or uninstall operations. `Default`, `All`, and the aggressive batch entrypoint all leave it untouched.

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

- Git background fetch, fsmonitor, or remote HTTP(S) helper processes.
- TortoiseGit shell cache helper presence, because a hot `TGitCache.exe` can block Explorer desktop/file interactions while icon overlays and repository state are recalculated.
- Conda PowerShell initialization helper processes.
- Local repository `core.fsmonitor` and `core.untrackedCache` settings when a repository path is available.

The tool does not kill those processes in `Diagnose` mode. `OptimizePerformance -Apply` may stop known stale helpers and may write local Git fsmonitor settings for the current `-RepositoryPath` repository plus same-parent repositories that already have fsmonitor daemon state.
