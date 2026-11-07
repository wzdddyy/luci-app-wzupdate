#!/bin/sh
# wzupdate - Link NN6000 固件在线更新引擎
#
# 用法（脚本方式）：
#   engine.sh manual   检查并更新（发现新版本时下载、校验、写入备份分区）
#   engine.sh check    仅检查新版本
#   engine.sh auto     自动模式（受 UCI enabled/auto 控制）
#   engine.sh cancel   撤回待重启的更新 / 回退到上一版本并重启
#   engine.sh apply    切换启动分区并重启
#
# 被 rpcd 以 WZU_LIB=1 方式 source 时只加载函数。

BASE=/tmp/wzupdate
STATE=$BASE/state
REMOTE=$BASE/remote.env
LOG=$BASE/update.log
FW=$BASE/firmware.bin
WORK=$BASE/work
PENDING=/etc/wzupdate/pending
LASTCHECK=$BASE/lastcheck

REPO_DEFAULT=wzdddyy/iStoreOS-NN6000
MIRROR_DEFAULT='https://ghfast.top/,https://gh-proxy.com/'

mkdir -p "$BASE" /etc/wzupdate 2>/dev/null

# ---------------- 基础工具 ----------------

log() {
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG"
}

kv_write() {
	[ -f "$1" ] || : >"$1"
	sed -i "/^$2=/d" "$1" 2>/dev/null
	printf '%s=%s\n' "$2" "$3" >>"$1"
}

kv_read() {
	local v=""
	[ -f "$1" ] && v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1)
	[ -n "$v" ] && printf '%s' "$v" || printf '%s' "${3:-}"
}

set_state() {
	printf 'phase=%s\npercent=%s\nmessage=%s\n' "$1" "$2" "$3" >"$STATE.tmp" 2>/dev/null
	mv "$STATE.tmp" "$STATE" 2>/dev/null
}

get_state() {
	local v=""
	v=$(sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n1)
	[ -n "$v" ] && printf '%s' "$v" || printf '%s' "${2:-}"
}

uci_get() {
	local v=""
	v=$(uci -q get "wzupdate.settings.$1" 2>/dev/null)
	[ -n "$v" ] || v=$(uci -q get "wzupdate.@wzupdate[0].$1" 2>/dev/null)
	[ -n "$v" ] || v=$(uci -q get "wzupdate.$1" 2>/dev/null)
	[ -n "$v" ] && printf '%s' "$v" || printf '%s' "${2:-}"
}

json_esc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

# ---------------- 设备与分区 ----------------

board_id() {
	local b="" m=""
	[ -r /tmp/sysinfo/board_name ] && b=$(tr -d '\r\n ' </tmp/sysinfo/board_name 2>/dev/null)
	# 兜底 1：设备树 compatible 列表
	if [ -z "$b" ] && [ -r /proc/device-tree/compatible ]; then
		b=$(tr '\000' '\n' </proc/device-tree/compatible 2>/dev/null |
			grep -E '^link,nn6000-v[12]$' | head -n1)
	fi
	# 兜底 2：sysinfo 型号名
	if [ -z "$b" ] && [ -r /tmp/sysinfo/model ]; then
		m=$(tr -d '\r\n' </tmp/sysinfo/model 2>/dev/null)
		case "$m" in
			*NN6000*v2*|*nn6000*v2*) b='link,nn6000-v2' ;;
			*NN6000*v1*|*nn6000*v1*) b='link,nn6000-v1' ;;
		esac
	fi
	case "$b" in
		*link,nn6000-v2*) printf 'link_nn6000-v2' ;;
		*link,nn6000-v1*) printf 'link_nn6000-v1' ;;
		*) printf '' ;;
	esac
}

has_wifi() {
	[ -n "$(ls /sys/class/ieee80211/ 2>/dev/null)" ]
}

local_version() {
	local v=""
	[ -r /etc/nn6000-build-time ] && v=$(tr -d '\r\n' </etc/nn6000-build-time)
	printf '%s' "$v"
}

# 统一时间戳格式：2026-11-06 15:30 -> 2026.11.06_15.30
norm_stamp() {
	printf '%s' "$1" | tr -d '\r\n' | tr ' -' '._'
}

firmware_type() {
	if has_wifi; then printf 'wifi'; else printf 'nowifi'; fi
}

