# CPanCleaner

CPanCleaner 是一个安全优先的 Windows C 盘清理工具。它以“先扫描、再 dry-run、最后显式 apply”为核心流程，默认只处理低风险临时目录，并通过路径白名单和敏感目录黑名单避免误删用户文档、系统组件库或程序安装目录。

## 项目定位

CPanCleaner 不是“尽可能多删除”的激进清理器，而是面向可审计维护场景的保守工具：

- 默认只扫描或预览，不会静默删除。
- 真实清理必须显式传入 `-Apply`。
- 中高风险目标必须显式 `-Include`。
- 管理员目标在非管理员会话中只提示，不强行执行。
- 每次运行都会写日志，方便回溯。
- 常规扫描/清理不处理 Git fsmonitor 和 Conda 残留；CPU 优化需显式使用 `OptimizePerformance -Apply`。
- Windows Update 自动下载禁用动作默认只做 dry-run 预览，真实修改系统策略、服务和计划任务必须显式传入 `-Apply`。

## 开发语言

- 主要语言：PowerShell。
- 入口脚本：[CPanCleaner.ps1](./CPanCleaner.ps1)。
- 核心模块：[src/CPanCleaner.psm1](./src/CPanCleaner.psm1)。
- 测试脚本：[tests/Invoke-StaticTests.ps1](./tests/Invoke-StaticTests.ps1)。

选择 PowerShell 的原因是 Windows 缓存、服务、回收站、权限和文件系统操作都可以通过系统内置能力完成，不需要额外运行时。

## 实现原理

CPanCleaner 的实现由四层组成：

1. 目标注册表
   所有可清理位置都由模块内的目标定义注册，包含 `Id`、路径、风险级别、是否默认、是否需要管理员、是否使用时间过滤等元数据。

2. 选择策略
   `-Include Default` 只选择低风险默认目标；`DiagnosticsCache`、`InternetCache`、`CrashDumps`、`CodexRuntimeCache` 是从原型保留下来的低风险缓存类目标；`WindowsUpdate`、`DeliveryOptimization`、`RecycleBin`、`OldQuarantine`、`NetLimiterStats` 等目标必须显式选择；`All` 只表示选择所有已注册目标，不表示绕过安全策略。

3. 路径安全检查
   删除前会检查候选路径是否位于目标允许根目录之内，并阻止进入敏感目录。工具清理缓存目录的“子项”，不删除父目录本身；对 NetLimiter 只允许删除明确的 `nlstats.db` 文件。

4. 执行模式
   `Scan` 只估算空间；`Clean` 默认 dry-run；`Clean -Apply` 才执行删除。管理员目标会先检查权限，Windows Update 缓存清理会尝试停止相关更新服务链后再清理缓存内容，NetLimiter 统计库清理会围绕 `NLSvc` 做停止和恢复。

## 支持的清理项

| Include | 默认 | 风险 | 权限 | 说明 |
| --- | --- | --- | --- | --- |
| `Default` | 是 | Low | 普通权限 | 当前用户临时目录和 `C:\Windows\Temp` 中超过 `-MinimumAgeDays` 的项目。 |
| `Temp` | 是 | Low | 普通权限 | 与默认临时目录目标相同。 |
| `DiagnosticsCache` | 是 | Low | 视目录而定 | Windows Error Reporting 缓存和调试符号缓存。ProgramData 下的目标可能需要管理员权限。 |
| `InternetCache` | 是 | Low | 普通权限 | 当前用户 `INetCache`。 |
| `CrashDumps` | 是 | Low | 普通权限 | 当前用户应用崩溃转储。 |
| `CodexRuntimeCache` | 是 | Low | 普通权限 | 仅清理 `codex-primary-runtime.previous-*` 旧 Codex runtime，不清理当前 runtime。 |
| `WindowsUpdate` | 否 | Medium | 管理员 | Windows Update 下载缓存、升级暂存目录、Update Assistant 缓存。保留父目录，不碰组件库。 |
| `DeliveryOptimization` | 否 | Medium | 管理员 | Delivery Optimization 缓存。 |
| `RecycleBin` | 否 | High | 普通权限 | 清空 C 盘回收站，会永久移除用户已删除文件。 |
| `OldQuarantine` | 否 | Medium | 管理员 | 删除历史维护产生的已知隔离目录。 |
| `NetLimiterStats` | 否 | High | 管理员 | 删除 NetLimiter 的历史流量统计数据库 `C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db`。会丢失按应用、进程或连接累计的历史流量记录。 |
| `All` | 否 | Mixed | 视目标而定 | 选择全部已注册目标，仍遵守权限和安全检查。 |

