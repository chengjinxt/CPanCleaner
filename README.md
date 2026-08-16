# CPanCleaner

CPanCleaner 是一个单文件 Windows PowerShell 清理工具。发布和复制到其他电脑时只需要 `CPanCleaner.ps1`。

当前版本只保留经过本机验证、影响可控的功能：

- 只读扫描低风险缓存。
- 清理低风险缓存，默认预览，必须显式使用 `-Apply`。
- 刷新 DNS，并临时降低少量已知后台辅助进程的优先级。
- 关闭当前 Windows 小组件进程，不修改注册表或系统策略。

## 快速使用

在 PowerShell 中进入脚本所在目录。

```powershell
# 只扫描，不删除
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan

# 预览将要删除的内容
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean

# 执行低风险清理
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Apply

# 申请管理员权限后执行，可处理 Windows 临时目录等系统缓存
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Apply -Elevate

# 预览/执行临时性能优化
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action OptimizePerformance
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action OptimizePerformance -Apply

# 预览/关闭当前 Windows 小组件面板进程
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action CloseWidgets
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action CloseWidgets -Apply
```

`Clean` 不带 `-Apply` 时永远不会删除文件。默认只清理至少 1 天未变更的临时项目，可用 `-MinimumAgeDays` 调高保留时间。

## 安全边界

脚本不会清理以下内容：

- 桌面、文档、下载、图片、音乐和视频。
- 回收站。
- Windows Update 和 Delivery Optimization 下载目录。
- `WinSxS`、servicing、`Program Files` 等系统或程序目录。
- Visual Studio 安装包缓存。
- NetLimiter 统计数据库。
- 当前 Codex 运行时和 Codex 会话数据。
- 浏览器历史、Cookie、书签、密码和个人资料。

临时目录按年龄过滤。目录只有在目录本身和全部后代都超过保留天数时才会成为删除候选。重解析点会被跳过，访问拒绝和占用文件只记录为警告，不会中断整个任务。

完整边界见 [docs/SAFETY.md](docs/SAFETY.md)，跨电脑发布步骤见 [docs/RELEASE.md](docs/RELEASE.md)。

## 验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-CPanCleaner.ps1
```

运行日志默认写到脚本旁的 `logs` 目录；该目录不是发布包的一部分。
