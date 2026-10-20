结论：**没有全部照搬**。CPanCleaner 覆盖了临时目录、Internet Cache 和回收站，但没有执行批处理里危险的“全盘按扩展名删除”、Prefetch、Cookie、最近使用记录清理。

| 批处理清理项                           | 覆盖情况         | CPanCleaner 界面位置                                         |
| -------------------------------------- | ---------------- | ------------------------------------------------------------ |
| `C:\*.tmp` 全盘递归                    | 部分覆盖         | `安全 → 文件与缓存 → 临时文件`，仅处理 `%TEMP%` 和 `C:\Windows\Temp`，不会扫描整个 C 盘 |
| `C:\*._mp`、`*.gid`、`*.chk`、`*.old`  | 未覆盖           | 无对应功能                                                   |
| `C:\Windows\*.bak`                     | 未覆盖           | 无对应功能                                                   |
| `C:\*.log` 全盘递归                    | 部分覆盖         | 仅有精确白名单：`剪映缓存与日志`、`WPS 下载缓存与日志`、`企业微信升级包与日志`等，不会删除所有日志 |
| `C:\recycled\*.*`                      | 功能意图已覆盖   | `高风险 → 不可恢复的数据 → 清空 C 盘回收站`                  |
| `C:\Windows\Prefetch`                  | 未覆盖           | 无对应功能                                                   |
| `C:\Windows\Temp`                      | 已覆盖，且更安全 | `安全 → 文件与缓存 → 临时文件`                               |
| `%USERPROFILE%\Cookies`                | 未覆盖           | 浏览器缓存功能明确保留 Cookie                                |
| `%USERPROFILE%\Recent`，脚本执行了两次 | 未覆盖           | `修复 Win+R 命令历史`不是清理 Recent，不能混为一项           |
| `Temporary Internet Files`             | 已覆盖           | `安全 → 文件与缓存 → Windows Internet Cache`                 |
| `Local Settings\Temp`                  | 已覆盖           | `安全 → 文件与缓存 → 临时文件`                               |

界面上最快的对应入口是：

- `安全 → 快速入口 → 扫描 / 清理全部低风险缓存`：同时包含临时文件和 Windows Internet Cache。
- `安全 → 文件与缓存 → 临时文件`：单独处理用户 Temp 与 Windows Temp。
- `安全 → 文件与缓存 → Windows Internet Cache`：对应旧版 `Temporary Internet Files`。
- `高风险 → 不可恢复的数据 → 清空 C 盘回收站`：需要单独确认，不包含在默认安全清理中。

几个关键差异：

- 批处理的全盘通配符命令见[一键清理系统垃圾.bat (line 5)](D:/一键清理系统垃圾.bat:5)。这种做法可能删除项目日志、安装日志、备份文件甚至仍有用途的临时文件；CPanCleaner 使用固定白名单是刻意的安全限制。
- 当前电脑上 `C:\recycled` 并不存在，实际回收站是 `C:\$Recycle.Bin`。程序使用 `Clear-RecycleBin`，比该批处理的旧路径更正确，定义见[features.json (line 643)](E:/PerSourceCodeStore/github/chengjinxt/CPanCleaner/src/CPanCleaner.Gui/Resources/features.json:643)。
- 临时文件默认保留 1 天，只删除候选子项并保留父目录，设置位置见[MainWindow.xaml (line 218)](E:/PerSourceCodeStore/github/chengjinxt/CPanCleaner/src/CPanCleaner.Gui/MainWindow.xaml:218)；目标实现见[CPanCleaner.psm1 (line 364)](E:/PerSourceCodeStore/github/chengjinxt/CPanCleaner/src/CPanCleaner.psm1:364)。
- 发现一个界面元数据小问题：单独的“临时文件”标记为不需要管理员权限，但 `C:\Windows\Temp` 后端目标实际需要管理员权限。普通权限下单独执行时，Windows Temp 可能显示 `NeedsAdministrator`；使用“扫描 / 清理全部低风险缓存”会正常触发提权。

我的建议是不要追求和这个旧批处理逐条一致。全盘扩展名、Prefetch、Cookie、Recent 这些缺失项目前更像安全设计，而不是功能遗漏。

本次仅做只读检查，没有运行该批处理、没有执行清理，也没有修改或提交项目文件。





你提到的 **Prefetch（预读取/预取文件）**，确实值得单独说明，因为很多老式“系统垃圾清理脚本”都会直接清空它，但在现代 Windows 上，**它不太适合作为常规垃圾清理项**。

### Prefetch 到底是什么

Windows 的 Prefetch 通常位于：

```
C:\Windows\Prefetch
```

里面常见的是 `.pf` 文件，例如：

`CHROME.EXE-xxxxxxxx.pf`
`EXPLORER.EXE-xxxxxxxx.pf`

Windows 会根据程序启动过程记录相关信息，之后利用这些数据优化应用启动和系统加载。简单理解就是：

> Prefetch 更接近 Windows 自动维护的“启动性能缓存”，而不是普通临时垃圾。

因此，“占空间”不等于“应该清理”。

### 删除 Prefetch 会发生什么

一般来说，删除 Prefetch **不会把 Windows 或对应软件卸坏**。Windows 后续会根据程序运行情况重新生成。

但问题在于：刚清理之后，Windows 丢失了已有的预取信息，一些程序首次或前几次启动反而可能变慢；之后随着 `.pf` 文件重新建立，性能才逐渐恢复。

所以会出现一个比较反直觉的情况：

**为了“优化电脑”而清 Prefetch，短期结果反而可能是降低启动优化效果。**

而且 Prefetch 通常并不是磁盘空间大户。即使清掉得到一些空间，也往往没有清理浏览器缓存、用户 Temp、Windows Temp、安装残留等项目划算。

### 你这个 BAT 为什么会清它

`一键清理系统垃圾.bat` 这类脚本通常来自比较老的 Windows 清理思路。当时很流行把：

```
Temp + Temporary Internet Files + Cookies + Recent + Prefetch
```

统一视为“垃圾”。

但它们实际上性质完全不同。例如 Temp 确实包含大量可清理临时文件；Cookies 可能包含登录状态；Recent 属于使用历史；而 Prefetch 则属于 Windows 性能优化机制产生的数据。

所以 CPanCleaner **没有 Prefetch 功能，并不代表漏实现了 BAT 的功能**。从产品设计角度，我反而倾向于继续保持现在这种状态：**不要把 Prefetch 加进“安全 → 文件与缓存 → 临时文件”，更不要加入“清理全部低风险缓存”。**

### 如果确实想增加 Prefetch

如果你的目标是让 CPanCleaner 的覆盖能力更完整，我建议可以增加，但定位成：

**高级/高风险 → 系统缓存 → Windows Prefetch（预取缓存）**

并且：

- 默认不勾选；
- 不进入“一键安全清理”；
- 明确提示“Windows 会自动重建”；
- 提示“清理后部分应用首次启动可能变慢”；
- 扫描阶段只统计，不直接删除；
- 需要管理员权限；
- 最好提供年龄过滤，而不是简单粗暴地 `del C:\Windows\Prefetch\*.*`。

也就是说，可以把它作为**故障排查/高级清理能力**，而不是“释放空间”的推荐项目。

对于你现在这个 CPanCleaner，我会把 Prefetch 的结论定为：

**BAT 有 → CPanCleaner 没有 → 建议保持默认不清理；如果为了功能覆盖而增加，则作为高级可选项，而不是安全清理项。**