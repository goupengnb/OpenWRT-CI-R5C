# OpenWRT-CI（友善 NanoPi R5C 专用）

只编译友善 NanoPi R5C 一个设备，源码用 **OpenWrt 官方** `openwrt-25.12` 稳定分支。

- 插件来源：**官方 feeds 里有的用官方的**；官方确实没有的，用原作者仍在维护的第三方（见下表）。
- 每天 05:00（北京时间）自动编译，也可以在 Actions 页面手动触发。

## 设备信息

| 项目 | 参数 | 软件包 |
| --- | --- | --- |
| SoC | Rockchip RK3568B2（4×Cortex-A55） | 内核 6.12 |
| 内存 / 存储 | 4GB LPDDR4X / 32GB eMMC + microSD | 内核内建 |
| 网口 | 2× 2.5Gbps（RTL8125B） | `kmod-r8169`（官方设备定义即用内核驱动） |
| 无线 | M.2 E-Key（PCIe）插槽，模块是 **MT7921** | `kmod-mt7921e` + `kmod-mt7921-firmware` |
| USB / 显示 | 2× USB 3.2 Gen1 / HDMI | 内核内建 |

R5C **没有板载 WiFi**。官方设备定义里默认带的 RTL8822CE 驱动与固件（`kmod-rtw88-8822ce`、
`rtl8822ce-firmware`）已用 `DEVICE_EXTRA_PACKAGES` 的减号语法移除。要换回该模块，
把 `Config/R5C.txt` 那行里的 `-kmod-rtw88-8822ce -rtl8822ce-firmware` 去掉即可。

## 固件说明

- 镜像：`*-squashfs-sysupgrade.img.gz`（只读系统 + overlay，可一键恢复出厂，推荐）、
  `*-ext4-sysupgrade.img.gz`（整分区可写）。
- 分区：`32M（u-boot idbloader + ITB）` + `boot 64M` + `rootfs 2048M`，剩余约 28G 由固件首次开机自动接管。
- 默认参数：

| 项目 | 默认值 |
| --- | --- |
| 主机名 / 管理地址 | `狗鹏` / `192.168.1.1` |
| WiFi | `狗鹏` / `12345678`（CN，`psk2+ccmp`，首次开机即启用） |
| SSH | dropbear，22 端口，默认开启 |
| SMB / FTP | 默认开启，都指向 `/opt/files` |
| 主题 | **shadcn**（第三方，唯一主题，自带亮/暗切换） |
| root 密码 | 无（首次进 LuCI 自己设） |

root 密码为空时 dropbear / vsftpd **会拒绝登录**。想刷完就能 SSH / FTP，把 `R5C.yml` 里的
`WRT_PW` 改成一个密码再重编（`Scripts/Settings.sh` 会生成 sha512 哈希写进 `/etc/shadow`）。

## 刷机

1. 从 Releases 下载 `nanopi-r5c` 开头的镜像。
2. 写 SD 卡用 BalenaEtcher / `dd`；写 eMMC 可用 USB 读卡器，或在现有系统里 `sysupgrade`。
3. 首次开机 1~2 分钟，网口 1 是 LAN（`192.168.1.1`）。剩余 eMMC 空间不用手动处理。

## 存储与共享

`/etc/init.d/docker-storage` 在首次开机把剩余空间接管给 Docker：

| 步骤 | 做什么 |
| --- | --- |
| 1 | 找承载 rootfs 的那块盘（内核命令行 `root=`，R5C 的 u-boot 给的是 `PARTUUID=`；再顺着 overlay 的 loop 设备追到底层盘） |
| 2 | `parted` 在最后一个分区后**追加**一个占满剩余空间的分区（只往后追加，空闲不足 8G 或已有 3 个分区则跳过） |
| 3 | `mkfs.ext4 -L docker -m 0`（卷标 `docker` 是这块盘的标识） |
| 4 | 挂到 `/opt` 并写 `/etc/config/fstab` —— `dockerd` 的数据目录 `/opt/docker` 就落在大盘上 |
| 5 | `mkdir -p /opt/files` —— SMB / FTP 的共享目录 |

脚本幂等，分区表在线生效（parted 用 BLKPG ioctl 同步，不需要重启）。已手动分过区就不会动。
想手动分：`parted -s /dev/mmcblk0 mkpart primary ext4 <rootfs 结束位置> 100%`，
卷标必须叫 `docker`。

**SMB**：官方 `samba4-server`，不装 `luci-app-samba4` 面板（LuCI 里没有「网络共享」菜单）。
共享 `files` → `/opt/files`，访客可读写、只对内网；改共享直接编辑 `/etc/config/samba4`。
官方模板写死了 `invalid users = root`，要账号密码就 `adduser` + `smbpasswd -a` 并关掉 guest_ok。

**FTP**：官方 `vsftpd`，root + 系统密码登录，锁在 `/opt/files`。默认值由 `Scripts/Handles.sh`
写进 `/etc/vsftpd.conf`（`local_root` + `allow_writeable_chroot=YES` + `seccomp_sandbox=NO`
—— 后者是因为 3.0.5 在 6.12 内核上自带 seccomp 会让登录直接 500）。

## DNS

只留 `dnsmasq-full`（基础解析 + DHCP）和 **AdGuard Home**（官方源版本）。SmartDNS 和
https-dns-proxy 已移除 —— 多个 DNS 组件会抢 53 端口。

AdGuard Home 是开机自启的，但默认也想监听 53，而 53 被 dnsmasq 占着，所以它启动失败
（系统本身不受影响）。要用就先去 `http://192.168.1.1:3000` 初始化，然后把管理端口改掉
（如 3001），再二选一接管 53：

