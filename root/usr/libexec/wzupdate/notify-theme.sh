#!/bin/sh

JS_FILE=/www/luci-static/resources/wzupdate/notify.js
JS_MARK='wzupdate/notify.js'

detect_theme() {
	THEME=""
	if command -v uci >/dev/null 2>&1; then
		THEME=$(uci -q get luci.main.mediaurlbase 2>/dev/null)
	fi
	THEME=${THEME##*/}
	[ -n "$THEME" ] || THEME=argon
}

detect_template() {
	TEMPLATE=""
	for p in \
		"/usr/share/ucode/luci/template/themes/$THEME/footer.ut" \
		"/usr/share/ucode/luci/template/footer.ut" \
		"/usr/lib/lua/luci/view/themes/$THEME/footer.htm" \
		"/usr/lib/lua/luci/view/footer.htm"
	do
		if [ -f "$p" ]; then
			TEMPLATE=$p
			return 0
		fi
	done
	return 1
}

build_tag() {
	VER=$(md5sum "$JS_FILE" 2>/dev/null | cut -d' ' -f1 | cut -c1-8)
	[ -n "${VER:-}" ] || VER=$(date +%s)
	TAG='<script src="/luci-static/resources/wzupdate/notify.js?v='"$VER"'"></script>'
}

apply_one() {
	detect_theme
	detect_template || return 1
	build_tag
	grep -q -F "$TAG" "$TEMPLATE" 2>/dev/null && return 0

	TMP="$TEMPLATE.wz-tmp"
	SRC="$TEMPLATE.wz-src"
	grep -v -F "$JS_MARK" "$TEMPLATE" >"$SRC" 2>/dev/null || :

	if grep -q '</body>' "$SRC" 2>/dev/null; then
		awk -v tag="$TAG" '
			{ gsub(/<\/body>/, tag "\n</body>") }
			{ print }
		' "$SRC" >"$TMP" || {
			rm -f "$TMP" "$SRC"
			return 1
		}
	else
		cat "$SRC" >"$TMP" || {
			rm -f "$TMP" "$SRC"
			return 1
		}
		printf '%s\n' "$TAG" >>"$TMP"
	fi

	rm -f "$SRC"
	mv -f "$TMP" "$TEMPLATE"
}

remove_all() {
	for f in \
		/usr/share/ucode/luci/template/themes/*/footer.ut \
		/usr/share/ucode/luci/template/footer.ut \
		/usr/lib/lua/luci/view/themes/*/footer.htm \
		/usr/lib/lua/luci/view/footer.htm
	do
		[ -f "$f" ] || continue
		grep -q -F "$JS_MARK" "$f" 2>/dev/null || continue
		grep -v -F "$JS_MARK" "$f" >"$f.wz-tmp" 2>/dev/null && mv -f "$f.wz-tmp" "$f"
		rm -f "$f.wz-tmp"
	done
}

case "$1" in
	apply)
		[ -f "$JS_FILE" ] || exit 0
		apply_one
		;;
	remove)
		remove_all
		;;
	*)
		printf 'usage: %s apply|remove\n' "$0" >&2
		exit 1
		;;
esac
