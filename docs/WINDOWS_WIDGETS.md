# 关闭 Windows 小组件

截图中的天气、市场面板是 Windows 11 Widgets。当前项目不再维护单独的关闭脚本，统一使用根目录的 `CPanCleaner.ps1`。

先预览：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action CloseWidgets
```

确认后关闭当前面板进程：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action CloseWidgets -Apply
```

这个动作只结束当前 `Widgets` / `WidgetService` 进程，不修改注册表，不重启 Explorer。Windows 后续可能重新启动后台进程。

若要长期隐藏入口，请使用 Windows「设置」->「个性化」->「任务栏」关闭「小组件」；若天气预警仍弹出，再到「设置」->「系统」->「通知」关闭 Widgets 或天气通知。需要恢复时重新打开对应开关即可。
