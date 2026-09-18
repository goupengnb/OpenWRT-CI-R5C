#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

#=========HomeProxy 首次开机默认值=========
#上游默认 lan_proxy_mode='disabled'，等于谁都不代理（容易被误以为装了没生效）。
#这里塞一个 uci-defaults 改成 except_listed：内网设备默认全部走代理。
HP_DIR=$(find "$PKG_PATH" -maxdepth 2 -type d -name "homeproxy" 2>/dev/null | head -n 1)
if [ -n "$HP_DIR" ]; then
	HP_UD_DIR="$HP_DIR/root/etc/uci-defaults"
	mkdir -p "$HP_UD_DIR"
	cat > "$HP_UD_DIR/zz-homeproxy-lan-proxy" <<'EOF'
#!/bin/sh
#内网设备全部走代理（上游默认是 disabled = 谁都不代理）
uci -q get homeproxy.control.lan_proxy_mode >/dev/null && {
	uci -q set homeproxy.control.lan_proxy_mode='except_listed'
	uci -q commit homeproxy
}
exit 0
EOF
	chmod 0755 "$HP_UD_DIR/zz-homeproxy-lan-proxy"
	echo "HomeProxy: 默认 lan_proxy_mode 已改为 except_listed（内网设备全部走代理）"
else
	echo "warning: homeproxy package not found, skip uci-defaults"
fi

#=========vsftpd：默认锁在 /opt/files=========
#官方 conf 没有 local_root，登录后会落在 /root；vsftpd 3.0 起也拒绝可写的 chroot 目录。
#/etc/config/vsftpd 默认 conf_file 指向这个静态文件，所以直接改它最直接。
#feeds 里的包目录是符号链接，find 必须加 -L 才找得到（之前漏了 -L，补丁一直没生效）。
VSF_CONF=$(find -L "$PKG_PATH" "$PKG_PATH/../feeds" -maxdepth 8 -type f -path "*vsftpd/files/vsftpd.conf" 2>/dev/null | head -n 1)
if [ -n "$VSF_CONF" ]; then
	if grep -q '^local_root=' "$VSF_CONF"; then
		echo "vsftpd: /etc/vsftpd.conf 已经改过，跳过"
	else
		cat >> "$VSF_CONF" <<'EOF'

#以下几行由 Scripts/Handles.sh 追加
local_root=/opt/files
allow_writeable_chroot=YES

#seccomp 沙箱在 6.12 内核上会让登录直接失败（500 OOPS: child died），必须关掉。
#关掉后仍有 privsep + chroot，且用户已被锁在 /opt/files 里。
seccomp_sandbox=NO
EOF
		echo "vsftpd: 默认 local_root=/opt/files（允许 chroot 目录可写 + 关闭 seccomp 沙箱）"
	fi
else
	#故意直接失败：默认值没生效在编译期是静默的，只有刷完登录才 500。
	echo "::error::没找到 feeds 里的 vsftpd（feeds/packages/net/vsftpd/files/vsftpd.conf），FTP 默认值会失效，已中止"
	exit 1
fi

#=========AdGuardHome=========
echo "Handles.sh: AdGuardHome 使用官方包，无需预置内核。"
