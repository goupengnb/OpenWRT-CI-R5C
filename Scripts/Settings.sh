#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#==========主题：把 luci-light 依赖的 luci-theme-bootstrap 换成 WRT_THEME==========
COLLECTION_MAKEFILES=$(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$COLLECTION_MAKEFILES" ]; then
	sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $COLLECTION_MAKEFILES
else
	echo "warning: luci collections not found, skip theme patch"
fi

#==========LuCI 小修补（找不到就跳过，不影响编译）==========
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

#==========「带宽监控」从「服务」挪到「网络」（menu.d 与 config.js 的硬编码链接都要改）==========
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

#==========内核补 fq 队列（BBR 的搭配；上游没有对应的 kmod 包）==========
for KCONF in ./target/linux/rockchip/config-* ./target/linux/rockchip/*/config-*; do
	[ -f "$KCONF" ] || continue
	if grep -q 'CONFIG_NET_SCH_FQ' "$KCONF"; then
		echo "kernel config $KCONF already mentions NET_SCH_FQ, skip"
	else
		echo 'CONFIG_NET_SCH_FQ=y' >> "$KCONF"
		echo "kernel config $KCONF: appended CONFIG_NET_SCH_FQ=y"
	fi
done

#==========默认队列改成 fq（内核默认是 fq_codel，不设 sysctl 的话 fq 没人用）==========
QDISC_CONF="./package/base-files/files/etc/sysctl.d/13-default-qdisc.conf"
mkdir -p "$(dirname "$QDISC_CONF")"
echo 'net.core.default_qdisc=fq' > "$QDISC_CONF"
echo "default qdisc: fq ($QDISC_CONF)"

#==========无线默认值（首次开机生成 /etc/config/wireless）==========
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_UC" ]; then
	#WIFI 名称 / 密码 / 加密方式 / 国家代码
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#R5C 没板载网卡，官方脚本会默认生成 disabled=1，这里改成开机即启用
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

#==========eMMC 剩余空间给 Docker（首次开机追加 ext4 分区挂到 /opt，之后按卷标挂）==========
DOCKER_STORAGE="./package/base-files/files/etc/init.d/docker-storage"
mkdir -p "$(dirname "$DOCKER_STORAGE")"
cat > "$DOCKER_STORAGE" <<'EOF'
#!/bin/sh /etc/rc.common
#R5C 专用：把 eMMC 剩余空间给 Docker 用（幂等）。只动承载 rootfs 的那块盘，
#只在剩余空间 >= 8G 时往后追加，已有卷标 docker 或已有 3 个分区就跳过。

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
#overlay 可能是 fstools 建的 loop 设备，顺着 sysfs 的 backing_file 再追一层。
disk_of() {
	local dev="$1"

	case "$dev" in
		/dev/loop*)
			dev=$(cat "/sys/block/$(basename "$dev")/loop/backing_file" 2>/dev/null)
			[ -n "$dev" ] || return 1
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

#写一条 fstab，之后开机交给 block-mount 挂
write_fstab() {
	#按「卷标 / 挂载点」判断，不能用「fstab 里已有 mount 段」
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

#==========SMB / FTP（不装 luci-app-samba4 面板，共享由 uci-defaults 首次开机建好）==========
FILE_SHARING="./package/base-files/files/etc/uci-defaults/zz-file-sharing"
mkdir -p "$(dirname "$FILE_SHARING")"
cat > "$FILE_SHARING" <<'EOF'
#!/bin/sh
#第一次开机执行一次：铺好 SMB / FTP 默认值
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

[ -x /etc/init.d/vsftpd ] && /etc/init.d/vsftpd enable

mkdir -p /opt/files

exit 0
EOF
chmod 0755 "$FILE_SHARING"

#==========外网访问 SMB / FTP==========
#WRT_WAN_SHARE 置 false 就只在局域网开放（samba4 也只绑 lan）。
if [ "$WRT_WAN_SHARE" = "true" ]; then
	WAN_SHARE="./package/base-files/files/etc/uci-defaults/zz-wan-share"
	cat > "$WAN_SHARE" <<'EOF'
#!/bin/sh
#外网访问 SMB / FTP：samba4 默认 bind interfaces only = yes 且只绑 lan，先放开，
#再放行 WAN 侧到本机的端口（TCP 445/139、FTP 控制 21 与被动数据口，见 Handles.sh）。
uci -q set samba4.@samba[0].interface='lan wan'
uci -q commit samba4

wan_rule() {
	uci -q show firewall | grep -q "name='$1'" && return 0
	local sec
	sec=$(uci add firewall rule) || return 0
	[ -n "$sec" ] || return 0
	uci -q set firewall.$sec.name="$1"
	uci -q set firewall.$sec.src='wan'
	uci -q set firewall.$sec.proto='tcp'
	uci -q set firewall.$sec.dest_port="$2"
	uci -q set firewall.$sec.target='ACCEPT'
}

wan_rule 'Allow-SMB-WAN' '445 139'
wan_rule 'Allow-FTP-WAN' '21'
wan_rule 'Allow-FTP-PASV-WAN' '50000-50010'
uci -q commit firewall

exit 0
EOF
	chmod 0755 "$WAN_SHARE"
	echo "WAN share: SMB(445/139) + FTP(21, 50000-50010) 已放行，samba4 绑定 lan+wan"
else
	echo "WAN share: 已关闭，SMB / FTP 只在局域网可用"
fi

#==========默认 root 密码（R5C.yml 的 WRT_PW；留空则 SSH / FTP 登不进）==========
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

#Ruby YJIT 的检查在 R5C.yml 的 Verify Key Packages 里

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#==========SSH 登录 banner==========
>package/base-files/files/etc/banner
echo -e ' ██████╗  ██████╗ ██╗   ██╗██████╗ ███████╗███╗   ██╗ ██████╗ ' >> package/base-files/files/etc/banner
echo -e '██╔════╝ ██╔═══██╗██║   ██║██╔══██╗██╔════╝████╗  ██║██╔════╝ ' >> package/base-files/files/etc/banner
echo -e '██║  ███╗██║   ██║██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║  ███╗' >> package/base-files/files/etc/banner
echo -e '██║   ██║██║   ██║██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║   ██║' >> package/base-files/files/etc/banner
echo -e '╚██████╔╝╚██████╔╝╚██████╔╝██║     ███████╗██║ ╚████║╚██████╔╝' >> package/base-files/files/etc/banner
echo -e ' ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝ \n' >> package/base-files/files/etc/banner

