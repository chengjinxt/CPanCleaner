结论：`Windows Management Instrumentation` 一直运行本身正常；持续占 CPU 的主要原因，是向日葵守护进程 `awesun_guard.exe` 注册了每 4 秒扫描一次进程创建/退出的 WMI 查询。CPanCleaner 已把它降为 `BelowNormal`，但没有消除这个查询；而且现有 PerformanceGuard 每 5 分钟也会主动执行一次 WMI 查询，存在短暂推高 WMI 的问题。

## 为什么它一直运行

截图中的 PID `5404` 已确认是：

```
svchost.exe → Winmgmt
```

`Winmgmt` 是 Windows 的 WMI 服务，系统和第三方程序通过它查询：

- 进程创建和退出
- 硬件、驱动、蓝牙、网络适配器
- 安全中心、TPM、虚拟化状态
- Lenovo 设备状态
- 软件授权状态

因此不能因为它常驻就结束 `svchost.exe` 或禁用 `Winmgmt`。

内存不是问题：

```
截图：11.6 MB
当前：24.8 MB
```

这个占用很小。异常点是周期性 CPU 峰值，本次采样最高仍达到约 `10.8%`。

## 目前查到的主要调用方

WMI 活动日志明确显示：

### 1. 向日葵守护进程——最主要嫌疑

进程：

```
awesun_guard.exe
PID 9352
```

它注册了两条持续订阅：

```
SELECT * FROM __InstanceCreationEvent
WITHIN 4
WHERE TargetInstance ISA 'Win32_Process'
SELECT * FROM __InstanceDeletionEvent
WITHIN 4
WHERE TargetInstance ISA 'Win32_Process'
```

`WITHIN 4` 表示 WMI 大约每 4 秒检查一次整个进程集合，用于检测进程启动和退出。这种轮询会让 `Winmgmt` 长期保持活动，尤其这台机器只有 4 个逻辑处理器时更加明显。

如果完全退出向日葵和无人值守守护功能，WMI CPU 很可能明显下降，但会影响远程控制和无人值守连接。

### 2. LenovoTray

`LenovoTray.exe` 在查询不存在或不可用的 Lenovo WMI 类：

```
LENOVO_OTHER_METHOD
LENOVO_NON_GAMING_DATA
LENOVO_GAMEZONE_DATA
```

日志中出现多次 `0x80041010`，表示查询的 WMI 类无效。它不是当前持续查询的主要来源，但启动时会制造额外 WMI 负载。

### 3. 微信

微信执行了蓝牙设备查询：

```
SELECT * FROM Win32_PnPEntity
WHERE PNPClass = 'Bluetooth'
```

频率较低，不是当前主要原因。

截图中 Chrome 自身还有 `27.7%` CPU，企业微信约 `5.7%`，所以当时的卡顿并非全部来自 WMI。

## CPanCleaner 当前有没有优化

有部分优化，但不完整。

已经生效的部分：

- `AweSun` 和 `awesun_guard` 已被 PerformanceGuard 设置成 `BelowNormal`。
- 任务每 5 分钟重新降低一次后台 helper 优先级。
- 当前实际进程优先级已经确认是 `BelowNormal`。
- 工具不会粗暴停止 `Winmgmt` 或未知 `svchost`，这一点是正确的。

已安装任务：

```
\CPanCleaner\PerformanceGuard
每 5 分钟运行一次
```

实际脚本位于：

[Set-PerformancePriority.ps1](C:/ProgramData/CPanCleaner/Set-PerformancePriority.ps1)

## 工具本身存在的问题

PerformanceGuard 每 5 分钟执行：

```
Get-CimInstance Win32_Process -Filter "Name = 'git.exe' ..."
```

对应源码：

[CPanCleaner.psm1 (line 1687)](E:/PerSourceCodeStore/github/chengjinxt/CPanCleaner/src/CPanCleaner.psm1:1687)

这意味着即使没有相关 Git 进程，它也会唤醒 WMI。它不是向日葵每 4 秒查询造成的持续负载，但会形成周期性额外峰值。

另外，工具的 `Diagnose` 和“一次性性能优化”也会查询 `Win32_Process`。这些只在用户点击时发生，但运行诊断时会短暂让 `Winmgmt` 看起来更忙。

因此准确评价是：

- 已经通过降低向日葵等进程优先级缓解卡顿。
- 没有阻止向日葵的 WMI 进程监控。
- 没有专门的“WMI 查询来源诊断”界面。
- PerformanceGuard 自身还存在可减少的 WMI 查询。

## 建议处理顺序

1. 在不依赖远程连接时，完全退出向日葵，观察 1–2 分钟 WMI CPU。
2. 如果 CPU 明显下降，到向日葵设置中关闭无人值守、进程守护或开机启动，而不是停止 `Winmgmt`。
3. 退出或禁止 Lenovo PC Manager 的 `LenovoTray` 自启动，减少无效 WMI 查询。
4. 不要结束 PID 5404 的 `svchost.exe`。
5. 优化 CPanCleaner：
   - PerformanceGuard 先用 `Get-Process git*` 判断，只有发现 Git 进程才调用 CIM。
   - 将守护周期从 5 分钟调整为 15 分钟。
   - 增加 WMI 诊断页面，展示查询发起方、查询语句和频率。
   - 将向日葵的每 4 秒进程监控标记为高频 WMI 来源。

本次只进行了读取和分析，没有停止向日葵、WMI 服务或修改计划任务。