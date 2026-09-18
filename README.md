# OpenWRT-CI（友善 NanoPi R5C 专用）

本仓库是 [goupengnb/OpenWRT-CI](https://github.com/goupengnb/OpenWRT-CI) 的 R5C 专用版本：

- **只编译友善 NanoPi R5C 一个设备**（不编译其它任何机型）
- 源码：**OpenWrt 官方** https://github.com/openwrt/openwrt.git（`openwrt-25.12` 稳定分支）
- 插件来源规则：**官方 feeds（base / packages / luci / routing）里有的，一律用官方的；
  官方确实没有的，用原作者仍在维护的第三方仓库**（清单见下表，逐个核对过 25.12.5 官方索引）
- 每天 05:00（北京时间）自动编译，也可以在 Actions 页面手动触发

# 设备信息（NanoPi R5C）

| 项目 | 参数 | 对应的软件包 |
| --- | --- | --- |
| SoC | Rockchip RK3568B2（4×Cortex-A55） | 内核 6.12 |
| 内存 | 4GB LPDDR4X | — |
| 存储 | 32GB eMMC + microSD 卡槽 | 内核内建（MMC_DW_ROCKCHIP=y） |
| 网口 | 2× 2.5Gbps（RTL8125B） | `kmod-r8169`（官方设备定义即用内核驱动） |
| 无线 | M.2 E-Key（PCIe）插槽 | 网卡是 **MT7921**：`kmod-mt7921e` + `kmod-mt7921-firmware`；官方设备定义里默认带的 RTL8822CE 驱动/固件（`kmod-rtw88-8822ce` + `rtl8822ce-firmware`）已用设备包移除机制摘掉 |
| USB | 2× USB 3.2 Gen1 | 内核内建（USB_DWC3=y、USB_XHCI_HCD=y） |
| 显示 | HDMI | 内核内建（drm/panfrost 都在 rockchip 内核里，不是独立 kmod） |
| 按键/灯 | Reset 按键、lan/power/heartbeat/wan/wlan 指示灯 | `kmod-gpio-button-hotplug`（官方默认） |

> 说明：R5C **没有板载 WiFi**，无线只能来自 M.2 E-Key 插槽里插的模块。固件里只带 **MT7921** 一套驱动（本机用的就是它），RTL8822CE 的驱动与固件已移除 —— 以后真要换回原厂 RTL8822CE 模块，需要自己把这两个包加回来，同时把 `Config/R5C.txt` 那行里的 `-kmod-rtw88-8822ce -rtl8822ce-firmware` 去掉。

# 固件说明

- 两种镜像：
  - `*-squashfs-sysupgrade.img.gz` —— 只读系统 + 可写 overlay，**日常推荐**（能一键恢复出厂）
  - `*-ext4-sysupgrade.img.gz` —— 整分区可写，方便 `resize2fs` 把剩余空间吃满
- 分区布局：`32M 对齐（u-boot idbloader+ITB）` + `boot 64M` + `rootfs 2048M`；剩下的约 28G
  裸空间由固件**首次开机自动接管**（分区 → 格式化 → 挂到 `/opt` → 交给 Docker，见「存储与共享」）
- 默认参数：
  - 主机名：`狗鹏`
  - 管理地址：`192.168.1.1`
  - WiFi：`狗鹏` / `12345678`（地区 CN，`psk2+ccmp`，**首次开机即启用**）
  - SSH：`dropbear`，22 端口，**默认开启**（`/etc/config/dropbear` 就是 enable=1 + 密码登录=开）
  - SMB / FTP：**默认开启**，都指向 `/opt/files`；SMB 访客可读写（只有服务端，没有 LuCI 面板），
    FTP 用 root 登录
  - 登录密码：无（买来是新机器，第一次进 LuCI 请自己设置密码）
  - 注意：root 密码为空时 dropbear / vsftpd 会**拒绝登录**（服务开着但进不去）。
    要"刷完就能 SSH / FTP 登录"，把 `R5C.yml` 里的 `WRT_PW` 从 `无` 改成一个密码再重编一次，
    `Scripts/Settings.sh` 会用它生成 sha512-crypt 哈希写进 `/etc/shadow`。
- 默认主题：**shadcn**（第三方 [eamonxg/luci-theme-shadcn](https://github.com/eamonxg/luci-theme-shadcn)，
  shadcn/ui 风格的侧栏主题；主题包自带 uci-defaults 会把 `luci.main.mediaurlbase` 设成 `/luci-static/shadcn`）。
  官方主题已按需求移除，shadcn 是唯一主题（靠 `Scripts/Settings.sh` 把 luci 集合里的
  `luci-theme-bootstrap` 换成它，否则 luci-light 会把 bootstrap 一起拖进来）。
  自带亮/暗切换，外观设置就在页面里，不需要额外的设置插件。

# 刷机方法

1. 到本仓库 **Releases** 下载对应镜像（`nanopi-r5c` 开头的文件）。
2. **写 SD 卡**：用 BalenaEtcher / Rufus（DD 模式）/ `dd` 直接写整卡；
   **写 eMMC**：把 R5C 的 eMMC 通过 USB 读卡器（或用 Maskrom/loader 模式）
   接到电脑再 `dd`，也可以在已经能用的系统里直接 `sysupgrade`：
   ```sh
   sysupgrade -n openwrt-25.12.x-rockchip-armv8-friendlyarm_nanopi-r5c-squashfs-sysupgrade.img.gz
   ```
3. 首次开机约 1~2 分钟，网口 1（LAN）地址 `192.168.1.1`。
4. **剩余 eMMC 空间不用手动处理**：首次开机会由 `/etc/init.d/docker-storage`
   自动分区、格式化（卷标 `docker`）并挂到 `/opt`，Docker 数据目录 `/opt/docker`
   直接落在这约 28G 上（细节见「存储与共享」）。想手动分也可以 —— 固件检测到磁盘上
   已经有 3 个以上分区就会跳过自动分区：
   ```sh
   parted -s /dev/mmcblk0 mkpart primary ext4 <rootfs 结束位置> 100%
   mkfs.ext4 -L docker /dev/mmcblk0p3   # 卷标必须是 docker，固件靠它认这块盘
   ```

5. 首次开机进系统后，如果要用 AdGuard Home，按下面「DNS 组件的默认启用策略」配一次。

# 存储与共享（Docker / SMB / FTP）

固件只把 eMMC 分出 `boot 64M` + `rootfs 2048M`，剩下的约 28G 是没分区的裸空间。
`/etc/init.d/docker-storage`（随固件编进去，`START=15`）在**首次开机**自动接管它：

| 步骤 | 做什么 | 为什么这么做 |
| --- | --- | --- |
| 1 | 找承载 rootfs 的那块盘（先看内核命令行 `root=`，R5C 的 u-boot 给的是 `PARTUUID=`，再用 `blkid` 反查设备；实在没有就看 overlay 的来源设备，overlay 是 loop 设备时顺着 sysfs 的 `backing_file` 追到底层盘） | 只动这一块盘，插着的移动硬盘不会被误伤 |
| 2 | 用 `parted` 在最后一个分区后面**追加**一个占满剩余空间的分区 | 从不修改/删除已有分区；空闲不足 8G 或磁盘上已有 3 个分区就直接跳过 |
| 3 | `mkfs.ext4 -L docker -m 0` | 卷标 `docker` 是这块盘的"身份证"，脚本和 fstab 都靠它认 |
| 4 | 挂到 `/opt`，并写一条 `/etc/config/fstab`（按卷标挂） | `dockerd` 的默认数据目录就是 `/opt/docker`，Docker 镜像/容器直接落在大盘上；fstab 那条在 LuCI 的「系统 → 挂载点」里也能看到 |
| 5 | `mkdir -p /opt/files` | SMB / FTP 的共享目录，和 Docker 共用这块盘 |

- 分区表是**在线生效**的：parted 3.x 用 BLKPG ioctl 把新分区同步给内核
  （libparted/arch/linux.c 的 `_disk_sync_part_table`），不用重启，也不必先卸载 overlay。
- 脚本幂等：以后每次开机只按卷标找盘、没挂就挂上；已经手动分过区就什么都不做。
- **SMB**：官方 `samba4-server`（按需求**不装** `luci-app-samba4` 面板，LuCI 里没有「网络共享」菜单），
  默认共享 `files` → `/opt/files`，访客可读写、只对内网（WAN 由防火墙挡着）。
  共享由 `Scripts/Settings.sh` 的 uci-defaults 首次开机写好，以后要改直接编辑 `/etc/config/samba4`。
  官方模板里写死了 `invalid users = root`，所以 SMB **不能**用 root 登录；
  要用账号密码就 `adduser` + `smbpasswd -a` 建个用户，再把共享里的"允许访客"关掉。
- **FTP**：官方 `vsftpd`，用 root + 系统密码登录，登录后锁在 `/opt/files`。
  官方 feed 里没有 FTP 的 LuCI 面板，默认值是 `Scripts/Handles.sh` 直接写进
  `/etc/vsftpd.conf` 的（`local_root` + `allow_writeable_chroot=YES` ——
  后者是 vsftpd 3.0 起"chroot 目录对登录用户可写"必须显式放行的开关，不加会 500 OOPS；
  同时还写了 `seccomp_sandbox=NO` —— 25.12 的 vsftpd 3.0.5 在 6.12 内核上，自带 seccomp 沙箱会让
  **登录直接 500（child died / priv_sock_get_cmd）**，沙盒里实测关掉它 FTP 才正常，所以默认关）。

# 插件来源

**官方 feeds 里没有、只能从第三方获取的插件**（都已确认上游作者仍在维护）：

| 插件 | 来源仓库 | 分支 | 说明 |
| --- | --- | --- | --- |
| `luci-theme-shadcn` | [eamonxg/luci-theme-shadcn](https://github.com/eamonxg/luci-theme-shadcn) | `main` | 官方 feed 无；shadcn/ui 风格侧栏主题，2026-09 仍在更新（0.5.11，作者 CI 同时出 ipk/apk）；只依赖 `luci-base`，不需要额外的设置插件 |
| `luci-app-homeproxy` | [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy) | `master` | 官方 feed 无；ImmortalWrt 官方团队维护；内核是**官方 feed 里的 `sing-box`**（25.12 是 1.13.x），固件里不带任何第三方二进制 |
| `luci-app-ddns-go`、`ddns-go` | [sirpdboy/luci-app-ddns-go](https://github.com/sirpdboy/luci-app-ddns-go) | `main` | 官方 feed 无；原作者仍在维护 |

**其余插件全部来自 OpenWrt 官方 feeds。** 其中 AdGuard Home 官方源已经有官方维护的
`adguardhome` + `luci-app-adguardhome`，所以不再使用第三方魔改版。

# 插件清单

已按需求精简到 **81 个包**（原 120 个；这里数的"个"= `Config/R5C.txt` + `Config/GENERAL.txt`
里明确勾选的包，上一个版本是 84）。移除的：官方主题、在线升级、硬盘休眠（含 `hdparm`）、
RTL8822CE 网卡驱动与固件、SmartDNS 与 DoH 代理、官方 DDNS/UPnP/WOL/SQM、
PBR/OpenVPN/WireGuard、网页终端页面（luci-app-ttyd）、网页文件管理、自定义命令、中断均衡（irqbalance）、
Tailscale、第三方 DiskMan 磁盘管理面板、SMB 的 LuCI 面板（luci-app-samba4）。
下面列的是保留下来的：

- **LuCI**：`luci`、`luci-ssl`(HTTPS)、简体中文、**shadcn 主题（第三方，唯一主题，不需要额外设置插件）**、`luci-app-firewall`、`luci-app-package-manager`、`luci-app-nlbwmon`（流量统计，菜单被挪到**网络 → 带宽监控**）
- **系统工具**：bash、nano、htop、curl、wget-ssl、rsync、ca-certificates、openssl-util、ip-full、ethtool、pciutils（lspci 看 M.2 网卡）、usbutils、iperf3、tcpdump、openssh-keygen、openssh-sftp-server、zoneinfo-core/asia
- **存储 / USB**：block-mount、blkid、lsblk、fdisk、sfdisk、parted、e2fsprogs、dosfstools、f2fs-tools、btrfs-progs、wipefs、xfs-mkfs、swap-utils、kmod-fs-vfat/exfat/ntfs3/btrfs/cifs、cifsmount、exfat-mkfs/fsck、kmod-usb-storage(+uas)、kmod-usb-net-rtl8152（USB 2.5G 网卡）、smartmontools
- **DNS**：`dnsmasq-full`（系统基础解析 + DHCP，唯一对外解析器）、AdGuard Home（`adguardhome` + `luci-app-adguardhome`，**官方源版本**）
- **网络服务**：**ddns-go + luci-app-ddns-go（第三方）**
- **文件共享**：**SMB**（官方 `samba4-server` 服务本体，**不带 LuCI 面板**，共享 `files` → `/opt/files`）、
  **FTP**（官方 `vsftpd`，锁在 `/opt/files`）
- **代理 / 分流**：**HomeProxy（第三方面板 + 官方 feed 的 `sing-box` 内核）**、`ucode-mod-math`（HomeProxy 要用但上游 Makefile 没声明，这里显式补上）
- **Docker**：`luci-app-dockerman` + `dockerd` + `docker` + `docker-compose`；数据目录 `/opt/docker`，落在 eMMC 剩余空间那块盘上（见「存储与共享」）
- **内核/网络加速**：`kmod-tcp-bbr`（BBR 拥塞控制）+ 内核打开 `sch_fq` 队列并把默认队列设为 `fq`（`Scripts/Settings.sh` 给 rockchip 内核配置补一行，同时写入 `/etc/sysctl.d/13-default-qdisc.conf`；上游没有对应的 kmod 包）、`kmod-veth`、`kmod-br-netfilter`、`kmod-tun`、`kmod-nf-nat6`、`kmod-nft-tproxy/socket/fib`、`wpad-openssl`。网卡只保留 **MT7921**（RTL8822CE 的驱动和固件已从设备默认包里一并移除）

# DNS 组件的默认启用策略

固件里只装了两套 DNS 相关组件，分工是清楚的：

| 组件 | 作用 | 默认状态 |
| --- | --- | --- |
| `dnsmasq-full` | 系统基础解析 + DHCP，对外唯一解析入口 | 开机自启，正常工作 |
| `adguardhome` + `luci-app-adguardhome` | 广告过滤面板 | 包在，但要手动配一次才能用 |

SmartDNS 和 https-dns-proxy 已按需求移除 —— 多个 DNS 组件同时存在只会互相抢 53 端口，
表现为解析绕来绕去、DNS 泄漏或干脆解析不了，只留一个反而清楚。

**AdGuard Home 为什么不能开箱即用**：OpenWrt 编固件时会**给每个包的 init 脚本自动建立自启链接**
（`package/base-files/files/lib/functions.sh` 里的 `default_postinst` 会对所有 `/etc/init.d/*` 执行 `enable`），
所以 AdGuard Home 也是开机自启的；而它的默认配置同样想监听 53 端口，那个端口已经被 dnsmasq 占着，
于是它自己启动失败。**系统本身不受影响**（dnsmasq 照常解析、DHCP 照常工作），只是 AGH 面板用不了。

要用就按这个顺序配一遍：

1. 浏览器打开 `http://192.168.1.1:3000` 完成初始化（设置后台账号密码）；
2. 在「设置 - 常规」里把**管理端口**从 3000 改掉（比如 3001），别和别的服务撞；
3. 在「DNS 设置」里把上游 DNS 填好；
4. 让它接管 53，下面两种做法二选一。

```sh
# 方式 A：AdGuard Home 独占 53，dnsmasq 只留 DHCP、不再做解析
uci set dhcp.@dnsmasq[0].port='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 方式 B：dnsmasq 继续占 53，但把解析全部转发给 AdGuard Home
#   （先把 AdGuard Home 的 DNS 监听端口改成 5353）
uci set dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

/etc/init.d/adguardhome enable
/etc/init.d/adguardhome restart
```

HomeProxy 的 DNS 是 sing-box 内置的（默认用 nft 把 53 劫持到 `infra.dns_port`，默认 5333），
和 AdGuard Home 是两条独立的路。**别让两边同时抢 53**：要么让 HomeProxy 管 DNS，
要么把 HomeProxy 的 DNS 劫持关掉、交给 AdGuard Home。

# 与原始配置的差异

| 项目 | 原来 | 现在 |
| --- | --- | --- |
| 源码 | immortalwrt（`immortalwrt/immortalwrt` master） | **OpenWrt 官方** `openwrt/openwrt` 的 `openwrt-25.12` 分支 |
| 编译目标 | 整个 rockchip/armv8 平台 | 只编译 `friendlyarm_nanopi-r5c` |
| 主题 | Argon（sbwml 的 fork） | **shadcn**（eamonxg，shadcn/ui 风格侧栏）；Argon / Liquid 按需求换掉 |
| 代理 / 分流 | OpenClash（vernesong `dev`，自带 mihomo 内核） | **HomeProxy**（immortalwrt `master`），内核换成官方 feed 里的 `sing-box` |
| AdGuardHome | 魔改版 `goupengnb/luci-app-adguardhome` | 官方 `adguardhome` + `luci-app-adguardhome` |
| DiskMan 磁盘管理面板 | sbwml fork | 按需求**移除**（官方 feed 没有此面板；分区/格式化用 `fdisk` / `parted` / `mkfs.*`） |
| ddns-go | sirpdboy | 同左 |
| `autocore`、`cpufreq` | immortalwrt 专有包 | 官方源没有，删除 |
| `opkg` / `opkg-conf` | 有 | 25.12 已改用 apk，删除 |
| `kmod-r8125` | 有 | 官方 R5C 设备定义用的就是内核 `r8169`，改用 `kmod-r8169` |
| `kmod-drm-panfrost` / `kmod-drm-rockchip` | 有 | 这两个在 rockchip 内核里是内建的（不是 kmod 包），删除 |
| `kmod-nft-fullcone`、`ipv6helper`、`luci-app-appfilter` 等 | 部分有 | 官方源没有，删除 |
| 第三方包版本更新脚本（`UPDATE_VERSION`，靠 sed 改 Makefile 版本号） | 启用 | **已删除**（容易把包改坏，交给上游自己更新） |
| ttyd 免密 root 登录补丁 | 有 | **移除**（等于局域网 root 后门） |
| Ruby YJIT（会连带从源码编译 rust 编译器） | 默认打开，单这一步就 3 小时以上，最后被 6 小时上限硬杀 | **已随 OpenClash 一起消失**（固件里不再有依赖 ruby 的包），只在 TEST 阶段留了一道拦截 |
| 第三方主题兜底 | 装了 `luci-theme-openwrt-2020` | 按需求移除，shadcn 是唯一主题 |
| 网卡驱动 | RTL8822CE + MT7921 两套 | 只留 MT7921（用设备包移除机制摘掉 RTL8822CE） |
| 网页终端页面 / 文件管理 / 自定义命令 / 中断均衡 | 都装了 | 按需求移除（都只是 LuCI 页面，删掉不影响功能；要 SSH 用系统的 dropbear）。注意 `ttyd` 二进制**留着**：`luci-app-dockerman` 的 Makefile 里是 `+ttyd`，容器终端靠它 |
| Tailscale 异地组网 | 装了 | 按需求移除 |
| SMB / FTP 文件共享 | 原来删掉了 | 按需求装回来：官方 `samba4-server` + `vsftpd`，共享 `/opt/files`；SMB 的 LuCI 面板按需求**移除**（只留服务，菜单里不再出现「网络共享」） |
| eMMC 剩余空间 | 自己 `parted` + `mkfs` 手动分区，再挂到 `/mnt/data` 或 `/opt` | **首次开机自动**分区（卷标 `docker`）→ 挂到 `/opt` → 直接给 Docker 用 |
| 带宽监控菜单位置 | 服务 → 带宽监控 | **网络 → 带宽监控**（`Scripts/Settings.sh` 改 menu.d 与页面里的硬编码链接） |
| 插件总量 | 120 个 | **81 个**（只留设备和用途上必需的） |

# 编译耗时与「Ruby YJIT」这个坑

| 阶段 | 冷编译（无缓存） | 有缓存 |
| --- | --- | --- |
| 工具链 + 内核 + 全部插件 | 约 1 ～ 1.5 小时 | 约 40 ～ 60 分钟 |

**千万不要打开 Ruby 的 YJIT。**

R5C 是 aarch64，而官方 feeds 里 `lang/ruby/Makefile` 对 aarch64 是默认开 YJIT 的：

```make
PKG_BUILD_DEPENDS:=ruby/host RUBY_ENABLE_YJIT:rust/host
config RUBY_ENABLE_YJIT
	default y if x86_64||aarch64
```

一旦打开，构建系统就会去 **从源码交叉编译一个 rust 编译器（`rust/host`）**。实测这一项跑 3 小时以上都出不来，
最后顶到 GitHub 的 6 小时上限被硬杀，连缓存都存不下来（白跑）。上游自己在 Makefile 里也写了
"It still does not support cross-compiling"。

原来会踩到它，是因为 OpenClash 硬依赖 `ruby` + `ruby-yaml`，删不掉，只能把 JIT 关掉。2026-09 换成
HomeProxy + 官方 `sing-box` 之后，固件里已经**没有任何包依赖 ruby**，`Config/GENERAL.txt` 和
`Scripts/Settings.sh` 里那两处关 YJIT 的写法也一并删了（以后真需要，按上面的 Makefile 片段加回来即可）。

`WRT-CORE.yml` 的 `Verify Key Packages` 里**留了一道保险丝**：一旦发现 `CONFIG_RUBY_ENABLE_YJIT=y` 直接中止。
以后要是又引入依赖 ruby 的插件，用 `TEST=true` 跑几分钟就能发现，不用等几个小时被 6 小时上限硬杀。

# 另一个坑：R5C 的设备包写死了 wpad-basic-mbedtls

官方 `target/linux/rockchip/image/armv8.mk` 里 R5C 的设备定义是：

```make
define Device/friendlyarm_nanopi-r5c
  DEVICE_PACKAGES := kmod-r8169 kmod-rtw88-8822ce rtl8822ce-firmware wpad-basic-mbedtls
endef
```

`DEVICE_PACKAGES` 会**无条件**叠进镜像，根本不看 `.config`。而本配置要的是功能更全的 `wpad-openssl`
（WPA3-SAE、802.11r/k/v、OWE、WPS），两者都提供 `hostapd` / `wpa-supplicant` 这两个虚拟包，APK 直接拒绝：

```
ERROR: unable to select packages:
  wpad-basic-mbedtls: conflicts: wpad-openssl[hostapd] / wpad-openssl[wpa-supplicant]
```

现象是**编译跑到最后打镜像时才失败**（前面全绿），2026-09-16 那轮 2 小时就是栽在这。

不用改官方源码。官方留了扩展入口，设备包列表 = `DEVICE_PACKAGES` + `DEVICE_EXTRA_PACKAGES`，
后者来自配置项，而且支持**减号前缀 = 移除该包**（实现见 `include/image.mk` 的 `merge_packages`）：

```
CONFIG_TARGET_DEVICE_PACKAGES_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5c="-wpad-basic-mbedtls -kmod-rtw88-8822ce -rtl8822ce-firmware"
```

同一行还顺便把 RTL8822CE 的驱动和固件也移除了 —— 它们同样被写死在这份 `DEVICE_PACKAGES` 里，
只在 `.config` 里删是没用的，照样会被塞进镜像。

写在 `Config/R5C.txt` 里。`Verify Key Packages` 步骤会 grep 这一行，没生效就直接中止，
免得又编两小时才炸。

# 目录说明

- `.github/workflows` —— CI 配置（`R5C.yml` 编译入口 + `WRT-CORE.yml` 公用核心 + `Auto-Clean.yml` / `Cache-Clean.yml` 清理）
- `Config/R5C.txt` —— 设备 / 内核 / 网卡配置（只编译 R5C）
- `Config/GENERAL.txt` —— 业务插件配置
- `Scripts/Settings.sh` —— 系统级修改与默认值：主题、默认主机名/IP、默认 WiFi、内核 `sch_fq`、
  带宽监控菜单挪到「网络」、`/etc/init.d/docker-storage`（eMMC 剩余空间 → `/opt` → Docker）、
  SMB/FTP 的 uci-defaults、可选的默认 root 密码（`WRT_PW`）
- `Scripts/Packages.sh` —— 从第三方仓库拉取**官方 feed 里没有**的插件（shadcn 主题 / HomeProxy / ddns-go）
- `Scripts/Handles.sh` —— 改第三方包自带文件的默认值：往 HomeProxy 包里塞
  `/etc/uci-defaults/zz-homeproxy-lan-proxy`（首次开机把 `lan_proxy_mode` 设成 `except_listed`）、
  给 vsftpd 的 `/etc/vsftpd.conf` 追加 `local_root=/opt/files` + `allow_writeable_chroot=YES`

# HomeProxy 怎么用（单节点 + 自动切换）

装完是「空」的，先把节点导进来：**服务 → HomeProxy → 节点设置**（订阅 / 手动添加），
然后去**客户端设置 → 路由设置**配主节点。

- **主节点**（`config.homeproxy.main_node`）：只有一个节点就选它，默认 `nil`（等于不代理）。
- **节点挂了自动切下一个**：把「主节点」选成 **`URLTest`**，再在下面的「URLTest 节点」里勾上所有备选节点，
  填「测试间隔」（秒）和「测试容差」（毫秒）。sing-box 会按这个间隔轮测所有节点，自动用最快的那个 ——
  这就是 HomeProxy 版的故障转移。注意它是**按延迟现挑**，不是 Clash 那种按你排的顺序固定切换。
- **主 UDP 节点**（`main_udp_node`）：默认 `same`（保持与主节点一致），要单独走别的节点再改。

**让整个局域网的设备都走代理**：**访问控制 → 局域网 IP 策略 → 代理过滤模式**，选
**「仅允许列表外」**（`except_listed`），下面几个直连列表留空即可。三个取值只有：

| 值 | 界面 | 含义 |
| --- | --- | --- |
| `disabled` | 禁用 | 谁都不代理（上游默认） |
| `listed_only` | 仅允许列表内 | 只代理列表里的 IP |
| `except_listed` | 仅允许列表外 | 除列表外全代理 ← **全屋走代理就是选它 + 列表留空** |

本仓库改的就是这一项：`Scripts/Handles.sh` 会预置一个 uci-defaults 脚本，首次开机自动设成 `except_listed`。

**广域网 IP 策略**（同一个页面的下一个标签）是另一回事：它让**转发流量**强制走代理（默认预置了 Telegram 的网段），
和上面那套按来源 IP 的策略互相独立。

DNS 由 sing-box 内置处理（`infra.dns_port`，默认 5333；`infra.dns_redirect=1` 时用 nft 把 53 劫持过去），
所以不需要像 OpenClash 那样去动 dnsmasq 的配置文件。

# 手动编译

Actions 页面选择 **R5C** workflow → Run workflow：

- `PACKAGE`：临时追加插件包（`CONFIG_PACKAGE_xxx=y`），多个用 `\n` 分隔
- `TEST`：勾选后只输出配置文件不编译固件（**改完 Config 建议先跑一次 TEST**）

编译流程里加了一步 **Verify Key Packages**：`make defconfig` 会把依赖不满足的包**静默丢掉**，
这一步会逐个检查关键插件是否真的进了 `.config`，缺了就中止编译，避免编出一个「看着正常但少了插件」的固件。

反过来还查一遍**被要求删除的包有没有被依赖偷偷拉回来**（比如某个插件依赖了 DiskMan）。
`make defconfig` 只会静默丢掉依赖不满足的包，但「被依赖拉进来」是静默的，不查的话固件会白胖，
所以这里也卡死。

# 说明

- 本固件由 GitHub Actions 云编译生成，本机（Windows）不需要搭建 Linux 编译环境；
  如果想本地编译，需要 Linux/WSL2（Ubuntu）或 Docker，按 [OpenWrt 官方文档](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem) 装依赖后
  先跑 `Scripts/Packages.sh` 拉第三方插件，再 `cp Config/R5C.txt Config/GENERAL.txt .config` 并 `make defconfig`。
- 安全说明：原脚本会把 ttyd 改成免密自动 root 登录（等于局域网 root 后门），本版本已移除；
  同时把 `wpad-basic-mbedtls` 换成 `wpad-openssl`，支持 WPA3-SAE / 802.11r / OWE。
  网页终端页面（`luci-app-ttyd`）也删了，但 `ttyd` 二进制保留 —— `luci-app-dockerman` 的
  Makefile 里写死 `+ttyd`（页面之外的容器终端功能依赖它），所以「服务 → 终端」不再出现在菜单里，
  只是少了这个页面，不是少了 ttyd 本体。
- 「开箱可用」的取舍：SMB 默认是**访客可读写**（官方模板里 `invalid users = root`，
  SMB 没法用 root 登录，访客是最省事的默认值；只对内网，WAN 被防火墙挡着）。
  FTP / SSH 要 root 密码才能登录，而固件默认密码为空 —— 想刷完就登得进去，把 `R5C.yml`
  里的 `WRT_PW` 改成一个密码再重编（公开仓库里塞固定密码等于给所有人留钥匙，所以默认不设）。
- HomeProxy 的页面是 ucode + JS 写的，不需要 `luci-compat` / `luci-lua-runtime`（那是 OpenClash 那种旧式 Lua 页面才要的）；
  它的 `sing-box`、`ucode`、`ucode-mod-*` 依赖全部来自官方 feed，不再需要预置任何第三方内核。
