# 实施计划：修复 CPanCleaner 防止破坏应用商店与更新服务 & KnowCraft 知识卡片沉淀

## 背景与问题描述
在本地使用 `winget install --id 9NT1R1C2HH7J --source msstore` 安装 ChatGPT 应用时报错：
`无法安装或更新 Microsoft Store 程序包。错误代码: 0x80004002` (E_NOINTERFACE)。
经深入排查，确认该故障由 `CPanCleaner` 的 `DisableWindowsUpdate` 和 `WindowsUpdateGuard` 引起：
1. 启用了极度激进的组策略 `DisableWindowsUpdateAccess = 1` 和 `DoNotConnectToWindowsUpdateInternetLocations = 1`，切断了 Windows Store 的端点连接与 COM 接口访问；
2. 禁用了负责应用商店和 WinGet 调度安装的核心系统服务 `UsoSvc` (Update Orchestrator Service) 并将其设为 Disabled (4)；
3. 停用了 `\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker` 等关键交互任务；
4. 后台以 SYSTEM 身份通过 `\CPanCleaner\WindowsUpdateGuard` 任务每 15 分钟持续覆盖加固上述禁用状态；
5. 原项目未提供任何还原恢复（Restore）机制，导致用户在误关后无法通过工具一键恢复。

## 修复目标与设计方案

### 1. CPanCleaner 改造防复发
- **剔除破坏 Store 的策略与服务项**：
  - 彻底从策略清单中移除 `DisableWindowsUpdateAccess` 和 `DoNotConnectToWindowsUpdateInternetLocations`。
  - 维持合理的更新控制：仅保留 `AUOptions = 2`（提示下载不自动下载）、`NoAutoUpdate = 1`、`ExcludeWUDriversInQualityUpdate = 1`，避免更新包私自占用大量 C 盘空间。
  - 彻底从服务禁用列表中移除 `UsoSvc`，保留 `UsoSvc` 正常运行，确保 Microsoft Store 和 WinGet 调用正常。
  - 从加固任务和 `WindowsUpdateGuard` 计划任务中同步剔除破坏性项目。
- **新增一键恢复动作 `RestoreWindowsUpdate`**：
  - 清理所有更新阻断性组策略。
  - 恢复核心服务启动类型：`wuauserv` (Auto/Demand)、`UsoSvc` (Auto Delayed)、`DoSvc` (Auto Delayed)、`WaaSMedicSvc` (Demand)，并启动关键服务。
  - 重新启用 `UpdateOrchestrator`、`WindowsUpdate` 和 `WaaSMedic` 计划任务。
  - 自动停用已注册的 `\CPanCleaner\WindowsUpdateGuard` 守护任务，防止被守护任务反向覆盖。
- **完善配置与界面支持**：
  - 在 `features.json` 中登记 `restore-windows-update` 功能。
  - 更新 `disable-windows-update` 及 `windows-update-guard-task` 的影响范围与安全边界说明。
- **完善静态安全测试**：
  - 在 `tests/Invoke-StaticTests.ps1` 中加入针对 `RestoreWindowsUpdate` 的 DryRun 测试。
  - 加入对 `DisableWindowsUpdateAccess` 和 `UsoSvc` 禁用项的安全断言（确保永远不会再次引入破坏 Store 的项）。
  - 执行测试并创建 Git 提交。

### 2. KnowCraft 知识卡片沉淀
- **设计 4 张系列原创知识卡片**（采用 3:4 竖版、浅色高对比度、圆角模块设计）：
  1. `01-error-symptom.png`：现象诊断卡——WinGet 报错 0x80004002，为什么重装商店和 wsreset 都无效？
  2. `02-architecture-dependency.png`：架构依赖卡——Microsoft Store 底层原来离不开 Windows Update 与 UsoSvc。
  3. `03-root-cause-analysis.png`：根因分析卡——粗暴“关更新/防占盘”如何引发 COM 接口断裂。
  4. `04-recovery-guide.png`：修复指南卡——恢复关键更新编排服务与清理阻断组策略。
- **规范保存目录**：`E:\PerSourceCodeStore\github\chengjinxt\KnowCraft\assets\20260926_05_winget-store-error-0x80004002-cards\`
- **编制标准说明文档**：创建包含卡片顺序、核心知识、双语术语全称、官方权威参考依据（Microsoft Learn）的 `README.md`。
