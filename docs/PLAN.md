# Bifrost 开发方案

Bifrost 是一个给 KoolCenter / Koolshare 软件中心（华硕梅林 386/388 改版固件）用的非官方 Tailscale 插件，模块名是 `bifrost`。核心由本仓库从 Tailscale 官方源码编译，插件页面重新设计，代码以 MIT 许可开源。

本文件只在项目起步阶段使用。某个里程碑发布后，把已经实现的部分并入 `README.md` 和 `docs/README.md`，再从本文件删掉。

文中的标记：

- 【已核实】：2026-11-23 在开发机、Tailscale 1.104.7 源码或官方文档上核对过。
- 【待实测】：设计已定，要在对应里程碑里实测确认。

项目所有者已经做出的决定记录在第 21 节。

状态：开发已启动（2026-11-23）。接口约定见 `docs/dev/contract.md`。

## 1. 产品定义

### 1.1 定位

一个可以替换插件市场原版 `tailscale` 的插件：核心跟得上官方稳定版，脚本看得见源码，页面能看清状态并完成常用设置，从原版换过来不用重新登录。

### 1.2 用户和场景

| 场景 | 用户要做的事 | 对应功能 |
|---|---|---|
| 在外面访问家里的设备 | 路由器宣告局域网网段 | 宣告网段、路由批准状态提示 |
| 在外面打开路由器后台 | 用 tailnet IP 或局域网 IP 访问路由器 | 「允许 tailnet 访问路由器本机」 |
| 家里没装 Tailscale 的设备访问 tailnet 里的设备 | 不用做任何事 | 「局域网设备访问 tailnet」 |
| 在外面借家里的网络上网 | 把路由器设成出口节点 | 「作为出口节点」 |
| 两地局域网互通 | 两边都宣告并接受路由 | 接受路由、关闭地址转换 |
| 用自建 headscale | 填控制服务器地址和预授权密钥 | 登录的高级选项 |
| 从原版换过来 | 点一次「迁移并切换」 | 迁移，失败自动回滚 |

### 1.3 目标

1. 跟进 Tailscale 稳定版。核心由本仓库自己编译，编译配方公开，别人可以重新编译并比对结果。
2. 插件脚本全部开源，用 BusyBox `sh` 写，不做编译或混淆。
3. 重做插件页面：状态一眼能看清，常用设置不用进命令行。页面采用 Kumo 设计系统，中英文可以切换，默认中文。
4. 能从插件市场的原版无缝迁移：设备身份不变，不用重新登录。
5. 支持自建控制服务器（headscale），范围见 7.4。

### 1.4 不做（v1）

| 不做的事 | 原因 |
|---|---|
| Tailscale SSH、Taildrop、Taildrive、web client | 编译时去掉。路由器上用不到，去掉后攻击面和体积都更小。 |
| 核心自动更新，以及 Tailscale 自带的 `tailscale update` | 只提供「检查更新」和「更新核心」两个按钮，由用户手动触发。自带更新会用官方包覆盖本插件的核心（见 2.6），编译时去掉。 |
| 路由器「使用出口节点」 | 它会改写全屋流量的默认路由，配错会让局域网进不了路由器后台。开发机是家里在用的路由器，无法安全测试。v1 只做「作为出口节点」。命令行仍然可以自己设置。 |
| 接受 tailnet 的 DNS 设置（`--accept-dns`） | 打开后 tailscaled 会改写路由器的 `/etc/resolv.conf`，和固件互相覆盖。固定为关，MagicDNS 用 dnsmasq 转发提供（第 10 节）。 |
| IPv6 的子网路由和地址转换 | v1 只保证 IPv6 直连（放行 UDP 端口）和路由器自己的 tailnet IPv6 地址。 |
| 管理 headscale 服务器 | 只做客户端。不在路由器上运行 headscale，不调用它的 API，不替用户批准路由。 |
| 多个登录档案的管理界面 | 切换控制服务器时会保留旧档案，但切回旧档案只能用命令行。 |
| 380 老固件、ARMv5 机型、HND 以外的平台 | 没有设备可以实测。包格式留了扩展位置（第 16 节）。 |

## 2. 现状与核实结果

### 2.1 原版插件【已核实】

koolshare/rogsoft 仓库里的 `tailscale` 2.0.8，作者 sadog。以下是在开发机上看到的情况：

- 核心是官方 v1.94.2，没有改源码，用上游 go1.26.0 编译；`GOARM=7`、`CGO_ENABLED=0`、合并二进制、`-s -w`，去掉 12 个功能，UPX 压缩后 6.1 MB。
- 脚本 `scripts/tailscale_config`、`tailscale_status` 等是 shc 编译过的 ELF，没有源码，也没有许可证。`init.d/S96tailscale.sh` 和 `N96tailscale.sh` 是文本，内容只有一行：把第一个参数传给 `tailscale_config`。
- 启动命令是 `tailscaled -state /koolshare/configs/tailscale/tailscaled.state`，没有指定端口（随机端口），socket 用默认路径，日志写到 `/tmp/upload/tailscaled_log.txt`。
- state 目录 `/koolshare/configs/tailscale/` 里有 `tailscaled.state`、`derpmap.cached.json`、`certs/`、`files/`。
- dbus 键：`tailscale_enable`、`tailscale_ipv4_enable`、`tailscale_ipv6_enable`、`tailscale_advertise_routes`、`tailscale_accept_routes`、`tailscale_exit_node`、`tailscale_ipv4`、`tailscale_ipv6`、`tailscale_title`、`tailscale_version`。
- 开发机上它的 prefs：netfilter 模式 on、关闭子网路由的源地址转换、不接受 DNS、接受路由。
- 它加的防火墙规则（都带 `tailscale_rule` 注释）：
  - `INPUT` 放行 UDP 监听端口，放行 `tailscale0` 的全部入站；
  - `FORWARD` 放行 `tailscale0` 的全部入站；
  - nat `POSTROUTING` 对出 `tailscale0` 的流量做 MASQUERADE（这条规则在开发机上重复了一次）；
  - nat `PREROUTING` 把目的地址是本机 tailnet IP 的流量全部 DNAT 到路由器的局域网 IP。
- tailscaled 进程常驻内存 47 MB，其中匿名内存 36 MB。
- tailscaled 的启动时间和最近一次固件重建防火墙的时间相同。推断原版靠重启 daemon 来恢复规则；这一点未确认。

### 2.2 参考项目

- **thetapilla/tailscale-koolshare**（模块名 `tailscaleks`）：功能和本项目最接近，做了签名的核心更新和原版迁移。它的 README 写明 HND 机型一律用 32 位核心，mtk 和 ipq64 用 64 位核心；README 没有提 headscale 和预授权密钥。它派生自原版，没有给自己的代码单独声明许可证，所以只参考思路，不复制代码、图标或文案。
- **heimdall**（同作者，MIT）：安装脚本、打包、发布流程、页面外壳、互斥锁写法可以直接复用。
- **po0fw**（同作者，MIT）的 `asus-merlin/`：一个软件中心插件。页面用 Kumo 的 React 组件，挂在固件外壳里的 Shadow DOM 上，已经随正式版发布。本项目页面的嵌入、构建、资源命名、安装替换和页面测试都照它做（2.9 节）。
- **nezha-kumo-theme**（同作者，MIT）：用 Kumo 做的 Nezha 前端，是一个独立网站。只参考它的语言切换和漏翻检查（2.9 节）。其中有几个文件改写自 zool-theme（MIT），复制时保留原有的署名。

### 2.3 开发机【已核实】

RT-AX86U，固件 388.12，软件中心 1.9.61，路由模式，PPPoE。

| 项目 | 情况 |
|---|---|
| 内核和用户态 | 内核 4.1.52 aarch64，用户态 32 位；已经在运行 64 位静态程序 |
| 内存 | 共 934 MB |
| JFFS | 挂在 USB 盘（ext4）。内置 JFFS2 分区 47 MB，另外挂载着，剩 20.9 MB |
| `/tmp` | tmpfs，456 MB |
| BusyBox | 1.25.1。`command -v` 不可用（返回 127），`type` 可用 |
| 有的命令 | `openssl` 1.1.1w、`curl` 8.17.0（支持 `--unix-socket`）、`wget`、`jq`、`md5sum`、`base64`、`hexdump`、`flock`、`nohup`、`gunzip`、`tar`、`awk`、`sed`、`cru`、`logger`、`pidof`、`readlink`、`iperf3`、`ipset`、`ip6tables` |
| 没有的命令 | `sha256sum`、`xz`、`od`、`mktemp`、`timeout`、`setsid`、`stat`。`start-stop-daemon` 只在 `/koolshare/bin` 里有 |
| iptables | v1.4.15。支持 `-C`，不支持 `-w`。有 `comment`、`mark`、`conntrack`、`state`、`TCPMSS`、`MASQUERADE` |
| 签名验证 | `openssl pkeyutl` 没有 `-rawin` 选项；`pkeyutl` 和 `dgst` 都不能用 Ed25519 密钥签名或验签。ECDSA P-256 配合 `openssl dgst -sha256 -verify` 可用：本机 OpenSSL 3.5.9 签的文件在路由器上验证通过，文件被改后不通过；通过时返回 0，不通过时返回 1 |
| 哈希 | `openssl dgst -sha256` 可用 |
| dnsmasq | `/etc/dnsmasq.conf` 里有 `conf-dir=/jffs/configs/dnsmasq.d` |
| 固件的 NAT | WAN 口的 MASQUERADE 规则匹配「源地址不是 WAN IP」，所以来自 tailnet 的流量出 WAN 时也会被转换 |
| 固件的 `FORWARD` | 有一条 `TCPMSS --clamp-mss-to-pmtu`，排在插件插入的规则之后 |
| httpd | 只监听 `127.0.0.1` 和局域网 IP，不监听 tailnet IP |
| 界面皮肤 | `nvram get sc_skin` 的值是 `ASUSWRT`、`ROG`、`TUF`、`TS` 之一 |

### 2.4 软件中心的约定【已核实】

来源是开发机上的 `ks_tar_install.sh`、`ks-nat-start.sh`、`ks-wan-start.sh`、`base.sh`、`/jffs/scripts/` 下的钩子，以及 heimdall 对页面接口的用法。

1. 离线包名取第一个 `-` 或 `_` 之前的部分作为模块名，要和包内顶层目录名相同；包名不能有空格和 `% @ # ￥ $ & * !`。所以包名用 `bifrost-<版本>-hnd.tar.gz`，顶层目录是 `bifrost/`。
2. 包里必须有 `webs/Module_bifrost.asp` 和 `scripts/` 目录。
3. `install.sh` 里不能出现 `detect_package` 和 `ks_tar_install` 这两个词。
4. 包里的 `.valid` 文件要含平台名。安装器按机型分为 `hnd`、`mtk`、`ipq32`、`ipq64`、`qca`，RT-AX86U 是 `hnd`。
5. 新装时，安装器用 `du -s` 算解压后的大小，要求 JFFS 剩余空间减 2 MB 后大于这个数；升级时只要求剩余空间不少于 2 MB。解压在 `/tmp` 里做。
6. 页面的 `<body>` 那一行要同时含 `app`、`onload`、`skin`。否则安装器会用 `sed` 改页面：按皮肤替换颜色值，或者删掉含 `rogcss` 的行。
7. 安装器只计算并打印 md5，不验证签名。
8. `install.sh` 没写版本号时，安装器会把版本写成 `0.1`。所以 `install.sh` 要自己写 `softcenter_module_bifrost_name`、`_title`、`_description`、`_version`、`_install`。
9. 卸载脚本的位置是 `/koolshare/scripts/uninstall_bifrost.sh`，由 `install.sh` 复制过去。
10. WAN 启动时（固件的 `wan-start` 钩子），软件中心执行 `/koolshare/init.d/S*.sh start`；固件重建防火墙时执行 `/koolshare/init.d/N*.sh start_nat`。两者都按文件名里的数字排序。
11. 页面向 `/_api/` 发 `{id, method, params, fields}`。软件中心执行 `/koolshare/scripts/<method> <id> <params...>`，脚本用 `http_response` 回应。`fields` 里的键值会在脚本运行前直接写进 dbus。`/tmp/upload/` 下的文件可以用 `/_temp/<文件名>` 读到。
12. `dbus export` 输出的值没有转义。实测把含 `$(...)`、反引号和双引号的值存进去，输出原样带出。所以 `eval $(dbus export ...)` 这个常见写法会执行值里的命令。
13. 离线安装把包解到 `/tmp/<模块名>/` 再执行里面的 `install.sh`；清理时 `rm -rf /tmp/<模块名>`，解包前还会删掉 `/tmp` 下含 `install.sh` 的目录。所以插件的运行时文件不能放在 `/tmp/bifrost/`。
14. `base.sh` 的 `http_response` 用 `curl -X POST -d "$*"` 把回应发给 `127.0.0.1:3030/_resp/<ID>`，`ID` 是脚本的第一个参数。回应按表单编码发送，所以回应里不能有 `&`、`+`、`%`、`=`。
15. 开发机 BusyBox 1.25.1 的 applet 清单见 `tests/shell/router-applets.txt`。测试容器只装这些 applet。

### 2.5 核心的实测数据【已核实】

在本机用 go1.27.4 交叉编译 1.104.7，`-trimpath -ldflags "-s -w"`：