## 开发环境要求

- Windows 10/11 或 Windows Server。
- Windows PowerShell 5.1 或 PowerShell 7+。
- Git，用于版本管理和发布。
- 推荐使用管理员 PowerShell 运行涉及系统缓存或服务控制的验证，但默认扫描和 dry-run 可在普通权限下运行。

## 运行权限

普通权限可执行：

- 默认扫描。
- 默认 dry-run。
- 默认低风险临时目录清理。
- Git/Conda 只读诊断。

管理员权限用于：

- Windows Update 缓存。
- Windows 升级暂存目录。
- Delivery Optimization 缓存。
- 旧隔离目录。
- NetLimiter 历史流量统计数据库。

可用 `-Elevate` 触发 UAC：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -Apply -Elevate
```

## 常用命令

进入项目目录：

```powershell
Set-Location E:\PerSourceCodeStore\github\chengjinxt\CPanCleaner
```

扫描默认低风险目标：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1
```

预览默认清理，不删除：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean
```

执行默认低风险清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Apply
```

预览 Windows Update 和 Delivery Optimization 清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -DryRun
```

执行管理员清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -Apply -Elevate
```

## 禁用 Windows 自动下载升级

Windows Update 不是单个服务，而是一组服务、计划任务、策略和后台传输组件共同工作。只设置 `NoAutoUpdate=1` 或只停止 `wuauserv` 并不一定能长期阻止 `C:\Windows\SoftwareDistribution\Download` 重新出现内容，因为 `UsoSvc`、UpdateOrchestrator 计划任务、`WaaSMedicSvc` 或手动“检查更新”都可能重新拉起扫描/下载链路。

本项目将相关资料沉淀在 [skills/windows-update-control/SKILL.md](./skills/windows-update-control/SKILL.md)。该 skill 记录了服务角色、缓存位置、诊断命令、禁用策略、2026-07-10 的处理方案，以及 2026-07-12 观察到“策略键仍在但服务被恢复运行”的复发现象。

2026-07-12 的复查结论是：`NoAutoUpdate`/`AUOptions` 这类策略不是唯一控制点。事件日志显示 `UsoSvc` 在 08:47:34 被从 Disabled 改回 Automatic，随后 08:48 开始下载，08:49 安装 Microsoft Defender Antivirus 安全智能更新；14:31 又下载/安装 Defender 智能更新，14:35 安装 Lenovo System Driver Update。因此需要同时处理服务启动类型、受保护计划任务、WaaSMedic 修复链路和 BITS 传输队列。

`DisableWindowsUpdate` 用于禁用 Windows 自动下载升级。它不会清理缓存目录；缓存清理仍使用 `Clean -Include WindowsUpdate,DeliveryOptimization`。禁用动作会做这些事情：

- 设置 `DisableWindowsUpdateAccess=1`、`SetDisableUXWUAccess=1`、`DoNotConnectToWindowsUpdateInternetLocations=1` 和 `ExcludeWUDriversInQualityUpdate=1`，阻断 Windows Update UX、联网扫描入口和驱动自动推送。
- 设置 `NoAutoUpdate=1` 和 `AUOptions=2`。
- 设置 Delivery Optimization 策略 `DODownloadMode=0`。
- 将 `UsoSvc`、`wuauserv`、`DoSvc` 配置为 disabled，并请求停止它们。
- 将 `WaaSMedicSvc` 也配置为 disabled，避免修复链路重新启用更新组件。
- 使用 `bitsadmin /reset /allusers` 取消当前 BITS 传输任务，但保留 BITS 服务本身。
- 尝试禁用 Windows Update、UpdateOrchestrator、WaaSMedic 中与扫描/修复相关的计划任务。
- 普通管理员 API 遇到 `Access is denied` 时，创建一次临时 SYSTEM 计划任务来完成受保护任务禁用和受保护服务 `Start=4` 固化，然后删除临时任务。
- 安装持久 SYSTEM 守护任务 `\CPanCleaner\WindowsUpdateGuard`，在启动时和每 5 分钟直接执行 allowlist 中的 `reg.exe add` 动作，重新应用策略键和服务 `Start=4`，防止组策略/服务自愈把 `wuauserv` 从 Disabled 改回 Manual。

预览禁用动作，不修改系统：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -DryRun
```

执行禁用动作：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -Apply -Elevate
```

禁用后再清理已下载缓存：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -Apply -Elevate
```

如果 `Download` 目录再次出现 hash 命名文件或目录，优先检查服务状态、UpdateOrchestrator/WaaSMedic 计划任务和 BITS 作业，而不是只看策略键：

```powershell
Get-Service -Name wuauserv,bits,usosvc,dosvc,WaaSMedicSvc -ErrorAction SilentlyContinue |
  Select-Object Name,Status,StartType

