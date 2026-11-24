# Bifrost 开发文档索引

本目录存放 Bifrost 的架构方案、模块接口约定与开发指南。

## 文档目录

- [PLAN.md](PLAN.md)：完整产品与技术方案（架构、核心编译、运行时、防火墙、DNS、迁移、核心签名更新、前端设计、测试与里程碑）。
- [dev/contract.md](dev/contract.md)：模块间接口约定（文件归属、shell 编写约定、错误码表、状态 / 任务 JSON 格式、跨包函数签名与质量门槛）。
- [../AGENTS.md](../AGENTS.md)：项目硬规则（BusyBox 1.25 兼容性、禁止 UPX 与 `--extra-small`、禁止提交私密信息、路由器操作规程）。
- [../NOTICE.md](../NOTICE.md)：第三方软件许可证与代码来源声明。
- [../packaging/THIRD_PARTY_NOTICES.core.md](../packaging/THIRD_PARTY_NOTICES.core.md)：由 `go version -m` 生成的核心静态链接 Go 模块许可证清单。
- [../CHANGELOG.md](../CHANGELOG.md)：版本变更记录。
- [../release-notes/v0.1.0.md](../release-notes/v0.1.0.md)：首个插件版本的发布说明（由发布工作流直接读取）。

## 本地检查与测试

在仓库根目录执行：

```sh
# 1. 静态检查：shellcheck -s sh、BusyBox 1.25 sh -n、禁用写法扫描
tools/check-sh.sh

# 2. 隐私信息检查（禁止提交路由器地址、真实 tailnet、本机路径、真实密钥）
tools/check-private.sh

# 3. 路由器脚本单元测试（在断网的 BusyBox 1.25 容器中执行）
tests/shell/run.sh

# 4. 安装 / 升级 / 卸载 / 并发锁测试（BusyBox 1.25 容器，使用真实 P1–P3 库）
tests/install/run.sh

# 5. 核心配方校验（需安装与 core/recipe.json 一致的 Go 版本）
core/build.sh --check-recipe

# 6. 前端类型检查、构建（由 pretest 自动触发含体积检查）与 Playwright 页面测试
(cd web && npm ci --include=dev --no-audit --no-fund --ignore-scripts && npm run check && npm test)

# 7. 可复现打包自测（真实前端构建 + 完整性与签名拒错 + BusyBox 安装冒烟）
packaging/test-build.sh

# 8. 容器集成测试（headscale v0.29.7 + 官方 tailscale v1.104.7 + 真实核心 + 真实脚本）
#    需 Docker 支持 --cap-add=NET_ADMIN 与 /dev/net/tun
tests/container/run.sh          # 自动运行 Stage A + Stage B
tests/container/run.sh --full   # 强制执行完整 Stage B 真实核心测试
```

## 打包方法

### 使用本地编译的核心（开发模式）

```sh
# 1. 编译核心到 core/out/
core/build.sh

# 2. 构建前端并打包到 dist/bifrost-<版本>-hnd.tar.gz（校验文件哈希）
packaging/build.sh --core-dir core/out --arch arm --out dist
```

### 使用已发布的签名核心（发布模式）

```sh
# 从 GitHub Release 下载 core.json、core.json.sig 与核心文件，
# 先用 plugin/bifrost/keys/*.pub.pem 验签，再校验哈希后打包：
packaging/build.sh --core-release "$(cat packaging/core-tag)" --arch arm --out dist
```

- 在 macOS 上，`packaging/test-build.sh` 用相同输入、工具和固定时间戳打包两次，并比对 SHA-256。Linux CI 用同一测试在运行器内比对两个包。
- 发布包有四种组合：默认 `hnd`、`hnd-arm64`，以及可选的 `hnd-upx`、`hnd-arm64-upx`（附加 `--variant upx`）。默认包和默认核心类型都是不压缩版。UPX 版每次启动需要独立解压，命令行响应更慢且内存不能共享。
- 相对路径参数（`--core-dir`、`--out`、`--web-dist`、`--keys-dir`）均按调用者当前工作目录解析。
- 已提前构建前端时，可附加 `--web-dist web/dist` 跳过重复构建。

## 升级核心版本后更新第三方 Go 模块声明

静态链接的 Tailscale 核心包含 wireguard-go、`golang.org/x/*` 等数十个 Go 模块。每次更新 `core/recipe.json` 后，请重新生成 `packaging/THIRD_PARTY_NOTICES.core.md`。该文件会自动打进插件包并安装到 `/koolshare/bifrost/`：

```sh
# 1. 编译一个本机可检查的测试核心（确保依赖已缓存在 GOMODCACHE）
core/build.sh --test-arch arm64   # Linux x86_64 可改用 amd64

# 2. 用 Python 3 读取 go version -m 和对应版本的模块缓存，收录许可证及 NOTICE 全文
packaging/gen-core-notices.py core/out/test/bifrostd-linux-arm64
```

## 正式签名密钥的生成与轮换

路由器使用 OpenSSL 1.1.1w，以 **ECDSA P-256 (`prime256v1`) + SHA-256** 校验清单和发布物签名（见 [PLAN.md](PLAN.md) 第 12.3 节）。