| 省略清单 | 架构 | 文件大小 | gzip -9 后 | JFFS2 上的估算占用 |
|---|---|---|---|---|
| 13 项（原版 12 项加 `completion_scripts`） | arm | 27,328,672 字节 | 10.5 MB | 12.4 MB |
| 25 项（5.2 节） | arm | 25,100,448 字节 | 9.6 MB | 11.4 MB |
| 13 项 | arm64 | 26,673,312 字节 | 10.0 MB | 没算 |
| 25 项 | arm64 | 24,576,160 字节 | 9.2 MB | 10.9 MB |

- 「JFFS2 上的估算占用」是把文件按 4 KiB 分页、每页单独做 zlib 压缩再加节点头算出来的，不是实测。
- 同一台机器上连续编译两次，sha256 相同。跨机器是否相同还没测。
- 用 13 项清单编译的 arm 核心在开发机上运行了 `version`，输出 `1.104.7`、提交 `cbc74fe48ef1b1649f69a4d9a602319427e25102`。25 项清单的核心还没有在路由器上运行过。
- 命令行启动耗时（开发机，各测 3 次）：

  | 核心 | `version` | `status --json` |
  |---|---|---|
  | 不压缩（1.104.7） | 0.02 秒 | 0.02 秒 |
  | 原版 UPX（1.94.2） | 0.94 秒 | 0.95 秒 |

### 2.6 上游行为【已核实】

来源是 Tailscale 1.104.7 源码，以及开发机上运行中的 1.94.2。

- **合并二进制**：程序文件名是 `tailscale`，或者设了环境变量 `TS_BE_CLI=1` 时，以命令行方式运行；否则以 daemon 方式运行。
- **`--extra-small`**：等于 `featuretags --min --add=osrouter,nattraversal`，会去掉 `advertiseroutes`、`useroutes`、`advertiseexitnode`、`useexitnode`、`iptables`、`dns` 等 82 项。路由器不能用。
- **featuretags 校验**：`cmd/featuretags --remove=<清单>` 会检查依赖关系。原版的 12 项清单在 1.104.7 上通不过：去掉 `completion` 必须同时去掉 `completion_scripts`。去掉 `serve` 必须同时去掉 `webclient`。
- **`tailscale up`**：改设置时必须带上所有非默认值的参数，否则报错；加 `--reset` 后，没带的参数回到默认值。`tailscale set` 没有这个限制。
- **`tailscale login`**：会先切到一个新的空档案再登录，旧档案留在 state 里。
- **换控制服务器**：运行中用 `up --login-server` 换服务器，必须加 `--force-reauth`。
- **预授权密钥**：`--auth-key=file:<路径>` 从文件读密钥。
- **防火墙模式**：`--netfilter-mode` 有 `on`、`nodivert`、`off`。`on` 模式下，tailscaled 自己建 `ts-input`、`ts-forward`、`ts-postrouting` 三条链并挂到主链上。开发机上的 `ts-input` 里有这两条：
  - `-i tailscale0 -j ACCEPT`：放行 tailnet 的全部入站；
  - `-s 100.64.0.0/10 ! -i tailscale0 -j DROP`：丢弃来源在这个网段、但不是从 `tailscale0` 进来的包。运营商级 NAT 常用这个网段。
- **规则恢复**：源码里只有 `ip rule` 被删后的恢复逻辑，没有找到 iptables 规则被清空后的恢复逻辑。
- **自带更新**：`clientupdate` 会下载官方 tarball，用里面的 `tailscale` 和 `tailscaled` 替换本机的两个程序文件，再尝试用 systemd 或 init.d 重启。
- **清理**：tailscaled 每次启动先清理一次上次留下的路由和规则；`tailscaled --cleanup` 只做清理然后退出。
- **日志上传**：`--no-logs-no-support` 或环境变量 `TS_NO_LOGS_NO_SUPPORT=true` 关闭上传。`TS_LOGS_DIR` 指定日志缓冲文件的目录。
- **netmap 缓存**：控制服务器可以让客户端把 netmap 缓存到 state 目录，环境变量 `TS_USE_CACHED_NETMAP` 可以关掉。写盘频率没测。
- **MagicDNS**：不接受 DNS 时，`100.100.100.100` 仍然能解析 tailnet 里的主机名（开发机实测）。
- **加密汇编**：`golang.org/x/crypto` v0.58.0 的 chacha20 有 arm64 汇编，没有 32 位 ARM 汇编。
- **Go 版本**：`go.mod` 写的是 `go 1.27.4`。
- **状态字段**：`status --json` 顶层有 `BackendState`、`AuthURL`、`Health`、`MagicDNSSuffix`、`CurrentTailnet`、`Self`、`Peer`、`TailscaleIPs`、`Version` 等；每个 peer 有 `HostName`、`DNSName`、`OS`、`Online`、`Active`、`CurAddr`、`Relay`、`PeerRelay`、`LastHandshake`、`LastSeen`、`RxBytes`、`TxBytes`、`ExitNodeOption`、`AllowedIPs` 等。

### 2.7 headscale 的情况【已核实】

- 最新稳定版是 v0.29.7。它要求客户端不低于 v1.80.0，官方说法是「尽量支持最近 10 个 Tailscale 客户端版本」，发布说明建议客户端用 v1.104.4 或更新。1.104.7 在支持范围内。
- 登录方式有两种。交互式：`tailscale up --login-server <地址>`，然后管理员在服务器上执行 `headscale auth register --user <用户> --auth-id <ID>`，配了 OIDC 时走单点登录。预授权密钥：`headscale preauthkeys create --user <用户ID>` 生成，默认 1 小时有效、只能用一次；客户端执行 `tailscale up --login-server <地址> --authkey <密钥>`。
- 宣告的路由要在服务器上批准：`headscale nodes approve-routes`，或者在策略里配 `autoApprovers`。
- 功能页列出了子网路由、出口节点、MagicDNS、内置 DERP。Funnel、Serve 和网络流日志在功能页上只挂着 issue 链接；本插件用不到这三项。
- 它最近的更新日志里修过一个问题：服务器关了 `logtail` 时客户端仍然向 Tailscale 上传日志。所以客户端这一侧也要自己关。

### 2.8 对上一版方案的修正

| 上一版的说法 | 核实结果 | 处理 |
|---|---|---|
| OpenSSL 1.1.1w 支持 Ed25519，用 `pkeyutl -verify -rawin` 验签 | 开发机上没有 `-rawin`，也不能用 Ed25519 验签 | 签名改用 ECDSA P-256（12.3 节） |
| 省略的功能沿用原版 12 项 | 这份清单在 1.104.7 上通不过 featuretags 的依赖校验 | 标签由 featuretags 生成，清单扩到 25 项（5.2 节） |
| 用自己的链放行端口和转发，「本机访问」做成开关 | 没写 tailscaled 自己的防火墙模式。默认模式下它已经放行 `tailscale0` 的全部入站，开关不起作用；固件重建防火墙后它的链会消失，上游不恢复 | tailscaled 的防火墙模式设为 `off`，规则全部由 Bifrost 管（第 9 节） |
| 安装时发现原版在运行就停掉它 | 这时 Bifrost 还没登录。远程用户会断开，而且连不回来 | 安装不动原版。页面提供「迁移并切换」，失败自动回滚（第 11 节） |
| 默认不用 UPX；文件大，小 JFFS 以后再考虑 | 软件中心按解压后的大小检查空间；RT-AX86U 内置 JFFS 只有 47 MB | 包里的核心用 gzip 存放，安装时解开（5.5 节） |
| arm64 核心占的内存会多一些 | 文件反而略小。运行内存没测 | M1 实测后按 5.3 节的规则决定 |
| 设置页有 accept-dns | 路由器上打开会改写 `/etc/resolv.conf` | 固定为关，用 dnsmasq 转发代替（第 10 节） |
| 设置页有「出口节点（宣告或使用）」 | 「使用」的影响面是全屋流量，无法安全测试 | v1 只做「宣告」 |
| 离线包的文件名要求 M2 实测 | 已读安装器脚本 | 见 2.4 节 |
| 没有提预授权密钥 | headscale 最常用的登录方式；Tailscale 官方的无人值守登录也用它 | 登录的高级选项里加（7.3 节） |

### 2.9 Kumo 设计系统和 po0fw 的做法【已核实】

来源是 po0fw 仓库的 `asus-merlin/`（提交 `0d9532d`，其中装的 `@cloudflare/kumo` 是 2.19.0），以及 nezha-kumo-theme 仓库（`@cloudflare/kumo` 2.18.1）。

Kumo 本身：

- Kumo 是 Cloudflare 的 React 组件库，MIT 许可。它要求 React 18 或 19，组件基于 Base UI，样式基于 Tailwind CSS 4。
- 深色模式靠元素上的 `data-mode="dark"` 属性切换。主题变量大量使用 `light-dark()`。
- 它的样式是全局的：有对所有元素的重置（`margin`、`padding`、`border` 归零），变量定义在 `:root` 上，还有 63 条 `@property` 规则。直接放进固件页面会破坏固件的菜单和页头。
- 有 `KumoLocaleProvider`，可以替换组件自带的文字；有 `KumoPortalProvider`，可以指定弹出层挂在哪个元素下。

po0fw 的做法（Kumo 页面从 tag `asus-merlin/v1.2.0` 起随正式版发布；README 写明插件已在 RT-AX86U 上验证）：

- **嵌入**：`Module_po0fw.asp` 保留固件的外壳和菜单。内容区放一个 `div`，脚本在它上面建 Shadow DOM，React 应用渲染在里面。Kumo 的样式只作用在 shadow tree 里。
- **挂载顺序**：先在 shadow root 里放 `<link rel="stylesheet">`，CSS 加载完再渲染，避免闪出没有样式的控件；CSS 地址由脚本自己的地址把 `.js` 换成 `.css` 得到。`KumoPortalProvider` 的容器是 shadow tree 里的一个 `div`，下拉框的弹出层也在 shadow tree 里。
- **`@property`**：浏览器在 shadow tree 里忽略 `@property`。构建脚本删掉 Tailwind `--tw-*` 变量的 `@property`，把它们的初始值写成 `@layer properties` 里对 `*, ::before, ::after, ::backdrop` 的普通声明。产物里只剩 Kumo 自己的两条（`--fade-left-n`、`--fade-right-n`），在 shadow tree 里不生效。
- **模态的问题**：下拉框用模态时，快速重开再按 Esc，Base UI 的遮罩会留在固件外壳和插件按钮上。所以下拉框都用 `modal={false}`。po0fw 没有用对话框。
- **资源**：软件中心的 `/res/` 只认字面文件名，地址不能带查询串。JS 和 CSS 的内容合起来算 sha256，取前 20 位十六进制作为两者共同的文件名摘要（`po0fw-app.<摘要>.js`、`.css`），只改 CSS 时脚本的文件名也会变。构建把摘要填进外壳模板，生成要打包的 `.asp`。产物不进仓库。
- **安装替换**：新资源先复制成同目录的临时文件再 `mv` 到位，最后用同样方式替换 `.asp`；外壳换好后删掉其他版本的资源。安装和卸载用 `flock` 互斥。
- **构建**：`build.mjs` 用 esbuild 打成一个 IIFE 脚本，用 PostCSS 跑 Tailwind；Tailwind 的 `@source` 只指向实际打包进脚本的 Kumo 模块。构建时检查未压缩的大小：JS 上限 600,000 字节，CSS 上限 120,000 字节。当前产物 JS 519,235 字节、CSS 97,629 字节；`gzip -9` 后是 170,440 和 16,716 字节。
- **数据**：`GET /_api/po0fw` 读 dbus 里 `po0fw_` 开头的键；`GET /_temp/<文件名>` 读 `/tmp/upload/` 下的文件；`POST /_api/` 执行脚本，`Content-Type` 是 `application/x-www-form-urlencoded; charset=UTF-8`，正文是 JSON。
- **外观**：固定深色。页头可以在 Kumo 和 coss ui 两套控件之间切换，选择存在路由器的 dbus 里，换设备后仍然有效；保存时只写这一个键。
- **字体**：系统字体，不带字体文件。
- **工具**：npm 加 `package-lock.json`，Node.js 22.18 或更新；TypeScript 7.0.2；测试用 `node --test` 加 `playwright-core`。
- **测试**：本地预览服务器提供固件外壳的桩、假设置和内存里的接口，对 `/res/` 下带查询串的请求返回 404。每个页面测试都断言没有脚本错误、没有发往外部的请求。测试覆盖：
  - 应用和弹出层在 shadow root 里，颜色是深色；
  - 读到设置之前不渲染；
  - 主题切换只发一个请求，失败时换回原值；
  - 只改 CSS、只改 JS 后，浏览器缓存仍然拿到新文件；
  - 和上一个发布版逐像素比对；
  - 在断网的 BusyBox 1.25 容器里覆盖安装和卸载。

nezha-kumo-theme 是独立网站，做法不同：用 Vite、`i18next`、Inter 字体，外观和语言的选择存在 localStorage。它有一个页面测试检查中文界面下没有漏翻的英文。它给 Kumo 2.18.1 的 `TagInput` 打了一个补丁。

## 3. 总体架构

```text
页面应用 ─POST /_api/─▶ 软件中心 httpdb ──▶ scripts/bifrost_config.sh ──▶ lib/*.sh
   ▲                                              │
   └──GET /_temp/bifrost_*.json──── /tmp/upload ◀─┘
                                                  │ 命令行（tailscale）
                                                  ▼
                                   bifrostd（tailscaled）── tailscale0
                                                  ▲
        iptables / dnsmasq / cru ◀── lib/fw.sh、lib/dns.sh、守护
```

页面应用是一个 Kumo 应用，挂在 `Module_bifrost.asp` 外壳里的 Shadow DOM 上（13.2 节）。

设计原则：