image_target() {
	local base mode
	base=$(board_id)
	case "$base" in
		link_nn6000-v1|link_nn6000-v2) ;;
		*) return 1 ;;
	esac
	mode=$(uci_get image auto)
	case "$mode" in
		wifi) printf '%s' "$base" ;;
		nowifi) printf '%s-nowifi' "$base" ;;
		*)
			if has_wifi; then printf '%s' "$base"; else printf '%s-nowifi' "$base"; fi
			;;
	esac
}

part_dev() {
	local name=$1 p label dev
	p="/dev/disk/by-partlabel/$1"
	if [ -e "$p" ]; then
		readlink -f "$p"
		return 0
	fi
	# OpenWrt 没有 udev，/dev/disk/by-partlabel 通常不存在，改读 sysfs 的 PARTNAME
	for p in /sys/class/block/*; do
		[ -r "$p/uevent" ] || continue
		label=$(sed -n 's/^PARTNAME=//p' "$p/uevent" 2>/dev/null | head -n1)
		[ "$label" = "$name" ] || continue
		dev=$(sed -n 's/^DEVNAME=//p' "$p/uevent" 2>/dev/null | head -n1)
		[ -n "$dev" ] || continue
		printf '/dev/%s' "$dev"
		return 0
	done
	return 1
}

part_labels() {
	local p label out=""
	for p in /sys/class/block/*; do
		[ -r "$p/uevent" ] || continue
		label=$(sed -n 's/^PARTNAME=//p' "$p/uevent" 2>/dev/null | head -n1)
		[ -n "$label" ] && out="$out $label"
	done
	printf '%s' "${out# }"
}

ab_missing() {
	local miss=""
	[ -n "$(part_dev '0:BOOTCONFIG')" ] || miss="$miss 0:BOOTCONFIG"
	[ -n "$(part_dev '0:HLOS_1')" ] || miss="$miss 0:HLOS_1"
	[ -n "$(part_dev 'rootfs_1')" ] || miss="$miss rootfs_1"
	printf '%s' "${miss# }"
}

ab_supported() {
	[ -n "$(part_dev '0:BOOTCONFIG')" ] &&
	[ -n "$(part_dev '0:HLOS_1')" ] &&
	[ -n "$(part_dev 'rootfs_1')" ]
}

current_slot() {
	local cfg a b
	cfg=$(part_dev '0:BOOTCONFIG') || { printf '0'; return 0; }
	a=$(od -An -tu1 -j 128 -N 1 "$cfg" 2>/dev/null | tr -d ' \n')
	b=$(od -An -tu1 -j 148 -N 1 "$cfg" 2>/dev/null | tr -d ' \n')
	case "$a$b" in
		00) printf '0' ;;
		11) printf '1' ;;
		*) printf '%s' "${b:-0}" ;;
	esac
}

slot_kern() {
	if [ "$1" = "1" ]; then printf '0:HLOS_1'; else printf '0:HLOS'; fi
}

slot_root() {
	if [ "$1" = "1" ]; then printf 'rootfs_1'; else printf 'rootfs'; fi
}

set_slot() {
	local cfg val
	cfg=$(part_dev '0:BOOTCONFIG') || return 1
	val=$1
	printf "\\$(printf '%03o' "$val")" | dd of="$cfg" bs=1 seek=128 conv=notrunc 2>/dev/null || return 1
	printf "\\$(printf '%03o' "$val")" | dd of="$cfg" bs=1 seek=148 conv=notrunc 2>/dev/null || return 1
	sync
	return 0
}

# ---------------- 网络 ----------------

curl_try() {
	curl -fsSL --connect-timeout 10 --max-time 3600 --retry 1 -o "$2" "$1" 2>/dev/null
}

http_get() {
	local url=$1 out=$2 ch mirrors m direct_ok=0
	ch=$(uci_get channel auto)
	mirrors=$(uci_get mirror "$MIRROR_DEFAULT")

	case "$ch" in
		mirror) ;;
		*)
			if curl_try "$url" "$out"; then direct_ok=1; fi
			;;
	esac
	[ "$direct_ok" = "1" ] && return 0
	[ "$ch" = "github" ] && return 1

	IFS=,
	for m in $mirrors; do
		[ -n "$m" ] || continue
		if curl_try "${m}${url}" "$out"; then
			unset IFS
			return 0
		fi
	done
	unset IFS
	return 1
}

# ---------------- 检查更新 ----------------

check_update() {
	local repo api json tag stamp target name url size notes line checked newer remote_ver cur_ver local_stamp remote_stamp first sha sha_url sha_idx digest names_cnt digest_cnt i an au ad body commit rkernel branch rbuild
	repo=$(uci_get repo "$REPO_DEFAULT")
	# 带随机参数避免镜像缓存到「固件尚未上传完成」的旧响应
	api="https://api.github.com/repos/$repo/releases/latest?ts=$(date +%s)-$$"
	json="$BASE/release.json"

	set_state checking 3 '正在查询在线版本'
	log "查询在线版本：$repo"
	if ! ab_supported; then
		log "分区检测未通过，缺少：$(ab_missing)；已识别：$(part_labels)"
	fi

	rm -f "$REMOTE"
	if ! http_get "$api" "$json"; then
		set_state error 0 '检查更新失败：无法访问 GitHub'
		log '检查更新失败：无法访问 GitHub Releases'
		return 1
	fi

	tag=$(jsonfilter -i "$json" -e '@.tag_name' 2>/dev/null | head -n1)
	stamp=$(printf '%s' "$tag" | sed 's/.*-//')
	if [ -z "$tag" ] || [ -z "$stamp" ]; then
		set_state error 0 '检查更新失败：发布信息不完整'
		log '检查更新失败：发布信息不完整'
		return 1
	fi

	target=$(image_target)
	case "$target" in
		link_nn6000-v1|link_nn6000-v1-nowifi|link_nn6000-v2|link_nn6000-v2-nowifi) ;;
		*)
			set_state error 0 '当前设备不在支持列表中'
			log "当前设备不在支持列表中（board_name=$(tr -d '\r\n' </tmp/sysinfo/board_name 2>/dev/null | head -n1)，model=$(tr -d '\r\n' </tmp/sysinfo/model 2>/dev/null | head -n1)，目标：$target）"
			return 1
			;;
	esac
	log "当前设备目标：$target"

	jsonfilter -i "$json" -e '@.assets[*].name' >"$BASE/assets.name" 2>/dev/null
	jsonfilter -i "$json" -e '@.assets[*].browser_download_url' >"$BASE/assets.url" 2>/dev/null
	jsonfilter -i "$json" -e '@.assets[*].digest' >"$BASE/assets.digest" 2>/dev/null

	# 部分 jsonfilter 版本不支持 [*] 通配，回退为按索引逐个提取
	if [ ! -s "$BASE/assets.name" ]; then
		i=0
		: >"$BASE/assets.name"
		: >"$BASE/assets.url"
		: >"$BASE/assets.digest"
		while [ "$i" -lt 50 ]; do
			an=$(jsonfilter -i "$json" -e "@.assets[$i].name" 2>/dev/null)
			[ -n "$an" ] || break
			au=$(jsonfilter -i "$json" -e "@.assets[$i].browser_download_url" 2>/dev/null)
			ad=$(jsonfilter -i "$json" -e "@.assets[$i].digest" 2>/dev/null)
			printf '%s\n' "$an" >>"$BASE/assets.name"
			printf '%s\n' "$au" >>"$BASE/assets.url"
			printf '%s\n' "$ad" >>"$BASE/assets.digest"
			i=$((i + 1))
		done
	fi

	name=$(grep -F "$target-squashfs-sysupgrade.bin" "$BASE/assets.name" 2>/dev/null | head -n1)
	if [ -z "$name" ]; then
		set_state error 0 '该版本没有适用于当前设备的固件'
		log "该版本没有适用于当前设备的固件（目标：$target，发布：$tag）"
		log "发布固件列表：$(tr '\n' ' ' <"$BASE/assets.name" 2>/dev/null | cut -c1-400)"
		return 1
	fi

	line=$(grep -n -F "$name" "$BASE/assets.name" 2>/dev/null | head -n1 | cut -d: -f1)
	url=""
	[ -n "$line" ] && url=$(sed -n "${line}p" "$BASE/assets.url" 2>/dev/null)
	if [ -z "$url" ]; then
		set_state error 0 '检查更新失败：固件下载地址缺失'
		log '检查更新失败：固件下载地址缺失'
		return 1
	fi

	size=$(curl -fsIL --max-time 30 "$url" 2>/dev/null | tr -d '\r')
	size=$(printf '%s' "$size" | sed -n 's/^[Cc]ontent-[Ll]ength: *//p')
	size=$(printf '%s' "$size" | tail -n1)
	case "$size" in ''|*[!0-9]*) size=0 ;; esac

	# 优先用 GitHub API 提供的 sha256 digest，其次找发布里的 sha256sums
	sha=""
	names_cnt=$(awk 'END{print NR}' "$BASE/assets.name" 2>/dev/null)
	digest_cnt=$(awk 'END{print NR}' "$BASE/assets.digest" 2>/dev/null)
	if [ -n "$digest_cnt" ] && [ "$names_cnt" = "$digest_cnt" ]; then
		digest=$(sed -n "${line}p" "$BASE/assets.digest" 2>/dev/null)
		case "$digest" in
			sha256:*) sha=${digest#sha256:} ;;
		esac
	fi
	if [ -z "$sha" ]; then
		sha_idx=$(grep -n -F 'sha256sums' "$BASE/assets.name" 2>/dev/null | head -n1 | cut -d: -f1)
		if [ -n "$sha_idx" ]; then
			sha_url=$(sed -n "${sha_idx}p" "$BASE/assets.url" 2>/dev/null)
			if [ -n "$sha_url" ] && http_get "$sha_url" "$BASE/sha256sums"; then
				sha=$(grep -F " $name" "$BASE/sha256sums" 2>/dev/null | awk '{print $1}' | head -n1)
			fi
		fi
	fi
	case "$sha" in ''|*[!0-9a-f]*) sha='' ;; esac

	body=$(jsonfilter -i "$json" -e '@.body' 2>/dev/null)
	notes=$(printf '%s\n' "$body" | head -n1 | cut -c1-400)
	# 从发布说明中提取版本信息（- **内核版本**: 6.12.112 等）
	commit=$(printf '%s\n' "$body" | grep -F '提交' | grep -oE '[0-9a-f]{7,40}' | head -n1)
	rkernel=$(printf '%s\n' "$body" | sed -n 's/.*内核版本[^:：]*[:：] *//p' | head -n1 | tr -d '\r')
	branch=$(printf '%s\n' "$body" | sed -n 's/.*iStoreOS 分支[^:：]*[:：] *//p' | head -n1 | tr -d '\r')
	rbuild=$(printf '%s\n' "$body" | sed -n 's/.*编译日期[^:：]*[:：] *//p' | head -n1 | tr -d '\r')
	rbuild=$(norm_stamp "$rbuild")
	checked=$(date '+%H:%M')

	remote_ver=$(printf '%s' "$stamp" | sed 's/_/ /; s/\./-/g')
	cur_ver=$(local_version)
	local_stamp=$(norm_stamp "$cur_ver")
	remote_stamp=$(norm_stamp "$stamp")
	newer=0
	if [ "$remote_stamp" != "$local_stamp" ]; then
		first=$(printf '%s\n%s\n' "$remote_stamp" "$local_stamp" | sort | head -n1)
		[ "$first" = "$local_stamp" ] && newer=1
	fi

	kv_write "$REMOTE" REMOTE_TAG "$tag"
	kv_write "$REMOTE" REMOTE_STAMP "$stamp"
	kv_write "$REMOTE" REMOTE_VER "$remote_ver"
	kv_write "$REMOTE" REMOTE_NAME "$name"
	kv_write "$REMOTE" REMOTE_URL "$url"
	kv_write "$REMOTE" REMOTE_SIZE "$size"
	kv_write "$REMOTE" REMOTE_SHA "$sha"
	kv_write "$REMOTE" REMOTE_NEWER "$newer"
	kv_write "$REMOTE" REMOTE_NOTE "$notes"
	kv_write "$REMOTE" REMOTE_COMMIT "$commit"
	kv_write "$REMOTE" REMOTE_KERNEL "$rkernel"
	kv_write "$REMOTE" REMOTE_BRANCH "$branch"
	kv_write "$REMOTE" REMOTE_BUILD "$rbuild"
	kv_write "$REMOTE" CHECKED_AT "$checked"

	log "在线版本：$remote_ver（$tag）"
	if [ "$newer" = "1" ]; then
		log '发现新版本'
	else
		log '当前已是最新版本'
	fi
	return 0
}

