# honk.run（25.12 · apk · 离线依赖）

## 适用条件

| 项 | 要求 |
|---|---|
| 固件 | OpenWrt / ImmortalWrt / **iStoreOS 25.12 及以上**（apk） |
| 内核 | ≥ 6.12（低于此值脚本直接退出） |
| 架构 | 必须与打包时选的架构一致：`aarch64_generic`、`aarch64_cortex-a53`、`aarch64_cortex-a72`、`aarch64_cortex-a76`、`x86_64` |
| BTF | `/sys/kernel/btf/vmlinux` 必须存在（iStoreOS 自带） |

24.10 / opkg 的系统不能用本包：honk 稳定通道只出 apk，且 opkg 没有仓库 tag 机制。24.10 请走 `kenzok8/openwrt-honk` 的 `linux66-*` ipk。

## 包里有什么

只放设备源里没有的包，其余全交给本机源解析：

| 打进 run | 大小 |
|---|---|
| `honk-<ver>-<arch>.apk` | 16.2 MB |
| `luci-app-honk-<ver>-<arch>.apk` | 5.4 KB |
| `luci-lib-daeuniverse-<ver>-<arch>.apk` | 12.3 KB |
| `luci-i18n-daeuniverse-zh-cn-<ver>-<arch>.apk` | 3.0 KB |
| `vmlinux-btf-builtin-1-r1.apk` | 970 B |
| `keys/daeuniverse.pem` | 178 B |
| `ARCH`、`SHA256SUMS`、`install.sh` | 数 KB |

**不打包、由本机源提供**：`kmod-sched-bpf`、`kmod-sched-core`、`kmod-veth`、`kmod-nft-queue`、`kmod-nft-core`、`kmod-nfnetlink-queue`、`kmod-nf-conntrack`、`libstdcpp6`（provides `libstdcpp`）、`v2ray-geoip`、`v2ray-geosite`、`luci-base`、`rpcd`、`cgi-io`、`jsonfilter`、`jshn`、`flock`、`coreutils-timeout`。

这样做的原因：`kmod-*` 与内核 ABI 逐位绑定，打进包里换内核就废；而 honk 本体是纯用户态二进制，可以随包走。产物约 16 MB。

## 安装

```sh
wget -O honk.run <附件地址>
sh honk.run
```

只解压不执行（可以先看 payload）：

```sh
sh honk.run --target /tmp/honk --noexec
```

## 脚本做了什么

1. 断言：root、`apk` 存在、内核 ≥ 6.12、`/sys/kernel/btf/vmlinux` 存在、`ARCH` 与本机 `DISTRIB_ARCH` 一致
2. 冲突预检：`dae` 是否开启、是否装了 OpenClash —— **只警告，不停任何服务**
3. `sha256sum -c SHA256SUMS` 校验 payload
4. 把 `daeuniverse.pem` 复制到 `/etc/apk/keys/`，让后续安装走正常验签
5. `apk update`（依赖要从本机源解析）
6. `apk add --simulate ./apks/*.apk` 预演完整依赖图
7. `apk add ./apks/*.apk` 正式安装
8. 只读校验：`apk info -e`、`honk-core --version`

**不做**：不写 `/etc/apk/repositories.d`（不引入任何第三方源）、不自动启停服务、不改 `/etc/honk/config.dae`、不改防火墙。

若包签名本机不认（发布方密钥），脚本会在 SHA256 校验通过的前提下，明确提示后改用 `--allow-untrusted` 重试一次。

## 装完还要三步

1. 改 `/etc/honk/config.dae`：默认 LAN 接口写死 `br-lan`，网桥名不同要先改
2. 浏览器打开 `http://<路由器IP>:9527/`（doona）—— 必须用 IP，honk 拒绝 `openwrt.lan`
3. 在 LuCI「服务 → honk」打开 Start at boot，或：

```sh
uci set honk.config.enabled=1 && uci commit honk && /etc/init.d/honk start
```

同机若还有 `dae` / OpenClash 在跑，先停干净再启动 honk。

## 真机核对记录（iStoreOS 25.12.6 · aarch64_generic · rockchip/armv8 · 6.12.112）

源为 cernet 镜像的官方 25.12.6（base/packages/luci/routing/telephony/video + `targets/rockchip/armv8/kmods/6.12.112-1-5eacf764…`），上面“由本机源提供”的清单逐项实测存在：7 个 kmod 全是 `6.12.112-r1`（与内核同源），`v2ray-geoip` / `v2ray-geosite` 为 20261005 / 20261009，`libstdcpp` 实际包名 `libstdcpp6`（`openwrt:abiversion=6`，provides `libstdcpp`）。

⚠️ 判断依赖是否齐全请用 `apk add --simulate`：按包名 `apk list --available libstdcpp` 会返回空，误判成缺依赖。

## 常见报错

| 报错 | 原因 |
|---|---|
| `架构不匹配：本包是 X，本机是 Y` | run 打错了架构，按正确架构重新生成 |
| 预演报 `kmod-xxx (no such package)` | 本机源里没有与当前内核同源的模块包，只能换同源固件或自编 |
| `本机没有 /sys/kernel/btf/vmlinux` | 内核缺 BTF，先装与 `uname -r` 匹配的 `vmlinux-btf` |
| `apk update 失败` | 设备自身源的问题，与本包无关 |
| 装完起不来，`logread \| grep -i honk` 报 BTF/tc 错误 | 内核侧能力缺失（BTF 或 tc-bpf），用户态安装没问题也跑不起来 |

## 卸载

```sh
apk del honk luci-app-honk luci-lib-daeuniverse luci-i18n-daeuniverse-zh-cn vmlinux-btf-builtin
rm -f /etc/apk/keys/daeuniverse.pem
```

`/etc/honk/`（含 `data/`）不随 `apk del` 删除，需要自己清。
