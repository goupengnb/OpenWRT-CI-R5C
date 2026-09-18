#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

#=========HomeProxy：默认内网全走代理=========
#上游 lan_proxy_mode='disabled' 是谁都不代理，改成 except_listed。
HP_DIR=$(find "$PKG_PATH" -maxdepth 2 -type d -name "homeproxy" 2>/dev/null | head -n 1)
if [ -n "$HP_DIR" ]; then
	HP_UD_DIR="$HP_DIR/root/etc/uci-defaults"
	mkdir -p "$HP_UD_DIR"
	cat > "$HP_UD_DIR/zz-homeproxy-lan-proxy" <<'EOF'
#!/bin/sh
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

#=========vsftpd：锁在 /opt/files=========
#官方 conf 没有 local_root，3.0 起也拒绝可写的 chroot 目录。
#feeds 里的包目录是符号链接，find 必须加 -L，否则补丁静默失效。
VSF_CONF=$(find -L "$PKG_PATH" "$PKG_PATH/../feeds" -maxdepth 8 -type f -path "*vsftpd/files/vsftpd.conf" 2>/dev/null | head -n 1)
if [ -n "$VSF_CONF" ]; then
	if grep -q '^local_root=' "$VSF_CONF"; then
		echo "vsftpd: /etc/vsftpd.conf 已经改过，跳过"
	else
		cat >> "$VSF_CONF" <<'EOF'

#以下几行由 Scripts/Handles.sh 追加
local_root=/opt/files
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=50000
pasv_max_port=50010

#seccomp 沙箱在 6.12 内核上会让登录直接失败（500 OOPS: child died）
seccomp_sandbox=NO
EOF
		echo "vsftpd: local_root=/opt/files + chroot 可写 + 关闭 seccomp + 被动口 50000-50010"
	fi
else
	#故意直接失败：默认值没生效在编译期是静默的，只有刷完登录才 500。
	echo "::error::没找到 feeds 里的 vsftpd（feeds/packages/net/vsftpd/files/vsftpd.conf），FTP 默认值会失效，已中止"
	exit 1
fi

