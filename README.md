# Langate

> **Gated LAN entry for localhost services.** Wi-Fi allowlist + token gate + HTTPS, on macOS. Nothing ever leaves your home network.

给 Mac 本机上的任意 Web 服务（`127.0.0.1:xxxx`）加一道安全门，让同一 Wi-Fi 下的 iPhone / iPad / 其他电脑可以访问——**出门自动关门，回家自动开门，访客必须持令牌**。

```console
$ ./install.sh --upstream 127.0.0.1:3000 --ssid HomeWifi
$ gate token
  Gate link: https://your-mac.local:8443/gate?t=a1b2c3...
```

手机打开门禁链接一次（装一张自签根证书），之后从主屏幕图标直接进，无证书警告、无登录框。你离开家，入口在一分钟内自动关闭。

## 它解决什么问题

本机服务要给局域网设备用，通常只有两条路：直接监听 `0.0.0.0`（所有同网设备都能摸到，连咖啡厅 Wi-Fi 时裸奔），或者上 Tunnel/内网穿透（流量出公网，多一个信任方）。

Langate 走第三条：**服务绑定不动，反代加在前面，门禁加在反代上**。

- 服务仍只监听 `127.0.0.1`，源码零改动
- 反代（Caddy）只在白名单 Wi-Fi 下运行，由 launchd 按网络状态自动启停
- 访客首次访问需要门禁链接换取一年期 Cookie
- HTTPS 由 Caddy 内部 CA 签发，iOS 装一次根证书即可

## 与现有工具的关系

不重复造轮子：TLS 和反代交给 Caddy，Langate 只做现有工具没有的**门禁层**。

| | 出公网 | 各设备装客户端 | Wi-Fi 白名单 | 访客门禁 |
|---|---|---|---|---|
| **Langate** | 否 | 否 | ✓ | ✓ 令牌 Cookie |
| [mkdev](https://github.com/venkatkrishna07/mkdev) | 否 | 否（需信任其CA） | ✗（README 明言"Anyone on the LAN can hit your shared routes"） | ✗ |
| [localcaddy](https://github.com/noelforte/localcaddy) | 否 | 否 | ✗ | ✗ |
| tailscale serve | 否（走其协调服务器） | ✓ | ✗ | Tailnet 内即用 |
| cloudflared / ngrok | **是** | 否 | ✗ | 部分有 |

如果你只用它做开发调试、不在乎谁在局域网里，mkdev 体验更好（有 TUI）。Langate 的场景是**长期服务**（家庭面板、自用 GUI、NAS 类服务）+ **不能裸奔在陌生 Wi-Fi**。

## 安装

macOS + [Homebrew Caddy](https://caddyserver.com)：

```bash
brew install caddy
git clone https://github.com/AFOGSHEEP/Langate.git
cd Langate
./install.sh
```

向导会依次问：要保护的本机服务（`host:port`，须先启动）、允许的 Wi-Fi 名称。其余（端口、主机名、令牌）有默认值，也可用 flag 一次性脚本化：

```bash
./install.sh --upstream 127.0.0.1:3000 --ssid HomeWifi --ssid Office -y
```

## 管理：`gate` 命令

```text
gate status               当前网络、白名单归属、caddy/agent 状态、最近事件
gate allow <ssid|--current>   加入白名单（--current = 当前 Wi-Fi），立即生效
gate deny <ssid>          移出白名单，立即生效
gate list                 查看白名单
gate token                打印门禁链接（装了 qrencode 会附二维码）
gate rotate-token         换令牌，旧链接全部作废
gate doctor               体检：依赖/作业/进程/端口/上游连通性
gate start | stop         手动整站启停（stop 会连闸门一起停，不被定时器拉起）
gate logs [caddy|gate] N  看日志
./uninstall.sh            干净卸载（含 plist、配置、自建 CA）
```

## 工作原理

```
iPhone / iPad Safari ──HTTPS──> Caddy :8443（校验门禁Cookie）
                                   │
                                   ▼
                          你的服务 127.0.0.1:3000（绑定未改动）

:8444（纯HTTP）：只用于分发根证书 root.crt

launchd 闸门（每60秒 + 网络切换事件）：
  当前 Wi-Fi 在白名单 → 保持 Caddy 运行
  陌生网络 / 热点 / 无Wi-Fi → 卸载 Caddy 作业
```

两个 launchd 作业：

- `com.langate.caddy`：`RunAtLoad` + `KeepAlive`，承载反代，崩溃自动重启
- `com.langate.gate`：60 秒一轮 + 监听系统网络配置文件变更，按当前 SSID 决定 `bootstrap` / `bootout` Caddy 作业

闸门从不直接 spawn Caddy——从 launchd 作业脚本里 `nohup` 出来的进程会随作业的进程组一起被 SIGTERM，这是 macOS 上最常见的一个坑。

## 安全模型

- 服务本身仍然只监听 `127.0.0.1`；Langate 只加门，不改服务
- 入口只在白名单 Wi-Fi 存在；**不提供任何公网访问路径**
- 令牌只存在于 Mac 上的 `~/.config/langate/config.env`（0600）和 Caddyfile
- 特权边界：全程无 sudo，只操作用户域 launchd（`gui/$UID`）
- 已知边界：Mac 睡眠/未登录时入口不可用；Android 不解析 `.local`（路线图支持 IP + 证书）；门禁 Cookie 是"持卡进入"，不防已持卡设备的丢失——换设备或怀疑泄露时 `gate rotate-token`

## FAQ

**为什么必须 HTTPS？** iOS Safari 在非安全上下文禁用部分 Web API（典型报错 `crypto.randomUUID is not a function`），且明文 Cookie 在局域网内可被嗅探。

**为什么用 Cookie 不用 Basic Auth？** iOS Safari 对 Basic Auth 凭据缓存不可靠，会反复弹登录框；Cookie 设一次管一年。

**公司/校园网能用吗？** 多播和客户端隔离常被禁，`.local` 解析可能失败。Langate 的白名单机制本来就建议陌生网络不放行。

## 路线图

- [ ] `gate` 多服务路由（一个入口反代多个本机服务）
- [ ] Android 支持：IP + SAN 证书方案
- [ ] 日志轮转
- [ ] Homebrew tap 分发

## License

[MIT](./LICENSE)
