# Bifrost 开发文档索引

本目录存放 Bifrost 的架构方案、模块接口约定与开发指南。

## 文档目录

- [PLAN.md](PLAN.md)：完整产品与技术方案（架构、核心编译、运行时、防火墙、DNS、迁移、核心签名更新、前端设计、测试与里程碑）。
- [dev/contract.md](dev/contract.md)：模块间接口约定（文件归属、shell 编写约定、错误码表、状态/任务 JSON 格式、跨包函数签名与质量门槛）。
- [../AGENTS.md](../AGENTS.md)：项目硬规则（BusyBox 1.25 兼容性、禁止 UPX / `--extra-small`、禁止提交私密信息、路由器操作规程）。
- [../NOTICE.md](../NOTICE.md)：第三方软件许可证与代码来源声明。
- [../CHANGELOG.md](../CHANGELOG.md)：版本变更记录。

## 本地检查与测试

在仓库根目录执行：

```sh
# 1. 静态检查：shellcheck -s sh、BusyBox 1.25 sh -n、禁用写法扫描
tools/check-sh.sh

# 2. 隐私信息检查（禁止提交路由器地址、真实 tailnet、本机路径、真实密钥）
tools/check-private.sh

# 3. 路由器脚本单元测试（在断网的 BusyBox 1.25 容器中执行）
tests/shell/run.sh

# 4. 安装 / 升级 / 卸载 / 并发锁测试（BusyBox 1.25 容器）
tests/install/run.sh

# 5. 核心配方校验（需安装与 core/recipe.json 一致的 Go 版本）
core/build.sh --check-recipe

# 6. 前端类型检查、构建、体积校验与 Playwright 页面测试
(cd web && npm ci && npm run check && npm run build && npm test)

# 7. 可复现打包自测（假核心 + 签名校验 + BusyBox 安装冒烟）
packaging/test-build.sh

# 8. 容器集成测试（headscale v0.29.7 + 官方 tailscale v1.104.7 + 假软件中心）
#    需 Docker 支持 --cap-add=NET_ADMIN 与 /dev/net/tun
tests/container/run.sh          # 自动判断：仅基础设施冒烟或完整套件
tests/container/run.sh --full   # 强制执行完整真实核心 + 真实脚本测试
```

## 打包方法

### 使用本地编译的核心（开发模式）

```sh
# 1. 编译核心到 core/out/
core/build.sh

# 2. 构建前端并打包到 dist/bifrost-<版本>-hnd.tar.gz（仅校验文件哈希）
packaging/build.sh --core-dir core/out --arch arm --out dist
```

### 使用已发布的签名核心（发布模式）

```sh
# 从 GitHub Release 下载 core.json、core.json.sig 与核心文件，
# 先用 plugin/bifrost/keys/*.pub.pem 验签，再校验哈希后打包：
packaging/build.sh --core-release "$(cat packaging/core-tag)" --arch arm --out dist
```

- 相同输入与相同 `SOURCE_DATE_EPOCH` 下，在 macOS 与 Linux 上均可复现打包出相同 SHA-256 的 `.tar.gz`。
- 若已预先构建前端，可附加 `--web-dist web/dist` 跳过重复构建。

## 正式签名密钥的生成与轮换

路由器端使用 OpenSSL 1.1.1w，采用 **ECDSA P-256 (`prime256v1`) + SHA-256** 进行清单与发布物验签（见 [PLAN.md](PLAN.md) 第 12.3 节）。

### 生成正式密钥对

请在离线或受保护环境中生成密钥对，**私钥绝不提交到仓库**：

```sh
# 生成 ECDSA P-256 私钥（权限 600）
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out bifrost-release-key.pem

# 导出对应公钥，按年份或序号命名提交到仓库
openssl ec -in bifrost-release-key.pem -pubout \
  -out plugin/bifrost/keys/release-2026.pub.pem
```

### 配置 GitHub Actions Secret

1. 将 `bifrost-release-key.pem` 的完整 PEM 文本存入仓库 Secrets，名称统一为 **`BIFROST_SIGNING_KEY`**（`core.yml` 与 `release.yml` 共用同一密钥）。
2. 将 `plugin/bifrost/keys/release-2026.pub.pem` 提交到 `main` 分支，并随插件包一起分发。
3. 妥善离线备份私钥并删除本机临时私钥文件。

### 密钥轮换与撤销

1. 生成新密钥对，将新公钥（如 `release-2027.pub.pem`）加入 `plugin/bifrost/keys/` 并发布一版同时包含新旧两个公钥的插件。
2. 等待用户升级后，将仓库 Secret `BIFROST_SIGNING_KEY` 切换为新私钥。
3. 如发生私钥泄露，立即从 `plugin/bifrost/keys/` 移除旧公钥并发布紧急插件版本。

## 发布流程

### 1. 发布核心（`core.yml`）

1. 更新 `core/recipe.json` 中的 Tailscale 版本、提交哈希、Go 版本或 `revision`。
2. 合并到 `main` 后打 tag 并推送：`git tag core-<Tailscale版本>-<revision> && git push origin core-<Tailscale版本>-<revision>`。
3. `core.yml` 会在两个独立 job 中分别编译比对哈希，运行容器冒烟测试，签名 `core.json` / `SHA256SUMS`，生成构建来源证明并发布，同时更新 `channel-stable`。

### 2. 发布插件（`release.yml`）

1. 更新 `plugin/bifrost/version`、`packaging/core-tag` 和 `CHANGELOG.md`。
2. 合并到 `main` 后打 tag 并推送：`git tag v<版本> && git push origin v<版本>`。
3. `release.yml` 会校验 tag 位于 `main` 且与 `plugin/bifrost/version` 一致、确认无同名发布、构建前端、用 `packaging/core-tag` 打包（arm 及可用的 arm64）、用 `BIFROST_SIGNING_KEY` 生成并校验 `SHA256SUMS.sig`、附加构建来源证明并创建 GitHub Release（附带 `LICENSE` 与 `LICENSE.tailscale`）。