1. **设置只存一处。** Tailscale 自己保存的设置（宣告网段、接受路由、设备名、控制服务器等）只存在 tailscaled 的 prefs 里，页面每次从 prefs 读。dbus 里只放 tailscaled 不知道的插件设置（端口、防火墙开关等）。这样两边不会不一致。
2. **只通过命令行和 tailscaled 交互。** 用到的子命令是 `status --json`、`debug prefs`、`set`、`up`、`login`、`logout`、`netcheck --format=json`、`ping`、`version`。不压缩的核心每次调用 0.02 秒，不需要为了速度去用内部的 LocalAPI。
3. **每个动作可以重复执行。** 启动、应用防火墙、应用 DNS 都先清掉自己的东西再重建，执行多少次结果都一样。
4. **改状态的动作互斥。** 用 `mkdir` 做锁（写法沿用 heimdall）。
5. **规则全部由 Bifrost 管。** tailscaled 不碰 iptables。固件重建防火墙后只需要重新应用规则，不用重启 daemon。
6. **不信任页面传来的任何值。** 每个参数先按白名单格式校验，再传给命令；不用 `eval`；不用 `fields`。

## 4. 文件、命名和数据

### 4.1 路径

| 用途 | 路径 |
|---|---|
| 核心 | `/koolshare/bifrost/bin/bifrostd` |
| 命令行入口 | `/koolshare/bifrost/bin/tailscale`（指向 `bifrostd` 的符号链接） |
| 给 SSH 用户的命令 | `/koolshare/bin/bifrost`（脚本：带上 socket 参数执行上面的 `tailscale`） |
| 上一版核心 | `/koolshare/bifrost/bin/bifrostd.prev.gz`（空间够时才保留） |
| 已安装核心的清单 | `/koolshare/bifrost/core.json` |
| 签名公钥 | `/koolshare/bifrost/keys/*.pub.pem` |
| 脚本库 | `/koolshare/bifrost/lib/*.sh` |
| 许可证 | `/koolshare/bifrost/LICENSE`、`LICENSE.tailscale` |
| state 目录 | `/koolshare/configs/bifrost/`（`tailscaled.state` 等） |
| 运行时 | `/tmp/bifrost-run/`（PID、锁、日志、临时文件）。不用 `/tmp/bifrost/`：那是软件中心解包和执行 `install.sh` 的目录，安装结束时会被整个删除（2.4 节第 13 条） |
| socket | `/var/run/bifrost/tailscaled.sock` |
| 给页面读的文件 | `/tmp/upload/bifrost_*.json`、`bifrost_*.log` |
| dnsmasq 配置 | `/jffs/configs/dnsmasq.d/bifrost.conf` |
| 软件中心约定 | `scripts/bifrost_config.sh`、`scripts/bifrost_status.sh`、`scripts/uninstall_bifrost.sh`、`webs/Module_bifrost.asp`、`res/icon-bifrost.png`、`res/bifrost-app.<摘要>.js` 和 `.css`（页面应用，13.2 节）、`init.d/S99bifrost.sh`、`init.d/N99bifrost.sh` |

- 核心文件叫 `bifrostd`，不叫 `tailscaled`。这样 `pidof` 和进程列表里能和原版分开。文件名不是 `tailscale` 时它以 daemon 方式运行【已核实】。
- socket 用自己的路径。原版的命令行不会连到 Bifrost 的 daemon，判断「谁在运行」也更清楚。
- 网卡名仍然是 `tailscale0`。两个插件本来就不能同时运行，其他插件的规则也可能引用这个名字。
- `init.d` 里的两个文件是指向 `bifrost_config.sh` 的符号链接。序号 99 排在原版（96）之后、lucky（110）和 heimdall（150）之前。

### 4.2 dbus 键

| 键 | 取值 | 默认 | 含义 |
|---|---|---|---|
| `bifrost_enable` | `0` / `1` | `0` | 是否启用。开机时据此决定是否启动 |
| `bifrost_port` | 1024–65535 | `41641` | UDP 监听端口 |
| `bifrost_local_access` | `0` / `1` | `1` | 允许 tailnet 访问路由器本机 |
| `bifrost_lan_masq` | `0` / `1` | `1` | 局域网设备访问 tailnet |
| `bifrost_snat` | `auto` / `on` / `off` | `auto` | tailnet 进局域网时是否转换源地址 |
| `bifrost_magicdns` | `0` / `1` | `0` | 局域网解析 tailnet 主机名 |
| `bifrost_no_logs` | `0` / `1` | `1` | 不向 Tailscale 上传日志 |
| `bifrost_mirror` | 空或 `https://.../` | 空 | 下载核心用的镜像前缀 |
| `bifrost_ui_lang` | `zh-CN` / `en` | `zh-CN` | 页面语言（13.9 节） |
| `bifrost_ui_mode` | `dark` / `light` / `system` | `dark` | 页面外观（13.8 节） |
| `softcenter_module_bifrost_*` | — | — | 软件中心登记用：`name`、`title`、`description`、`version`、`install` |

不放进 dbus 的东西：预授权密钥、登录链接、控制服务器地址、任何 tailscaled 自己保存的设置。

### 4.3 tailscaled 的 prefs

| prefs | 谁决定 | 值 |
|---|---|---|
| `--accept-dns` | 固定 | `false` |
| `--netfilter-mode` | 固定 | `off` |
| `--snat-subnet-routes` | 固定 | 保持默认 `true`。防火墙模式是 `off` 时它不起作用；保持默认是为了不触发「出口节点没有源地址转换」的健康告警 |
| `--shields-up` | 固定 | `false`。它会连子网路由的入站一起挡掉 |
| `--advertise-routes` | 用户 | 设置页 |
| `--advertise-exit-node` | 用户 | 设置页 |
| `--accept-routes` | 用户 | 设置页。新装默认 `false`，迁移时保留原值 |
| `--hostname` | 用户 | 设置页。空表示用系统主机名 |
| `--login-server` | 用户 | 登录的高级选项 |
| 其他 | 不管 | 用户用命令行改的其他设置不动，但重新登录时会被重置（7.6 节） |

每次启动后和守护检查时，都核对三个固定项；不一致就用 `tailscale set` 改回去。

## 5. 核心

### 5.1 配方

`core/recipe.json` 是编译设置的唯一来源，本地和 CI 共用 `core/build.sh`。

```json
{
  "tailscale": {
    "version": "1.104.7",
    "commit": "cbc74fe48ef1b1649f69a4d9a602319427e25102"
  },
  "go": "1.27.4",
  "revision": 1,
  "omit": ["aws", "bird", "tap", "kube", "completion", "completion_scripts",
           "systray", "tpm", "debugeventbus", "syspolicy", "capture", "ssh",
           "taildrop", "clientupdate", "webclient", "drive", "desktop_sessions",
           "webbrowser", "networkmanager", "resolved", "dbus", "synology",
           "sdnotify", "flashappliance", "cloud"],
  "targets": [
    { "name": "arm", "GOARCH": "arm", "GOARM": "7" },
    { "name": "arm64", "GOARCH": "arm64" }
  ]
}
```

- `revision` 是同一个 Tailscale 版本的重新编译序号，对应核心 tag 的最后一段。
- `build.sh` 的步骤：
  1. 检查本机 Go 版本等于 `go`，并且等于源码 `go.mod` 里的版本。不相等就停止。
  2. 按 tag 克隆 Tailscale 源码，检查 `HEAD` 等于 `commit`。不相等就停止。
  3. 运行 `go run ./cmd/featuretags --remove=<omit>` 得到标签。校验失败就停止。
  4. 对每个 target 执行：`TAGS=ts_include_cli,<标签> CGO_ENABLED=0 GOOS=linux GOARCH=... ./build_dist.sh --strip -o <输出> ./cmd/tailscaled`。`build_dist.sh` 会写入版本号并加 `-trimpath`【已核实】。
  5. 检查产物：`go version -m` 里的标签和配方一致；文件里能找到版本号。
  6. 输出 `bifrost-core-<版本>-<revision>-linux-<target>.gz`（`gzip -9 -n`）和清单 `core.json`（12.2 节）。
- 必须从 git 检出编译。从模块缓存编译的产物没有提交信息，哈希会不一样。
- 用上游 Go，不用 Tailscale 自己的 Go 分支。原版也是这样做的。

### 5.2 省略的功能

| 功能 | 原因 |
|---|---|
| `aws` `bird` `tap` `kube` `completion` `systray` `tpm` `debugeventbus` `syspolicy` `capture` `ssh` `taildrop` | 原版去掉的 12 项 |
| `completion_scripts` | 依赖校验要求和 `completion` 一起去掉 |
| `clientupdate` | 防止 `tailscale update` 或控制台触发的更新用官方包覆盖核心。去掉后这个命令和 `--auto-update` 都不存在 |
| `webclient` | 不开 web client |
| `drive` | Taildrive 文件共享，不做 |
| `desktop_sessions` `webbrowser` | 桌面环境才用 |
| `networkmanager` `resolved` `dbus` | Linux 桌面和服务器的 DNS 管理方式，路由器上没有。这里的 `dbus` 是 freedesktop D-Bus，和软件中心的 `dbus` 命令无关 |
| `synology` `flashappliance` `cloud` `sdnotify` | 群晖、刷机镜像、云主机、systemd 才用 |

25 项比 13 项小 2.2 MB（arm）。

明确保留的功能：`advertiseroutes`、`useroutes`、`advertiseexitnode`、`useexitnode`、`osrouter`、`iptables`、`dns`、`netstack`、`portmapper`、`peerapiserver`、`peerapiclient`、`health`、`logtail`、`debug`（`debug prefs` 要用）、`serve` 和 `acme`（给命令行用户）、`qrcodes`、`cachenetmap`、`tailnetlock`。

每次升级 Tailscale 版本时，重新运行 `featuretags --list`，检查有没有新增的、路由器用不到的功能。

### 5.3 架构

- 插件包里只带 arm 核心（`GOARM=7`）。它在所有 HND 机型上都能运行，包括 64 位内核、32 位用户态的机型。
- arm64 核心是可选的优化，只通过「更新核心」在线获取。内核是 `aarch64` 的机型才显示「切换到 arm64 核心」。
- M1 在开发机上实测两种核心，按下面的规则决定：
  - 经 tailnet 的 iperf3 吞吐，arm64 比 arm 高 20% 以上，并且常驻内存多出不超过 15 MB：发布 arm64 核心，在核心页提供切换。
  - 否则只发布 arm 核心，`targets` 里删掉 arm64。
- 预期 arm64 更快，因为 chacha20 有 arm64 汇编而没有 32 位 ARM 汇编。thetapilla 在 HND 上一律用 32 位核心。

### 5.4 体积和启动耗时

数据见 2.5 节。

### 5.5 不用 UPX

- 不压缩的核心每次命令行调用 0.02 秒，UPX 版 0.94 秒。页面每 3 秒查一次状态，UPX 版每次都要占一秒 CPU。
- UPX 版每个进程都要把整个程序解压进自己的匿名内存，不能共享，也不能被系统回收。
- 代价是占的空间更大。应对办法：
  - **包里的核心用 gzip 存放**（`bin/bifrostd.gz`，约 9.6 MB）。软件中心按解压后的大小检查空间，这样新装只要求约 12 MB 剩余空间，而不是 27 MB。
  - `install.sh` 把它解到 JFFS 上。JFFS2 和 UBIFS 会透明压缩，实际占用估算约 11 MB【待实测】。
  - 写入失败（空间不足）时不影响已安装的旧版本（15.1 节）。
- M1 在开发机的内置 JFFS2 分区上实测实际占用。如果在常见机型上仍然装不下，再出 UPX 版；v1 不预先做。

### 5.6 可复现

- 同一个 tag、同一个 Go 版本、`-trimpath`、`CGO_ENABLED=0`，编出来的 sha256 应该相同。同一台机器上已经验证相同。
- M1 验证跨机器：macOS 本机和 CI 的 Linux 各编一次，比对 sha256。
- CI 发布核心时用两个独立的 job 各编一次，哈希不同就不发布。

## 6. 运行

### 6.1 启动命令

```sh
TS_LOGS_DIR=/tmp/bifrost-run/logs \
/koolshare/bifrost/bin/bifrostd \
  --statedir=/koolshare/configs/bifrost \
  --socket=/var/run/bifrost/tailscaled.sock \
  --tun=tailscale0 \
  --port="$bifrost_port" \
  [--no-logs-no-support] \
  >>/tmp/bifrost-run/bifrostd.log 2>&1 &
```

- `bifrost_no_logs=1` 或者控制服务器不是 Tailscale 官方时，加 `--no-logs-no-support`。
- 端口固定，防火墙规则才能提前写好，用户也才能在上级路由做端口映射。

### 6.2 启动顺序

1. 取锁。
2. 预检查。任何一项不通过就停止，并把原因写进状态：
   - 核心文件存在，`bifrostd --version` 能输出版本；
   - `/dev/net/tun` 存在；
   - 没有别的 tailscaled 在运行（原版，或用户自己起的）。判断方法：存在 `tailscale0`，但它不属于 Bifrost 的 PID；
   - state 目录可写。
3. 建运行时目录，目录权限 700。
4. 启动 daemon，写 PID 文件。
5. 等 socket 可用，最多 15 秒。
6. 核对固定的 prefs（4.3 节），不一致就改。
7. 应用防火墙规则（第 9 节）。
8. 应用 DNS 设置（第 10 节）。
9. 登记守护任务。
10. 写状态文件。

启动不执行 `tailscale up`。tailscaled 会按 state 里保存的状态自己连接；没登录过就停在「需要登录」。

