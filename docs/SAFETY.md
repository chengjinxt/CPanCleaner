# 安全说明

## 执行模型

- `Scan` 只读取目录和磁盘空间。
- `Clean` 默认是 dry-run；只有同时提供 `-Apply` 才删除候选项。
- `OptimizePerformance` 默认预览；`-Apply` 只刷新 DNS，并把明确列出的后台辅助进程优先级临时设为 `BelowNormal`。
- `CloseWidgets` 默认预览；`-Apply` 只结束当前 `Widgets` 和 `WidgetService` 进程。
- `-Elevate` 只负责通过 UAC 重新启动同一脚本，不绕过 Windows 权限。

## 允许清理的目标

- 当前用户临时目录。
- `C:\Windows\Temp`。
- Windows Error Reporting 缓存。
- 下载的调试符号缓存。
- Windows minidump。
- 当前用户 INetCache、CrashDumps 和 D3D shader cache。
- Edge/Chrome 的 `Cache` 与 `Code Cache`，不包含用户资料数据。
- NVIDIA/AMD shader cache。
- 远程桌面 bitmap cache。
- 名称匹配 `codex-primary-runtime.previous-*` 的旧 Codex 运行时备份；当前运行时不处理。

## 删除保护

每个候选必须是其固定允许根目录的子项；脚本拒绝删除目标根目录本身。以下位置另外受到显式保护：

- `C:\`、`C:\Windows`、System32、SysWOW64、WinSxS 和 servicing。
- `Program Files` 与 `Program Files (x86)`。
- 用户配置文件根目录及桌面、文档、下载、图片、音乐、视频。

重解析点不会进入删除候选。使用年龄过滤的目录必须保证自身及全部可枚举后代均早于截止时间；无法完整枚举的目录会跳过。

## 明确排除

为避免丢失历史、安装修复能力或系统状态，当前版本不提供以下功能：

- 清空回收站。
- 删除 Windows Update 或 Delivery Optimization 内容。
- 删除 Visual Studio 安装包缓存。
- 删除 NetLimiter 统计数据库。
- 禁用 Windows Update 服务、策略或计划任务。
- 创建性能守护计划任务、修改 Git 全局设置或持久调整进程策略。
- 删除 Codex 当前运行时、会话数据库、日志或其他用户数据。

## 失败处理

占用、拒绝访问或其他单项错误会记录到结果和日志，随后继续处理其他目标。日志写入失败会自动停用本次日志，不会让清理任务整体终止。

空间统计以 C 盘执行前后的可用空间为准；按文件估算的 `RemovedMB` 可能受文件占用、压缩、稀疏文件和扫描上限影响。
