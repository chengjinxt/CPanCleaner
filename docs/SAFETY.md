# 安全说明

## 执行模型

CPanCleaner 2.4 的 GUI 和命令行后端共用同一套规则：

1. 扫描和 dry-run 不删除文件、不写策略。
2. 真实变更必须显式进入 apply。
3. 中高风险功能必须单独选择；高风险功能还必须输入“执行”。
4. 需要系统权限时由 GUI 触发 UAC，不要求整个应用始终以管理员身份运行。
5. 每次 PowerShell 操作都记录日志；管理员子进程完成后应再次预览核对状态。

## 风险分层

### 低风险

`Default` 只包含可重建的缓存、临时数据或只读诊断：

- 当前用户和 Windows Temp。
- Windows Error Reporting、调试符号与崩溃转储。
- INetCache、Edge/Chrome Cache 与 Code Cache。
- Direct3D、NVIDIA、AMD shader cache。
- 远程桌面 bitmap cache。
- 仅匹配 `codex-primary-runtime.previous-*` 的旧 Codex runtime。
- Git/Conda/TortoiseGit 只读诊断。
- 仅结束当前 Widgets 进程。
- 全部合法 Chrome/Edge 配置中的基础缓存；VS Code 下载缓存、npm、剪映和 WPS 明确缓存。

部分低风险系统目录仍需要管理员权限。非管理员状态下后端报告 `NeedsAdministrator`，不会绕过权限。

### 中等风险

中等风险功能可能中断后台工作、导致重新下载或写入当前用户设置：

- Windows Update 下载和升级暂存缓存。
- Delivery Optimization 缓存。
- 历史 CPanCleaner 隔离目录。
- 一次性性能优化。
- 当前用户 Widgets 隐藏设置。
- 浏览器 Service Worker 离线缓存、Qoder `SharedClientCache\index/cache`、NuGet、Playwright 和企业微信升级包/日志。
- NuGet 分阶段迁移、删除原缓存和回滚。

Windows Update 缓存只处理 `SoftwareDistribution\Download`、升级暂存和明确的 Delivery Optimization Cache。它不删除 `SoftwareDistribution\DataStore`、BITS 队列数据库、WinSxS、servicing 元数据或更新日志。

### 高风险

高风险功能会永久丢失可恢复数据或持久改变系统行为：

- 清空回收站。
- 删除 NetLimiter `nlstats.db` 历史流量数据库。
- 删除 Visual Studio Installer Packages 子项。
- 历史激进组合清理。
- 禁用 Windows Update 自动下载。
- 写入 Git/TortoiseGit 持久设置；PerformanceGuard 由独立界面功能按用户设置的周期管理。
- 写入机器级 Widgets 策略。
- Downloads 根目录允许扩展文件的逐项永久删除。
- Docker、WSL、Visual Studio 迁移仅提供只读检测和官方入口，不直接移动数据。

高风险功能不属于 `Default`。`VisualStudioPackageCache` 也不属于 `All`，只能通过完全匹配的 Include 选择；历史激进组合同样不包含它和回收站。

## 文件删除保护

每个目标都包含固定路径、允许根、目标种类和风险元数据。删除前执行以下检查：

- 目录型缓存只删除候选子项，不删除父目录。
- `DirectorySelf` / `FileSelf` 只用于动态隔离目录和精确单文件目标。
- 重解析点不进入候选或递归测量。
- 带年龄过滤的目录若包含近期后代，或无法完整枚举后代，则整体跳过。
- 明确阻止 C 盘根、Windows 根、System32、SysWOW64、WinSxS、servicing、Program Files、Defender 数据。
- 明确阻止用户 Profile 根以及 Desktop、Documents、Downloads、Pictures、Music、Videos。
- 单项占用或访问失败只记录该项，不扩大删除范围。
- 目标应用进程运行时真实清理返回 `BlockedByProcess`；不会自动结束 Chrome、Qoder、剪映、企业微信、VS Code、WPS 或 dotnet。

### 空间分析勾选清理

空间分析表格展示的是用户数据或应用数据总目录，但可勾选项携带的是该目录内部既有清理注册表生成的精确目标 ID。执行不会删除表格显示的整个目录。目标必须同时满足固定 allowlist、存在可释放内容、位于显示根目录内；Chrome/Edge 基础缓存不会包含单独分级的 Service Worker 离线缓存。高风险目录、迁移建议和人工处理建议没有可执行目标，复选框保持禁用。被进程占用的目标允许加入本次选择，但后端在真实执行时返回 `BlockedByProcess` 并跳过，不会结束进程。