### 6.3 停止顺序

1. 取锁，删掉守护任务。
2. 删掉 Bifrost 的防火墙链和 dnsmasq 配置。
3. 给 daemon 发 `TERM`，最多等 10 秒。超时才发 `KILL`。
4. 执行 `bifrostd --cleanup`，清理残留的网卡地址、路由和策略路由规则。
5. 写状态文件。

停止不执行 `tailscale down` 或 `logout`。设备在 tailnet 里显示为离线，再次启动后恢复。

### 6.4 开机和防火墙重建

- `S99bifrost.sh start`（WAN 启动时）：`bifrost_enable=1` 时执行启动顺序。daemon 已经在运行就什么都不做。
- `N99bifrost.sh start_nat`：只重新应用防火墙规则，不重启 daemon。daemon 没在运行时什么都不做。
- 入口脚本对第一个参数只接受 `start`、`stop`、`start_nat` 三个值。

### 6.5 守护

- 用 `cru` 每 2 分钟执行一次 `bifrost_config.sh local watchdog`。
- 检查项：
  1. PID 文件里的进程存在，并且 `/proc/<pid>/exe` 指向 Bifrost 的核心；
  2. `status --json` 在 10 秒内返回；
  3. 三个固定的 prefs 没被改；
  4. Bifrost 的链还挂在主链的第一条；
  5. MagicDNS 后缀和 dnsmasq 配置一致；
  6. 日志文件超过 1 MB 时截到最后 200 KB。
- 第 1、2 项失败时重启 daemon。30 分钟内最多重启 3 次；超过后不再重启，把状态标成「多次重启失败」，等用户处理。
- 开发机没有 `timeout` 命令。超时用「后台运行命令，再起一个 `sleep` 后 `kill` 的子进程」实现。守护自己也要取锁，取不到就直接退出，避免堆积。

### 6.6 日志

- daemon 的输出追加到 `/tmp/bifrost-run/bifrostd.log`（内存盘）。用追加方式打开，所以守护可以直接截断。
- 脚本的日志写到 `/tmp/bifrost-run/bifrost.log`，每行带时间和动作名。
- 页面显示的日志都先脱敏（13.10 节）。

## 7. 登录和控制服务器

### 7.1 状态

页面的状态由 `bifrost_enable`、进程是否存在和 `BackendState` 得出：

| 页面状态 | 条件 | 页面显示 |
|---|---|---|
| 未启用 | `bifrost_enable=0` | 「启用」按钮。检测到原版时显示迁移入口 |
| 有冲突 | 别的 tailscaled 在运行 | 说明原因，给出「迁移并切换」 |
| 核心缺失 | 核心文件不在或不能运行 | 指向核心页 |
| 启动中 | 进程在，`BackendState` 是 `NoState` 或 `Starting` | 等待提示 |
| 需要登录 | `NeedsLogin` | 登录入口 |
| 等待批准 | `NeedsMachineAuth` | 提示去控制台批准这台设备 |
| 已停止 | `Stopped` | 「连接」按钮（执行 `tailscale up`，不带参数） |
| 运行中 | `Running` | 概览 |
| 出错 | 守护放弃重启，或预检查失败 | 原因和处理建议 |

### 7.2 交互式登录

1. 用户点「登录」。脚本在后台执行 7.6 节的 `up` 命令，带 `--timeout=10m`，立即回应页面。
2. 页面每 2 秒查一次状态。`AuthURL` 不为空时显示这个链接，并在浏览器里生成二维码。
3. 用户在任意设备上打开链接完成授权。`BackendState` 变成 `Running` 后，页面转到概览。
4. 10 分钟没完成，页面提示「链接已过期」，可以重新获取。

- 二维码用打包进页面的 JS 库生成（MIT 许可），不依赖 `up --json` 的输出格式。
- `up` 命令行退出后，待完成的登录是否仍然有效【待实测】。如果无效，就让 `up` 一直等到用户完成或取消。

### 7.3 预授权密钥

- 登录的高级选项里有「预授权密钥」输入框。填了就不走交互式登录。
- 两种控制服务器都能用。Tailscale 官方的密钥用于无人值守登录和带标签的设备。
- 处理方式：
  1. 页面把密钥放在 `params` 里，不放 `fields`，所以不会进 dbus。
  2. 脚本校验格式 `^[A-Za-z0-9_-]{16,128}$`，写进 `/tmp/bifrost-run/authkey`（权限 600）。
  3. 执行 `up --auth-key=file:/tmp/bifrost-run/authkey ...`。密钥不出现在 tailscaled 的命令行里。
  4. 命令结束后立刻删除文件，不管成功还是失败。
- 密钥不写日志。页面提示用户用一次性、短有效期的密钥。
- 残留风险：脚本运行的几秒内，密钥在脚本自己的参数里，路由器上的 root 用户能看到；路由器后台走 HTTP 时，密钥在局域网里是明文。这和路由器的管理密码处于同一水平，写进 README。

### 7.4 自建控制服务器（headscale）

支持，范围限定为「作为客户端接入」。理由：

- 这个插件的用户大多在国内。官方控制服务器和 DERP 在国内不稳定，自建 headscale 加自建 DERP 是常见做法。
- 成本很小：一个 `--login-server` 参数、一个输入框。预授权密钥本来就要做。
- 协议兼容由 headscale 负责，1.104.7 在它的支持范围内（2.7 节）。

要做的事：

| 项目 | 做法 |
|---|---|
| 控制服务器地址 | 登录的高级选项里的输入框。空表示 Tailscale 官方。格式校验：`http://` 或 `https://` 开头，主机名，可选端口和路径，不含空白和引号。`http://` 给出警告 |
| 切换服务器 | 当前档案的服务器和要登录的不同时，用 `tailscale login`。它会新建档案，旧档案留在 state 里，可以用命令行 `bifrost switch` 切回去 |
| 登录链接 | 页面只显示 `AuthURL` 和二维码，不假设它是 Tailscale 的地址。服务器不是官方时，加一句提示：「请在控制服务器上批准这台设备，或者改用预授权密钥」 |
| 路由批准 | 页面比较「已宣告」和「已生效」的网段，没生效的标「等待批准」。服务器是官方时给控制台链接；不是时只提示「请在控制服务器上批准」，不写具体命令，因为 headscale 的命令随版本变化 |
| 日志上传 | 服务器不是官方时，强制加 `--no-logs-no-support`，不管 `bifrost_no_logs` 的值 |
| 页面文字 | 不写死 `login.tailscale.com`、`*.ts.net`、DERP 区域名。MagicDNS 后缀、tailnet 名、DERP 名称都从状态里读 |
| 证书 | 服务器要用公共 CA 签的证书。路由器上有系统 CA 包，核心里还内置了 Let's Encrypt 根证书。自签证书不支持，写进 README |

不做的事见 1.4 节。发布说明里写明测试过的 headscale 版本。

### 7.5 重新登录和退出

- **重新登录**（密钥过期或换账号）：执行 7.6 节的命令，加 `--force-reauth`。
- **退出登录**：执行 `tailscale logout`。它会让这台设备在控制服务器上失效。页面要求二次确认，并说明后果。
- **清除登录状态**：诊断页的按钮。先退出登录，再停止 daemon，再删除 state 目录。二次确认。

### 7.6 登录命令的构造

`up` 改设置时要带齐所有非默认值的参数，所以登录命令总是用 `--reset` 加完整的参数表：

```text
tailscale up --reset
  --accept-dns=false --netfilter-mode=off
  --accept-routes=<当前值> --advertise-routes=<当前值>
  --advertise-exit-node=<当前值> --hostname=<当前值>
  [--login-server=<地址>] [--auth-key=file:<路径>] [--force-reauth]
  --timeout=10m
```

- 「当前值」从 `debug prefs` 读。读不到（第一次登录）就用 4.3 节的默认值。
- 后果：用户用命令行设的、不在这张表里的设置，重新登录后回到默认值。写进 README。
- `tailscale login` 从空档案开始，用同一张参数表，但不带 `--reset` 和 `--force-reauth`。
- 日常改设置只用 `tailscale set`，不用 `up`。

## 8. 设置项

| 设置 | 默认 | 实现 | 校验和提示 |
|---|---|---|---|
| 启用 Bifrost | 关 | 启动或停止，写 `bifrost_enable` | — |
| 宣告网段 | 空 | `set --advertise-routes=` | IPv4 CIDR 列表，最多 16 条，逐项检查数值范围，不允许 `0.0.0.0/0`。输入框预填路由器的局域网网段，用户勾选后才提交。保存后显示每条网段「已生效」或「等待批准」 |
| 作为出口节点 | 关 | `set --advertise-exit-node=` | 说明：tailnet 里的设备可以借这台路由器的网络上网，需要在控制台批准 |
| 接受其他设备宣告的路由 | 关（迁移时保留原值） | `set --accept-routes=` | 打开前检查：如果有设备宣告的网段和路由器局域网网段重叠，警告会造成局域网不通，要求再次确认 |
| 设备名 | 空（系统主机名） | `set --hostname=` | 字母、数字、连字符，1–63 位，首尾不是连字符 |
| 监听端口 | 41641 | 写 `bifrost_port`，重启 daemon，重新应用防火墙 | 1024–65535 |
| 允许 tailnet 访问路由器本机 | 开 | 写 `bifrost_local_access`，重新应用防火墙 | 关闭前检查当前浏览器是不是从 tailnet 进来的。是的话警告会断开，要求再次确认 |
| 局域网设备访问 tailnet | 开 | 写 `bifrost_lan_masq`，重新应用防火墙 | 说明：两地局域网互通、需要保留源地址时关掉 |
| 进局域网时转换源地址 | 自动 | 写 `bifrost_snat`，重新应用防火墙 | 自动：路由模式下关，AP 模式下开（`nvram get sw_mode` 不是 `1`）。说明两种取值的区别 |
| 局域网解析 tailnet 主机名 | 关 | 写 `bifrost_magicdns`，应用 DNS | 说明会改 dnsmasq 配置 |
| 不向 Tailscale 上传日志 | 开 | 写 `bifrost_no_logs`，重启 daemon | 控制服务器不是官方时这一项锁定为开 |
| 下载镜像 | 空 | 写 `bifrost_mirror` | `https://` 开头，以 `/` 结尾，只含字母、数字和 `. / _ -` |

- 每次保存只提交改动的那一项。脚本执行后重新读一次 prefs、dbus 和实际规则，把读到的值返回给页面。页面显示的是读回来的值，不是提交的值。
- daemon 没在运行时，属于 tailscaled 的设置（宣告网段、出口节点、接受路由、设备名）置灰，提示「启动后可以修改」。
- 会让 tailnet 连接短暂中断的动作（改端口、改日志上传、更新核心、迁移），页面先说明再执行。脚本在后台完成，不依赖浏览器连接。

## 9. 防火墙

### 9.1 做法

tailscaled 的防火墙模式固定为 `off`，所有规则由 Bifrost 自己的链提供。理由：

1. **开关才能生效。** `on` 模式下 tailscaled 自己放行 `tailscale0` 的全部入站，「允许访问本机」关了也没用。
2. **重建后不用重启 daemon。** 固件重建防火墙会清掉所有自定义链，上游不恢复。Bifrost 的规则不依赖 daemon 的内部状态，重新应用一次就行，tailnet 连接不中断。
3. **不带上游的 `100.64.0.0/10` 丢弃规则。** WAN 口是运营商级 NAT 地址时，这条规则会误伤上游发来的包。Bifrost 只按入站网卡 `tailscale0` 放行，不按源地址放行，所以不需要这条防伪造规则。

代价：子网路由和出口节点的转发规则由 Bifrost 维护，上游以后改规则时要跟着核对。规则很少，用容器测试覆盖（第 17 节）。

### 9.2 规则

链名在 iptables 和 ip6tables 里相同。每条链用 `-I <主链> 1` 挂在主链第一条。

**IPv4 filter**

| 链 | 规则 | 条件 |
|---|---|---|
| `BIFROST_INPUT` | `-p udp --dport <端口> -j ACCEPT` | 总是 |
| | `-i tailscale0 -j ACCEPT` | 允许访问本机 |
| | `-i tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT` | 不允许访问本机 |
| | `-i tailscale0 -p icmp -j ACCEPT` | 不允许访问本机 |
| | `-i tailscale0 -p tcp --dport <PeerAPI 端口> -j ACCEPT` | 不允许访问本机，并且是出口节点（出口节点的 DNS 要用） |
| | `-i tailscale0 -j DROP` | 不允许访问本机 |
| `BIFROST_FORWARD` | `-i tailscale0 -j MARK --set-xmark 0x40000/0xff0000` | 转换源地址时 |
| | `-i tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` | 总是 |
| | `-o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` | 总是 |
| | `-i tailscale0 -j ACCEPT` | 总是 |
| | `-o tailscale0 -j ACCEPT` | 总是 |

**IPv4 nat**

| 链 | 规则 | 条件 |
|---|---|---|
| `BIFROST_POSTROUTING` | `-m mark --mark 0x40000/0xff0000 ! -o tailscale0 -j MASQUERADE` | 转换源地址时 |
| | `-o tailscale0 -j MASQUERADE` | 局域网设备访问 tailnet |
| `BIFROST_PREROUTING` | `-i tailscale0 -d <本机 tailnet IP> -p tcp --dport <后台端口> -j DNAT --to-destination <局域网 IP>` | 允许访问本机。HTTP 和 HTTPS 端口各一条，端口从 nvram 读 |

**IPv6 filter**（有 `ip6tables` 时）

