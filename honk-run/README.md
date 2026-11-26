# honk-run：给 CloudRunFilesBuilder 用的离线安装包

四个文件按目录合并进 `justintsaocz/CloudRunFilesBuilder`（`daily` 分支）：

| 本目录 | 放进 fork 的位置 |
|---|---|
| `.github/workflows/honk.yml` | `.github/workflows/honk.yml` |
| `shell/honk-install.sh` | `shell/honk-install.sh` |
| `info/honk.md` | `info/honk.md` |
| `README.md` | 不需要提交，只是本目录说明 |

## 怎么用

Actions → 「Make honk offline run」→ Run workflow → 选目标架构（默认 `aarch64_generic`，与 iStoreOS 那台一致）→ 跑完在当日 release 里下载 `honk-offline-<honk版本>-<arch>.run`，约 16 MB。

只在需要时手动生成，不做定时任务。

## 打包边界

**打进 run**（设备源里没有的）：`honk`、`luci-app-honk`、`luci-lib-daeuniverse`、`luci-i18n-daeuniverse-zh-cn`、`vmlinux-btf-builtin`、发布方公钥。

**不打包**（本机源解析）：7 个 `kmod-*`、`libstdcpp6`、`v2ray-geoip/geosite`、`luci-base`、`rpcd`、`cgi-io`、`jsonfilter`、`jshn`、`flock`、`coreutils-timeout`。

原因是 `kmod-*` 与内核 ABI 逐位绑定——打进包里换内核就废；honk 本体是用户态二进制，可以随包走。

| | 仓库里 daeede 那套 | 这个 honk 包 |
|---|---|---|
| payload | 各架构分成三份 ipk 目录 | 单架构 apk，约 16 MB |
| 依赖 | 全靠 `opkg install *.ipk` 本地解 | 只带官方源缺的，其余走本机源 |
| 产物数量 | 一次三个 run | 一次一个（按输入架构） |
| 设备副作用 | — | 只多一个 `/etc/apk/keys/daeuniverse.pem` |

## 与上一版（纯在线 feed）的差别

上一版靠写 `/etc/apk/repositories.d/daeuniverse.list` 引第三方源，让 apk 在线解依赖。这一版改成把 daeuniverse 独有的 5 个包直接打进 run，**不再往设备写任何源**，离线可装；代价是每次换架构要重新生成。