### Downloads 逐文件删除

只列出 Downloads 根目录中的 `.exe`、`.msi`、`.zip` 和 `.crdownload`。所有行默认未选；执行前要求高风险文字确认，并重新核对直接父目录、扩展名、大小和 UTC 修改时间。文件变化、重解析点、子目录或其它扩展名一律跳过；成功删除会记录执行前 SHA256。

### NuGet 迁移

迁移目标必须是非 C 盘、本地固定磁盘、NTFS、空目录且不是重解析点。Prepare 先在同分区唯一暂存目录中使用 `robocopy /XJ`，核对文件数量、逻辑大小和 `.nupkg.sha512` 后原子提交为最终目标，随后才设置用户级 `NUGET_PACKAGES`，并通过新 `dotnet` 进程验证；源缓存仍保留。RemoveSource 与 Rollback 是独立功能，均重新检查状态和阻塞进程。Docker、WSL、Visual Studio、Qoder、Codex、剪映和企业微信不使用目录联接自动迁移。

## 特殊高风险目标

### NetLimiter

只允许删除 `C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db`。执行时先记录 `NLSvc` 状态；如果运行中的服务无法停止，拒绝删除；完成后按原状态恢复。该动作会丢失历史流量统计，不会卸载 NetLimiter 或删除规则、驱动、许可证。

### Visual Studio Packages

允许根为 `C:\ProgramData\Microsoft\VisualStudio\Packages`。该目录可能同时承载包缓存和安装器状态。删除可能导致 C++ 工作负载识别异常，并影响修复、修改、更新、卸载或离线安装。界面明确建议只扫描。执行删除前应准备完整备份，并接受重新下载或重装后果。

### 禁用 Windows Update

该动作只设置“通知但不自动下载”等限制策略，调整 `wuauserv`、`WaaSMedicSvc`、BITS 作业及非核心更新任务；保留 Microsoft Store 和 WinGet 依赖的 `UsoSvc` 及核心 UpdateOrchestrator 任务，也不再自动安装 `\CPanCleaner\WindowsUpdateGuard`。

它可能阻止安全更新、Defender 情报、驱动和功能更新自动下载。GUI 提供独立的“恢复 Windows 更新与微软商店”功能，用于移除限制策略、恢复服务与系统任务，并注销可能重新施加限制的 `WindowsUpdateGuard`。缓存删除与禁用自动下载仍是两个独立动作。

### 性能防复发

`PreventPerformanceSpikes` 只写入 Git/TortoiseGit 持久设置。`\CPanCleaner\PerformanceGuard` 和 `\CPanCleaner\WindowsUpdateGuard` 在界面中独立展示，只有用户明确开启后才注册；周期限制为 5–1440 分钟，默认 15 分钟。关闭只移除守护任务（PerformanceGuard 同时移除专用脚本），不自动回滚其他策略。

### Win+R 命令历史修复

`RepairRunHistory` 默认只读检查当前用户的 `Start_TrackProgs`、`RunMRU`、Explorer 历史策略和 ACL。`-Apply` 会先生成 `.run-history-backup.json`，再启用 `Start_TrackProgs`、移除当前用户中非零的历史阻断策略、确保 `RunMRU` 可写并通知 Explorer。它不会开启 `Start_TrackDocs`、不会清空已有命令、不会结束 Explorer，也不会自动修改机器级策略。启用后 Windows 会保存程序启动和 Win+R 命令历史，属于明确的隐私取舍。

## GUI 安全边界

- 功能目录只决定界面展示和传给后端的固定参数，不执行任意命令文本。
- C# 使用 `ProcessStartInfo.ArgumentList` 传参，避免拼接用户输入形成 PowerShell 命令。
- 可变输入包括 0–3650 的保留天数、5–1440 分钟任务周期、经过严格验证的 NuGet 目标空目录、后端生成的 Downloads 身份令牌，以及空间分析结果携带并由目标注册表再次校验的精确清理 ID。
- 普通执行直接捕获 JSON；管理员执行使用 UAC 隔离进程，通过一次性随机文件名 JSON 回传结果并在读取后删除。
- 取消只能终止仍在运行的进程，已经完成的系统操作不会自动回滚。

高风险功能的原理、影响与路径来源位于 [features.json](../src/CPanCleaner.Gui/Resources/features.json)，架构说明见 [GUI_ARCHITECTURE.md](./GUI_ARCHITECTURE.md)。