- `BIFROST_INPUT`：UDP 端口规则，以及和 IPv4 相同的「本机访问」规则（ICMP 换成 ICMPv6）。
- `BIFROST_FORWARD`：`-i tailscale0` 和 `-o tailscale0` 的放行。
- 不做 IPv6 的 nat。

说明：

- **谁能进来由 tailnet 策略决定。** tailscaled 在把包写进 `tailscale0` 之前，已经按 tailnet 策略和本机宣告的网段过滤过。`-i tailscale0 -j ACCEPT` 放行的是已经过滤后的流量，这和上游的做法一样。
- **标记值**和上游相同（`0x40000/0xff0000`）。上游保留了这一段掩码，不会和它自己绕过路由用的标记冲突。
- **MSS 钳制**：固件自己的钳制规则排在后面，被 `ACCEPT` 提前截断后不会执行，所以 Bifrost 自己加。`tailscale0` 的 MTU 是 1280。
- **出口节点上网**不需要额外的 nat 规则。固件 WAN 口的 MASQUERADE 已经覆盖【已核实】。
- **后台的 DNAT**：httpd 不监听 tailnet IP，所以用 tailnet IP 打开后台要靠这条规则。原版把所有端口都转过去，连 PeerAPI 端口也转走了；Bifrost 只转后台端口。固件的 httpd 是否接受这样进来的请求【待实测】。不接受就删掉这条规则，改成在页面上提示用局域网 IP 访问。
- **不允许访问本机时**，从 tailnet 仍然可以访问局域网里的其他设备，也可以 ping 路由器。

### 9.3 应用和恢复

- `fw_apply` 的步骤：读设置 → 对每条链「没有就建，有就清空」→ 按上表填规则 → 确认主链第一条是到本链的跳转，不是就删掉旧跳转重新插入。
- `fw_clear`：删跳转，清空并删除链。
- 调用时机：启动之后；`start_nat`；改了相关设置之后；登录成功拿到 tailnet IP 之后；守护发现链不在第一条时。
- 开发机的 iptables 不支持 `-w`，没有锁。每条命令失败后重试，最多 3 次，间隔 1 秒；最后用 `-C` 逐条确认。

### 9.4 和其他插件

- 透明代理类插件（heimdall、merlinclash、fancyss 等）要让去往 `100.64.0.0/10` 和已接受网段的流量绕过代理。heimdall 已经对 `100.64.0.0/10` 这样做了【已核实】。README 里写明这个要求。
- 这类插件用 `-I` 在主链第一条插自己的跳转时，Bifrost 的链会被挤到后面。守护会把它挪回第一条。如果两个插件互相抢位置，守护日志里会记录，README 里写处理办法。

## 10. DNS

- `--accept-dns` 固定为 `false`。路由器自己的 DNS 设置不变。
- 「局域网解析 tailnet 主机名」打开时：
  1. 从状态里读 MagicDNS 后缀，校验只含小写字母、数字、点和连字符。
  2. 写 `/jffs/configs/dnsmasq.d/bifrost.conf`，内容是一行：`server=/<后缀>/100.100.100.100`。
  3. 执行 `service restart_dnsmasq`。
- 停止、关闭这个选项、卸载时，删掉文件并重启 dnsmasq。daemon 停了以后 `100.100.100.100` 不可达，留着这行会让这个后缀的查询超时。
- 后缀变了（换 tailnet 或换控制服务器），守护负责更新。
- 固件的 dnsmasq 配置里没有 `conf-dir` 这一行时，这个选项置灰并说明原因。
- 不处理 tailnet 里配置的分流 DNS 和搜索域。

## 11. 与原版共存和迁移

### 11.1 共存规则

- 模块名、dbus 键、文件路径、state 目录、socket 都是 Bifrost 自己的。软件中心更新原版时不会覆盖本插件，本插件也不改原版的任何文件。
- 两个插件不能同时运行，因为都要用 `tailscale0`，而且迁移后是同一个设备身份。
- **安装 Bifrost 不动原版。** 新装后 `bifrost_enable=0`。
- 启动 Bifrost 时如果原版在运行，拒绝启动，并在页面上给出迁移入口。

### 11.2 迁移流程

页面上是一个按钮：「迁移并切换」。脚本在后台执行，不依赖浏览器连接，因为用户可能正通过 tailnet 访问路由器。

1. **预检查**：原版的 state 文件存在；Bifrost 的核心可用；Bifrost 的 daemon 没在运行。
2. **记录**：用原版的命令行读它的设备 ID、公钥和 `BackendState`，存到 `/tmp/bifrost-run/migrate/`。
3. **备份**：Bifrost 的 state 目录里已经有文件时，先改名为带时间的备份。
4. **停止原版**：通过原版自己的脚本停止，并关掉它的开机启动。具体调用方式【待实测】：原版脚本是编译过的，候选做法是把 `tailscale_enable` 设成 `0`，再执行它页面上的提交动作。M2 第一步在维护窗口里确认。确认不了就不做自动切换，改成提示用户先在原版页面里关闭，Bifrost 检测到它停了再继续。
5. **复制**：把原版的 `tailscaled.state` 和 `derpmap.cached.json` 复制到 Bifrost 的 state 目录，权限 600。不复制 `files/`（Taildrop 已去掉）。原版的文件一个都不改。
6. **启动 Bifrost**：`bifrost_enable=1`，执行启动顺序。第 6 步会把防火墙模式改成 `off`。
7. **验证**：60 秒内 `BackendState` 回到记录的状态，设备 ID 和公钥与记录的相同。
8. **成功**：写结果文件。页面提示以后可以卸载原版。
9. **失败**：停止 Bifrost，`bifrost_enable=0`，删掉刚复制的文件，恢复第 3 步的备份，重新启用并启动原版，把失败原因写进结果文件。

原版的设置不用单独迁移：宣告网段、接受路由等都在 state 文件里，跟着文件过来。

### 11.3 迁移后的注意事项

- 原版的 state 文件还在。以后在 Bifrost 里重新登录或密钥轮换后，原版那份就过期了；那时再切回原版需要重新登录。页面和 README 里说明。
- 手动回到原版的步骤写进 README：在 Bifrost 里停用，再到原版页面里启用。

## 12. 核心分发与更新

### 12.1 发布物

- 插件包里带 arm 核心，离线安装后马上能用。
- 核心单独发布，tag 是 `core-<Tailscale 版本>-<revision>`。附件：
  - `bifrost-core-<版本>-<revision>-linux-arm.gz`，发布 arm64 时还有对应的 `arm64` 文件；
  - `core.json`、`core.json.sig`；
  - `SHA256SUMS`、`SHA256SUMS.sig`；
  - `LICENSE.tailscale`；
  - GitHub 的构建来源证明。
- 另有一个固定的发布 `channel-stable`，CI 每次发布核心后覆盖它的 `core.json` 和 `core.json.sig`。路由器检查更新时读这个固定地址：`https://github.com/<owner>/bifrost/releases/download/channel-stable/core.json`。

### 12.2 清单格式

```json
{
  "schema": 1,
  "serial": 7,
  "tailscale": "1.104.7",
  "revision": 1,
  "tag": "core-1.104.7-1",
  "min_plugin": "0.1.0",
  "assets": {
    "arm": {
      "file": "bifrost-core-1.104.7-1-linux-arm.gz",
      "size": 9590179,
      "sha256": "<gz 文件的 sha256>",
      "raw_size": 25100448,
      "raw_sha256": "<解压后的 sha256>"
    }
  }
}
```

- `serial` 每次发布加 1。路由器拒绝安装 `serial` 不大于已安装版本的清单，防止有人拿旧的、签名有效的清单让用户降级到有漏洞的版本。
- `min_plugin` 是这个核心要求的最低插件版本。插件版本低于它时，提示先更新插件。
- 文件的下载地址由 `tag` 和 `file` 拼出来，清单里不写完整地址。

### 12.3 签名

- 算法：ECDSA P-256，SHA-256。开发机的 OpenSSL 不能验 Ed25519【已核实】。
- CI 里签名：`openssl dgst -sha256 -sign <私钥> -out core.json.sig core.json`。
- 路由器上验证：`openssl dgst -sha256 -verify <公钥> -signature core.json.sig core.json`。返回 0 才继续【已核实】。
- 文件哈希用 `openssl dgst -sha256` 算。
- 公钥放在插件包的 `keys/` 目录里，可以有多个。任意一个公钥验证通过就算通过，这样可以轮换密钥：先发一个带新公钥的插件版本，过一段时间再换私钥。
- 私钥只放在 GitHub Actions secret 里，不进仓库。
- 先验清单签名，再按清单里的哈希验文件。所以从镜像下载也一样安全。
- 插件包自己的 `SHA256SUMS` 也用同一个密钥签名，给用户手动核对。软件中心安装时不验证签名（2.4 节）。

### 12.4 更新流程

1. 下载 `core.json` 和 `core.json.sig` 到 `/tmp/bifrost-run/update/`。
2. 验签名。检查 `schema`、`serial`、`min_plugin`，以及有没有本机架构的文件。
3. 检查空间（12.6 节）。
4. 下载 `.gz` 到 `/tmp`，核对大小和 `sha256`。
5. 解压到 `/koolshare/bifrost/bin/bifrostd.new`，核对 `raw_sha256`。写入失败就删掉这个文件并停止，已安装的核心不受影响。
6. 试运行：`bifrostd.new --version` 输出的版本要和清单一致。
7. 把 `tailscaled.state` 复制一份作为快照。
8. 停止 daemon；把 `bifrostd` 改名为 `bifrostd.old`，把 `bifrostd.new` 改名为 `bifrostd`；启动。
9. 60 秒内检查：进程在，`status --json` 有回应，`BackendState` 和更新前相同。
10. **通过**：把新清单存为已安装清单。空间够时把 `bifrostd.old` 压成 `bifrostd.prev.gz`，然后删掉 `bifrostd.old`。
11. **不通过**：停止，把 `bifrostd.old` 改回 `bifrostd`，恢复 state 快照，启动，报告失败原因。

每一步的进度写到 `/tmp/upload/bifrost_update.json`，页面轮询显示。更新期间 tailnet 连接会中断几十秒，页面先说明。

### 12.5 回退

- 「回退到上一版」用本地的 `bifrostd.prev.gz`，走 12.4 节第 5 步以后的流程，不检查 `serial`。
- 没有保留上一版时，按钮置灰，说明可以重新安装插件包来恢复包里带的核心。
- 手动回退不恢复 state 快照。旧核心读不了新 state 的话，页面给出「恢复更新前的登录状态」的选项，并说明可能需要重新登录。

### 12.6 空间

- 平时占用：一个不压缩的核心，加一个可选的 `prev.gz`。
- 更新时的峰值：当前核心加新核心，再加可选的 `prev.gz`。
- 规则：
  - 解压新核心前，剩余空间少于新核心的 `raw_size` 时，先删 `prev.gz`；还不够就停止，提示清理空间或使用 USB2JFFS。
  - 更新成功后，剩余空间放不下 `prev.gz` 时就不保留，并在页面上说明「没有保留上一版」。
- JFFS2 和 UBIFS 会压缩，`df` 的数字偏保守。以解压是否成功为准，不提前拒绝。

### 12.7 镜像

- `bifrost_mirror` 不为空时，下载地址是「镜像前缀 + 原始地址」。
- 下载用 `curl -fsSL --connect-timeout 10 --max-time 300 --retry 2`。
- 镜像不可信也没关系，签名和哈希会挡住被改过的文件。
- 检查更新不调用 GitHub API，避免未登录的频率限制。

## 13. 页面

### 13.1 技术

页面直接使用 Kumo 的 React 组件，不自己仿写样式。嵌入、构建、资源命名、安装替换和测试都照 po0fw 的 `asus-merlin/web` 做（2.9 节），能复制的代码直接复制，并写明来源提交。

| 用途 | 选型 |
|---|---|
| 组件和主题 | `@cloudflare/kumo` |
| 框架 | React 19、TypeScript |
| 样式 | Tailwind CSS 4，由 PostCSS 处理。先引入 Tailwind，再引入 Kumo 的 Tailwind 样式 |
| 构建 | `build.mjs`：esbuild 打成一个 IIFE 脚本，Tailwind 生成 CSS，再做 13.2 节的处理 |
| 图标 | `@phosphor-icons/react`，按图标路径引入 |
| 字体 | 系统字体，不带字体文件 |
| 语言 | 两份 TypeScript 字典和一个 `t()` 函数，不用 `i18next`（13.9 节） |
| 二维码 | 一个 MIT 许可的小库 |
| 测试 | `node --test`、`playwright-core` |
| 包管理 | npm，`package-lock.json` 进仓库；Node.js 22.18 或更新 |

- 依赖版本精确固定，和 po0fw 的 `asus-merlin/web/package.json` 保持一致。写这份方案时是 Kumo 2.19.0、React 19.3.1、Tailwind CSS 4.3.5、esbuild 0.28.2、TypeScript 7.0.2、`playwright-core` 1.65.1。升级 Kumo 时两个项目一起评估。
- 只按组件路径引入（`@cloudflare/kumo/components/...`）。不用 `chart`、`code`、`flow` 这类组件，它们会带进 echarts 和 shiki。
- 不用 `TagInput`（nezha-kumo-theme 给它打过补丁）。宣告网段用普通输入框加列表。
- 不用 `CloudflareLogo` 组件，页面上不出现 Cloudflare 的名称和标志。
- 页面不加载任何外部资源（字体、CDN、统计）。路由器后台要能离线使用。
- 体积预算：构建时检查未压缩的大小，JS 不超过 800,000 字节，CSS 不超过 160,000 字节，超了就构建失败。po0fw 的上限是 600,000 和 120,000 字节；本项目多了表格、标签页、对话框、Toast、二维码和两份字典，所以放宽。M4 把实测值写回本节。
- 浏览器要求：Chrome 或 Edge 123、Safari 17.5、Firefox 128 及更新版本。这是 Tailwind CSS 4 和 `light-dark()` 的要求。脚本先检测，不支持时在挂载点显示一句提示，不渲染应用。

