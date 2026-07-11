# CPanCleaner

CPanCleaner 是一个安全优先的 Windows C 盘清理工具。它以“先扫描、再 dry-run、最后显式 apply”为核心流程，默认只处理低风险临时目录，并通过路径白名单和敏感目录黑名单避免误删用户文档、系统组件库或程序安装目录。

## 项目定位

CPanCleaner 不是“尽可能多删除”的激进清理器，而是面向可审计维护场景的保守工具：

- 默认只扫描或预览，不会静默删除。
- 真实清理必须显式传入 `-Apply`。
- 中高风险目标必须显式 `-Include`。
- 管理员目标在非管理员会话中只提示，不强行执行。
- 每次运行都会写日志，方便回溯。
- Git fsmonitor 和 Conda 残留只做诊断，不默认杀进程或改配置。

## 开发语言

- 主要语言：PowerShell。
- 入口脚本：[CPanCleaner.ps1](./CPanCleaner.ps1)。
- 核心模块：[src/CPanCleaner.psm1](./src/CPanCleaner.psm1)。
- 测试脚本：[tests/Invoke-StaticTests.ps1](./tests/Invoke-StaticTests.ps1)。

选择 PowerShell 的原因是 Windows 缓存、服务、回收站、权限和文件系统操作都可以通过系统内置能力完成，不需要额外运行时。

## 实现原理

CPanCleaner 的实现由四层组成：

1. 目标注册表
   所有可清理位置都由模块内的目标定义注册，包含 `Id`、路径、风险级别、是否默认、是否需要管理员、是否使用时间过滤等元数据。

2. 选择策略
   `-Include Default` 只选择低风险默认目标；`WindowsUpdate`、`DeliveryOptimization`、`RecycleBin`、`OldQuarantine`、`NetLimiterStats` 等目标必须显式选择；`All` 只表示选择所有已注册目标，不表示绕过安全策略。

3. 路径安全检查
   删除前会检查候选路径是否位于目标允许根目录之内，并阻止进入敏感目录。工具清理缓存目录的“子项”，不删除父目录本身；对 NetLimiter 只允许删除明确的 `nlstats.db` 文件。

4. 执行模式
   `Scan` 只估算空间；`Clean` 默认 dry-run；`Clean -Apply` 才执行删除。管理员目标会先检查权限，Windows Update 缓存清理会尝试停止相关更新服务链后再清理缓存内容，NetLimiter 统计库清理会围绕 `NLSvc` 做停止和恢复。

## 支持的清理项

| Include | 默认 | 风险 | 权限 | 说明 |
| --- | --- | --- | --- | --- |
| `Default` | 是 | Low | 普通权限 | 当前用户临时目录和 `C:\Windows\Temp` 中超过 `-MinimumAgeDays` 的项目。 |
| `Temp` | 是 | Low | 普通权限 | 与默认临时目录目标相同。 |
| `WindowsUpdate` | 否 | Medium | 管理员 | Windows Update 下载缓存、升级暂存目录、Update Assistant 缓存。保留父目录，不碰组件库。 |
| `DeliveryOptimization` | 否 | Medium | 管理员 | Delivery Optimization 缓存。 |
| `RecycleBin` | 否 | High | 普通权限 | 清空 C 盘回收站，会永久移除用户已删除文件。 |
| `OldQuarantine` | 否 | Medium | 管理员 | 删除历史维护产生的已知隔离目录。 |
| `NetLimiterStats` | 否 | High | 管理员 | 删除 `C:\ProgramData\Locktime\NetLimiter\5\Stats\nlstats.db`。会丢失 NetLimiter 历史流量统计。 |
| `All` | 否 | Mixed | 视目标而定 | 选择全部已注册目标，仍遵守权限和安全检查。 |

## 开发环境要求

- Windows 10/11 或 Windows Server。
- Windows PowerShell 5.1 或 PowerShell 7+。
- Git，用于版本管理和发布。
- 推荐使用管理员 PowerShell 运行涉及系统缓存或服务控制的验证，但默认扫描和 dry-run 可在普通权限下运行。

## 运行权限

普通权限可执行：

- 默认扫描。
- 默认 dry-run。
- 默认低风险临时目录清理。
- Git/Conda 只读诊断。

管理员权限用于：

- Windows Update 缓存。
- Windows 升级暂存目录。
- Delivery Optimization 缓存。
- 旧隔离目录。
- NetLimiter 历史流量统计数据库。