bitsadmin.exe /list /allusers
```

## NetLimiter 清理说明

NetLimiter 是一类 Windows 网络流量监控和控制工具，通常用于查看每个应用、进程或连接的上传/下载流量，并按规则进行限速、阻止、优先级控制或长期统计。CPanCleaner 中的 `NetLimiterStats` 目标不是清理网络驱动、程序文件、限速规则或配置，而是只清理 NetLimiter 维护的历史流量统计数据库。

当前目标只允许触碰这个文件：

```text
C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db
```

这个数据库可能随使用时间增长到数 GB，因为它保存 NetLimiter 的历史流量记录。删除它通常能释放空间，但代价是 NetLimiter 界面中按应用、进程、连接或时间累计的历史统计会被重置；已有的程序安装、服务、驱动和 CPanCleaner 未触碰的规则/配置目录不会被主动删除。NetLimiter 后续运行时可能重新创建新的统计数据库。

实际执行时，CPanCleaner 会尝试先停止 `NLSvc` 服务，删除 `nlstats.db`，再按原运行状态恢复服务。如果服务正在运行且不能安全停止，工具会跳过删除，避免在数据库仍被占用时强行处理。该目标属于高风险清理项，不包含在 `Default` 中，必须显式传入 `-Include NetLimiterStats`。

预览 NetLimiter 历史流量统计数据库清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include NetLimiterStats -DryRun
```

执行 NetLimiter 历史流量统计数据库清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include NetLimiterStats -Apply -Elevate
```

执行时工具会尝试停止 `NLSvc`，删除 `nlstats.db`，再按原运行状态重启 `NLSvc`。删除该数据库会释放空间，但会丢失 NetLimiter 历史流量统计；不确定是否需要保留历史统计时，先使用 dry-run 查看预估大小。

Visual Studio 安装器状态和包缓存不会被 CPanCleaner 清理。`C:\ProgramData\Microsoft\VisualStudio\Packages` 中包含实例/工作负载识别所需的安装器元数据，删除后可能导致 C++ 项目无法加载、修复/修改/卸载失效或需要重新下载组件。

2026-07-12 的现场问题：清理后打开 `D:\gitlibcmic\pc_client\output\project\mCloudElectron.sln`，VS2017 中 `base`、`account`、`cloud`、`MirrorServer`、`SyncMirrorServer` 等 C++ 项目显示“缺少安装组件”，提示 `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`。根因不是项目文件损坏，而是 Visual Studio 安装器状态/包缓存被清理后，VS 无法正确识别或补齐 C++ 工作负载组件。

处理方案已经固化到本工具：

- `VisualStudioPackageCache` 不再作为清理目标暴露，`Default`、`All` 和 `Run-Clean-Aggressive.bat` 都不会清理 Visual Studio 安装器状态或包缓存。
- 显式传入 `-Include VisualStudioPackageCache` 会被拒绝，防止误删 `C:\ProgramData\Microsoft\VisualStudio\Packages`。
- VS2017 项目缺组件时，应通过 Visual Studio Installer 精确补装 `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`；该 mCloudElectron 方案还需要 `Microsoft.VisualStudio.Component.VC.ATLMFC` 才能完整编译 MFC/ATL 项目。

运行 Git fsmonitor / Conda 残留诊断：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Diagnose
```

## CPU/卡顿优化

`OptimizePerformance` 用于处理本机反复出现的高 CPU/卡顿来源。它不是通用杀进程工具，默认只做 dry-run 预览；真实处理必须显式传入 `-Apply`。

2026-07-12 的现场问题：实时 CPU 采样多次达到 `95%` 到 `100%`。主要异常是多个 `git fsmonitor--daemon run --detach --ipc-threads=8` 反复出现，并伴随卡住的 Conda PowerShell helper：`conda-script.py shell.powershell hook/activate`。停止后 Git fsmonitor 又换 PID 复活，旁边常驻 `TGitCache.exe`，判断为 TortoiseGit 外壳缓存/状态扫描继续触发 Git 后台监控。`Dnscache`、`Winmgmt/WmiPrvSE`、`FlClash`、`NLSvc`、`syncDisk`、`wpscloudsvr`、`mCloud` 属于次级网络、同步或诊断负载。