### 13.2 嵌入方式

做法和 po0fw 相同：`Module_bifrost.asp` 保留固件的外壳，Kumo 应用挂在外壳里一个 `div` 的 Shadow DOM 上。

- Kumo 的样式是全局的（2.9 节）。放进 Shadow DOM 后只作用在里面，固件的菜单和页头不受影响，固件的样式也进不来。
- 应用和外壳在同一个文档里，接口请求带着路由器的登录状态，页面高度和滚动也不用另外处理。
- 不提供「在新标签页打开」。

**外壳**（`plugin/bifrost/webs/Module_bifrost.asp`，模板）：

- 加载固件的菜单和页头脚本，用 `show_menu()` 生成菜单。
- `<body>` 行同时含 `id="app"`、`skin`、`onload`，`skin` 的值取 `nvram get sc_skin`。这样安装器不会改页面（2.4 节）。外壳里不出现 `rogcss` 这个词。
- 内容区放 `<div id="bifrost-app"></div>`。
- 用 `<script defer src="/res/bifrost-app.__BIFROST_ASSETS__.js">` 引用应用。构建时把占位符换成摘要。
- 外壳不写自己的样式。

**挂载**（`web/src/main.tsx`）：

1. 在 `#bifrost-app` 上建 open 模式的 shadow root。
2. 在 shadow root 里放 `<link rel="stylesheet">`。地址由脚本自己的地址（`document.currentScript.src`）把 `.js` 换成 `.css` 得到。
3. 建一个主题容器，写 `data-mode`（13.8 节）。容器里放应用的根节点和一个弹出层容器。
4. CSS 加载完、读到界面设置之后再渲染。CSS 加载失败时，挂载点显示一句中英文并列的「样式加载失败，请刷新」。
5. `KumoPortalProvider` 的容器设为弹出层容器。对话框、下拉框、提示和 Toast 都挂在 shadow tree 里。

**构建对 CSS 的处理**（照搬 po0fw 的 `build.mjs`）：

- 删掉 Tailwind `--tw-*` 变量的 `@property`，把初始值写成 `@layer properties` 里的普通声明（2.9 节）。
- Tailwind 的 `@source` 只指向实际打包进脚本的 Kumo 模块，不扫整个包。
- `:host` 上写 `display: block`、最大宽度和系统字体；窄宽度用容器查询处理。

**资源命名**：

- `/res/` 下的地址不能带查询串（2.9 节）。
- JS 和 CSS 的内容合起来算 sha256，取前 20 位十六进制，文件名是 `bifrost-app.<摘要>.js` 和 `bifrost-app.<摘要>.css`。只改 CSS 时脚本的文件名也会变，浏览器不会用缓存里的旧文件。
- 构建把摘要填进外壳模板，生成要打包的 `Module_bifrost.asp`。
- 文件直接放在 `/koolshare/res/` 下，不建子目录。安装时的替换顺序见 15.1 节。

**弹出层**：

- `Select` 一律用 `modal={false}`。原因见 2.9 节「模态的问题」。
- 语言和外观切换也用 `Select`，和 po0fw 的主题切换相同，不用 `DropdownMenu`。

要在开发机上确认的一点【待实测】：

| 问题 | 首选做法 | 不行时的做法 |
|---|---|---|
| 模态对话框放在 shadow tree 里、外面是固件外壳时，遮罩是否盖住整个页面（包括固件菜单），焦点是否留在对话框里，按 Esc 关闭后遮罩是否完全消失。po0fw 没有用过对话框 | 用 Kumo 的 `Dialog`。先在本地预览里用页面测试验证，再在开发机上人工走一遍 | 二次确认改用非模态的 `Popover`：贴着按钮弹出，里面放确认按钮 |

### 13.3 结构

- 页头：插件名、当前状态的标记、语言切换、外观切换、「返回软件中心」按钮（调用固件的 `reload_Soft_Center()`）。
- 五个标签页：**概览、设备、设置、核心、诊断**。
- 登录不单独占一页。「需要登录」时，概览页整页显示登录入口；登录后显示状态。这样用户第一眼看到的总是当前最该做的事。
- 布局按固件内容区的宽度设计。浏览器窗口变窄时，用容器查询保证 420 px 宽度下仍然能完成登录和改设置。

### 13.4 各页内容

**概览**

- 顶部一行：当前状态（7.1 节）和主按钮（启用、登录、连接、停用）。
- 运行中时显示：
  - 本机：设备名、tailnet IPv4 和 IPv6、MagicDNS 名、所属 tailnet、控制服务器（不是官方时才显示）；
  - 连接：首选 DERP 及延迟、UDP 是否可用、有没有端口映射；
  - 路由：宣告的网段和各自的批准状态、是不是出口节点、是否接受路由；
  - 密钥到期时间，少于 14 天时提醒；
  - 版本：插件版本、核心版本、有没有新核心；
  - 健康提示：tailscaled 的 `Health` 列表原文，加上 Bifrost 自己的检查结果（规则不完整、固定设置被改、守护放弃重启等）。
- 检测到原版时显示迁移入口。

**设备**

- 一张表：设备名、tailnet IP、系统、在线状态、连接方式（直连、对端中继、DERP 中继及区域）、最近握手时间、收发流量、是不是出口节点、宣告的网段。
- 默认在线的排前面，可以按名称筛选。
- 每行一个「ping」按钮，结果显示在行内。
- 设备很多时只渲染前 200 行，其余用筛选找。

**设置**

- 分三组：路由（宣告网段、出口节点、接受路由）、访问控制（本机访问、局域网访问 tailnet、源地址转换、MagicDNS）、其他（设备名、端口、日志上传、镜像）。
- 每项旁边有一句说明。字段和校验见第 8 节。
- 每项单独保存。保存后显示读回来的值。

**核心**

- 当前核心：Tailscale 版本、revision、架构、文件大小、安装时间。
- 「检查更新」：显示最新版本和发布说明链接。
- 「更新核心」：带进度。
- 「回退到上一版」。
- 内核是 `aarch64` 并且发布了 arm64 核心时，显示「切换到 arm64 核心」。
- 编译配方的摘要（省略的功能、Go 版本）和核对哈希的方法。

**诊断**

- 「网络检测」：`netcheck` 的结果，显示 UDP、IPv4、IPv6、端口映射方式、各 DERP 延迟。
- 环境检查：`/dev/net/tun`、iptables 规则是否齐全、是否和原版冲突、WAN 地址是不是运营商级 NAT、JFFS 剩余空间、时间是否已同步。
- 日志：daemon 日志和脚本日志的最后 200 行，已脱敏。
- 「复制诊断信息」：把脱敏后的状态、设置、环境检查和日志合成一段文本，方便贴到 issue。
- 「清除登录状态」（7.5 节）。

### 13.5 组件

| 界面元素 | Kumo 组件 |
|---|---|
| 标签页 | `Tabs` |
| 状态、在线、直连、中继的标记 | `Badge` |
| 健康提示、冲突、警告 | `Banner` |
| 设备列表 | `Table`，筛选用 `Input` |
| 开关类设置 | `Switch` |
| 文本类设置 | `Input`、`Field`、`Label` |
| 三选一（源地址转换） | `Select`（`modal={false}`） |
| 预授权密钥 | `SensitiveInput` |
| 登录的高级选项 | `Collapsible` |
| 二次确认 | `Dialog`（13.2 节的【待实测】项） |
| 保存结果 | `Toast` |
| tailnet IP、MagicDNS 名、登录链接、诊断信息的复制 | `ClipboardText`、`InlineCopyText` |
| 语言和外观切换 | `Select`（`modal={false}`） |
| 更新进度 | `Meter` |
| 加载中、没有设备 | `Loader`、`SkeletonLine`、`Empty` |
| 说明文字的补充 | `Tooltip` |
| 卡片容器 | `LayerCard`、`Surface` |

这些组件在 2.18.1 和 2.19.0 里都有【已核实】。具体的导出名字以实际代码为准。Kumo 里没有的东西（二维码、路由批准状态的列表）用 Kumo 的变量和 Tailwind 的工具类自己写，不引入别的组件库。

### 13.6 接口

页面只用三种请求，写法照 po0fw 的 `api.ts`（2.9 节），都带 `cache: "no-store"`：

- `GET /_api/bifrost`：读 dbus 里 `bifrost_` 开头的键。页面只用它取 `bifrost_ui_lang` 和 `bifrost_ui_mode`，其余设置以状态文件为准。这些键里没有密钥（4.2 节）。
- `GET /_temp/<文件名>`：读脚本写在 `/tmp/upload/` 下的文件。
- `POST /_api/`：执行脚本。`method` 是脚本名，`params` 的第一个元素是动作，`fields` 永远是空的：软件中心会把 `fields` 不经校验直接写进 dbus（2.4 节）。

| 脚本 | 动作 | 参数 | 说明 |
|---|---|---|---|
| `bifrost_status.sh` | — | — | 刷新 `/tmp/upload/bifrost_status.json` 并回应。页面可见时每 3 秒调一次，不可见时停止 |
| `bifrost_config.sh` | `enable` / `disable` | — | 启用或停用 |
| | `connect` | — | 「已停止」时重新连接 |
| | `login` | 服务器地址、预授权密钥，都可以为空 | 后台执行 |
| | `relogin` / `logout` / `purge` | — | 7.5 节 |
| | `set` | 键、值 | 第 8 节里的一项 |
| | `migrate` | — | 后台执行，结果在 `bifrost_migrate.json` |
| | `core-check` / `core-update` / `core-rollback` / `core-arch` | `core-arch` 带架构名 | 后台执行，进度在 `bifrost_update.json` |
| | `netcheck` | — | 结果在 `bifrost_netcheck.json` |
| | `ping` | 设备的 tailnet IP | 只接受当前设备列表里的 IP |
| | `logs` | — | 脱敏后写到 `bifrost_logs.txt` |
| | `ui` | 语言、外观 | 只校验并写入 `bifrost_ui_lang` 和 `bifrost_ui_mode`，不做别的事 |

- 脚本的第一个参数：是数字就当作请求 ID，动作取第二个参数；是 `local` 就是内部调用（守护）；是 `start`、`stop`、`start_nat` 就是软件中心的钩子。其他值一律拒绝。
- 短动作直接回应结果。长动作立刻回应「已开始」，在后台继续，页面轮询对应的文件。
- 回应统一是一行 JSON：`{"ok":true}` 或 `{"ok":false,"code":"...","msg":"..."}`。`code` 是固定的英文短词，页面按它显示中文。
- 页面里也做输入校验，但只是为了及时提示。真正的校验在脚本里（第 14 节）。

### 13.7 状态文件

`bifrost_status.json` 的结构（示例数据）：

```json
{
  "schema": 1,
  "time": 1795430000,
  "state": "running",
  "plugin": { "version": "0.1.0", "enabled": true },
  "core": { "tailscale": "1.104.7", "revision": 1, "arch": "arm", "update": null },
  "conflict": { "original_installed": true, "original_running": false },
  "self": {
    "hostname": "router", "dns_name": "router.example.ts.net",
    "ips": ["100.64.0.1"], "tailnet": "example.ts.net",
    "control": "", "key_expiry": "2027-05-01T00:00:00Z"
  },
  "prefs": {
    "advertise_routes": ["192.168.1.0/24"], "advertise_exit_node": false,
    "accept_routes": false, "hostname": ""
  },
  "routes": [{ "cidr": "192.168.1.0/24", "approved": true }],
  "settings": {
    "port": 41641, "local_access": true, "lan_masq": true,
    "snat": "auto", "magicdns": false, "no_logs": true, "mirror": ""
  },
  "auth_url": "",
  "health": [],
  "peers": [{
    "name": "laptop", "ip": "100.64.0.2", "os": "macOS", "online": true,
    "path": "direct", "relay": "", "last_handshake": 1795429990,
    "rx": 1024, "tx": 2048, "exit_node_option": false, "routes": []
  }]
}
```

- 用 `jq` 从 `status --json` 和 `debug prefs` 里挑字段生成。不把完整的状态交给页面，密钥类字段不出现。
- `auth_url` 只在「需要登录」时有值。
- 脚本依赖软件中心自带的 `/koolshare/bin/jq`。安装时检查，没有就拒绝安装并说明。

### 13.8 外观

- 三种外观：深色、浅色、跟随系统。默认深色（第 9 项决定）。四种固件皮肤都是深色，浅色面板放在里面反差太大。
- 外观写在 shadow tree 里主题容器的 `data-mode` 上，同时设好 `color-scheme`。不改固件页面的 `<html>`。
- 选择存在路由器的 dbus 里（`bifrost_ui_mode`），换设备、换浏览器后仍然有效。做法和 po0fw 的主题切换相同：
  - 切换后立即生效，然后发一个 `ui` 请求保存；
  - 保存期间切换控件不可用；
  - 保存失败时换回原来的外观，并显示错误；
  - 读到的值不认识时按深色处理，不回写。
- 固件的四种皮肤（`ASUSWRT`、`ROG`、`TUF`、`TS`）只影响外壳。应用在 Shadow DOM 里，颜色不随皮肤变。

