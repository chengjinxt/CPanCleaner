# CPanCleaner

CPanCleaner 2.5.0 是一个面向 Windows 10/11 的 C# WPF 图形化空间与性能维护工具。界面按风险分为“安全 / 中等风险 / 高风险”三个 Tab；每个 Tab 再按用途分组，选择功能后会动态显示实现原理、可能影响、涉及路径、权限要求、安全护栏和历史来源。执行结果中的文本单元格支持鼠标悬停查看可换行的完整内容。

工具仍遵循“先扫描或 dry-run、再明确确认、最后 apply”的执行模型。PowerShell 后端保留系统操作的可审计性，C# 只负责界面、异步执行、结果展示、UAC 和风险确认。

## 为什么使用 C#

对这个 Windows 专用工具，C# + WPF 比继续堆叠批处理入口更合适：

- 原生支持 Tab、分组列表、详情面板、进度、取消和可访问性。
- 能可靠区分普通权限与管理员权限，并在必要时触发 UAC。
- 后台扫描不会冻结界面，JSON 结果可结构化展示。
- 不把高风险命令暴露成容易误双击的多个 `.bat`。
- 可以发布为带 PowerShell 后端和功能目录的可审计 Windows 应用文件夹。

PowerShell 仍适合服务、注册表、计划任务、BITS 和缓存目录操作，因此项目采用混合架构，而不是把已验证的系统逻辑重新翻译一遍。

## 界面结构

| Tab | 典型功能 | 执行保护 |
| --- | --- | --- |
| 安全 | C 盘深度分析、全部 Chrome/Edge 配置基础缓存、VS Code/npm/剪映/WPS 缓存、临时文件、旧 Codex runtime | 后台 BelowNormal、可取消；默认预览；精确叶目录白名单 |
| 中等风险 | Service Worker、Qoder 索引、NuGet/Playwright/企业微信缓存、NuGet 分阶段迁移、Windows Update、守护任务 | 运行中应用阻止；单项确认；迁移复制/校验/切换/删源/回滚分离 |
| 高风险 | Downloads 逐文件审查、Docker/WSL/Visual Studio 官方迁移向导、回收站、NetLimiter、系统策略 | 文件默认不选；输入“执行”；状态变化跳过；不使用目录联接 |

功能说明由 [features.json](./src/CPanCleaner.Gui/Resources/features.json) 驱动，Tab、分组和详情不是写死在 XAML 中。新增功能时应同时更新功能目录、PowerShell allowlist 和静态测试。

执行结果表格支持右键“打开选中条目所在文件夹”。目录目标会直接打开，文件目标会在 Explorer 中定位并选中；不存在的路径以及注册表、计划任务、诊断详情等非文件系统内容不会启用该菜单。

## 2.4 空间分析、清理和迁移