### 生成正式密钥对

在离线或受保护环境中生成密钥对。**不要把私钥提交到仓库**（`.gitignore` 已忽略 `*.key.pem`）：

```sh
# 生成 ECDSA P-256 私钥（权限 600）
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out bifrost-release.key.pem

# 导出对应公钥，按年份或序号命名提交到仓库
openssl ec -in bifrost-release.key.pem -pubout \
  -out plugin/bifrost/keys/release-2026.pub.pem
```

### 配置 GitHub Actions Secret

1. 将 `bifrost-release.key.pem` 的完整 PEM 文本存入仓库 Secrets，名称设为 **`BIFROST_SIGNING_KEY`**（`core.yml` 与 `release.yml` 共用同一密钥）。
2. 将 `plugin/bifrost/keys/release-2026.pub.pem` 提交到 `main` 分支，随插件包一起分发。
3. 离线备份私钥，并删除本机临时私钥文件。

### 密钥轮换与撤销

1. 生成新密钥对，将新公钥（如 `release-2027.pub.pem`）加入 `plugin/bifrost/keys/`，先发布一版同时包含新旧两个公钥的插件。
2. 等待用户升级后，将仓库 Secret `BIFROST_SIGNING_KEY` 切换为新私钥。
3. 若私钥泄露，立即从 `plugin/bifrost/keys/` 移除旧公钥，并发布紧急插件版本。

## 发布流程

### 1. 发布核心（`core.yml`）

1. 更新 `core/recipe.json` 中的 Tailscale 版本、提交哈希、Go 版本或 `revision`，并运行 `packaging/gen-core-notices.py` 更新 `packaging/THIRD_PARTY_NOTICES.core.md`。
2. 先执行 `git fetch origin main`，确认本地分支包含 `origin/main` 的最新提交，再合并到 `main`，打 tag 并推送：`git tag core-<Tailscale版本>-<revision> && git push origin core-<Tailscale版本>-<revision>`。
3. `core.yml` 在两个独立 job 中分别编译并比对哈希，在 qemu-user 下运行四个核心的 `--version`，在 runner 上以 `--tun=userspace-networking` 运行冒烟测试，签名 `core.json` 和 `SHA256SUMS`，生成构建来源证明并发布，最后更新 `channel-stable`。对已有的核心 tag 也可以手动触发 `core.yml`；手动触发失败时，工作流开一个 issue。

### 2. 发布插件（`release.yml`）

1. 更新 `plugin/bifrost/version`、`packaging/core-tag` 和 `CHANGELOG.md`，并新增 `release-notes/v<版本>.md`（发布工作流会直接读取该文件作为发布说明）。
2. 先执行 `git fetch origin main`，确认本地分支包含 `origin/main` 的最新提交，再合并到 `main`，打 tag 并推送：`git tag v<版本> && git push origin v<版本>`。
3. `release.yml` 分三个权限隔离的 job 执行：
   - `verify`（只读，`persist-credentials: false`）：校验 tag 位于 `origin/main` 且与 `plugin/bifrost/version` 一致，然后重跑 `check-sh.sh`、`check-private.sh`、`tests/shell/run.sh` 和 `tests/install/run.sh`。
   - `build`（只读，`persist-credentials: false`）：用 `npm ci --ignore-scripts` 构建前端，打包 `arm` 和 `arm64` 的不压缩版与 UPX 版离线包（核心发布缺少某个 `arm64` 资产时跳过对应的包），并上传构件。
   - `publish`（不运行任何 npm/node 代码）：确认同名发布不存在，生成 `SHA256SUMS` 和 `plugin.json` 并签名、校验，附加构建来源证明，然后创建 GitHub Release（附带 `LICENSE` 与 `LICENSE.tailscale`），最后更新 `channel-stable` 上的 `plugin.json` 和 `plugin.json.sig`，供路由器提示新插件版本。

### 3. 自动跟随上游

`.github/workflows/upstream-follow.yml` 每天 03:17 UTC 在 `main` 上查询 Tailscale 最新稳定版（次版本号为偶数）。也可以手动运行；传入 `dry_run=true` 时只跑检查，不提交、不发布、不开 issue。

发现新版本时，工作流按以下顺序执行：

1. 更新 `core/recipe.json`（版本、提交、Go 版本取上游 `go.mod`、完整 featuretags 集合，`revision` 归 1）和 `packaging/core-tag`。
2. 检查配方，编译一次，在 qemu-user 下运行四个核心的 `--version`，重新生成核心第三方声明。
3. 运行容器集成测试，覆盖插件脚本用到的命令行参数和 JSON 字段。
4. 检查通过后提交到 `main`。
5. 推送 `core-<版本>-1` tag，再手动触发 `core.yml` 完成双编译、签名和发布。用 `GITHUB_TOKEN` 推送的 tag 不会自动触发工作流。

检查失败时，工作流为这个上游版本开一个 issue（已有同名 issue 时追加评论），之后的定时运行跳过这个版本。修好后手动运行工作流重试。上游出现配方里没有的 featuretags 时，核心照常发布（保留这些功能），另开 issue 提醒审阅是否加入 `omit`。