可用 `-Elevate` 触发 UAC：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -Apply -Elevate
```

## 常用命令

进入项目目录：

```powershell
Set-Location E:\PerSourceCodeStore\github\chengjinxt\CPanCleaner
```

扫描默认低风险目标：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1
```

预览默认清理，不删除：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean
```

执行默认低风险清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Apply
```

预览 Windows Update 和 Delivery Optimization 清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -DryRun
```

执行管理员清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include WindowsUpdate,DeliveryOptimization -Apply -Elevate
```

预览 NetLimiter 历史流量统计数据库清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include NetLimiterStats -DryRun
```

执行 NetLimiter 历史流量统计数据库清理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include NetLimiterStats -Apply -Elevate
```

执行时工具会尝试停止 `NLSvc`，删除 `nlstats.db`，再按原运行状态重启 `NLSvc`。删除该数据库会释放空间，但会丢失 NetLimiter 历史流量统计。

运行 Git fsmonitor / Conda 残留诊断：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Diagnose
```

输出 JSON：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include All -Json
```

## 日志

每次运行会在 `logs\` 下生成日志：

```text
logs\cpancleaner-YYYYMMDD-HHMMSS-xxxxxxxx.log
```

日志记录内容包括：

- 运行模式和权限状态。
- dry-run 预览。
- 管理员目标跳过原因。
- Windows Update 服务停止尝试。
- NetLimiter 服务停止和恢复尝试。
- 删除成功或失败的路径。

`logs\*.log` 和 `logs\*.json` 默认不提交到 Git；仓库仅保留 `logs\.gitkeep`。

## 测试验证方式

静态安全测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticTests.ps1
```

默认扫描验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include Default -Json
```

默认 dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include Default -DryRun
```

NetLimiter 扫描验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Scan -Include NetLimiterStats -Json
```

NetLimiter dry-run 验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Clean -Include NetLimiterStats -DryRun
```

诊断入口验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action Diagnose -Json
```

发布前至少通过以上验证。涉及 `-Apply` 的真实清理应只在明确维护窗口中执行，并先保留 dry-run 输出或日志。

## 安全边界

CPanCleaner 禁止手工删除或递归进入以下敏感位置：

- C 盘根目录。
- `C:\Windows` 本身。
- `C:\Windows\System32`
- `C:\Windows\SysWOW64`
- `C:\Windows\WinSxS`
- `C:\Windows\servicing`
- `C:\Windows\servicing\Packages`
- `C:\Program Files`
- `C:\Program Files (x86)`
- Windows Defender 数据。
- 用户 Profile 根目录。
- Desktop、Documents、Downloads、Pictures、Music、Videos 等用户内容目录。

Windows Update 清理只处理缓存和暂存内容，不删除：

- `WinSxS`
- `servicing\Packages`
- BITS 队列数据库
- Windows Update 日志
- 系统组件库

回收站属于高风险目标，不在默认清理范围内。

NetLimiter 统计数据库属于高风险目标，不在默认清理范围内。CPanCleaner 只允许删除明确的 `nlstats.db` 文件，不清理整个 NetLimiter 目录。

## 版本规范

CPanCleaner 使用语义化版本：

```text
MAJOR.MINOR.PATCH
```

- `MAJOR`：安全模型、命令行参数或清理语义发生不兼容变化。
- `MINOR`：新增清理目标、诊断能力、输出字段或文档化能力，保持兼容。
- `PATCH`：缺陷修复、文档修正、测试增强或不改变行为的内部调整。

模块版本定义在 `src\CPanCleaner.psm1` 的 `$script:CleanerVersion`。发布前应确保 README、测试说明和版本号一致。

## 发布规范

建议发布流程：

1. 更新 `$script:CleanerVersion`。
2. 更新 README 中与版本相关的说明。
3. 运行测试验证章节中的命令。
4. 确认 `git status` 只包含预期文件。
5. 提交：

```powershell
git add .
git commit -m "Release CPanCleaner vX.Y.Z"
```

6. 打标签：

```powershell
git tag vX.Y.Z
```

7. 推送分支和标签：

```powershell
git push
git push origin vX.Y.Z
```

如果只是开发提交而不是正式发布，提交信息应描述行为变化，例如：

```powershell
git commit -m "Add NetLimiter statistics cleanup target"
```