- `AnalyzeStorage` 优先使用 `diskusage.exe /c` 获取 `SizeOnDiskBytes`，跳过重解析点；不可用时使用有数量上限的 .NET 扫描。结果同时提供 `ReclaimableBytes`、建议、阻塞进程和迁移支持状态。
- 分析结果中只有能映射到既有精确白名单、存在可释放内容且目标位于该行显示根目录内的项目可以勾选。点击“清理勾选的白名单缓存”时只传递这些目标 ID，不会把 Chrome、Qoder、VS Code 等整个用户数据目录交给删除逻辑；高风险、迁移和人工建议保持不可选。
- Chrome/Edge 会发现 `Default`、`Profile N`、`Guest Profile`、`System Profile`，普通缓存与 Service Worker 离线缓存分开分级；书签、Cookie、密码、扩展、IndexedDB 和 Local Storage 均不在目标内。
- Chrome、Qoder、剪映、企业微信、VS Code、WPS、dotnet 等对应进程运行时，真实清理会返回 `BlockedByProcess`，程序从不自动结束这些进程。
- Downloads 只列出根目录的 EXE/MSI/ZIP/CRDOWNLOAD，默认不选；永久删除前重新校验路径、大小和修改时间并记录 SHA256。
- 自动迁移第一版只支持 [NuGet 全局包](https://learn.microsoft.com/nuget/consume-packages/managing-the-global-packages-and-cache-folders)。Prepare 复制、校验和切换但保留源；RemoveSource 需要单独确认；Rollback 使用 `%LOCALAPPDATA%\CPanCleaner\migrations` 中的清单。[Docker](https://docs.docker.com/desktop/settings-and-maintenance/settings/)、[WSL](https://learn.microsoft.com/windows/wsl/faq) 和 [Visual Studio](https://learn.microsoft.com/visualstudio/install/change-installation-locations?view=visualstudio) 只提供检测与官方入口。

## 2.5 FlClash 国内流量代理审计

“FlClash 国内流量代理审计”位于低风险页的“只读诊断”组。它检查 FlClash 当前接管模式和规则顺序，使用 APNIC 中国 IPv4 分配表归类活动 TCP 连接，并将“疑似误走代理”和“控制器确认经代理传输”分开显示。APNIC 数据缓存在 `%LOCALAPPDATA%\CPanCleaner\network-data`，有效期 7 天。

默认审计无需管理员权限，也不会修改 FlClash 配置。若在 FlClash 中把外部控制器设为仅回环的 `127.0.0.1:9090`，审计还可读取 Mihomo `/connections`，按进程、目标、命中规则汇总活动连接的上传和下载字节，并标记累计达到 100 MB 的项目。完整配置方法、结果边界和本机分析示例见 [FlClash 代理路由审计说明](./docs/FLCLASH_PROXY_ROUTING_AUDIT.md)。

## 计划任务管理

`PerformanceGuard` 和 `WindowsUpdateGuard` 是 CPanCleaner 注册到 Windows Task Scheduler 的任务。Windows 会把注册定义存储在 `C:\Windows\System32\Tasks\CPanCleaner`；用户不应直接复制、编辑或删除该目录里的文件。

- 任务在 GUI 中独立展示，未开启时不会创建。
- 可设置 5–1440 分钟周期，默认 15 分钟；两者还会在开机时运行。
- “刷新任务状态”显示安装、启用、运行状态、周期、SYSTEM 身份、上下次运行、退出码和实际动作。
- “开启 / 更新任务”通过 UAC 注册或替换任务；PerformanceGuard 此时才将专用脚本写入 `C:\ProgramData\CPanCleaner`。
- “关闭并移除任务”注销任务；PerformanceGuard 也删除专用脚本，但不会还原其他 Git、注册表、服务或 Windows Update 策略。
- PerformanceGuard 先通过低开销进程 API 判断 Git 是否存在，只有确有 Git 进程才使用 CIM 检查命令行，减少空闲时的 WMI 唤醒。

## Win+R 命令历史修复

“修复 Win+R 命令历史”位于中等风险页的“桌面与 Explorer”组。它会检测 `Start_TrackProgs`、`RunMRU`、相关 Explorer 策略和注册表 ACL。真实修复前会把状态保存为日志旁的 `.run-history-backup.json`，然后只启用当前用户的应用启动跟踪并验证 `RunMRU` 可写；已存在的注册表键不会被强制重建。它不会开启 `Start_TrackDocs`、不会清空现有历史，也不会终止 Explorer。机器级策略只报告，不自动绕过。

## 恢复的历史功能

Git 历史中在 `0504839` 删除的入口已在 GUI 中恢复为对应功能：

- `Run-Scan.bat`
- `Run-Clean-Safe.bat`
- `Run-Clean-Aggressive.bat`
- `Run-Clean-NetLimiter.bat`
- `Run-Disable-WindowsUpdate.bat`
- `Run-Optimize-Performance.bat`
- `Run-Prevent-Performance-Spikes.bat`
- `Run-Close-WindowsWidgets.bat`

核心模块 [CPanCleaner.psm1](./src/CPanCleaner.psm1) 也已恢复，并合并了 1.0.0 单文件版的浏览器缓存、图形缓存、Windows minidump 和远程桌面位图缓存。

`VisualStudioPackageCache` 来自更早的 `d3af64e`。它曾因可能破坏 Visual Studio 工作负载识别、修复、修改和卸载而在 `a037cf0` 被移除。2.0 只在高风险页单独展示，`Default`、`All` 和历史激进组合都不会包含它；界面也明确建议只扫描、不执行。

## 项目结构

```text
CPanCleaner.sln
CPanCleaner.ps1                    PowerShell 命令行包装器
src/
  CPanCleaner.psm1                 清理、更新、性能与诊断核心
  CPanCleaner.Gui/
    MainWindow.xaml                三层风险 GUI
    Models/OperationSelection.cs   勾选结果到精确清理目标的去重映射
    Resources/features.json        动态功能、原理和影响目录
    Services/CleanerBackend.cs     PowerShell、JSON、UAC 编排
scripts/
  Close-WindowsWidgets.ps1         可 dry-run 的 Widgets 后端
tests/
  Invoke-StaticTests.ps1           安全边界与历史功能测试
  CPanCleaner.Gui.LogicTests/      GUI 结果解析、选择和后端参数行为测试
docs/
  SAFETY.md
  FLCLASH_PROXY_ROUTING_AUDIT.md  FlClash 规则、流量与配置说明
  GUI_ARCHITECTURE.md
  RELEASE.md
```

## 构建和运行

当前仓库使用本机已有的 .NET 7 SDK，并已在 Windows 11 上完成 WPF 构建验证：

```powershell
dotnet restore .\CPanCleaner.sln --ignore-failed-sources
dotnet build .\CPanCleaner.sln -c Release --no-restore
.\src\CPanCleaner.Gui\bin\Release\net7.0-windows\CPanCleaner.exe
```

普通权限启动即可。只有所选功能确实需要系统权限时，GUI 才会启动隐藏的管理员 PowerShell 进程并显示 UAC。提升进程把结构化结果写到本次操作专用的临时 JSON，GUI 读取后立即删除；完整审计记录仍保存在 `backend\logs`，完成后应再次预览确认状态。

## 命令行兼容

图形界面之外仍可直接运行 PowerShell 后端。以下命令都不会真实修改系统：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include Default -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action AnalyzeStorage -AnalysisScope All -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action AuditProxyRouting -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action ReviewDownloads -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Migrate -MigrationTarget NuGetPackages -MigrationOperation Prepare -DestinationPath D:\NuGetPackages -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action OptimizePerformance -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action PreventPerformanceSpikes -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action ManageGuard -GuardName PerformanceGuard -GuardOperation Enable -GuardIntervalMinutes 30 -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1 -Action PersistMachine -DryRun -Json
```

真实变更必须显式添加 `-Apply`。命令行使用者还必须自行判断是否需要管理员 PowerShell；GUI 会负责触发 UAC。

## 安全模型

- 每个文件目标都有固定 `Path`、`Kind`、`Risk`、`Category` 和 `RequiresAdmin`。
- `Default` 只选择低风险目标。
- 删除父目录子项时禁止删除父目录本身。
- 拒绝重解析点；带年龄过滤的目录只要存在近期后代或无法完整枚举就跳过。
- 显式保护系统根、System32、SysWOW64、WinSxS、servicing、Program Files、Defender 数据和用户内容目录。
- `NetLimiterStats` 只允许删除精确的 `nlstats.db`。
- `VisualStudioPackageCache` 必须精确 Include，永远不由 `Default`、`All` 或激进组合间接选择。
- Downloads 只能删除用户明确勾选、位于根目录且身份未变化的允许扩展文件。
- NuGet 迁移拒绝 C 盘、非本地固定盘、非 NTFS、非空目录和重解析点；准备阶段不删除源。
- Windows Update 禁用、持久性能策略和机器级 Widgets 都先返回计划变更，真实执行需要管理员权限。

详见 [安全说明](./docs/SAFETY.md) 和 [GUI 架构](./docs/GUI_ARCHITECTURE.md)。

## 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CPanCleaner.ps1
dotnet build .\CPanCleaner.sln -c Release --no-restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include Default -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include VisualStudioPackageCache -DryRun -Json
```

发布和跨电脑复制方式见 [RELEASE.md](./docs/RELEASE.md)。
