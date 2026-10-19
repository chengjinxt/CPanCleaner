# FlClash 国内流量代理审计

## 这台机器的当前结论

2026-10-19 的只读快照确认 FlClash 以 TUN 模式接管流量，Windows 系统代理开关未开启。当前生成配置包含 591 条规则，第一条中国直连规则 `GEOIP,CN,DIRECT` 位于索引 447；它之前已有 416 条会选择代理策略的规则。Mihomo 按从上到下、首次命中即停止的方式处理规则，因此这些规则命中的国内目标不会再执行后面的中国直连规则。

当前还存在 2 个完全相同目标同时配置直连和代理策略的冲突项：`itunes.apple.com` 与 `licdn.com`。最终实际走向由更靠前的规则决定。

活动 TCP 快照发现 Chrome、企业微信相关进程、QQ、WorkBuddy 和同步盘存在国内 IP 连接，但没有同时找到同目标的 FlClashCore 直连出口。这是“疑似经代理”的相关性证据，不是确定结论：当前 FlClash 未开启外部控制器，无法取得域名、命中规则、代理链和每条连接的累计字节。

两次各 20 秒的网卡计数中，代理节点方向合计约为 0.54 MB 和 0.43 MB；第二次 Meta Tunnel 总方向流量约为 2.28 MB。采样时没有观察到持续的大流量代理传输，但短快照不能排除稍早已结束、UDP 或稍后才发生的下载。

## 推荐配置顺序

先启用精确观测，再改规则。这样可以根据 `Rule`、`RulePayload`、进程、域名和累计字节确认真正消耗流量的目标，避免为了少数误判把整个应用永久设为直连。

1. 在 FlClash 的“工具 → 覆写 → 基础 → 外部控制器”中设置 `127.0.0.1:9090`。不同版本的菜单文字可能略有差异。
2. 只监听回环地址，不要使用 `0.0.0.0:9090` 或局域网地址。若界面支持 `secret`，建议同时设置；CPanCleaner 只从本机配置读取它，不会写入报告。
3. 保持产生问题的下载、同步或视频任务运行一段时间，然后在 CPanCleaner 中执行“FlClash 国内流量代理审计”，或运行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CPanCleaner.ps1 -Action AuditProxyRouting -Json
   ```

4. 优先为报告中已经确认且流量较大的域名添加窄规则，例如：

   ```yaml
   rules:
     - DOMAIN-SUFFIX,已确认的国内业务域名,DIRECT
   ```

5. 如果希望国内站点整体优先直连，可在 FlClash 当前配置的“进阶配置 / 附加规则”中按以下顺序添加：

   ```yaml
   rules:
     - GEOSITE,CN,DIRECT
     - GEOIP,CN,DIRECT,no-resolve
   ```

FlClash 会把附加规则放到订阅规则之前，因此这两条可避免当前“416 条代理规则抢先于中国直连规则”的问题。先添加 `GEOSITE,CN,DIRECT` 并观察；`GEOIP,CN,DIRECT,no-resolve` 是更宽的兜底，可能让使用国内 IP 但业务上需要代理的目标改走直连。不要把瞬时 CDN IP 长期写成规则，也不建议一开始就把 Chrome、QQ 或企业微信整个进程强制直连。

不要直接编辑 `%APPDATA%\com.follow\clash\config.json`。它是运行时生成配置，切换配置或重新覆写后可能被重建。

## CPanCleaner 如何判断

- 规则审计：定位第一条 `GEOSITE,CN,DIRECT` 或 `GEOIP,CN,DIRECT`，统计它之前的代理规则，并检查同一域名目标的直连/代理冲突。
- 国内地址归类：下载 APNIC 公共分配表，仅保留中国 IPv4 范围；有效数据在 `%LOCALAPPDATA%\CPanCleaner\network-data\delegated-apnic-latest` 缓存 7 天。
- 无控制器时：关联 TUN 应用连接与 FlClashCore 的直接出口，只输出 `SuspectedProxy`，不把它描述为确定流向。
- 开启控制器时：只访问 `127.0.0.1`、`localhost` 或 `::1` 的 Mihomo `/connections`；排除 `DIRECT` 链后，按进程、主机和命中规则汇总上传与下载字节，累计达到 100 MB 标记为 `Large`。
- 报告不会显示控制器 secret、订阅 URL、节点口令或完整代理链，也不会修改 FlClash、系统代理、网卡或规则。

系统代理模式下，应用通常只连接本机代理端口；不开控制器时无法从 `netstat` 还原原始目标，因此精确流向同样依赖 `/connections`。控制器统计只覆盖仍然活动的连接。已经关闭的连接、没有出现在 `/connections` 的流量以及控制器重启前的累计量不会进入结果，因此“大流量”用于定位当前会话，不等同于运营商或代理服务商账单。

## 结果解读

| 状态 | 含义 | 建议 |
| --- | --- | --- |
| `ProxyRulesFirst` | 中国直连规则之前已有代理规则 | 把确认安全的国内直连规则放到附加规则前部 |
| `SuspectedProxy` | 国内 TUN 连接缺少同目标直连出口 | 开启本机控制器后复测，不直接据此改进程规则 |
| `Observed` | 控制器确认国内目标经过非 `DIRECT` 链 | 根据域名和命中规则添加窄直连规则 |
| `Large` | 同一进程、主机与规则组合累计达到 100 MB | 优先处理并观察修改后的命中结果 |
| `NoneObserved` | 当前活动连接中未发现对应情况 | 让目标业务持续运行后再次审计 |

## 参考

- [FlClash 配置合并代码：附加规则先于订阅规则](https://github.com/chen08209/FlClash/blob/main/lib/common/task.dart)
- [FlClash 简体中文界面文字：外部控制器](https://github.com/chen08209/FlClash/blob/main/lib/l10n/intl/messages_zh_CN.dart)
- [Mihomo External Controller API](https://wiki.metacubex.one/en/api/)
- [APNIC delegated address statistics](https://ftp.apnic.net/stats/apnic/)
