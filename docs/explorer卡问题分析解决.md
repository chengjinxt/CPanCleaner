# Explorer 卡死问题分析与解决记录

## 结论

2026 年 10 月 18 日现场发生的资源管理器无响应，不是 `KnowCraft` 目录、Git 仓库规模或磁盘 I/O 直接导致的。

现场等待链和两个进程的全量转储共同表明：`explorer.exe` 与企业微信邮件组件 `WeMail.exe` 都加载了“中国移动统一安全网关”的 `MozartBreathCoreSDP.dll`。Explorer 线程在该安全组件的跨进程互斥锁上等待，而持有/关联该锁的 WeMail 线程也卡在同一组件的 `HMutexEx::lock` 逻辑中，形成长时间阻塞。

短期处理是先抓取 Explorer、WeMail 转储和等待链，再只结束阻塞的 `WeMail.exe`。企业微信随后自动拉起新的 WeMail 进程，Explorer 保持原 PID、没有重启，7 个已打开的资源管理器窗口全部恢复响应。

根治方向是由公司 IT 或“中国移动统一安全网关”厂商升级、修复 `Security Assistant SDPAgent 5.0.1.0` 的进程注入和互斥锁实现。未经 IT 确认，不建议自行卸载或禁用企业安全组件。

## 用户场景

- 时间：2026 年 10 月 18 日晚间。
- 系统：Windows 11，系统内部版本 22631。
- 操作位置：`E:\PerSourceCodeStore\github\chengjinxt\KnowCraft`。
- 可见现象：文件资源管理器窗口无响应，任务管理器和 PowerShell 也一度无法正常打开。
- Explorer 进程：PID `4784`，启动时间 `2026-10-18 00:14:33`。
- 现场目录所在 E 盘只剩约 1.4 GB 可用空间，这是需要另外处理的容量风险，但现场磁盘队列很低，也没有对应的磁盘或 NTFS 超时事件，不是本次卡死的直接原因。

## 分析过程与时间线

| 时间 | 动作 | 结果 |
| --- | --- | --- |
| 22:52:34—22:52:42 | 使用 ProcDump 对 `explorer.exe` PID `4784` 抓取全量转储 | 成功写入约 1.43 GiB 转储，未结束 Explorer |
| 约 23:05 | 使用 Windows Wait Chain Traversal 抓取 Explorer 等待链 | 定位到 Explorer TID `7248` 等待一个由 WeMail PID `15068`、TID `15740` 关联的 Mutex |
| 23:07:01—23:07:02 | 对 `WeMail.exe` PID `15068` 抓取全量转储 | 成功写入约 261 MiB 转储 |
| 23:07 后 | 执行 `taskkill /pid 15068 /f` | 只结束阻塞的 WeMail 组件，Explorer 未被结束 |
| 23:08:26 | 企业微信自动拉起新 `WeMail.exe` | 新 PID 为 `29044`，进程响应正常 |
| 23:11—23:14 | 使用 CDB/WinDbg 离线解析两个阻塞线程 | Explorer 和 WeMail 的目标线程均落在 `MozartBreathCoreSDP.dll` 的互斥锁/广播消息队列逻辑 |
| 最终验证 | 枚举全部 Explorer 窗口并调用 `IsHungAppWindow` | `ExplorerWindows=7`、`HungWindows=0`，Explorer PID 仍为 `4784` |

## 关键证据

### 1. Windows 等待链

等待链的原始关系为：

```text
explorer.exe PID 4784 / TID 7248（Blocked）
    -> Mutex（Owned）
        -> WeMail.exe PID 15068 / TID 15740（Blocked）
```

Windows Wait Chain Traversal 的节点语义是线程和同步对象交替出现，同步对象后面的线程是其所有者或关联等待者。因此，这条链直接说明 Explorer 的目标线程正在等待 WeMail 侧关联的互斥对象。

### 2. Explorer 阻塞线程栈

Explorer TID `7248`，十六进制线程号 `0x1c50`：

```text
ntdll!NtWaitForSingleObject
KERNELBASE!WaitForSingleObjectEx
MozartBreathCoreSDP!HMutexEx::lock
MozartBreathCoreSDP!HAutoMutexEx::HAutoMutexEx
MozartBreathCoreSDP!HSmBroadcastMgr::_DeQueue
MozartBreathCoreSDP!HSmBroadcastMgr::msg_loop
```