# ---------------- 下载 / 校验 / 写入 ----------------

download_image() {
	local url expected ch mirrors cands c pid size pct rc part_url part_size
	url=$(kv_read "$REMOTE" REMOTE_URL '')
	expected=$(kv_read "$REMOTE" REMOTE_SIZE 0)
	ch=$(uci_get channel auto)
	mirrors=$(uci_get mirror "$MIRROR_DEFAULT")

	[ -n "$url" ] || { set_state error 0 '未找到匹配的固件'; return 1; }

	# 分片只对同一固件有效：换版本或大小不符时丢弃
	part_url=$(kv_read "$BASE/partial" URL '')
	part_size=$(kv_read "$BASE/partial" SIZE 0)
	if [ "$part_url" != "$url" ] || { [ "$expected" -gt 0 ] && [ "$part_size" != "$expected" ]; }; then
		rm -f "$FW"
	fi
	kv_write "$BASE/partial" URL "$url"
	kv_write "$BASE/partial" SIZE "$expected"

	size=$(stat -c %s "$FW" 2>/dev/null)
	[ -n "$size" ] || size=0
	if [ "$expected" -gt 0 ] 2>/dev/null && [ "$size" -lt "$expected" ]; then
		local avail need
		avail=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')
		case "$avail" in ''|*[!0-9]*) avail=0 ;; esac
		need=$(( (expected - size) / 1024 + 16384 ))
		if [ "$avail" -gt 0 ] && [ "$avail" -lt "$need" ]; then
			set_state error 0 '临时空间不足，无法下载固件'
			log "临时空间不足：还需 $((need / 1024))MB，/tmp 可用 $((avail / 1024))MB"
			return 1
		fi
	fi
	if [ "$expected" -gt 0 ] 2>/dev/null && [ "$size" = "$expected" ]; then
		set_state downloading 60 '使用已下载的固件'
		log '检测到完整固件，跳过下载'
		return 0
	fi

	case "$ch" in
		github) cands="$url" ;;
		mirror)
			cands=""
			IFS=,
			for c in $mirrors; do [ -n "$c" ] && cands="$cands ${c}${url}"; done
			unset IFS
			;;
		*)
			cands="$url"
			IFS=,
			for c in $mirrors; do [ -n "$c" ] && cands="$cands ${c}${url}"; done
			unset IFS
			;;
	esac

	for c in $cands; do
		size=$(stat -c %s "$FW" 2>/dev/null)
		[ -n "$size" ] || size=0
		if [ "$size" -gt 0 ]; then
			set_state downloading 6 "正在续传（已下载 $((size / 1048576)) MB）"
			log "断点续传：从 $((size / 1048576)) MB 继续，下载：$c"
			curl -fsSL -C - --connect-timeout 10 --max-time 3600 --retry 1 -o "$FW" "$c" 2>/dev/null &
		else
			set_state downloading 6 '正在下载固件'
			log "下载：$c"
			curl -fsSL --connect-timeout 10 --max-time 3600 --retry 1 -o "$FW" "$c" 2>/dev/null &
		fi
		pid=$!
		while kill -0 "$pid" 2>/dev/null; do
			size=$(stat -c %s "$FW" 2>/dev/null)
			[ -n "$size" ] || size=0
			if [ "$expected" -gt 0 ] 2>/dev/null; then
				pct=$(( 6 + size * 54 / expected ))
				[ "$pct" -gt 60 ] && pct=60
				set_state downloading "$pct" "下载中 $((size / 1048576)) MB / $((expected / 1048576)) MB"
			else
				set_state downloading 40 "下载中 $((size / 1048576)) MB"
			fi
			sleep 1
		done
		wait "$pid"
		rc=$?
		if [ "$rc" = "0" ] && [ -s "$FW" ]; then
			size=$(stat -c %s "$FW" 2>/dev/null)
			if [ "$expected" -gt 0 ] 2>/dev/null && [ "$size" != "$expected" ]; then
				log "下载大小不符（$size / $expected），清除分片重试"
				rm -f "$FW"
				continue
			fi
			set_state downloading 60 '下载完成'
			log '下载完成'
			return 0
		fi
		if [ "$rc" = "33" ]; then
			log '服务器不支持断点续传，已清除分片'
			rm -f "$FW"
		fi
		log "下载中断（$rc），保留分片，尝试下一个地址"
	done

	set_state error 0 '下载失败，已保留分片，可重新检查更新续传'
	log '下载失败，分片已保留，可重试续传'
	return 1
}

