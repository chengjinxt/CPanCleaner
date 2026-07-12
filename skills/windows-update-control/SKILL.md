---
name: windows-update-control
description: Diagnose, stop, and document Windows Update automatic download activity for CPanCleaner maintenance.
---

# Windows Update Control

Use this project skill when Windows Update resumes download activity, `C:\Windows\SoftwareDistribution\Download` grows again, or CPanCleaner needs to disable automatic Windows Update downloads.

## Core Model

Treat Windows Update as a service chain, not a single service:

- `wuauserv`: Windows Update service. Detects, downloads, and coordinates update installation.
- `UsoSvc`: Update Orchestrator Service. Schedules scans, downloads, installs, and reboot workflows. It can relaunch update work after `wuauserv` is stopped.
- `BITS`: Background Intelligent Transfer Service. Performs background transfers for Windows Update and non-update apps. Keep the service enabled unless the operator explicitly wants broader disruption.
- `DoSvc`: Delivery Optimization. Handles optimized download/cache behavior for Windows Update and related Microsoft content.
- `WaaSMedicSvc`: Windows Update Medic Service. Protected repair service that can restore update components.
- `MoUsoCoreWorker.exe`, `UsoClient.exe`, `SIHClient.exe`, `TiWorker.exe`, `TrustedInstaller.exe`: update/session/servicing workers. Stop exact PIDs only when clearly tied to active update work.

## Important Locations

- `C:\Windows\SoftwareDistribution\Download`: primary Windows Update payload/cache location.
- `C:\Windows\SoftwareDistribution\DataStore`: Windows Update metadata database. Avoid deleting unless doing a full Windows Update reset.
- `C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache`: Delivery Optimization cache on some systems.
- `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache`: Delivery Optimization cache used on this system.
- `C:\ProgramData\Microsoft\Network\Downloader`: BITS queue database/state. Prefer `bitsadmin /reset /allusers`; do not delete the directory by default.
- `C:\$WINDOWS.~BT`, `C:\$Windows.~WS`, `C:\Windows10Upgrade`: upgrade staging folders when present.
- `C:\Windows\WinSxS`, `C:\Windows\servicing`, `C:\Windows\servicing\Packages`: protected component store and servicing metadata. Never manually delete.

## Diagnostic Commands

Check current service state:

```powershell
Get-Service -Name wuauserv,bits,usosvc,dosvc,WaaSMedicSvc -ErrorAction SilentlyContinue |
  Select-Object Name,DisplayName,Status,StartType
```

Check policy keys:

```powershell
Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue |
  Select-Object NoAutoUpdate,AUOptions

Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue |
  Select-Object DisableWindowsUpdateAccess,SetDisableUXWUAccess,DoNotConnectToWindowsUpdateInternetLocations,ExcludeWUDriversInQualityUpdate

Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue |
  Select-Object DODownloadMode
```

Check update tasks:

```powershell
Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\','\Microsoft\Windows\UpdateOrchestrator\','\Microsoft\Windows\WaaSMedic\' -ErrorAction SilentlyContinue |
  Select-Object TaskPath,TaskName,State,@{Name='Enabled';Expression={$_.Settings.Enabled}}
```

Check active BITS jobs:

```powershell
bitsadmin.exe /list /allusers
```

Check active cache contents:

```powershell
Get-ChildItem -LiteralPath 'C:\Windows\SoftwareDistribution\Download' -Force -ErrorAction SilentlyContinue |
  Select-Object Name,Mode,CreationTime,LastWriteTime,Length
```

## CPanCleaner Commands

Preview the disable action without changing the system:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -DryRun
```

Apply the disable action with UAC elevation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -Apply -Elevate
```

