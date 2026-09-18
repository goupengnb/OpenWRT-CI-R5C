#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

#=========HomeProxy 首次开机默认值=========
#HomeProxy 内核是 sing-box，来自官方 packages feed，本身不需要预置任何东西，
#但它自带的默认配置里 lan_proxy_mode='disabled'，含义是【不代理任何内网设备】：
#路由器自己走代理，你电脑和手机根本不进代理，很容易被误以为"装了没生效"。
#这里往包里塞一个 uci-defaults 脚本（luci.mk 会把包里的 root/ 整个装进固件，
#/etc/uci-defaults/ 下的脚本由首次开机由 /etc/init.d/boot 执行一次），
#把默认值改成"仅允许列表外 + 直连列表留空"，等于内网设备全部走代理。
#节点没法预设（要你自己填一个），routing_mode 保持上游默认的 bypass_mainland_china（大陆直连）。
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
#官方包的 /etc/vsftpd.conf 里没有 local_root，root 登录后会落在 /root 并能翻遍整个文件系统；
#而 vsftpd 从 3.0 起会拒绝"chroot 目录对登录用户可写"的情况：
#    500 OOPS: vsftpd: refusing to run with writable root inside chroot()
#所以要把登录目录指到共享目录，并显式放行可写的 chroot。
#注意 /etc/config/vsftpd 默认带着 option conf_file '/etc/vsftpd.conf'，init 脚本会优先用这个
#静态文件（uci 里那些选项就不生效了），所以直接改它最直接、也最不容易误解。
#feeds 里的包在 package/feeds/<feed>/<包名> 下只是一个【符号链接】（指向 ../../feeds/.../<包名>），
#而 find 默认【不跟符号链接】、-type f 也匹配不到，所以必须显式加 -L；顺便把真正的 feeds 源码树也搜一遍。
#（之前这里没加 -L，导致这个补丁从来没生效过，构建日志里只有一行 warning，很容易漏看。）
VSF_CONF=$(find -L "$PKG_PATH" "$PKG_PATH/../feeds" -maxdepth 8 -type f -path "*vsftpd/files/vsftpd.conf" 2>/dev/null | head -n 1)
if [ -n "$VSF_CONF" ]; then
	if grep -q '^local_root=' "$VSF_CONF"; then
		echo "vsftpd: /etc/vsftpd.conf 已经改过，跳过"
	else
		cat >> "$VSF_CONF" <<'EOF'

#以下几行由本仓库的 Scripts/Handles.sh 追加：登录后锁在共享目录、允许该目录本身可写、
#并关掉 vsftpd 自带的 seccomp 沙箱（原因见下）。
local_root=/opt/files
allow_writeable_chroot=YES

#seccomp_sandbox=NO：25.12 的官方 vsftpd 3.0.5 在 6.12 内核上，它自带的 seccomp 沙箱会让
#【登录直接失败】—— 本地实测客户端只收到 500 OOPS: child died / priv_sock_get_cmd，
#连 FTP 握手都完不成（改成 NO 之后同一个 conf 立刻正常收发）。
#vsftpd 关掉沙箱后仍有 privsep + chroot，而且这里已经把用户锁死在 /opt/files 里，
#安全性影响很小 —— FTP 刷完就能用更重要。
seccomp_sandbox=NO
EOF
		echo "vsftpd: 默认 local_root=/opt/files（允许 chroot 目录可写 + 关闭 seccomp 沙箱）"
	fi
else
	#这里【故意】直接失败：找不到配置文件就等于 FTP 的默认值（登录目录 / seccomp）全都没生效，
	#而默认值失效在编译期是完全静默的，只有刷完登录才 500。宁可 TEST 阶段就炸出来。
	echo "::error::没找到 feeds 里的 vsftpd（feeds/packages/net/vsftpd/files/vsftpd.conf），FTP 默认值会失效，已中止"
	exit 1
fi

#=========AdGuardHome=========
#已改用官方 packages 源的 adguardhome + luci-app-adguardhome，
#内核由官方包自己从 AdGuardTeam/AdGuardHome 拉源码编译，不需要额外预置。
echo "Handles.sh: AdGuardHome 使用官方包，无需预置内核。"