该线程明确停在安全组件的 `HMutexEx::lock`，不是 Explorer 自身的目录枚举、Git 状态查询或文件读取函数。

### 3. WeMail 阻塞线程栈

WeMail TID `15740`，十六进制线程号 `0x3d7c`：

```text
ntdll!NtDelayExecution
KERNELBASE!SleepEx
KERNELBASE!Sleep
MozartBreathCoreSDP!HMutexEx::log
MozartBreathCoreSDP!HMutexEx::lock
MozartBreathCoreSDP!HAutoMutexEx::HAutoMutexEx
MozartBreathCoreSDP!HSmBroadcastMgr::_DeQueue
MozartBreathCoreSDP!HSmBroadcastMgr::msg_loop
```

WeMail 侧目标线程处于该安全组件互斥锁实现的休眠/重试路径。结合等待链，可以判断这不是单独的 WeMail UI 卡顿，而是安全组件注入多个进程后的共享同步链异常。

### 4. 安全组件身份

Explorer 进程内相关模块信息：

```text
路径：C:\WINDOWS\LVUAAgentSDPInstBaseRoot\system32\MozartBreathCoreSDP.dll
文件版本：5.0.1.0
产品：Security Assistant SDPAgent
签名方：ShenZhen LeagSoft Technology Co.,Ltd.
安装项：中国移动统一安全网关
服务：CmicSDPAccessAgentDaemon（Automatic / Running）
```

同目录还加载了 `SauternesCoreSDP.dll`、`MozartBreathPrintSDP.dll`、`MozartBreathBoloSDP.dll`、`OverlordSpearSDP.dll` 和 `SteinwayMSVCRT.dll` 等同一产品组件。

### 5. 排除项

- `KnowCraft` 仓库只有约 199 个已跟踪文件，现场 `git status` 约 83 ms，不足以解释数十分钟级卡死。
- 机器安装了较多 Shell 扩展，最初它们都是候选项；但现场等待链和线程栈已直接指向 `MozartBreathCoreSDP.dll`，因此不能把根因笼统归为 TortoiseGit、网盘图标覆盖或其他 Shell 扩展。
- E 盘空间严重不足会放大系统性能和更新风险，但现场没有与卡死时间对应的高磁盘队列、磁盘超时或 NTFS 错误。

## 本次恢复操作

### 1. 抓取 Explorer 全量转储

```powershell
D:\ExplorerDumps\procdump64.exe -accepteula -ma 4784 D:\ExplorerDumps\explorer_hung_20261018.dmp
```

### 2. 抓取等待链

```powershell
D:\ExplorerDumps\WaitChainCapture.exe 4784
```

### 3. 在解除阻塞前抓取 WeMail 全量转储

```powershell
D:\ExplorerDumps\procdump64.exe -accepteula -ma 15068 D:\ExplorerDumps\wemail_blocker_20261018.dmp
```

### 4. 只结束阻塞组件

```powershell
taskkill /pid 15068 /f
```

如果任务管理器和 PowerShell 都打不开，可以尝试按 `Win+R`，运行：

```text
cmd /c taskkill /f /im WeMail.exe
```

该操作可能中断企业微信邮件组件当前任务，应优先完成转储；企业微信主程序通常会自动重新拉起 WeMail。不要直接结束 Explorer，也不要在未获得公司 IT 授权时停止或删除统一安全网关服务。

### 5. 验证恢复结果

```powershell
D:\ExplorerDumps\HangWindowProbe.exe 4784
```

现场输出：

```text
ExplorerWindows=7 HungWindows=0
explorer.exe PID=4784 Responding=True
WeMail.exe PID=29044 Responding=True StartTime=2026-10-18 23:08:26
```

Explorer 的 PID 和启动时间保持不变，说明窗口是在解除阻塞后自行恢复，不是通过重启 Explorer 掩盖问题。

## 证据文件

以下文件保存在现场机器的 `D:\ExplorerDumps`，未提交到 Git 仓库：

