<p align="center"><img src="https://gh-proxy.com/https://raw.githubusercontent.com/2220545672/dsh-unraid/main/templates/img/dsh.png" width="128" alt="DSH for Unraid"></p>

<h1 align="center">DSH for Unraid</h1>

<p align="center">在 Unraid 上运行 <b>DeepSeek Harness（DSH）</b> 编码智能体：浏览器界面、<b>在你的内核上真正可用的命令沙箱</b>、跟随上游自动更新。</p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <img src="https://img.shields.io/badge/image-ghcr.io%2F2220545672%2Fdsh-2496ed" alt="image">
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <a href="https://github.com/2220545672/dsh-unraid/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-unraid?label=tracking&color=orange" alt="tracking"></a>
</p>

> **English** — An Unraid-first packaging of [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness): a coding agent you drive from the browser, with a `bubblewrap` sandbox that actually works on Unraid kernels (they ship without Landlock), rebuilt automatically for every upstream release, multi-arch, and with no built-in password auth — that belongs to your reverse proxy or a trusted LAN.

---

## 目录

- [这是什么](#这是什么)
- [功能一览](#功能一览)
- [快速开始](#快速开始)
- [配置](#配置)
- [为什么还需要这个镜像](#为什么还需要这个镜像)
- [沙箱：两个 `--security-opt` 为什么不能删](#沙箱两个---security-opt-为什么不能删)
- [安全模型](#安全模型)
- [更新与版本](#更新与版本)
- [常见问题](#常见问题)
- [测试与验证](#测试与验证)
- [文档](#文档)
- [支持与反馈](#支持与反馈)
- [许可与商标](#许可与商标)

## 这是什么

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（简称 **DSH**）是开源的编码智能体：对话、模型管理与会话历史都在浏览器里，工具链能直接在你的服务器上读写项目、执行命令，能力通过插件扩展。

本仓库提供它在 Unraid 上的**打包**：一个多架构容器镜像、一份 Community Applications 模板，以及安装、沙箱原理与排障文档。

```
ghcr.io/2220545672/dsh:latest
```

## 功能一览

- **开箱可用的命令沙箱** —— Unraid 内核没有启用 Landlock，DSH 的沙箱链只剩 `bubblewrap` 一条腿。镜像内置 `bubblewrap`，模板默认带上让它在容器里真正生效的两个启动参数，因此工具不会因为"缺沙箱"而拒绝执行（详见[下文](#沙箱两个---security-opt-为什么不能删)）。
- **跟随上游自动更新** —— 每小时检查 npm 上 `@deepseek-ai/dsh` 的最高版本，有新版本就构建、冒烟测试、推送镜像并生成版本锁定的模板；你只需在 Docker 页点一次更新。
- **多架构** —— `linux/amd64` 与 `linux/arm64` 同时发布，附 SBOM 与 provenance 证明。
- **收敛的运行时** —— 以非 root（uid 1000）运行，不挂载 docker socket，不接触 `/boot`，模板里不要求任何密钥。
- **鉴权交给边缘** —— 镜像不含密码登录，配合 SWAG + Authelia、VPN 或受信内网使用；容器自身仍强制 Host/Origin 校验与安全响应头。
- **中英文文档** —— 安装、沙箱原理、迁移与排障都在 [`docs/`](docs/)。

## 快速开始

### 方式一：Community Applications（收录后）

`Apps` 里搜 **DSH**（描述含 "DeepSeek Harness"，搜 `deepseek` 也能命中），安装后按需修改端口与路径即可。

### 方式二：Unraid `Docker → Add Container`（现在就能用）

把 [`templates/dsh.xml`](templates/dsh.xml) 的内容粘进模板编辑器（或导入该文件），**不要删掉 `Extra Parameters`**：

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

### 方式三：Docker Compose

```bash
git clone https://github.com/2220545672/dsh-unraid.git
cd dsh-unraid
DSH_IMAGE=ghcr.io/2220545672/dsh:latest PUBLIC_URL=https://dsh.example.com docker compose up -d
```

### 方式四：docker run

```bash
docker run -d --name dsh --restart unless-stopped \
  -p 8080:8080 \
  -e TZ=Asia/Shanghai \
  -e PUBLIC_URL=https://dsh.example.com \
  -v /mnt/user/appdata/dsh/data:/data \
  -v /mnt/user/appdata/dsh/workspace:/workspace \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

浏览器打开 `http://<你的服务器>:8080`。**首次访问不需要从日志里复制带 token 的 URL** —— Caddy 会自动把 DSH 的启动 token 换成签名会话 cookie。

## 配置

| 名称 | 默认 | 说明 |
|---|---|---|
| `8080`（容器端口） | — | 唯一需要发布的端口，由 Caddy 监听。DSH 自己只绑 `127.0.0.1:3080`（`dsh web` 拒绝通配地址，所以前面必须有一层代理） |
| `/data` | — | `DSH_HOME`：会话、凭据、agent home 与 Caddy 状态。**必须持久化**，否则重建容器即丢会话 |
| `/workspace` | — | 智能体工作目录（`DSH_WORKSPACE`），启动后即在此工作 |
| `PUBLIC_URL` | 空 | 对外 origin，例如 `https://dsh.example.com`（只填协议+主机名，不要带路径）。设置后进入 **edge 模式**；留空为 **lan 模式** |
| `DSH_TRUSTED_HOSTS` | 空 | 额外可信的 authority，逗号分隔（如 `dsh.example.com,192.168.1.10:8080`），仅 edge 模式生效 |
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `AUTH_MODE` | `none` | 唯一支持的值；填其它值容器会启动失败并说明原因 |

> **卷属主**：启动脚本会把两个卷改成 `1000:1000`（镜像内的 `node` 账户）。**不要**按 Unraid 习惯改成 `99:100`，否则容器无权访问自己的数据。

## 为什么还需要这个镜像

社区里已有其它 DSH 打包（[runzhliu/deepseek-harness-docker](https://github.com/runzhliu/deepseek-harness-docker)、[okxlin 的运行时镜像](https://github.com/okxlin/release-factory)）。选这个镜像的理由是三个能立刻感受到的差异：

- **沙箱开箱可用** —— `bubblewrap` 与它需要的启动参数都在模板里，不必自己去查"为什么命令工具一直报 `SANDBOX_UNAVAILABLE`"。
- **不会被跟版逻辑坑** —— 始终跟上游最高版本重建，不会因为上游发布标签的顺序而静默停在旧版本。
- **不假装有认证** —— 不提供弱密码登录，鉴权明确交给边缘（反代 + SSO、VPN 或受信内网）。

## 沙箱：两个 `--security-opt` 为什么不能删

DSH 的命令执行沙箱按 `bwrap → landlock` 顺序选择后端。Unraid 内核没有编译 Landlock（`landlock_create_ruleset` 返回 `ENOSYS`），于是只剩 `bubblewrap`；而 `bwrap` 要在容器里创建命名空间，必须放开 seccomp 的 `unshare` 系列调用与 `/proc` 掩码：

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

**缺任何一个，`bash` 工具都完全不可用**（fail-closed 报 `SANDBOX_UNAVAILABLE`），唯一的替代是 `danger-full-access`（无沙箱、无审批），比这更糟。

完整证据、对照实验与自查命令见 **[docs/unraid-sandbox.md](docs/unraid-sandbox.md)**。

## 安全模型

DSH 自身有一道"浏览器信任栅栏"：请求的 `Host` 必须是 loopback、监听绑定地址或显式声明的 `--trusted-host`；若带 `Origin` 则必须与 Host 同源；`Sec-Fetch-Site: cross-site` 的请求一律拒绝。本镜像据此提供两种模式：

- **edge 模式**（设置了 `PUBLIC_URL`）：Caddy 把 `Host` 改写成该 authority 并作为 `--trusted-host` 传给 DSH，同时拒绝任何 Origin 不等于 `PUBLIC_URL` 的请求。适合 SWAG + Authelia 这类前置鉴权。
- **lan 模式**（`PUBLIC_URL` 留空）：Caddy 把 `Host` 固定为 loopback 并**剥掉** `Origin`。防 DNS rebinding 与防跨站两条防线仍然有效，但**不要**把 lan 模式直接暴露到公网。

两种模式都会把"在桌面端打开文件"这类端点（`/api/settings.openDocument` 等）返回 403，并注入安全响应头（CSP、`X-Frame-Options: DENY` 等）。

## 更新与版本

镜像**自动跟版**：上游一发新版就重建、冒烟测试并推送，同时打上 `dsh-<版本>` 标签并生成 Release（附**版本锁定**的模板 XML，供需要可复现部署的人使用）。

| 标签 | 含义 |
|---|---|
| `:<版本>`（如 `:0.2.1-alpha.3`） | 不可变，适合固定版本 |
| `:latest` | 始终指向最新（含预发布） |
| `:alpha` / `:rc` / `:stable` | 按上游发布通道跟随 |

在 Unraid 上更新：Docker 页 → 该容器 → **force update**（或等它提示 apply update）。不需要改任何配置；`/data` 与 `/workspace` 里的内容保持不变。

## 常见问题

**界面打不开 / 一直转圈**
先看 `docker logs dsh | head -30`：entrypoint 会写明运行模式（edge / lan）、上游版本与启动结果。再确认 `PUBLIC_URL` 与你实际访问的地址一致（协议 + 主机名，不能带路径或结尾斜杠）。

**命令工具报 `SANDBOX_UNAVAILABLE`**
`Extra Parameters` 里的两个 `--security-opt` 被删掉了，恢复即可。原理见 [docs/unraid-sandbox.md](docs/unraid-sandbox.md)。

**8080 端口被占用**
改模板里的端口映射（宿主端口可任意，容器端口保持 8080）。

**升级后界面没变化**
Unraid 只有在镜像 digest 变化时才会重建容器；先在 Docker 页点 **force update**，再 `docker inspect` 确认镜像 digest 是否更新。

**放在反向代理后面该怎么配**
设 `PUBLIC_URL=https://你的域名`，反代指到 `容器名:8080`。若反代会改写 Host（SWAG 默认会），无需额外配置；若你的反代改用了别的 authority，用 `DSH_TRUSTED_HOSTS` 补上。

**数据在哪？怎么备份？**
会话与凭据在 `/data`（默认 `appdata/dsh/data`），项目在 `/workspace`（默认 `appdata/dsh/workspace`）。备份这两个目录即可，升级/重建容器不影响它们。

**为什么容器用 uid 1000 而不是 Unraid 常见的 `99:100`？**
镜像以固定的非 root 账户运行，启动时会把卷 chown 成 `1000:1000` 并降权。这样沙箱与文件权限的行为在任何宿主上都一致。

**支持 arm64 吗？**
支持，CI 会构建并推送 `linux/arm64`，但**尚未在 ARM 真机上跑过**；遇到问题欢迎开 issue。

**上游还在预发布阶段吗？**
是。`:latest` 会跟随上游的预发布版本；需要稳定可固定到具体的 `:<版本>` 标签。

## 测试与验证

每次发布前，镜像都会在 CI 里真实启动并通过冒烟断言；仓库与模板也有自动化检查，检查不过就不会发布。下面是这些检查覆盖的范围。

| 验证项 | 内容 |
|---|---|
| CI 冒烟（每次发版） | lan 模式：`/healthz` = ok、`/` 返回 303 且下发 `dsh-auth-*`、跨站 `/api` 被 403、受管端点被 403、两个 Caddyfile 通过 `caddy validate`、容器内 `bwrap` 可用；edge 模式：容器起得来、外来 Origin 被 403、声明的 Origin 可达 DSH |
| 目标平台验收 | 在 Unraid 7.3.2 / 内核 `6.18.38-Unraid` 上：edge 模式启动 → `/healthz` = ok → `/` 返回 **303** 且下发 `dsh-auth-*` cookie → 容器内 `bwrap … echo SANDBOX_OK` 输出 **SANDBOX_OK** |
| 发布物 | 多架构 index（amd64 + arm64）与 SBOM/provenance；未登录匿名 `docker pull` 实测成功 |
| 模板与仓库 | CA 的 minimum/recommended 字段、`ca_profile.xml` 门槛、卷与 `Config` 路径一致性、图标一致性，全部由自动化检查断言 |

发布物与检查脚本都在本仓库里，可自行复现；维护者视角的流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/unraid-sandbox.md](docs/unraid-sandbox.md) | 沙箱原理、对照实验与自查命令 |
| [docs/migrate-from-another-image.md](docs/migrate-from-another-image.md) | 从其它 DSH 镜像迁移过来（含"容器名变了要让反代跟着改"与最小中断步骤） |
| [docs/ca-submission.md](docs/ca-submission.md) | Community Applications 的提交门槛与流程 |
| [docs/ca-pitfalls.md](docs/ca-pitfalls.md) | CA 生态里前人踩过的坑（下架、废弃、模板不回流……） |
| [docs/publish.md](docs/publish.md) | 如何发布这个仓库（fork 后用） |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 本地构建、自检、发版与图标生成 |

## 支持与反馈

- **Bug / 功能请求**：[GitHub Issues](https://github.com/2220545672/dsh-unraid/issues)。
- 提问时请附上：`docker logs <容器名> | head -30` 的输出、Unraid 版本、内核版本（`uname -r`）、以及你的 `PUBLIC_URL` 设置（隐去域名）。
- 上游 DSH 自身的问题（模型、插件、界面行为）请提到 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 许可与商标

- 本仓库内容以 **MIT** 许可发布，见 [LICENSE](LICENSE)。DeepSeek Harness 本身由 DeepSeek 以 MIT 许可发布，本仓库只做打包。
- 图标为原创合成作品：DSH 官方标记 + Unraid 官方标记的组合，素材出处与商标说明见 [templates/img/src/README.md](templates/img/src/README.md)。
- 本仓库是**社区打包**，与 DeepSeek（深度求索）及 Lime Technology 均无隶属、合作或授权关系。命名遵循 DSH 官方品牌规范：项目名使用缩写 **DSH**，`DeepSeek Harness` 仅出现在描述性文字中。