现场优化结果：停止 stale Git/Conda helper 和 `TGitCache.exe` 后，`git fsmonitor`、Conda helper、`TGitCache.exe` 残留检查为空；CPU 从持续满载变成短时波动，最后采样已能落到约 `17%` 到 `34%`。因此工具内置的是“压住循环触发源 + 降低后台 helper 抢占”的方案，而不是杀系统服务。

当前动作只做低风险优化：

- 停止残留的 `git fsmonitor--daemon run --detach --ipc-threads=8`、`git fetch`、`git remote-http` 后台进程。
- 当发现上述 Git 后台异常时，同时停止 `TGitCache.exe`，让 TortoiseGit 外壳缓存重新拉起，避免它继续循环触发 Git 状态扫描。
- 停止卡住的 Conda PowerShell 初始化 helper：`conda-script.py shell.powershell hook/activate`。
- 刷新 DNS 缓存，缓解 `Dnscache` 因代理/网络抖动导致的持续占用。
- 将已知网络/同步 helper 进程降到 `BelowNormal`：`NLSvc`、`FlClash`、`FlClashCore`、`SDPProxyClient`、`CmicSDPAccessAgent*`、`wpscloudsvr`、`syncDisk`。
- 当当前 `-RepositoryPath` 仓库或同级源码目录中出现 `.git\fsmonitor--daemon` 痕迹时，写入对应仓库的本地配置：`core.fsmonitor=false`、`core.untrackedCache=false`。未出现 daemon 痕迹的其它仓库不会被批量改配置。

它不会杀 `System`、`svchost`、`WmiPrvSE`、`Codex`、微信/企业微信主进程，也不会禁用服务或删除文件；Git 配置只改当前 `-RepositoryPath` 仓库和同级目录中已有 daemon 痕迹的仓库，不改全局配置。

预览 CPU 优化动作：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action OptimizePerformance -DryRun
```

执行 CPU 优化动作：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action OptimizePerformance -Apply
```

输出 JSON：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include All -Json
```

## 批处理入口

仓库提供了几个双击可用的批处理入口，适合临时维护时快速执行：

| 文件 | 行为 | 说明 |
| --- | --- | --- |
| `Run-Scan.bat` | 扫描默认低风险目标 | 不删除文件。 |
| `Run-Clean-Safe.bat` | 执行默认低风险清理 | 只处理默认目标。 |
| `Run-Disable-WindowsUpdate.bat` | 禁用 Windows 自动下载升级 | 会触发 UAC；修改 Windows Update 策略、服务和计划任务。 |
| `Run-Optimize-Performance.bat` | 降低高 CPU/卡顿 | 停止 stale Git/Conda/TortoiseGit cache helper、刷新 DNS、降低网络/同步 helper 优先级；不杀系统进程。 |
| `Run-Clean-NetLimiter.bat` | 清理 NetLimiter 历史流量统计数据库 | 会触发 UAC；会丢失 NetLimiter 历史流量统计。 |
| `Run-Clean-Aggressive.bat` | 清理 Windows Update、Delivery Optimization、旧隔离目录和 NetLimiter 统计库 | 会触发 UAC；不包含回收站和 Visual Studio 安装器缓存，避免误删用户文件或破坏开发环境依赖。 |

## 日志

每次运行会在 `logs\` 下生成日志：

```text
logs\cpancleaner-YYYYMMDD-HHMMSS-xxxxxxxx.log
```

日志记录内容包括：

- 运行模式和权限状态。
- dry-run 预览。
- 管理员目标跳过原因。
- Windows Update 服务停止尝试。
- Windows Update 自动下载禁用动作的策略、服务、BITS 和计划任务结果。
- NetLimiter 服务停止和恢复尝试。
- 删除成功或失败的路径。

同名 CSV 报告也会自动生成，默认位于 `logs\`：

```text
logs\cpancleaner-YYYYMMDD-HHMMSS-xxxxxxxx.csv
```

`logs\*.log`、`logs\*.json` 和 `logs\*.csv` 默认不提交到 Git；仓库仅保留 `logs\.gitkeep`。

## 测试验证方式

静态安全测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticTests.ps1
```

兼容原型项目的根目录测试入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-CPanCleaner.ps1
```

默认扫描验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include Default -Json
```

默认 dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include Default -DryRun
```

原型兼容的短时间窗口临时文件预览：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include Temp -MinimumAgeHours 2 -DryRun
```

低风险缓存分组 dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include DiagnosticsCache,InternetCache,CrashDumps,CodexRuntimeCache -DryRun
```

NetLimiter 扫描验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include NetLimiterStats -Json
```

NetLimiter dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include NetLimiterStats -DryRun
```

Windows Update 自动下载禁用 dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -DryRun -Json
```