is_squashfs_at() {
	local file=$1 off=$2 bs maj bs_off maj_off
	[ "$(dd if="$file" bs=1 skip="$off" count=4 2>/dev/null)" = "hsqs" ] || return 1
	bs_off=$((off + 12))
	maj_off=$((off + 28))
	bs=$(od -An -tu4 -j "$bs_off" -N 4 "$file" 2>/dev/null | tr -d ' \n')
	maj=$(od -An -tu2 -j "$maj_off" -N 2 "$file" 2>/dev/null | tr -d ' \n')
	case "$bs" in
		4096|8192|16384|32768|65536|131072|262144|524288|1048576) ;;
		*) return 1 ;;
	esac
	[ "$maj" = "4" ] || return 1
	return 0
}

prepare_image() {
	local size off sha cand expect_sha
	set_state verifying 63 '正在校验固件'
	size=$(stat -c %s "$FW" 2>/dev/null)
	[ -n "$size" ] || size=0
	if [ "$size" -lt 1048576 ]; then
		set_state error 0 '固件文件不完整'
		log '固件文件不完整'
		return 1
	fi

	off=""
	for cand in $(grep -abo 'hsqs' "$FW" 2>/dev/null | cut -d: -f1 |
			awk '$1 > 1048576 {print}' | head -n 30); do
		if is_squashfs_at "$FW" "$cand"; then
			off=$cand
			break
		fi
	done
	if [ -z "$off" ]; then
		for cand in $((12288 * 1024)) $((131072)); do
			if is_squashfs_at "$FW" "$cand"; then
				off=$cand
				break
			fi
		done
	fi
	if [ -z "$off" ] || [ "$off" -ge $((size - 65536)) ]; then
		set_state error 0 '固件格式无法识别'
		log '固件格式无法识别：未找到 squashfs 文件系统'
		return 1
	fi

	sha=$(sha256sum "$FW" 2>/dev/null | cut -d' ' -f1)
	expect_sha=$(kv_read "$REMOTE" REMOTE_SHA '')
	if [ -n "$expect_sha" ] && [ "$expect_sha" != "$sha" ]; then
		rm -f "$FW" "$BASE/partial"
		set_state error 0 '固件校验失败：SHA-256 不一致'
		log '固件校验失败：SHA-256 与发布校验值不一致'
		return 1
	fi
	if [ -z "$expect_sha" ]; then
		log '发布未提供校验值，仅做写入回读校验'
	fi

	rm -rf "$WORK"
	mkdir -p "$WORK" || return 1
	kv_write "$WORK/meta" OFFSET "$off"
	kv_write "$WORK/meta" SIZE "$size"
	kv_write "$WORK/meta" SHA "$sha"

	log "固件解析：内核 $((off / 1024)) KiB / 系统文件 $(((size - off) / 1024)) KiB"
	log "SHA-256：$sha"
	set_state verifying 66 '固件校验通过'
	return 0
}

