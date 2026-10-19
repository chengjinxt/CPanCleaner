# 发布与跨电脑使用

## 发布前验证

在仓库根目录执行：

```powershell
dotnet restore .\CPanCleaner.sln --ignore-failed-sources
dotnet build .\CPanCleaner.sln -c Release --no-restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CPanCleaner.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include Default -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include Default -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action DisableWindowsUpdate -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action PreventPerformanceSpikes -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action ManageGuard -GuardName PerformanceGuard -GuardOperation Enable -GuardIntervalMinutes 30 -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action RepairRunHistory -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action AnalyzeStorage -AnalysisScope All -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action ReviewDownloads -DryRun -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1 -Action PersistMachine -DryRun -Json
```

以上命令不能带 `-Apply`。涉及实际删除、服务或策略的验证只能在明确维护窗口和可恢复测试机上进行。

## 发布目录

WPF 程序需要同时携带可审计 PowerShell 后端和动态功能目录。发布物是一个文件夹，不是只有一个 EXE：

```text
CPanCleaner.exe
CPanCleaner.dll
CPanCleaner.deps.json
CPanCleaner.runtimeconfig.json
Resources/
  features.json
backend/
  CPanCleaner.ps1
  src/CPanCleaner.psm1
  scripts/Close-WindowsWidgets.ps1
```

不要遗漏 `Resources` 或 `backend`。GUI 启动时会校验这些文件是否可找到。

## 框架依赖发布

目标电脑已安装 .NET 7 Desktop Runtime 时：

```powershell
dotnet publish .\src\CPanCleaner.Gui\CPanCleaner.Gui.csproj -c Release -r win-x64 --self-contained false -o .\artifacts\CPanCleaner-win-x64
```

## 自包含发布到 dist

目标电脑没有 .NET Desktop Runtime 时：

```powershell
dotnet publish .\src\CPanCleaner.Gui\CPanCleaner.Gui.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o .\dist\CPanCleaner-2.5.0-win-x64
Compress-Archive -Path .\dist\CPanCleaner-2.5.0-win-x64\* -DestinationPath .\dist\CPanCleaner-2.5.0-win-x64.zip
Get-FileHash .\dist\CPanCleaner-2.5.0-win-x64.zip -Algorithm SHA256
```

即使启用 `PublishSingleFile`，`Resources` 和 `backend` 仍是独立内容文件，这是为了让风险说明与系统脚本可审计、可更新。

## 校验和版本

发布前记录：

```powershell
Get-FileHash .\artifacts\CPanCleaner-win-x64\CPanCleaner.exe -Algorithm SHA256
Get-FileHash .\artifacts\CPanCleaner-win-x64\backend\CPanCleaner.ps1 -Algorithm SHA256
Get-FileHash .\artifacts\CPanCleaner-win-x64\backend\src\CPanCleaner.psm1 -Algorithm SHA256
```

发布说明应包含版本、Git 提交、目标运行时、三项 SHA256 和验证命令结果。

## 首次运行

1. 解压整个发布目录，不能只复制 EXE。
2. 校验发布说明中的 SHA256。
3. 普通权限启动 `CPanCleaner.exe`。
4. 先查看每个功能的原理和影响，再运行预览。
5. 只有确认预览路径后才执行；需要系统权限的功能会触发 UAC。
6. 高风险功能执行后再次预览，并保留 `backend\logs`。

## 回滚

文件删除本身不可撤销。缓存通常会重建，但回收站、NetLimiter 历史和 Visual Studio Packages 不保证可恢复。

计划任务可在 GUI 中关闭和移除，但其他持久策略不会被自动回滚：

- Windows Update 禁用仍需另行恢复策略、服务启动类型和 Windows 自带任务；关闭 WindowsUpdateGuard 只停止周期重申。
- 关闭 PerformanceGuard 会删除任务和专用脚本，但 Git/TortoiseGit 设置仍需另行还原。
- Widgets 需要还原 HKCU/HKLM Dsh 与 TaskbarDa 值。

发布回滚只能换回旧程序文件，不能自动逆转已经执行的系统操作。
