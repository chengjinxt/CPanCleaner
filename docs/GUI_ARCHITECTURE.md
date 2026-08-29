# GUI 架构

## 分层

```text
features.json
    ↓ 功能元数据、风险、原理、影响、固定参数
WPF MainWindow
    ↓ 用户选择、预览、确认、进度、结果
CleanerBackend.cs
    ↓ ArgumentList、JSON、UAC、取消
CPanCleaner.ps1 / Close-WindowsWidgets.ps1
    ↓
CPanCleaner.psm1
    ↓ allowlist、路径检查、服务/注册表/任务操作
Windows
```

## C# 界面层

`MainWindow.xaml` 提供三个风险 Tab。每个列表按 `Group` 动态分组，详情区绑定当前 `CleanerFeature`，因此切换选择时会立即更新：

- 摘要
- 实现原理
- 可能影响
- 安全护栏
- 涉及路径/组件
- Git 历史来源
- 权限和按钮文本

`HighRiskConfirmationWindow` 要求用户输入“执行”。中低风险使用普通确认对话框，所有修改型功能均保留预览入口。

## 功能目录

`Resources/features.json` 是展示层的唯一功能目录。它不包含可执行 PowerShell 文本，只包含经过枚举的：

- `operationKind`：`Cleaner` 或 `Widgets`
- `action`：后端 ValidateSet 支持的动作
- `includes`：目标注册表支持的 Include
- 风险、分组、说明和受影响位置

新增目录项时必须同步测试，不能通过 JSON 引入任意脚本路径或任意命令参数。

## PowerShell 后端

`CPanCleaner.ps1` 是兼容命令行包装器；`CPanCleaner.psm1` 负责目标注册、扫描、删除、Windows Update 控制和性能操作。Widgets 使用独立脚本，但也支持 dry-run、apply 和 JSON。

GUI 默认以普通权限运行。普通操作使用重定向管道捕获 JSON；管理员操作由 `Verb=runas` 启动隐藏 PowerShell，并等待退出。提升进程通过随机命名的一次性临时 JSON 回传结构化结果，GUI 读取后立即删除；PowerShell 日志保留完整审计记录。

## 扩展规则

新增功能应按以下顺序：

1. 确定风险级别和恢复方案。
2. 在 PowerShell 后端使用固定 ValidateSet/allowlist 实现。
3. 添加 dry-run 输出与静态安全测试。
4. 在 `features.json` 添加原理、影响、护栏和路径。
5. 构建 WPF 并执行只读冒烟验证。
6. 更新 README、SAFETY、CHANGELOG 和 RELEASE。

不要把任意 PowerShell 文本、任意路径输入或“清理整个目录树”的通用能力暴露给 GUI。