verify_dev() {
	local dev=$1 size=$2 want=$3 blocks got
	blocks=$(( (size + 1048575) / 1048576 ))
	got=$(dd if="$dev" bs=1M count="$blocks" 2>/dev/null | head -c "$size" | sha256sum | cut -d' ' -f1)
	[ -n "$want" ] && [ "$want" = "$got" ]
}

write_image() {
	local active inactive kname rname kdev rdev ksize fsize rsize ksha rsha skip ver stamp prev
	active=$(current_slot)
	inactive=$((1 - active))
	kname=$(slot_kern "$inactive")
	rname=$(slot_root "$inactive")
	kdev=$(part_dev "$kname")
	rdev=$(part_dev "$rname")
	if [ -f "$PENDING" ]; then
		set_state error 0 '已有待重启的更新'
		log '已有待重启的更新，请先重启或撤回'
		return 1
	fi
	[ -n "$kdev" ] && [ -n "$rdev" ] || {
		set_state error 0 '找不到可写入的备份分区'
		log '找不到可写入的备份分区'
		return 1
	}

	ksize=$(kv_read "$WORK/meta" OFFSET 0)
	fsize=$(kv_read "$WORK/meta" SIZE 0)
	rsize=$((fsize - ksize))
	skip=$((ksize + 1))
	[ "$ksize" -gt 0 ] && [ "$rsize" -gt 0 ] || {
		set_state error 0 '固件信息缺失'
		return 1
	}

	set_state writing 70 '正在写入备份分区（内核）'
	log "写入内核到 $kname（$((ksize / 1024)) KiB）"
	ksha=$(head -c "$ksize" "$FW" 2>/dev/null | sha256sum | cut -d' ' -f1)
	if ! head -c "$ksize" "$FW" 2>/dev/null | dd of="$kdev" bs=65536 conv=fsync 2>/dev/null; then
		set_state error 0 '写入内核失败'
		log '写入内核失败'
		return 1
	fi
	if ! verify_dev "$kdev" "$ksize" "$ksha"; then
		set_state error 0 '内核写入校验失败'
		log '内核写入校验失败'
		return 1
	fi
	log '内核写入校验通过'

	set_state writing 84 '正在写入备份分区（系统文件）'
	log "写入系统文件到 $rname（$((rsize / 1024)) KiB）"
	rsha=$(tail -c +"$skip" "$FW" 2>/dev/null | sha256sum | cut -d' ' -f1)
	if ! tail -c +"$skip" "$FW" 2>/dev/null | dd of="$rdev" bs=1M conv=fsync 2>/dev/null; then
		set_state error 0 '写入系统文件失败'
		log '写入系统文件失败'
		return 1
	fi
	set_state writing 90 '正在校验写入内容'
	log '回读备份分区校验写入结果'
	if ! verify_dev "$rdev" "$rsize" "$rsha"; then
		set_state error 0 '系统文件写入校验失败'
		log '系统文件写入校验失败'
		return 1
	fi
	log '系统文件写入校验通过'

	ver=$(kv_read "$REMOTE" REMOTE_VER '')
	stamp=$(kv_read "$REMOTE" REMOTE_STAMP '')
	prev=$(local_version)
	rm -rf /etc/wzupdate
	mkdir -p /etc/wzupdate
	kv_write "$PENDING" slot "$inactive"
	kv_write "$PENDING" prev_slot "$active"
	kv_write "$PENDING" version "$ver"
	kv_write "$PENDING" stamp "$stamp"
	kv_write "$PENDING" prev_version "$prev"
	kv_write "$PENDING" sha "$(kv_read "$WORK/meta" SHA '')"
	kv_write "$PENDING" time "$(date '+%Y-%m-%d %H:%M')"
	rm -rf "$WORK"
	rm -f "$FW" "$BASE/partial"

	set_state done 100 '已写入，等待重启'
	log '新版本已写入备份分区并完成校验，等待手动重启'
	return 0
}

