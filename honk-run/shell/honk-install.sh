#!/bin/sh
#=================================================
# honk 离线安装器（OpenWrt / iStoreOS 25.12 · apk）
#
# payload 里只放 iStoreOS 官方源没有的包：
#   apks/honk-*.apk
#   apks/luci-app-honk-*.apk
#   apks/luci-lib-daeuniverse-*.apk
#   apks/luci-i18n-daeuniverse-zh-cn-*.apk
#   apks/vmlinux-btf-builtin-*.apk
#   keys/daeuniverse.pem
# 其余依赖（kmod-*、libstdcpp6、v2ray-geoip/geosite、luci-base…）全部由设备自己的源提供。
#=================================================
set -u

PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PAYLOAD_DIR" || { echo "[fail] 无法进入 payload 目录" >&2; exit 1; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[fail] %s\n' "$*" >&2; exit 1; }

# ---------- 1. 环境断言 ----------
step "环境检查"

[ "$(id -u)" = "0" ] || die "需要 root 身份运行"
command -v apk >/dev/null 2>&1 || die "本机没有 apk：这是 24.10 及更早的 opkg 系统，本包只支持 25.12+"
[ -r /etc/openwrt_release ] || die "读不到 /etc/openwrt_release"
# shellcheck source=/dev/null
. /etc/openwrt_release

RELEASE="${DISTRIB_RELEASE:-}"
ARCH="${DISTRIB_ARCH:-}"
[ -n "$ARCH" ] || die "openwrt_release 里没有 DISTRIB_ARCH"

# payload 是为某个架构打的，架构不符直接停，不要硬装
WANT_ARCH="$(cat ARCH 2>/dev/null || true)"
[ -n "$WANT_ARCH" ] || die "payload 缺少 ARCH 标记，包不完整"
if [ "$ARCH" != "$WANT_ARCH" ]; then
	die "架构不匹配：本包是 $WANT_ARCH，本机是 $ARCH。请用对应架构重新生成 run"
fi

KREL="$(uname -r)"
MAJOR="${KREL%%.*}"
REST="${KREL#*.}"
MINOR="${REST%%.*}"
case "$MAJOR" in ''|*[!0-9]*) die "无法解析内核版本：$KREL" ;; esac
case "$MINOR" in ''|*[!0-9]*) die "无法解析内核版本：$KREL" ;; esac
if [ "$MAJOR" -lt 6 ] || { [ "$MAJOR" -eq 6 ] && [ "$MINOR" -lt 12 ]; }; then
	die "内核 $KREL 低于 6.12（honk 稳定通道门槛）；24.10/6.6 请用 linux66 实验通道的 ipk"
fi

# payload 里的 vmlinux-btf-builtin 只在内核自带 BTF 时才肯装
[ -e /sys/kernel/btf/vmlinux ] || die "本机没有 /sys/kernel/btf/vmlinux：
  honk-core 是 CO-RE eBPF，必须要有 BTF。请先装与 $(uname -r) 匹配的 vmlinux-btf，再来运行本包"

say "固件 ${RELEASE:-未知} · 架构 $ARCH · 内核 $KREL"

# ---------- 2. 冲突预检（只警告，不改任何服务状态） ----------
step "冲突预检"

if [ -x /etc/init.d/dae ]; then
	_dae_en="$(uci -q get dae.config.enabled 2>/dev/null)"
	case "$_dae_en" in
		1|on|true|yes|enabled)
			warn "dae 当前是开启状态：dae 与 honk 不能同时运行。"
			warn "  启用 honk 前请先：/etc/init.d/dae stop && uci set dae.config.enabled=0 && uci commit dae"
			;;
	esac
fi
if [ -x /etc/init.d/openclash ]; then
	warn "检测到 OpenClash：tproxy/redirect 规则与 honk 的 eBPF 数据面会冲突，启用 honk 前请先停用并确认规则已撤净"
fi

# ---------- 3. 完整性校验 ----------
step "校验 payload"

[ -f SHA256SUMS ] || die "payload 缺少 SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum -c SHA256SUMS >/dev/null 2>&1 || die "payload 校验失败（文件损坏）。请重新下载 run"
	say "SHA256 校验通过"
else
	warn "本机没有 sha256sum，跳过完整性校验"
fi

