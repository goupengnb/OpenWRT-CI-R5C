#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#官方 feeds 里有的用官方的；下面这几个官方确实没有，只从仍在维护的第三方仓库拉。

#替换/新增第三方软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)
	local REPO_NAME=${PKG_REPO#*/}
	local CLONE_DIR="upload-${REPO_NAME}"  # 先克隆到中转目录，避免同名覆盖

	echo " "

	#删除 feeds 里可能存在的同名包，避免冲突
	for NAME in "${PKG_LIST[@]}"; do
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not fonud directory: $NAME"
		fi
	done

	rm -rf "$CLONE_DIR"
	if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" "$CLONE_DIR"; then
		echo "ERROR: git clone failed: $PKG_REPO ($PKG_BRANCH)"
		return 1
	fi

	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		#从大杂烩仓库里提取目标插件目录（-mindepth 1 排除中转目录本身）
		find "./$CLONE_DIR" -mindepth 1 -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		rm -rf "$PKG_NAME"
		mv -f "$CLONE_DIR" "$PKG_NAME"
	else
		#仓库根目录就是插件本体，保持原名
		rm -rf "$REPO_NAME"
		mv -f "$CLONE_DIR" "$REPO_NAME"
	fi

	rm -rf "$CLONE_DIR"
}

#调用格式：UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg/name"
#  pkg = 从大杂烩仓库里单独提取该插件；name = 把仓库重命名为包名；留空 = 仓库根目录即包本体

#shadcn 主题（作者 eamonxg；仓库根目录就是包本体，只依赖 luci-base）
UPDATE_PACKAGE "luci-theme-shadcn" "eamonxg/luci-theme-shadcn" "main"

#HomeProxy（ImmortalWrt 官方团队维护；sing-box 内核来自官方 packages feed）
UPDATE_PACKAGE "homeproxy" "immortalwrt/homeproxy" "master"

#ddns-go（作者 sirpdboy；仓库里含 ddns-go 主程序和 luci-app-ddns-go 两个包）
UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"

#引入私有扩展脚本
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