CPU/卡顿优化 dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action OptimizePerformance -DryRun -Json
```

诊断入口验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Diagnose -Json
```

发布前至少通过以上验证。涉及 `-Apply` 的真实清理应只在明确维护窗口中执行，并先保留 dry-run 输出或日志。

## 安全边界

CPanCleaner 禁止手工删除或递归进入以下敏感位置：

- C 盘根目录。
- `C:\Windows` 本身。
- `C:\Windows\System32`
- `C:\Windows\SysWOW64`
- `C:\Windows\WinSxS`
- `C:\Windows\servicing`
- `C:\Windows\servicing\Packages`
- `C:\Program Files`
- `C:\Program Files (x86)`
- Windows Defender 数据。
- 用户 Profile 根目录。
- Desktop、Documents、Downloads、Pictures、Music、Videos 等用户内容目录。

Windows Update 清理只处理缓存和暂存内容，不删除：

- `WinSxS`
- `servicing\Packages`
- BITS 队列数据库
- Windows Update 日志
- 系统组件库

Windows Update 自动下载禁用只修改明确的策略键、服务启动类型和计划任务状态。它不删除 `DataStore`、BITS 队列数据库、日志、组件库或 servicing 元数据；已下载缓存需要通过清理命令单独处理。某些大型 `Package_for_RollupFix` 展开目录可能包含几十万文件，普通 `Remove-Item` 会很慢；维护时应先禁用服务和任务，再只针对 `SoftwareDistribution\Download` 下的明确残留目录做校验后删除。

彻底禁用依赖持久守护任务 `\CPanCleaner\WindowsUpdateGuard`。该任务以 SYSTEM 身份直接执行 allowlist 中的 `reg.exe add` 动作，只重复写入 Windows Update 策略键和相关服务 `Start=4`；不会重置 BITS、删除文件、反复修改计划任务或触碰组件库。受保护计划任务由 `DisableWindowsUpdate -Apply` 的一次性 SYSTEM 加固阶段禁用。

默认低风险缓存包含 WER、调试符号缓存、当前用户 INetCache、当前用户 CrashDumps 和旧 Codex runtime。旧 Codex runtime 只匹配 `codex-primary-runtime.previous-*`，不清理当前 runtime。

回收站属于高风险目标，不在默认清理范围内。

NetLimiter 统计数据库属于高风险目标，不在默认清理范围内。CPanCleaner 只允许删除明确的 `nlstats.db` 文件，不清理整个 NetLimiter 目录，也不主动删除程序、服务、驱动、规则或配置。该目标释放的是历史流量记录占用的空间，不是卸载 NetLimiter。

Visual Studio 包缓存和安装器状态目录不再作为清理目标暴露。CPanCleaner 会拒绝 `-Include VisualStudioPackageCache`，`Default`、`All` 和 aggressive 批处理入口都不会清理 `C:\ProgramData\Microsoft\VisualStudio\Packages`，因为该目录可能包含 Visual Studio 实例识别、C++ 工作负载检测和修复/修改/卸载流程需要的元数据。

`OptimizePerformance` 只做进程级临时优化和出现过 fsmonitor daemon 状态的本地 Git 仓库配置修正：停止已知 stale helper、必要时停止 `TGitCache.exe`、刷新 DNS、降低已知 helper 优先级。它不修改服务启动类型，不重启系统服务，不杀未知 `svchost` 组，也不关闭用户正在使用的主应用。

## 版本规范

CPanCleaner 使用语义化版本：

```text
MAJOR.MINOR.PATCH
```

- `MAJOR`：安全模型、命令行参数或清理语义发生不兼容变化。
- `MINOR`：新增清理目标、诊断能力、输出字段或文档化能力，保持兼容。
- `PATCH`：缺陷修复、文档修正、测试增强或不改变行为的内部调整。

模块版本定义在 `src\CPanCleaner.psm1` 的 `$script:CleanerVersion`。发布前应确保 README、测试说明和版本号一致。

## 发布规范

建议发布流程：

1. 更新 `$script:CleanerVersion`。
2. 更新 README 中与版本相关的说明。
3. 运行测试验证章节中的命令。
4. 确认 `git status` 只包含预期文件。
5. 提交：

```powershell
git add .
git commit -m "Release CPanCleaner vX.Y.Z"
```

6. 打标签：

```powershell
git tag vX.Y.Z
```

7. 推送分支和标签：

```powershell
git push
git push origin vX.Y.Z
```

如果只是开发提交而不是正式发布，提交信息应描述行为变化，例如：

```powershell
git commit -m "Add NetLimiter statistics cleanup target"
```
