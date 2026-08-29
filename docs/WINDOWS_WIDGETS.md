# 关闭 Windows 小组件

截图中的天气、市场面板是 Windows 11 Widgets。CPanCleaner 2.0 在 GUI 中提供三个分级动作：安全页只关闭当前进程，中等风险页隐藏当前用户入口，高风险页写入机器级策略。

先预览：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1 -Action Close -DryRun
```

确认后关闭当前面板进程：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Close-WindowsWidgets.ps1 -Action Close -Apply
```

这个动作只结束当前 `Widgets` / `WidgetService` 进程，不修改注册表，不重启 Explorer。Windows 后续可能重新启动后台进程。持久用户或机器设置应从 GUI 中单独选择并先预览。

若要长期隐藏入口，请使用 Windows「设置」->「个性化」->「任务栏」关闭「小组件」；若天气预警仍弹出，再到「设置」->「系统」->「通知」关闭 Widgets 或天气通知。需要恢复时重新打开对应开关即可。