# ---------------- 任务入口 ----------------

lock_take() {
	local i=0
	while ! mkdir "$BASE/lock" 2>/dev/null; do
		if [ -n "$(find "$BASE/lock" -mmin +120 2>/dev/null)" ]; then
			rm -rf "$BASE/lock"
			continue
		fi
		i=$((i + 1))
		[ "$i" -gt 5 ] && return 1
		sleep 1
	done
	echo $$ >"$BASE/lock/pid" 2>/dev/null
	return 0
}

lock_release() {
	rm -rf "$BASE/lock"
}

can_check() {
	local last now
	last=$(cat "$LASTCHECK" 2>/dev/null)
	case "$last" in ''|*[!0-9]*) last=0 ;; esac
	now=$(date +%s)
	if [ $((now - last)) -lt 60 ]; then
		return 1
	fi
	printf '%s' "$now" >"$LASTCHECK" 2>/dev/null
	return 0
}

run_manual() {
	lock_take || { log '已有任务在运行'; return 1; }
	: >"$LOG"
	log '开始手动检查更新'
	check_update || { lock_release; return 1; }
	if [ "$(kv_read "$REMOTE" REMOTE_NEWER 0)" != "1" ]; then
		set_state idle 0 '已是最新版本'
		lock_release
		return 0
	fi
	if ! ab_supported; then
		set_state error 0 '分区不支持在线更新'
		log "分区检测未通过，缺少：$(ab_missing)；已识别：$(part_labels)"
		lock_release
		return 1
	fi
	if download_image && prepare_image && write_image; then
		:
	else
		[ -f "$STATE" ] || set_state error 0 '更新失败'
	fi
	lock_release
}