### 13.9 语言

- 两种语言：简体中文和英文。默认简体中文。页头有语言切换。
- 取值顺序：dbus 里的 `bifrost_ui_lang` → 简体中文。不按浏览器语言自动选。保存方式和外观相同（13.8 节）。
- 所有界面文字放在 `web/src/i18n/zh-CN.ts` 和 `en.ts` 两份字典里，组件里不写死文字。
  - 中文字典是基准。英文字典的类型是 `Record<keyof typeof zhCN, string>`，少一个键或多一个键，类型检查都不通过。
  - `t(key, vars)` 只支持 `{name}` 这种占位符。
  - 不用 `i18next`：两种语言、几百条文字，一个小函数就够，也少一个依赖。
- Kumo 组件自带的文字用 `KumoLocaleProvider` 提供两种语言。
- 脚本返回的错误只有 `code`（13.6 节），页面按 `code` 显示当前语言的文字。脚本不输出给用户看的句子。
- 不翻译的内容：tailscaled 的健康提示原文、日志、命令输出。
- 脚本日志用英文。安装和卸载时显示在软件中心日志窗口里的提示用中文；软件中心里的插件名称和简介也用中文，因为软件中心只有中文界面。
- 用词规则：
  - 中文：用「设备」不用「节点」或「peer」；用「网段」不用「子网」；Tailscale 的专有名词（tailnet、MagicDNS、DERP）保留原文，第一次出现时加一句解释。
  - 英文：用 Tailscale 官方文档里的说法（device、subnet router、exit node、auth key）。
- 每个设置的说明写清楚「打开后会发生什么」，不只写选项名。
- README 做中英双语。

### 13.10 脱敏

显示日志和生成诊断信息之前做替换：

| 内容 | 替换成 |
|---|---|
| 公网 IPv4 地址（不含私有网段和 `100.64.0.0/10`） | `<ipv4>` |
| IPv6 地址（不含 `fd7a:115c:a1e0::/48`） | `<ipv6>` |
| 邮箱地址 | `<email>` |
| MagicDNS 后缀和 tailnet 名 | `<tailnet>` |
| 登录链接 | `<auth-url>` |
| `tskey-` 和 `hskey-` 开头的字符串 | `<key>` |
| MAC 地址 | `<mac>` |

设备名和 tailnet IP 保留，排查问题要用。诊断信息顶部写明做过哪些替换。

### 13.11 测试

做法照 po0fw（2.9 节），预览服务器、测试夹具和安装测试脚本从那边复制后改写。

- **类型检查**：`tsc --noEmit`。两份字典的键是否一致也由它检查。
- **单元测试**（`node --test`）：状态到界面的映射、输入校验函数、接口封装、`t()` 的占位符替换。
- **预览服务器**（`web/preview/server.mjs`，`npm run preview`）：
  - 提供固件外壳的桩：只实现外壳用到的几个全局函数，比如 `show_menu()`、`reload_Soft_Center()`；
  - 内存里有一份假 dbus 和假脚本，`/_temp/` 返回示例数据；
  - 和路由器一样，`/res/` 下带查询串的请求返回 404。
- **页面测试**（`node --test` 加 `playwright-core` 驱动 Chromium）：每个测试都断言没有脚本错误、没有发往外部的请求。覆盖：
  - 挂载：应用和所有弹出层都在 shadow root 里，外观和设置一致，外壳的元素不受影响；
  - 首屏：读到界面设置和状态之前不渲染，初始化完成前动作按钮不可用；
  - 每个页面状态（7.1 节）、每个设置的保存和报错、登录流程、更新流程、迁移流程；
  - 语言和外观切换：只发一个 `ui` 请求；失败时换回原值；新开一个浏览器上下文能读到新值；
  - 对话框：13.2 节的【待实测】项先在这里测；
  - 漏翻检查：中文界面下没有没翻译的英文句子，专有名词放在白名单里。思路来自 nezha-kumo-theme 的 `i18n.spec.ts`；
  - 体积：实际加载的 JS 和 CSS 在预算内（13.1 节）；
  - 缓存升级：先装上一版页面再换新版，只改 CSS、只改 JS 两种情况下浏览器都拿到新文件。测试里不拦截请求，用真实的浏览器缓存。
- **安装测试**（`web/test/install-upgrade.sh`）：在断网的 BusyBox 1.25 容器里，先装上一版再覆盖安装，检查 `/koolshare/res/` 下只剩当前这一对资源，页面引用的正是它们；再卸载，检查都删干净了。
- **截图**：每个页面状态一张（深色、中文）；浅色和英文各一组主要页面；420 px 宽度一组。只用示例数据。
- **外壳**：固件真实的菜单脚本和样式不能放进仓库，预览用的是桩，所以真实外壳只能在开发机上看。开发机是 `ASUSWRT` 皮肤；`ROG`、`TUF`、`TS` 没有设备。
- 示例数据里不出现真实的 tailnet 名、地址和设备名。

## 14. 脚本规范

- 只用 BusyBox `/bin/sh` 的语法。检查：`busybox sh -n` 和 `shellcheck -s sh`。
- 不用 `local`（POSIX `sh` 没有，`shellcheck -s sh` 会报）。函数里的变量加函数名前缀，或者把函数体写成子 shell。
- 判断命令是否存在用 `type`，不用 `command -v`。
- 不用这些命令：`sha256sum`、`xz`、`od`、`mktemp`、`timeout`、`setsid`、`stat`、`start-stop-daemon`。临时文件放在 `/tmp/bifrost-run/` 下，用固定名字加 PID。
- `iptables` 不加 `-w`。
- 不用 `eval`，尤其不用 `eval $(dbus export ...)`。每个键单独用 `dbus get` 读，读出来先校验再用。
- 所有外来的值（页面参数、dbus 值、nvram 值、命令输出里要拼进命令的部分）先过白名单校验。校验函数集中在一个文件里，每个都有测试。
- 变量展开都加双引号。
- 改状态的动作先取锁。锁用 `mkdir`，带超时和过期清理。
- 调用可能卡住的命令（命令行、`curl`）都带超时。
- 写文件用「写到临时文件，再 `mv`」，避免页面读到写了一半的 JSON。
- 密钥和登录链接不写日志。
- CI 里有一份禁用清单，用 `grep` 检查上面这些写法，出现就失败。

## 15. 安装、升级、卸载

### 15.1 安装和升级

`install.sh` 由软件中心在 `/tmp/bifrost/` 里执行：

1. **检查环境**：是 Koolshare 软件中心；`uname -m` 是 `armv7l` 或 `aarch64`；有 `/dev/net/tun`，或者能加载 `tun` 模块；有 `jq`、`openssl`、`curl`、`gunzip`。不满足就停止并说明。
2. **判断是新装还是升级**：看 `softcenter_module_bifrost_install`。
3. **升级时**：记下 daemon 是否在运行，然后停止。
4. **装核心**：
   - 把 `bin/bifrostd.gz` 解压到 `/koolshare/bifrost/bin/bifrostd.new`；
   - 按包里的 `core.json` 核对 `raw_sha256`，试运行 `--version`；
   - 通过后改名为 `bifrostd`，建 `tailscale` 符号链接；
   - 不通过（空间不足或文件损坏）就删掉 `.new`。升级时保留旧核心继续用，并提示；新装时停止安装并清理。
   - 升级时，如果已安装的核心比包里的新（`serial` 更大），保留已安装的，不降级。
5. **装其他文件**：脚本、库、图标、公钥、许可证。`uninstall.sh` 复制为 `/koolshare/scripts/uninstall_bifrost.sh`；建 `init.d` 的两个符号链接和 `/koolshare/bin/bifrost`。
6. **换页面**，顺序照 po0fw 的 `install.sh`，保证外壳引用的资源始终完整：
   1. 从包里的 `Module_bifrost.asp` 读出资源文件名，确认包里有这一对 JS 和 CSS；
   2. JS、CSS 各自先复制成 `/koolshare/res/` 下的临时文件，再 `mv` 成正式文件名；
   3. 用同样方式替换 `/koolshare/webs/Module_bifrost.asp`；
   4. 外壳换好后，删掉 `/koolshare/res/` 下其他符合 `bifrost-app.<20 位十六进制>.js` 或 `.css` 的文件；
   5. 前三步任何一步失败就停止安装。如果外壳还指向旧资源，删掉刚复制的新资源。
7. **登记**：写 `softcenter_module_bifrost_*`。新装时写各设置的默认值；升级时保留已有的值，只补上新增的键。
8. **升级时**：之前在运行就重新启动。
9. **新装时**：不启动。检测到原版时，在安装日志里提示可以到页面里迁移。
10. state 目录在安装和升级时都不动。

安装和卸载先取同一把锁（第 14 节），避免两次安装同时换页面、删旧资源。

### 15.2 卸载

`uninstall_bifrost.sh`：

1. 停止 daemon（6.3 节）。
2. 删掉守护任务、防火墙链、dnsmasq 配置。
3. 删掉 `/koolshare/bifrost/`、`/koolshare/res/` 下符合 `bifrost-app.<20 位十六进制>.js` 或 `.css` 的文件和安装留下的临时文件、脚本、外壳页面、图标、`init.d` 链接、`/koolshare/bin/bifrost`、`/tmp/bifrost-run/`、`/tmp/upload/bifrost_*`。
4. 删掉 `bifrost_*` 和 `softcenter_module_bifrost_*`。
5. **保留** `/koolshare/configs/bifrost/`。重新安装后不用再登录。

- 软件中心的卸载没有选项界面。想彻底清除的用户，卸载前先在诊断页点「清除登录状态」。README 里写明 state 目录的位置。
- 卸载不退出登录。设备在控制台里显示为离线，需要的话用户自己删除。

## 16. 仓库、打包、发布、CI

### 16.1 仓库结构

```text
core/
  recipe.json              核心编译配方
  build.sh                 编译脚本（本地和 CI 共用）
plugin/bifrost/            软件中心插件，目录结构就是包的结构
  .valid  version  install.sh  uninstall.sh
  scripts/                 bifrost_config.sh、bifrost_status.sh
  lib/                     common.sh、validate.sh、daemon.sh、fw.sh、dns.sh、
                           login.sh、migrate.sh、update.sh、diag.sh
  webs/Module_bifrost.asp  外壳模板，含资源摘要的占位符
  res/                     icon-bifrost.png；bifrost-app.<摘要>.js/.css 由页面构建生成，不进仓库
  keys/                    签名公钥
web/                       页面应用，结构照 po0fw 的 asus-merlin/web
  package.json  package-lock.json  tsconfig.json
  build.mjs                构建：esbuild、Tailwind、@property 改写、体积检查、资源命名、生成外壳
  src/main.tsx             挂载 Shadow DOM
  src/app/                 应用、状态、外观和语言
  src/pages/               五个标签页
  src/components/          页面自己的组件
  src/core/                接口封装、数据模型、输入校验
  src/i18n/                zh-CN.ts、en.ts、t()
  preview/                 预览服务器和固件外壳的桩
  test/                    页面测试、安装测试、示例数据
  dist/                    构建生成的 Module_bifrost.asp，不进仓库
tests/
  shell/                   脚本测试和假命令
  container/               容器测试环境
packaging/build.sh         打包脚本
.github/workflows/         ci.yml、core.yml、release.yml
docs/                      方案和开发说明
NOTICE.md                  第三方声明
```

### 16.2 包

- 文件名：`bifrost-<版本>-hnd.tar.gz`。顶层目录是 `bifrost/`。
- `.valid` 的内容是 `hnd`。以后支持其他平台时，在这个文件里加平台名，或者按平台分包。
- `bin/` 里是 `bifrostd.gz` 和它的 `core.json`。
- 打包脚本从指定的核心发布下载核心，验签名和哈希后才放进包里。
- 包里带 `LICENSE`（MIT）、`LICENSE.tailscale`（BSD-3-Clause）和第三方声明 `NOTICE.md`。
- 打包前先构建页面应用，包里用构建生成的 `Module_bifrost.asp` 和对应的一对资源。构建结果不进仓库。

### 16.3 版本号

- 插件 tag：`v0.x.y`。
- 核心 tag：`core-<Tailscale 版本>-<revision>`。同一个 Tailscale 版本重新编译时 revision 加 1。
- 插件和核心各自发布。插件版本说明里写明包里带的是哪个核心。

### 16.4 CI

| 工作流 | 触发 | 内容 |
|---|---|---|
| `ci.yml` | 每次推送和 PR | 脚本语法检查、`shellcheck`、禁用清单；脚本测试；页面的类型检查、单元测试、构建、体积检查、页面测试和安装测试；用 featuretags 校验配方；检查仓库里没有私人信息（地址、tailnet 名、绝对路径的常见形式） |
| `core.yml` | 推送 `core-*` tag | 两个独立的 job 各编译一次并比对哈希；用编出来的核心跑容器冒烟测试；生成清单；签名；生成构建来源证明；发布；更新 `channel-stable` |
| `release.yml` | 推送 `v*` tag | 构建页面；打包；生成 `SHA256SUMS` 并签名；生成构建来源证明；发布。tag 已有发布时拒绝覆盖 |

## 17. 测试

### 17.1 层次

| 层 | 测什么 | 在哪里跑 |
|---|---|---|
| 脚本单元测试 | 校验函数、登录命令的构造、防火墙规则的生成（和预期文件比对）、状态 JSON 的生成、脱敏 | CI 和本机。用假的 `dbus`、`nvram`、`iptables`、`tailscale` 命令 |
| 页面测试 | 13.11 节 | CI 和本机 |
| 容器集成测试 | 真实的核心加真实的脚本：启动、登录、设置、防火墙、更新、回退 | CI 和本机 |
| 开发机验收 | 每个里程碑的验收项 | 开发机 |