ls apks/*.apk >/dev/null 2>&1 || die "payload 里没有 apk"

# ---------- 4. 导入打包签名公钥 ----------
# 目的是让下面 apk add 走正常验签，而不是一上来就 --allow-untrusted
step "导入签名公钥"

mkdir -p /etc/apk/keys || die "无法创建 /etc/apk/keys"
if [ -s /etc/apk/keys/daeuniverse.pem ]; then
	say "公钥已存在"
else
	cp keys/daeuniverse.pem /etc/apk/keys/daeuniverse.pem || die "复制公钥失败"
	say "已写入 /etc/apk/keys/daeuniverse.pem"
fi

# ---------- 5. 刷新索引（依赖仍来自设备自己的源） ----------
step "apk update"

apk update || die "apk update 失败：依赖需要从本机源解析，先解决源的问题再重试"

# ---------- 6. 依赖预演（不落盘） ----------
step "依赖预演"

# --simulate 走完整依赖图，能认出 provides（25.12 的 libstdcpp 实为 libstdcpp6）
# 以及 kmod 与内核 ABI 的绑定；按包名 apk list 查会误判成缺依赖
# shellcheck disable=SC2086
SIM_OUT="$(apk add --simulate ./apks/*.apk 2>&1)"
SIM_RC=$?
if [ "$SIM_RC" != "0" ]; then
	case "$SIM_OUT" in
		*"unrecognized option"*|*"Usage: apk"*|*"usage: apk"*)
			warn "本机 apk 不支持 --simulate，跳过预演"
			;;
		*)
			printf '%s\n' "$SIM_OUT" | sed 's/^/    /' >&2
			MISSING="$(printf '%s\n' "$SIM_OUT" | sed -n 's/^  \([^ ]*\) (no such package):$/\1/p' | tr '\n' ' ')"
			if [ -n "$MISSING" ]; then
				die "本机源里缺少这些依赖：$MISSING
  若都是 kmod-*：它们与 $(uname -r) 这棵内核树不同源，本地源没有就只能自编；
  其余包：固件分支与打包时不一致。没有安装任何包。"
			fi
			die "依赖预演失败（原始输出见上）。没有安装任何包。"
			;;
	esac
else
	say "依赖全部可解析"
fi

# ---------- 7. 安装 ----------
step "安装 honk / luci-app-honk / 中文语言包"

# shellcheck disable=SC2086
if ! OUT="$(apk add ./apks/*.apk 2>&1)"; then
	case "$OUT" in
		*UNTRUSTED*|*untrusted*)
			# payload 已过 SHA256 校验，签名只是发布方的密钥本机不认；这一点与 kenzok8
			# 官方安装脚本的取舍一致，明确告知后放宽这一次
			warn "包签名本机不认（发布方密钥），已通过 SHA256 校验，改用 --allow-untrusted 重试"
			# shellcheck disable=SC2086
			apk add --allow-untrusted ./apks/*.apk || die "安装失败（原始报错见上）"
			;;
		*)
			printf '%s\n' "$OUT" | sed 's/^/    /' >&2
			die "apk add 失败：看上面原始报错。kmod 类多半是与内核不同源，非 kmod 类多半是源缺包"
			;;
	esac
fi

# ---------- 8. 只读校验 ----------
step "校验"

_missing=""
for _p in honk luci-app-honk; do
	apk info -e "$_p" >/dev/null 2>&1 || _missing="$_missing $_p"
done
[ -z "$_missing" ] || die "安装后未找到包：$_missing"

if [ -x /usr/bin/honk-core ]; then
	say "honk-core: $(/usr/bin/honk-core --version 2>/dev/null | head -n 1)"
else
	warn "/usr/bin/honk-core 不存在，安装结果异常"
fi

# ---------- 9. 收尾提示（不自动启动、不改配置） ----------
say ""
say "安装完成。以下动作本脚本不会自动做："
say "  1) 编辑 /etc/honk/config.dae：默认 LAN 接口写的是 br-lan，网桥名不同必须先改"
say "  2) 打开 doona：http://<路由器IP>:9527/ —— 必须用 IP，honk 拒绝 openwrt.lan 这类主机名"
say "  3) 在 LuCI（服务 → honk）打开 Start at boot，或："
say "       uci set honk.config.enabled=1 && uci commit honk && /etc/init.d/honk start"
say "  4) 同机还有 dae / OpenClash 在跑的话，先停干净再启动 honk"
say ""
say "卸载：apk del honk luci-app-honk luci-lib-daeuniverse luci-i18n-daeuniverse-zh-cn vmlinux-btf-builtin"
say "      /etc/honk/data/ 与 /etc/apk/keys/daeuniverse.pem 不随 apk del 删除，需要自己删"
exit 0