run_check() {
	lock_take || return 1
	if ! can_check; then
		lock_release
		return 0
	fi
	: >"$LOG"
	log '开始检查更新'
	if check_update; then
		if [ "$(kv_read "$REMOTE" REMOTE_NEWER 0)" = "1" ]; then
			set_state idle 0 '发现新版本'
		else
			set_state idle 0 '已是最新版本'
		fi
	fi
	lock_release
	return 0
}

run_update_only() {
	lock_take || return 1
	set_state checking 2 '准备更新固件'
	: >"$LOG"
	if [ ! -f "$REMOTE" ] || [ "$(kv_read "$REMOTE" REMOTE_NEWER 0)" != "1" ]; then
		set_state error 0 '请先检查更新'
		log '请先检查更新'
		lock_release
		return 1
	fi
	if ! ab_supported; then
		set_state error 0 '分区不支持在线更新'
		log "分区检测未通过，缺少：$(ab_missing)；已识别：$(part_labels)"
		lock_release
		return 1
	fi
	log '开始更新固件'
	if download_image && prepare_image && write_image; then
		:
	fi
	lock_release
}

run_auto() {
	[ "$(uci_get enabled 0)" = "1" ] || return 0
	[ "$(uci_get auto 0)" = "1" ] || return 0
	[ -f "$PENDING" ] && return 0
	lock_take || return 0
	: >"$LOG"
	log '自动检查更新'
	if check_update && [ "$(kv_read "$REMOTE" REMOTE_NEWER 0)" = "1" ]; then
		if ! ab_supported; then
			set_state error 0 '分区不支持在线更新'
			log "分区检测未通过，缺少：$(ab_missing)；已识别：$(part_labels)"
		else
			log '自动更新：开始下载'
			download_image && prepare_image && write_image
		fi
	else
		[ "$(get_state phase)" = "error" ] || set_state idle 0 '已是最新版本'
	fi
	lock_release
}