### 17.2 容器环境

- 一个带 BusyBox、iptables、`/dev/net/tun` 的容器，里面放一套假的软件中心（`dbus` 用文件存键值，`nvram` 返回固定值，`http_response` 写到文件）。核心用同一份配方按容器的架构编译，只用于测试。
- 另一个容器运行 headscale，版本固定。
- 用途：
  - **headscale 的登录流程**。开发机登录的是 Tailscale 官方，不能为了测试切到 headscale。
  - **防火墙规则的行为**。再起一个容器当 tailnet 里的另一台设备，检查能不能访问、该挡的有没有挡住。
  - **核心更新的失败场景**。可以放心地篡改文件、填满磁盘、让新核心启动失败。
  - **发布核心前的冒烟测试**。检查新版本的命令行输出和脚本用到的字段还对得上。
- 容器里的 BusyBox 比开发机新，功能更多。开发机特有的限制靠禁用清单保证（第 14 节）。

### 17.3 在开发机上测试的规程

开发机同时是家里的子网路由。停掉原版会中断从 tailnet 到家里局域网的访问。

- 能在容器里验证的，先在容器里验证。
- 会中断 tailnet 的操作只在维护窗口做，并且人在局域网里，用局域网的 SSH 连着。
- 每次操作前写明回滚步骤。会替换的文件先备份。
- 停止任何插件都通过它自己的脚本，不直接杀进程。
- 路由器地址、登录方式和变更记录只写在本地的 `AGENTS.local.md` 里。

## 18. 里程碑

每一步都写明验收方法。带 ★ 的验收项会中断开发机的 tailnet，按 17.3 节执行。

| 里程碑 | 内容 | 验收 |
|---|---|---|
| M0 | 仓库骨架：本文件、README、LICENSE、AGENTS.md | 已完成 |
| M1 | 核心：`core/recipe.json`、`core/build.sh`，编出 arm 和 arm64 核心；测量 | 1. 配方通过 featuretags 校验。<br>2. macOS 本机和 Linux CI 各编一次，两种架构的 sha256 都相同。<br>3. 两个核心在开发机上运行 `version`，输出配方里的版本和提交。<br>4. 把核心写到开发机的内置 JFFS2 分区，记录 `df` 的变化和首次启动耗时，然后删除。<br>5. ★ 用原版 state 的副本分别启动两种核心，各测：经 tailnet 的 iperf3 吞吐、运行 10 分钟后的常驻内存、24 小时内 state 目录的写入次数。测完恢复原版。<br>6. 按 5.3 节的规则决定是否发布 arm64；按 5.5 节决定是否需要 UPX 版；结论写回本文件 |
| M2 | 最小插件：安装、卸载、启停、守护、基本防火墙、登录（含控制服务器和预授权密钥）、状态、迁移；外壳页面里先放几个原生按钮（启停、登录链接、状态文字），不含 Kumo 应用；容器测试环境 | 1. 新装、升级、卸载各做一遍。卸载后检查清单里的每一项都不在了，state 目录还在。<br>2. 容器里：交互式登录、预授权密钥登录、登录到 headscale，都能进入「运行中」。<br>3. ★ 确认原版的停止方式（11.2 节第 4 步）。<br>4. ★ 迁移后设备 ID 和公钥不变，不用重新登录，从 tailnet 能访问局域网设备。<br>5. ★ 人为让迁移验证失败，确认自动回到原版并且原版恢复工作。<br>6. ★ 执行 `service restart_firewall`：10 秒内规则恢复，daemon 的 PID 不变，tailnet 上正在进行的连接不断。<br>7. ★ 重启路由器后自动恢复到「运行中」。<br>8. ★ 强制结束 daemon，守护在 3 分钟内把它拉起来；连续失败 3 次后停止重试并在状态里说明。<br>9. ★ 核对 9.2 节里标了【待实测】的后台 DNAT；核对 7.2 节的登录超时行为 |
| M3 | 设置：第 8 节的全部设置项；DNS | 1. 每项改完后读回 prefs、dbus、iptables 或 dnsmasq 配置，和提交的值一致。<br>2. 每项都用一组非法输入测试，全部被拒绝，系统状态不变。<br>3. 容器里：关掉「允许访问本机」后，另一台设备访问不了路由器的端口，但能访问它后面的网段、能 ping 通。<br>4. 容器里：三种源地址转换设置下，对端看到的源地址符合预期。<br>5. ★ 打开 MagicDNS 后，局域网设备能解析 tailnet 主机名；关掉后配置文件被删除 |
| M4 | 新页面：Kumo 应用挂在 Shadow DOM 上、五个标签页、中英文、深浅色 | 1. 类型检查、单元测试、页面测试、安装测试全部通过，体积在预算内；实测体积写回 13.1 节。<br>2. 中文界面下没有漏翻的英文句子。<br>3. 截图齐全（13.11 节），只用示例数据。<br>4. 在开发机上确认 13.2 节的【待实测】项，并按结果定下做法。<br>5. 在开发机上逐页人工走一遍，对照 13.4 节的内容清单；两种语言、两种外观各走一遍主要页面。<br>6. 在开发机上换一台设备打开页面，语言和外观和上次的选择一致。<br>7. 在开发机上覆盖安装一次，页面不用强制刷新就是新版，`/koolshare/res/` 下只剩一对资源。<br>8. 断开外网时页面能完整显示。<br>9. 外壳不写自己的样式。`ROG`、`TUF`、`TS` 没有设备，发布说明里写明没有实测 |
| M5 | 核心更新：检查、下载、验签、替换、失败恢复、回退、镜像、架构切换 | 容器里逐项验证，每项都要求拒绝安装并且旧核心继续运行：<br>1. 改了清单内容；<br>2. 改了签名；<br>3. 改了核心文件；<br>4. 拿旧的清单和签名（`serial` 更小）；<br>5. 下载中断；<br>6. 磁盘写满；<br>7. 新核心能通过试运行但启动后不工作，60 秒后自动换回旧核心。<br>另外：经镜像前缀下载成功；回退成功。<br>★ 在开发机上做一次真实的更新和一次回退 |
| M6 | 开源发布 | 中英文 README、示例数据截图、CHANGELOG、三个工作流都跑通、第一个核心发布和第一个插件发布、发布物里带两份许可证 |

## 19. 风险

| 风险 | 应对 |
|---|---|
| 开发机是家里在用的路由器，测试会影响家里的网络 | 17.3 节的规程；尽量用容器 |
| 小 JFFS 的机型装不下不压缩的核心 | 包里用 gzip；M1 实测实际占用；必要时出 UPX 版 |
| 上游改了命令行的输出或参数 | 核心版本固定，更新由我们发布；发布前用容器冒烟测试核对脚本用到的字段和命令 |
| 防火墙规则自己维护，可能和上游的行为产生差异 | 规则很少；容器测试覆盖子网路由、出口节点、本机访问；每次升级 Tailscale 时对照上游规则的改动 |
| iptables 没有锁，可能和其他插件同时改规则 | 重试，最后逐条确认；守护定期核对 |
| 软件中心改了安装约定 | 约定集中写在 2.4 节；发布前在开发机上实际安装一次 |
| 签名私钥泄露或丢失 | 支持多个公钥，可以轮换；泄露时发一个去掉旧公钥的插件版本 |
| 国内访问 GitHub 不稳定 | 镜像前缀；签名保证镜像不可信也安全；插件包自带核心，离线可用 |
| headscale 以后的版本不兼容 | 发布说明里写测试过的版本；容器测试里固定版本，升级时重跑 |
| 迁移后用户同时启动两个插件 | 启动前检查冲突并拒绝；README 说明 |
| Kumo 升级后组件的接口或样式变了 | 版本固定，和 po0fw 一起升级；升级时跑一遍页面测试，比对截图 |
| 页面体积变大，挤占 JFFS | 构建时检查体积预算；只按组件引入 |
| 模态对话框在 Shadow DOM 里和固件外壳冲突 | 13.2 节的备用做法 |
| 新版 Kumo 依赖 shadow tree 里不生效的 `@property` | 构建脚本改写 Tailwind 的变量；挂载测试检查组件的外观；截图比对 |
| `ROG`、`TUF`、`TS` 皮肤没有设备 | 应用在 Shadow DOM 里，不受皮肤影响；外壳不写自己的样式；发布说明里写明 |
| 两种语言的文字不同步 | 字典键由类型检查保证；漏翻检查 |
| Tailscale 的商标 | 插件名、图标不用 Tailscale 的名称和 logo；写明「非官方」 |

## 20. 开源注意事项

- 插件代码用 MIT 许可。核心是 Tailscale 的代码，许可证是 BSD-3-Clause，安装包和发布页里要附上 Tailscale 的许可证文本。
- 不复制原版的脚本、页面和图标，因为它们没有许可证；也不复制 thetapilla 的代码。可以读原版的文本文件来了解它的调用方式。
- 页面用到的第三方库都在 `NOTICE.md` 和安装包里列出：Kumo（MIT，Cloudflare）、React（MIT）、Base UI（MIT）、Tailwind CSS（MIT）、Phosphor Icons（MIT）、二维码库（MIT）。发布前按实际打包进去的依赖核对一遍。
- 从 po0fw 复制的构建脚本、预览服务器和测试夹具是同一作者的 MIT 代码，复制时在文件头写明来源提交。不复制 po0fw 里的 coss ui 控件。
- 从 nezha-kumo-theme 复制的文件里，改写自 zool-theme 的部分保留原署名。
- 不使用 Cloudflare 的名称和标志。`NOTICE.md` 里写明本项目与 Cloudflare 无关。
- 插件图标不用 Tailscale 的 logo。README 和插件说明里写明「非官方，与 Tailscale Inc. 无关」。
- 仓库里不放私人信息：路由器地址、tailnet 名称、凭据、局域网细节、本机的绝对路径。这些写在本地的 `AGENTS.local.md` 里，该文件已加入 gitignore。测试用的示例数据全部是编的。

## 21. 决定

### 21.1 项目所有者的决定（2026-11-23）

| 编号 | 事项 | 决定 |
|---|---|---|
| 1 | 「允许 tailnet 访问路由器本机」的默认值 | 开 |
| 2 | 是否默认不向 Tailscale 上传日志 | 不上传 |
| 3 | 是否支持 headscale | 支持，范围见 7.4 节 |
| 4 | 支持哪些平台 | v1 只做 HND。包格式留了扩展位置；有人愿意测试其他平台时再加，并标为实验性 |
| 5 | 页面的外观和语言 | 采用 Kumo；中英文可以切换，默认中文 |
| 6 | v1 是否做路由器「使用出口节点」 | 不做 |
| 7 | 工作范围 | 先制定方案；2026-11-23 起按本方案开发，由多个执行者并行完成、集中验收 |
| 8 | 页面的实现方式 | 和 po0fw 的 `asus-merlin` 相同：直接用 Kumo 的 React 组件 |
| 9 | 外观的默认值 | 深色 |
| 10 | 是否提供「在新标签页打开」 | 不提供 |

### 21.2 由核实结果得出的技术决定

| 决定 | 依据 |
|---|---|
| 签名用 ECDSA P-256，不用 Ed25519 | 开发机的 OpenSSL 验不了 Ed25519 |
| tailscaled 的防火墙模式设为 `off`，规则由 Bifrost 管 | 9.1 节 |
| 不用 UPX；包里的核心用 gzip 存放 | 2.5 节的耗时数据；2.4 节的空间检查方式 |
| 编译标签由 featuretags 生成，省略 25 项 | 2.6 节 |
| Tailscale 自己保存的设置只存在 prefs 里 | 第 3 节 |
| 安装不动原版；迁移是页面里的一个动作，失败自动回滚 | 2.8 节 |
| `--accept-dns` 固定为关 | 1.4 节 |
| 包里只带 arm 核心；arm64 是否发布由 M1 的数据决定 | 5.3 节 |
| 核心文件叫 `bifrostd`，socket 用自己的路径 | 4.1 节 |
| 页面的构建、资源命名、安装替换和测试照 po0fw 做，依赖版本和它一致 | 第 8 项决定；2.9 节 |
| Kumo 应用挂在固件外壳里的 Shadow DOM 上，不用 iframe | 13.2 节；po0fw 的正式版已经这样做 |
| 页面资源直接放在 `/res/` 下，文件名带内容摘要，地址不带查询串 | 2.9 节 |

### 21.3 本文自己选的默认做法

这几项没有问过项目所有者，可以改。

| 事项 | 本文的选择 | 换一种的后果 |
|---|---|---|
| 语言的初始值 | 固定为简体中文 | 按浏览器语言选时，英文系统的用户第一次打开就是英文 |
| 语言和外观的选择存在哪里 | 路由器的 dbus，和 po0fw 的主题切换相同，换设备后仍然有效 | 存在浏览器的 localStorage 里时，每台设备、每个浏览器要各选一次，但不用多一个 `ui` 动作 |
| 语言字典 | 两份 TypeScript 字典加一个 `t()` 函数 | 用 `i18next` 的话多两个依赖（`i18next`、`react-i18next`），字典键的检查要另写测试 |
| 是否带 po0fw 的 coss ui 控件切换 | 不带，只用 Kumo | 带的话每个控件要维护两套实现，页面测试翻倍 |
| 脚本日志的语言 | 英文，不翻译 | 做成双语要给每条日志维护两份文字 |
