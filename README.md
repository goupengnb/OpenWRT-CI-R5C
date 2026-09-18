# OpenWRT-CI（友善 NanoPi R5C）

只编 R5C 一个设备，源码用 **OpenWrt 官方** `openwrt-25.12`。每天 05:00 自动编译，也可在 Actions 手动触发。

## 默认参数

| 项目 | 值 |
| --- | --- |
| 主机名 / 地址 | `狗鹏` / `192.168.1.1` |
| root 密码 | `12345678`（SSH、FTP 都用它） |
| WiFi | `狗鹏` / `12345678`（CN，`psk2+ccmp`，开机即启用） |
| 主题 | shadcn（第三方，唯一主题，自带亮/暗切换） |
| SMB | `\\192.168.1.1\files` → `/opt/files`，访客可读写，不用账号 |
| FTP | `ftp://192.168.1.1`，root / `12345678`，锁在 `/opt/files` |
| 外网访问 | SMB 445/139、FTP 21 与被动口 50000-50010 已放行；`WRT_WAN_SHARE` 改 `false` 即只在局域网 |

镜像：`squashfs`（只读系统 + overlay，可恢复出厂，推荐）和 `ext4` 两种。
分区：前 32M 给 u-boot，`boot 64M` + `rootfs 2048M`，剩余约 28G 首次开机自动接管。

## 刷机

1. Releases 下载 `nanopi-r5c` 开头的镜像；SD 卡用 BalenaEtcher / `dd`，eMMC 用读卡器或现有系统 `sysupgrade`。
2. 首次开机 1~2 分钟，网口 1 是 LAN。
3. 剩余 eMMC 空间自动分区（卷标 `docker`）、格式化并挂到 `/opt`：Docker 数据落在 `/opt/docker`，
   SMB / FTP 共享 `/opt/files`，三者共用这块盘。已手动分过区（>= 3 个分区）则跳过。

## 插件

第三方（官方 feed 里确实没有，且作者仍在维护）：

| 插件 | 来源 | 分支 |
| --- | --- | --- |
| `luci-theme-shadcn` | [eamonxg/luci-theme-shadcn](https://github.com/eamonxg/luci-theme-shadcn) | `main` |
| `luci-app-homeproxy` | [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy) | `master` |
| `ddns-go`、`luci-app-ddns-go` | [sirpdboy/luci-app-ddns-go](https://github.com/sirpdboy/luci-app-ddns-go) | `main` |

HomeProxy 的 `sing-box` 内核来自官方 feed，固件里没有第三方二进制。其余全部来自官方 feeds：
LuCI（shadcn / firewall / package-manager / nlbwmon）、系统工具、存储与文件系统工具、
`dnsmasq-full` + AdGuard Home、`samba4-server` + `vsftpd`、HomeProxy + `sing-box`、Docker 全家桶、
`kmod-tcp-bbr` + 内核 `fq` 队列、MT7921 无线。

已移除（`R5C.yml` 的 `FORBIDDEN` 每次编译反向检查，被依赖拉回来会失败）：官方主题、在线升级、hdparm、
RTL8822CE 驱动与固件、SmartDNS、https-dns-proxy、官方 DDNS/UPnP/WOL/SQM、PBR/OpenVPN/WireGuard、
Tailscale、irqbalance、DiskMan、网页终端/文件管理/自定义命令页面、SMB 的 LuCI 面板。

## DNS

只装 `dnsmasq-full`（基础解析 + DHCP）和 AdGuard Home。AGH 默认也想监听 53，而 53 被 dnsmasq 占着，
所以它起不来（不影响系统）。要用就去 `http://192.168.1.1:3000` 初始化，把管理端口改成 3001，然后二选一：

```sh
# A：AGH 独占 53，dnsmasq 只做 DHCP
uci set dhcp.@dnsmasq[0].port='0'; uci commit dhcp; /etc/init.d/dnsmasq restart

# B：dnsmasq 继续占 53，解析转发给 AGH（AGH 的 DNS 端口改成 5353）
uci set dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci set dhcp.@dnsmasq[0].noresolv='1'; uci commit dhcp; /etc/init.d/dnsmasq restart

/etc/init.d/adguardhome enable; /etc/init.d/adguardhome restart
```

HomeProxy 的 DNS 是 sing-box 内置的（nft 把 53 劫持到 5333），和 AGH 是两条路，别让两边同时抢 53。

## HomeProxy

先在**服务 → HomeProxy → 节点设置**导入订阅，再去**客户端设置**选主节点。
全屋走代理已经是默认值（`访问控制 → 局域网 IP 策略 → 代理过滤模式` = 仅允许列表外）；
要故障转移就把主节点选成 `URLTest` 并勾上备选节点。

## 仓库结构

```
.github/workflows/R5C.yml   唯一的 workflow：编译 -> 发布 -> 清理旧 Release
Config/R5C.txt              设备 / 内核 / 网卡
Config/GENERAL.txt          业务插件
Scripts/Packages.sh         拉第三方插件
Scripts/Settings.sh         编译期改默认值（主题、IP/主机名/WiFi、内核 fq、
                            docker-storage、SMB/FTP 的 uci-defaults、外网放行、root 密码）
Scripts/Handles.sh          改第三方包自带文件（HomeProxy uci-defaults、vsftpd.conf）
```

## 手动编译

Actions → R5C → Run workflow：`PACKAGE` 临时追加插件（多个用 `\n` 分隔），`TEST` 只生成配置不编译。
改完 Config 建议先跑一次 TEST（几分钟）——流程里的 `Verify Key Packages` 会检查关键插件是否真的进了
`.config`，`FORBIDDEN` 会反查不要的包有没有被依赖拉回来。
