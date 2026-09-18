#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#==========LuCI 主题：把 luci-light 依赖的 luci-theme-bootstrap 换成 WRT_THEME==========
COLLECTION_MAKEFILES=$(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$COLLECTION_MAKEFILES" ]; then
	sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $COLLECTION_MAKEFILES
else
	echo "warning: luci collections not found, skip theme patch"
fi

#==========LuCI 小修补（按官方 25.12 路径；找不到就跳过，不影响编译）==========
#概览/登录页显示的默认 IP
FLASH_JS=$(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null)
if [ -n "$FLASH_JS" ]; then
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $FLASH_JS
else
	echo "warning: flash.js not found, skip ip patch"
fi
#页脚的编译标记
STATUS_JS=$(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" 2>/dev/null)
if [ -n "$STATUS_JS" ]; then
	sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $STATUS_JS
else
	echo "warning: 10_system.js not found, skip version patch"
fi

#==========把「带宽监控」从「服务」挪到「网络」==========
#luci-app-nlbwmon 上游注册的菜单是 admin/services/nlbw（界面上是「服务 → 带宽监控」），
#这里改成 admin/network/nlbw（「网络 → 带宽监控」）。菜单标题是 JS 框架按英文原文查 i18n
#（po 里的 msgid 是 "Bandwidth Monitor"），所以只改路径不会丢中文翻译；
#但 view/nlbw/config.js 里有一处硬编码链接 L.url('admin/services/nlbw/backup')
#（配置页里的"下载备份"）必须一起改，否则那个链接点进去是 404。
NLBW_DIR=$(find ./feeds/luci/applications -maxdepth 1 -type d -name "luci-app-nlbwmon" 2>/dev/null)
if [ -n "$NLBW_DIR" ]; then
	find "$NLBW_DIR" -type f \( -name "*.json" -o -name "*.js" \) -exec \
		sed -i 's#admin/services/nlbw#admin/network/nlbw#g' {} +
	if grep -rqs 'admin/services/nlbw' "$NLBW_DIR"; then
		echo "warning: nlbwmon 里还有 admin/services/nlbw 残留，菜单可能没搬干净"
	else
		echo "nlbwmon: 菜单已从「服务」移到「网络」（menu.d 与 config.js 一起改）"
	fi
else
	echo "warning: luci-app-nlbwmon not found, skip menu patch"
fi

#==========内核小优化：打开 fq 队列（BBR 建议的搭配）==========
#官方 generic 内核配置里是 "# CONFIG_NET_SCH_FQ is not set"，而 OpenWrt 上游并没有对应的
#kmod 包（kmod-sched-core 里不含 sch_fq），所以在 rockchip 的内核 config 里补一行。
#OpenWrt 会用 generic + subtarget 两份 config 合成内核配置，subtarget 这份后应用（优先级更高）。
#写成内置（=y）而不是模块，避免出现“编出来但没有 kmod 包收编”的模块。
for KCONF in ./target/linux/rockchip/config-* ./target/linux/rockchip/*/config-*; do
	[ -f "$KCONF" ] || continue
	if grep -q 'CONFIG_NET_SCH_FQ' "$KCONF"; then
		echo "kernel config $KCONF already mentions NET_SCH_FQ, skip"
	else
		echo 'CONFIG_NET_SCH_FQ=y' >> "$KCONF"
		echo "kernel config $KCONF: appended CONFIG_NET_SCH_FQ=y"
	fi
done

#==========默认队列改成 fq（配合 BBR）==========
#上面把 fq 队列编进了内核，但 OpenWrt 默认队列是 fq_codel（generic config 里是
#CONFIG_DEFAULT_FQ_CODEL=y），不设 sysctl 的话编进去的 fq 没人用。
#写进 base-files，随固件落到 /etc/sysctl.d/，开机由 /etc/init.d/sysctl 统一加载。
QDISC_CONF="./package/base-files/files/etc/sysctl.d/13-default-qdisc.conf"
mkdir -p "$(dirname "$QDISC_CONF")"
echo 'net.core.default_qdisc=fq' > "$QDISC_CONF"
echo "default qdisc: fq ($QDISC_CONF)"

#==========无线默认值（首次开机生成 /etc/config/wireless）==========
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_UC" ]; then
	#WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#加密方式
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
	#国家代码
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#R5C 没有板载无线网卡，官方脚本对这类设备默认生成 disabled=1，这里改成开机即启用
	sed -i "s/disabled='.*'/disabled='0'/g" $WIFI_UC
else
	echo "warning: mac80211.uc not found, skip wifi defaults"
fi

#==========默认 IP / 主机名==========
CFG_FILE="./package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
	sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
else
	echo "warning: config_generate not found, skip ip/hostname patch"
fi

#==========R5C：eMMC 剩余空间默认全给 Docker==========
#官方镜像只分到 boot 64M + rootfs 2048M，32G eMMC 里剩下的约 28G 是"没分区"的裸空间；
#而 Docker 的数据目录默认是 /opt/docker（包自带的 /etc/config/dockerd 里写死的），
#不处理的话只能落在 1.9G 的 overlay 上。这里往固件里塞一个 init 脚本，让它：
#  第一次开机：在剩余空间追加一个 ext4 分区（卷标 docker）→ 格式化 → 挂到 /opt → 写 fstab
#  以后每次开机：按卷标找到它、检查还没挂就挂上（fstab 也会挂，重复挂载被 is_mounted 挡掉）
#实现要点（都对着 25.12 的源码/包核对过，不是猜的）：
#  - parted 3.6 是用 BLKPG ioctl 把新分区同步给内核的（libparted/arch/linux.c 的
#    _disk_sync_part_table，linux_disk_commit 里调用），所以分区表在有分区挂载的情况下
#    也能立刻生效，不需要重启；partprobe 只是再补一刀，失败也无所谓；
#  - block-mount（/sbin/block）认 config mount 的 label/uuid/device/target/fstype/options/enabled
#    这几个选项（见 fstools 的 block.c：MOUNT_LABEL/UUID/TARGET/ENABLE），所以 fstab 里
#    按【卷标】挂载就够，不用去解析 UUID；enabled 缺省即启用，这里显式写 1；
#  - /etc/init.d/ 下的脚本 OpenWrt 打包时会自动 enable（base-files 的 default_postinst：
#    `"$root/etc/rc.common" "$root$i" enable`），这里再显式 enable 一次只是保险；
#  - 用到的工具都在固件里：blkid（CONFIG_PACKAGE_blkid）、parted、partprobe、
#    mkfs.ext4（e2fsprogs），ext4 驱动是内核内建（EXT4_FS=y），不需要额外 kmod。
DOCKER_STORAGE="./package/base-files/files/etc/init.d/docker-storage"
mkdir -p "$(dirname "$DOCKER_STORAGE")"
cat > "$DOCKER_STORAGE" <<'EOF'
#!/bin/sh /etc/rc.common
#R5C 专用：把 eMMC 上还没分区的剩余空间给 Docker 用（幂等，可以反复执行）
#
#安全边界：
#  - 只处理承载 rootfs 的那块盘（eMMC / SD / USB 都可能是它），其它磁盘一概不碰；
#  - 只在真的有 >= 8G 未分区空间时才动分区表，且只往后追加，从不修改/删除已有分区；
#  - 已经建过（卷标 docker 在）或磁盘上已经有 >= 3 个分区（说明自己手动分过了）就直接跳过。

START=15

LABEL='docker'
TARGET='/opt'
SHAREDIR='/opt/files'
MIN_FREE_MIB=8192

DISK=''

log() { echo "docker-storage: $*"; }

is_mounted() { grep -qs " $TARGET " /proc/mounts; }

#内核命令行里的 root=（可能是 /dev/xxx，也可能像 R5C 的 u-boot 一样给 PARTUUID=xxx）
cmdline_root() {
	tr ' ' '\n' < /proc/cmdline | sed -n 's/^root=//p' | head -n 1
}

#把 root= 的值翻译成设备名
resolve_dev() {
	local spec="$1" found

	case "$spec" in
		/dev/*) echo "$spec"; return 0 ;;
		PARTUUID=*|UUID=*) ;;
		*) return 1 ;;
	esac

	found=$(blkid -t "$spec" -o device 2>/dev/null | head -n 1)
	[ -n "$found" ] && echo "$found"
}

#从设备名推出整盘名：/dev/mmcblk0p2 → /dev/mmcblk0，/dev/sda1 → /dev/sda
#overlay 是 fstools 的 rootdisk 驱动建的 loop 设备（见 fstools 的 rootdisk.c：
#它 LOOP_SET_FD + lo_offset 把 rootfs 之后的空闲空间做成 loop），
#这种设备的 sysfs backing_file 里写着真正的 root 设备，所以顺着它再追一层。
disk_of() {
	local dev="$1"

	case "$dev" in
		/dev/loop*)
			dev=$(cat "/sys/block/$(basename "$dev")/loop/backing_file" 2>/dev/null)
			[ -n "$dev" ] || return 1
			#有的内核在 sysfs 里写的是去掉 /dev 前缀的路径（实测见过 "/vda"）
			case "$dev" in /dev/*) ;; *) dev="/dev/$dev" ;; esac
			disk_of "$dev"
			return $?
			;;
		/dev/mmcblk*p[0-9]*) DISK="${dev%p*}" ;;
		/dev/nvme*p[0-9]*)   DISK="${dev%p*}" ;;
		/dev/sd[a-z][0-9]*)  DISK="${dev%[0-9]}" ;;
		/dev/mmcblk[0-9]|/dev/sd[a-z]|/dev/vd[a-z]|/dev/nvme[0-9]n[0-9]) DISK="$dev" ;;
		*) return 1 ;;
	esac

	return 0
}

find_disk() {
	local spec src

	#1) 内核命令行：root=/dev/xxx 或 root=PARTUUID=xxx（真机 u-boot 用的是后者）
	spec=$(cmdline_root)
	if [ -n "$spec" ]; then
		src=$(resolve_dev "$spec")
		if [ -n "$src" ] && disk_of "$src" && [ -b "$DISK" ]; then
			return 0
		fi
	fi

	#2) 退一步：看 overlay（或 /）的挂载来源
	src=$(awk '$2 == "/overlay" { print $1; exit }' /proc/mounts)
	[ -n "$src" ] || src=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
	[ -n "$src" ] || return 1

	disk_of "$src" && [ -b "$DISK" ]
}

#/dev/mmcblk0 + 3 → /dev/mmcblk0p3；/dev/sda + 3 → /dev/sda3
part_dev() {
	case "$1" in
		/dev/mmcblk*|/dev/nvme*|/dev/loop*) echo "$1p$2" ;;
		*) echo "$1$2" ;;
	esac
}

#已经有卷标 docker 的分区就直接用它（第二次开机走的就是这里）
data_dev() {
	blkid -t LABEL="$LABEL" -o device 2>/dev/null | head -n 1
}

last_partno() {
	parted -m -s "$DISK" unit MiB print 2>/dev/null | \
		awk -F: 'NR > 2 && $1 ~ /^[0-9]+$/ { n = $1 } END { print n + 0 }'
}

#输出 "<起始MiB> <大小MiB>"（最后一个 >= MIN_FREE_MIB 的空闲区），没有就什么都不输出
free_space() {
	parted -m -s "$DISK" unit MiB print free 2>/dev/null | \
		awk -F: -v min="$MIN_FREE_MIB" '
			$5 ~ /^free/ {
				sub(/MiB$/, "", $2); sub(/MiB$/, "", $4)
				if ($4 + 0 >= min) { start = $2; size = $4 }
			}
			END { if (size != "") print int(start), int(size) }'
}

create_partition() {
	local parts info start size

	parts=$(last_partno)
	if [ "$parts" -ge 3 ]; then
		log "$DISK 上已经有 $parts 个分区（像是手动分过了），不自动分区"
		return 1
	fi

	info=$(free_space)
	if [ -z "$info" ]; then
		log "未分区空间不足 ${MIN_FREE_MIB}M，跳过"
		return 1
	fi
	start=${info%% *}
	size=${info##* }

	log "在 $DISK 的 ${start}MiB 处追加分区，占满剩余空间（约 $(($size / 1024))G）"
	parted -s "$DISK" unit MiB mkpart primary ext4 "${start}MiB" 100% || return 1
	partprobe "$DISK" 2>/dev/null
	sleep 1
	[ -b "$(part_dev "$DISK" "$(last_partno)")" ]
}

format_dev() {
	[ -n "$(blkid -o value -s TYPE "$1" 2>/dev/null)" ] && return 0
	log "格式化 $1（ext4，卷标 $LABEL）"
	mkfs.ext4 -F -q -m 0 -L "$LABEL" "$1"
}

mount_dev() {
	mkdir -p "$TARGET"
	is_mounted && return 0
	mount -o rw,noatime "$1" "$TARGET" || return 1
	mkdir -p "$SHAREDIR"
}

#写一条 fstab，之后开机交给 block-mount 挂（LuCI 的「挂载点」页面里也能看到）
write_fstab() {
	#注意：不能用「fstab 里已经有 mount 段」当判据 —— 固件自带的 /etc/config/fstab
	#本来就可能带着 /overlay、/rom 那种 enabled=0 的段，那样会被误判成"已经写过了"。
	#这里按「卷标 / 挂载点」判断是不是我们自己写的那条。
	uci -q show fstab 2>/dev/null | grep -q "label='$LABEL'" && return 0
	uci -q show fstab 2>/dev/null | grep -q "target='$TARGET'" && return 0
	uci -q add fstab mount >/dev/null 2>&1 || return 0

	uci -q set fstab.@mount[-1].label="$LABEL"
	uci -q set fstab.@mount[-1].target="$TARGET"
	uci -q set fstab.@mount[-1].fstype='ext4'
	uci -q set fstab.@mount[-1].options='rw,noatime'
	uci -q set fstab.@mount[-1].enabled='1'
	uci -q commit fstab
	log "已写入 /etc/config/fstab（按卷标 $LABEL 挂到 $TARGET）"
}

start() {
	local dev

	command -v blkid >/dev/null 2>&1 || { log "没有 blkid，跳过"; return 0; }
	find_disk || { log "找不到承载 rootfs 的磁盘，跳过"; return 0; }

	dev=$(data_dev)
	if [ -z "$dev" ]; then
		create_partition || return 0
		dev=$(part_dev "$DISK" "$(last_partno)")
	fi
	[ -b "$dev" ] || return 0

	format_dev "$dev" || return 0
	mount_dev "$dev" || return 0
	write_fstab
	log "$dev 已挂到 $TARGET（Docker 的数据目录 /opt/docker 就在这块盘上）"
}
EOF
chmod 0755 "$DOCKER_STORAGE"

#==========SMB / FTP 开箱可用==========
#SMB 用官方 samba4-server（按需求不装 luci-app-samba4 面板，LuCI 里没有共享页面），
#FTP 用官方 vsftpd。
#samba4 自带的 /etc/config/samba4 里只有一个注释掉的示例共享，这里塞一个 uci-defaults
#（首次开机由 /etc/init.d/boot 跑一次），把共享 name=files → /opt/files 建出来：
#  /opt/files 就是 docker-storage 挂上来的那块大盘，所以 SMB/FTP/Docker 共用同一个空间。
#访客可读写（guest_ok/guest_only=yes + force_root=1）：因为 samba4 的模板里写死了
#  invalid users = root，root 根本登录不了 SMB；而且刚装好的固件 root 密码是空的，
#  dropbear / vsftpd 同样会拒绝空密码登录。要账号密码访问就自己 adduser + smbpasswd -a，
#  再把共享的 guest_ok 关掉（没有 LuCI 面板，直接改 /etc/config/samba4）。
FILE_SHARING="./package/base-files/files/etc/uci-defaults/zz-file-sharing"
mkdir -p "$(dirname "$FILE_SHARING")"
cat > "$FILE_SHARING" <<'EOF'
#!/bin/sh
#第一次开机执行一次（恢复出厂后也会再执行）：把 SMB / FTP 的默认值铺好。
#SMB：共享名 files → /opt/files（eMMC 剩余空间那块盘），访客可读写，只对内网。
#FTP：vsftpd 用 root + 系统密码登录，登录后锁在 /opt/files（/etc/vsftpd.conf 里配的）。
if [ -f /etc/config/samba4 ]; then
	uci -q get samba4.@sambashare[0] >/dev/null 2>&1 || {
		uci -q add samba4 sambashare
		uci -q set samba4.@sambashare[-1].name='files'
		uci -q set samba4.@sambashare[-1].path='/opt/files'
		uci -q set samba4.@sambashare[-1].browseable='yes'
		uci -q set samba4.@sambashare[-1].read_only='no'
		uci -q set samba4.@sambashare[-1].guest_ok='yes'
		uci -q set samba4.@sambashare[-1].guest_only='yes'
		uci -q set samba4.@sambashare[-1].create_mask='0666'
		uci -q set samba4.@sambashare[-1].dir_mask='0777'
		uci -q set samba4.@sambashare[-1].force_root='1'
		uci -q commit samba4
	}
	[ -x /etc/init.d/samba4 ] && /etc/init.d/samba4 enable
fi

#FTP 的服务本身（/etc/vsftpd.conf 里的默认值由 Scripts/Handles.sh 写进包里）
[ -x /etc/init.d/vsftpd ] && /etc/init.d/vsftpd enable

#共享目录（docker-storage 把大盘挂到 /opt 之后，这个目录就在那块盘上）
mkdir -p /opt/files

exit 0
EOF
chmod 0755 "$FILE_SHARING"

#==========默认 root 密码（可选，靠 R5C.yml 里的 WRT_PW）==========
#固件默认 root 密码是空的（新机器，第一次进 LuCI 自己设）。空密码时 dropbear 会拒绝
#一切 SSH 登录、vsftpd 也登不进去 —— 也就是"服务开着但进不去"。所以这里留一个开关：
#WRT_PW 填的不是 无/空/default 时，就把 base-files 里的 /etc/shadow 改成这个密码
#（sha512-crypt，musl 的 crypt 认 $6$），开机即可 SSH / FTP 登录。
#公开仓库里塞一个固定密码等于给所有人留钥匙，所以默认不设。
if [ -n "$WRT_PW" ] && [ "$WRT_PW" != "无" ] && [ "$WRT_PW" != "none" ] && [ "$WRT_PW" != "default" ]; then
	SHADOW_FILE="./package/base-files/files/etc/shadow"
	if [ -f "$SHADOW_FILE" ] && command -v openssl >/dev/null 2>&1; then
		root_hash=$(openssl passwd -6 "$WRT_PW")
		sed -i "s|^root:[^:]*:|root:${root_hash}:|" "$SHADOW_FILE"
		echo "默认 root 密码已写入 /etc/shadow（来自 WRT_PW）：SSH / FTP 开箱可登录"
	else
		echo "warning: 找不到 $SHADOW_FILE 或系统没有 openssl，跳过默认密码设置"
	fi
fi

#==========写入 .config（在 make defconfig 之前生效）==========
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config

#==========注：Ruby YJIT 那套处理已随 OpenClash 一起移除==========
#原来这里会写 "# CONFIG_RUBY_ENABLE_YJIT is not set"，并顺手摘掉 feeds 里 ruby 的
#rust/host 编译依赖。起因只有一个：OpenClash 硬依赖 ruby + ruby-yaml，而官方 feeds 的
#lang/ruby/Makefile 对 aarch64 默认开 YJIT，会去从源码交叉编译 rust 编译器，
#实测 3 小时以上都跑不完，最后顶到 GitHub 的 6 小时上限被硬杀。
#2026-09 移除 OpenClash（改用 HomeProxy + 官方 feed 的 sing-box）后，固件里已经没有任何包
#依赖 ruby，这段配置一并删除。以后若再引入依赖 ruby 的插件，记得把这套处理加回来
#（WRT-CORE.yml 的 Verify Key Packages 里留了一道 YJIT 检查，TEST 模式几分钟就能拦下来）。

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#==========修改ssh登录信息==========
>package/base-files/files/etc/banner
echo -e ' ██████╗  ██████╗ ██╗   ██╗██████╗ ███████╗███╗   ██╗ ██████╗ ' >> package/base-files/files/etc/banner
echo -e '██╔════╝ ██╔═══██╗██║   ██║██╔══██╗██╔════╝████╗  ██║██╔════╝ ' >> package/base-files/files/etc/banner
echo -e '██║  ███╗██║   ██║██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║  ███╗' >> package/base-files/files/etc/banner
echo -e '██║   ██║██║   ██║██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║   ██║' >> package/base-files/files/etc/banner
echo -e '╚██████╔╝╚██████╔╝╚██████╔╝██║     ███████╗██║ ╚████║╚██████╔╝' >> package/base-files/files/etc/banner
echo -e ' ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝ \n' >> package/base-files/files/etc/banner

#注：这里原本还会给 ttyd 打补丁改成免密自动 root 登录（/bin/login -f root），
#    那等于在局域网上开了一个 root 后门，已移除；LuCI 的「终端」页面自带登录鉴权，不受影响。
