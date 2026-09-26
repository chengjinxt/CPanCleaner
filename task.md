# 任务清单：修复 CPanCleaner 更新与商店依赖破坏问题及沉淀 KnowCraft 知识卡片

- [x] 1. CPanCleaner 问题修复与防护 <!-- id: 1 -->
  - [x] 1.1 改造 DisableWindowsUpdate：剔除破坏应用商店的策略与服务禁用项（移除 DisableWindowsUpdateAccess、DoNotConnectToWindowsUpdateInternetLocations，解除对 UsoSvc 的禁用和停止） <!-- id: 1.1 -->
  - [x] 1.2 改造 WindowsUpdateGuard：移除守护任务中对 UsoSvc 和 DisableWindowsUpdateAccess 的周期性加固写入 <!-- id: 1.2 -->
  - [x] 1.3 实现 RestoreWindowsUpdate 功能：在 CPanCleaner.ps1 和 CPanCleaner.psm1 中提供一键还原更新策略、恢复并启动核心服务、恢复计划任务、停用守护任务的功能 <!-- id: 1.3 -->
  - [x] 1.4 更新 features.json：新增 restore-windows-update 功能，更新 disable-windows-update 与 windows-update-guard 说明和风险边界 <!-- id: 1.4 -->
  - [x] 1.5 扩展静态测试用例：在 tests/Invoke-StaticTests.ps1 中增加 RestoreWindowsUpdate 及 Store 兼容性断言 <!-- id: 1.5 -->
  - [x] 1.6 运行全部测试并验证通过 <!-- id: 1.6 -->
  - [x] 1.7 提交 Git commit（遵循 AGENTS.md 规范） <!-- id: 1.7 -->
- [x] 2. KnowCraft 知识卡片制作与归档 <!-- id: 2 -->
  - [x] 2.1 规划 4 张知识卡片内容（故障现象、底层架构依赖、根因机制、恢复排查）并符合白话与专业结合标准 <!-- id: 2.1 -->
  - [x] 2.2 使用 imagegen 生成 4 张竖版高质量原创知识卡片位图，保存至 assets/20260926_05_msstore-error-0x80004002-cards/ <!-- id: 2.2 -->
  - [x] 2.3 编写该卡片集详细 README.md，包含核心知识、术语双语全称、官方权威参考依据及生成说明 <!-- id: 2.3 -->
- [x] 3. 最终综合交付报告 <!-- id: 3 -->
  - [x] 3.1 总结排查过程、修复代码、测试结果及知识卡片交付物 <!-- id: 3.1 -->