| 文件 | 大小 | 用途 |
| --- | ---: | --- |
| `explorer_hung_20261018.dmp` | 1,530,666,553 字节 | Explorer 全量转储 |
| `wemail_blocker_20261018.dmp` | 273,258,363 字节 | WeMail 全量转储 |
| `explorer_thread_1c50.txt` | 9,850 字节 | Explorer 阻塞线程离线栈 |
| `wemail_thread_3d7c.txt` | 8,738 字节 | WeMail 阻塞线程离线栈 |
| `WaitChainCapture.cs/.exe` | 现场工具 | 等待链采集工具 |
| `HangWindowProbe.cs/.exe` | 现场工具 | Explorer 窗口挂起状态验证工具 |

转储包含目标进程当时的内存数据，可能带有文件路径、账号信息或业务内容。只能通过公司批准的渠道交给 IT 或厂商，不应上传到公开仓库或公共网盘。

## 原因判断

### 已确认

1. Explorer 无响应的直接等待点是 `MozartBreathCoreSDP!HMutexEx::lock`。
2. Windows 等待链把该 Mutex 关联到 WeMail 的目标线程。
3. WeMail 目标线程也位于同一 DLL 的 `HMutexEx::lock` 和 `HSmBroadcastMgr` 路径。
4. 结束旧 WeMail 后 Mutex 被释放或相关共享状态被重建，Explorer 在不重启的情况下恢复。

因此，本次问题可高置信度归类为“中国移动统一安全网关 / SDPAgent 5.0.1.0 注入 Explorer 和 WeMail 后的跨进程互斥锁阻塞”。

### 尚不能从公开符号确认

转储中只有导出函数附近的符号，没有该产品的私有 PDB 和源码，因此还不能确定厂商内部是哪一处状态机造成锁未释放，例如异常退出、锁顺序反转、广播队列状态损坏或超时重试缺陷。这个内部实现结论需要厂商结合私有符号继续分析。

## 解决方案与优化建议

### 短期处置

1. 复发时先记录 Explorer 和 WeMail PID。
2. 先抓 Explorer 等待链和两个进程的全量转储。
3. 如果等待链仍指向 WeMail，再只重启 `WeMail.exe`，避免关闭所有 Explorer 窗口。
4. 验证全部 Explorer 窗口 `Hung=False`，同时确认 WeMail 已重新拉起且可响应。

### 长期修复

1. 向公司 IT/安全客户端维护方提交本文件及两个转储。
2. 要求厂商重点检查 `MozartBreathCoreSDP.dll 5.0.1.0` 的以下路径：
   - `HMutexEx::lock`
   - `HAutoMutexEx`
   - `HSmBroadcastMgr::_DeQueue`
   - `HSmBroadcastMgr::msg_loop`
3. 确认是否存在高于 `5.0.1.0` 的统一安全网关客户端，并在受控环境升级验证。
4. 如果厂商提供进程注入排除策略，可先在测试机评估对 `explorer.exe` 和 `WeMail.exe` 的排除效果；生产机变更必须经过公司安全策略审批。
5. 另行释放 E 盘空间，建议至少保留 10%—15% 可用容量，避免磁盘空间问题干扰后续复现和转储采集。

## 验证与回归点

- 连续打开、切换并刷新多个本地目录和 Git 仓库目录，Explorer 不出现长时间白屏或“未响应”。
- 启动、退出、登录企业微信及打开邮件功能时，Explorer 不被同步阻塞。
- 复发时等待链不再出现 `Explorer -> Mutex -> WeMail` 的关系。
- Explorer 和 WeMail 中如仍加载 `MozartBreathCoreSDP.dll`，其 `HSmBroadcastMgr` 线程不应长时间卡在同一 Mutex。
- 升级安全网关后记录 DLL 文件版本、安装项版本和服务版本，避免只依据服务端升级信息判断现场版本。
- 验证任务管理器、PowerShell 和 `Win+R` 能正常启动，以确认 Shell 交互链已完全恢复。

## 检索关键词

`Explorer 未响应`、`资源管理器卡死`、`任务管理器打不开`、`PowerShell 打不开`、`WeMail.exe`、`企业微信邮件`、`MozartBreathCoreSDP.dll`、`HMutexEx::lock`、`HSmBroadcastMgr`、`LVUAAgentSDPInstBaseRoot`、`Security Assistant SDPAgent`、`中国移动统一安全网关`、`联软科技`、`Wait Chain Traversal`、`ProcDump`