```sh
# A：AGH 独占 53，dnsmasq 只做 DHCP
uci set dhcp.@dnsmasq[0].port='0'; uci commit dhcp; /etc/init.d/dnsmasq restart

# B：dnsmasq 继续占 53，把解析转发给 AGH（AGH 的 DNS 端口改成 5353）
uci set dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci set dhcp.@dnsmasq[0].noresolv='1'; uci commit dhcp; /etc/init.d/dnsmasq restart

/etc/init.d/adguardhome enable; /etc/init.d/adguardhome restart
```

HomeProxy 的 DNS 是 sing-box 内置的（默认用 nft 把 53 劫持到 5333），和 AGH 是两条独立的路，
别让两边同时抢 53。

## 插件来源

官方 feeds 里没有的第三方插件（均已确认作者仍在维护）：

| 插件 | 来源 | 分支 |
| --- | --- | --- |
| `luci-theme-shadcn` | [eamonxg/luci-theme-shadcn](https://github.com/eamonxg/luci-theme-shadcn) | `main` |
| `luci-app-homeproxy` | [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy) | `master` |
| `luci-app-ddns-go`、`ddns-go` | [sirpdboy/luci-app-ddns-go](https://github.com/sirpdboy/luci-app-ddns-go) | `main` |

HomeProxy 的 `sing-box` 内核来自官方 feed（25.12 是 1.13.x），固件里不含任何第三方二进制。
其余插件全部来自官方 feeds，包括 AdGuard Home（不再用魔改版）。

## 插件清单（80 个显式包）

- **LuCI**：`luci`、`luci-ssl`、简体中文、`luci-app-firewall`、`luci-app-package-manager`、
  `luci-theme-shadcn`、`luci-app-nlbwmon`（菜单在**网络 → 带宽监控**）
- **系统工具**：bash、nano、htop、curl、wget-ssl、rsync、ca-certificates、openssl-util、ip-full、
  ethtool、pciutils、usbutils、iperf3、tcpdump、openssh-keygen、openssh-sftp-server、zoneinfo-core/asia
- **存储**：block-mount、blkid、lsblk、fdisk、sfdisk、parted、e2fsprogs、dosfstools、f2fs-tools、
  btrfs-progs、wipefs、xfs-mkfs、swap-utils、kmod-fs-vfat/exfat/ntfs3/btrfs/cifs、cifsmount、
  exfat-mkfs/fsck、kmod-usb-storage(+uas)、kmod-usb-net-rtl8152、smartmontools
- **DNS**：`dnsmasq-full`、`adguardhome`、`luci-app-adguardhome`
- **网络服务**：`ddns-go`、`luci-app-ddns-go`
- **文件共享**：`samba4-server`、`vsftpd`
- **代理**：`luci-app-homeproxy`、`sing-box`、`ucode-mod-math`、`coreutils-nohup/timeout`、
  `kmod-nft-tproxy/socket/fib`
- **Docker**：`luci-app-dockerman`、`dockerd`、`docker`、`docker-compose`
- **网络加速**：`kmod-tcp-bbr` + 内核 `sch_fq` + 默认队列 `fq`、`kmod-veth`、`kmod-br-netfilter`、
  `kmod-tun`、`kmod-nf-nat6`、`wpad-openssl`

已移除：官方主题、在线升级、hdparm、RTL8822CE 驱动与固件、SmartDNS、https-dns-proxy、
官方 DDNS/UPnP/WOL/SQM、PBR/OpenVPN/WireGuard、Tailscale、irqbalance、第三方 DiskMan 面板、
网页终端/文件管理/自定义命令页面、SMB 的 LuCI 面板。这份清单在 `R5C.yml` 的 `FORBIDDEN`
里做反向检查，被依赖悄悄拉回来就会编译失败。

## HomeProxy

装完是空的，先在**服务 → HomeProxy → 节点设置**导入订阅或手动加节点，再去**客户端设置**配主节点：

- **主节点**：单节点就选它；要故障转移就选 **`URLTest`**，勾上备选节点并填测试间隔/容差
  （按延迟现挑最快，不是按顺序固定切换）。
- **全屋代理**：**访问控制 → 局域网 IP 策略 → 代理过滤模式** 选 **「仅允许列表外」**
  （`except_listed`），直连列表留空。`Scripts/Handles.sh` 已经把默认值预置成这个，不用手动改。

## 仓库结构

```
.github/workflows/R5C.yml   唯一的 workflow：编译 + 发布 + 清理旧 Release
Config/R5C.txt              设备 / 内核 / 网卡配置
Config/GENERAL.txt          业务插件配置
Scripts/Packages.sh         拉取官方 feed 里没有的第三方插件
Scripts/Settings.sh         编译期改默认值（主题、IP/主机名/WiFi、内核 fq、
                            docker-storage、SMB/FTP 的 uci-defaults、可选 root 密码）
Scripts/Handles.sh          改第三方包自带文件（HomeProxy 的 uci-defaults、
                            vsftpd 的 /etc/vsftpd.conf）
```

## 手动编译

Actions → R5C → Run workflow：

- `PACKAGE`：临时追加插件包（`CONFIG_PACKAGE_xxx=y`），多个用 `\n` 分隔
- `TEST`：只生成配置不编译固件（**改完 Config 建议先跑一次 TEST**）

流程里有两道检查：`Verify Key Packages` 确认关键插件真的进了 `.config`
（`make defconfig` 会把依赖不满足的包静默丢掉），`FORBIDDEN` 反向确认不要的包没被拉回来。

本地编译需要 Linux/WSL2 或 Docker，装好 [官方依赖](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem)
后按上面 `仓库结构` 的顺序跑脚本即可。