cancel_update() {
	local pend_ver prev cur
	if [ ! -f "$PENDING" ]; then
		set_state idle 0 '没有待处理的更新'
		log '没有待处理的更新'
		return 0
	fi
	pend_ver=$(kv_read "$PENDING" version '')
	cur=$(local_version)
	if [ "$pend_ver" = "$cur" ]; then
		prev=$(kv_read "$PENDING" prev_slot 0)
		if ! set_slot "$prev"; then
			log '回退失败：无法切换启动分区'
			return 1
		fi
		rm -f "$PENDING"
		set_state idle 0 '正在回退到上一版本'
		log "已切换到上一版本（槽位 $prev），即将重启"
		(sleep 2; reboot) >/dev/null 2>&1 &
	else
		rm -f "$PENDING"
		rm -rf "$WORK" "$FW" "$BASE/partial"
		set_state idle 0 '已撤回待重启的更新'
		log '已撤回待重启的更新'
	fi
	return 0
}

apply_update() {
	local slot
	if [ ! -f "$PENDING" ]; then
		log '没有待应用的更新'
		return 1
	fi
	slot=$(kv_read "$PENDING" slot 1)
	if ! set_slot "$slot"; then
		log '切换启动分区失败'
		return 1
	fi
	log "已切换到槽位 $slot，即将重启"
	(sleep 2; reboot) >/dev/null 2>&1 &
	return 0
}

if [ "${WZU_LIB:-0}" != "1" ]; then
	case "${1:-}" in
		manual) run_manual ;;
		check) run_check ;;
		update) run_update_only ;;
		auto) run_auto ;;
		cancel|rollback) cancel_update ;;
		apply) apply_update ;;
		*) echo "usage: $0 {manual|check|update|auto|cancel|apply}" >&2; exit 1 ;;
	esac
fi
