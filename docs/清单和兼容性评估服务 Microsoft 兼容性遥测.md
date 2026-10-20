结论：这两项都是微软签名的 Windows 兼容性评估组件，不是可疑程序；可以控制，但目前不建议永久禁用。

- `InventorySvc`：中文名“清单和兼容性评估服务”，由 `svchost.exe -k InvSvcGroup -p` 托管，负责收集软件、驱动、硬件信息，用于系统升级和应用兼容性判断。
- `CompatTelRunner.exe`：任务管理器显示为“Microsoft 兼容性遥测”，负责执行实际扫描。文件位于 `C:\Windows\System32`，数字签名有效，确认为微软系统文件。
- 两者属于同一条兼容性评估链路，所以可能同时升高 CPU。

本机现状：

- `InventorySvc` 是“按需启动”，不是自动启动。
- `Microsoft Compatibility Appraiser` 计划任务已经处于禁用状态。
- `CompatTelRunner.exe` 当前已经退出。
- `InventorySvc` 当前仍运行，但连续采样 CPU 为 `0%`，仅占约 35 MB 内存。
- 当前整机 CPU 大约 `5%–12%`。截图中的约 `20%` 更像扫描阶段的短时峰值，并非持续异常。
- 截图中的 `Winmgmt` 是 WMI 服务，不要禁用；PowerShell、任务管理器或管理软件频繁查询系统信息时，它也会短暂升高。

建议按以下级别控制：

1. 推荐：发现它持续占用时临时停止，不修改启动配置：

```
Stop-Service InventorySvc
```

它以后可能被 Windows Update 或兼容性检查重新按需启动。

1. 保持现状：兼容性评估计划任务已经禁用，通常不需要再处理。停止当前空闲服务只能释放约 35 MB 内存，性能收益很小。
2. 强力控制但不推荐：把 `InventorySvc` 永久禁用：

```
Stop-Service InventorySvc
Set-Service InventorySvc -StartupType Disabled
```

恢复方式：

```
Set-Service InventorySvc -StartupType Manual
Start-Service InventorySvc
```

永久禁用可能影响 Windows 功能更新前的兼容性检查、升级准备状态和部分兼容性故障诊断，而且系统大版本更新后可能恢复设置。

综合判断：可以优化控制，但这次无需立即处理；若以后每次开机或空闲时都连续占用 `15%–25%` 超过十几分钟，再进一步记录触发时间并控制调用源，比直接禁用系统服务更稳妥。本次只做了只读诊断，没有修改系统配置或项目文件。