Clean Windows Update download caches separately after disabling downloads:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -Apply -Elevate
```

## Disable Strategy

`DisableWindowsUpdate` applies these controls:

- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\AUOptions=2`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\DisableWindowsUpdateAccess=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\SetDisableUXWUAccess=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\DoNotConnectToWindowsUpdateInternetLocations=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ExcludeWUDriversInQualityUpdate=1`.
- Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode=0`.
- Configure `UsoSvc`, `wuauserv`, `DoSvc`, and `WaaSMedicSvc` with `Start=4` in the service registry.
- Request stop for `UsoSvc`, `wuauserv`, `DoSvc`, and `WaaSMedicSvc`.
- Reset BITS jobs with `bitsadmin /reset /allusers`, while leaving the shared BITS service enabled.
- Best-effort disable Windows Update, UpdateOrchestrator, and WaaSMedic scheduled tasks that can be changed by the current administrator token.
- If ordinary administrator APIs return `Access is denied`, run a temporary SYSTEM scheduled task to disable protected UpdateOrchestrator/WaaSMedic tasks and solidify protected service `Start=4`, then remove that temporary task.
- Install persistent SYSTEM task `\CPanCleaner\WindowsUpdateGuard`, which runs allowlisted `reg.exe add` actions directly at startup and every 5 minutes. The guard re-applies policy values and service `Start=4`, but does not reset BITS, delete files, or repeatedly modify scheduled tasks.

Protected tasks may return `Access is denied`. Record that result; do not fight protected ACLs unless explicitly requested.

## Why Downloads Can Reappear

If `NoAutoUpdate=1` and Delivery Optimization policy remain set, but `wuauserv` or `UsoSvc` returns to `Running`, Windows has likely restored or relaunched part of the update chain. Common causes:

- Update Orchestrator scheduled tasks such as `Schedule Scan`, `Schedule Scan Static Task`, `Schedule Work`, or `UUS Failover Task`.
- `WaaSMedicSvc` or `\Microsoft\Windows\WaaSMedic\PerformRemediation` repairing update components.
- A manual Windows Update scan from Settings.
- Another maintenance tool restoring default service startup types.
- Non-Windows Update BITS jobs; verify with `bitsadmin /list /allusers`.

Small hash-named files or directories under `SoftwareDistribution\Download` may be metadata or partial payloads from a scan. Correlate by creation time and service/task state; do not expect update URL names to appear directly on disk.

## Incident Notes

On 2026-07-10, a Windows Update download session was stopped by disabling `wuauserv` and `UsoSvc`, stopping `DoSvc`, setting update and Delivery Optimization policy keys, resetting BITS jobs, disabling `\Microsoft\Windows\WindowsUpdate\Scheduled Start`, and clearing active update caches.

On 2026-07-12, the policy keys still existed, but `wuauserv`, `UsoSvc`, and `DoSvc` were running again. `wuauserv` had returned to `Manual`, `UsoSvc` to `Automatic`, and several `UpdateOrchestrator` tasks plus `WaaSMedic\PerformRemediation` were enabled. New hash-named content appeared in `C:\Windows\SoftwareDistribution\Download`, which indicates the service/task chain resumed activity despite the policy keys still being present.

Event log evidence from 2026-07-12:

- `08:47:34`: Service Control Manager changed `UsoSvc` from Disabled to Automatic.
- `08:48`: Windows Update started downloading updates.
- `08:49`: Microsoft Defender Antivirus security intelligence update installed.
- `14:31`: another Defender intelligence update downloaded and installed.
- `14:35`: Lenovo System Driver Update installed.

The successful hardening used a temporary SYSTEM scheduled task because normal administrator APIs could not disable protected UpdateOrchestrator/WaaSMedic tasks. Final desired state:

- `wuauserv`, `UsoSvc`, `DoSvc`, `WaaSMedicSvc`: Stopped and Disabled.
- Windows Update, UpdateOrchestrator, and WaaSMedic scheduled tasks: Disabled.
- `NoAutoUpdate=1`, `AUOptions=2`, `DODownloadMode=0`, `DisableWindowsUpdateAccess=1`, `SetDisableUXWUAccess=1`, `DoNotConnectToWindowsUpdateInternetLocations=1`, and `ExcludeWUDriversInQualityUpdate=1`.
- Persistent `\CPanCleaner\WindowsUpdateGuard` task: Ready and enabled.
- BITS service remains enabled, but BITS jobs are reset. New Chrome Component Updater BITS jobs are not Windows Update activity.
- `C:\Windows\SoftwareDistribution\Download` should have zero top-level items after cache cleanup. Large residual `Package_for_RollupFix` directories can require a robust bottom-up deletion because PowerShell `Remove-Item` may stop on transient missing child paths.

At 2026-07-12 16:04:52, Service Control Manager again changed `wuauserv` from Disabled to Manual even after protected tasks were disabled. That indicates a deeper service/group-policy self-healing path, so the persistent guard task is required for reboot and periodic repair scenarios.
