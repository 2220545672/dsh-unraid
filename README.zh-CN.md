<p align="center"><img src="https://gh-proxy.com/https://raw.githubusercontent.com/2220545672/dsh-unraid/main/templates/img/dsh.png" width="128" alt="DSH for Unraid"></p>

<h1 align="center">DSH for Unraid</h1>

<p align="center">在 Unraid 上运行 DeepSeek Harness：浏览器界面里的编码智能体，命令沙箱在你的内核上真正可用，并跟随上游自动更新。</p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <img src="https://img.shields.io/badge/image-ghcr.io%2F2220545672%2Fdsh-2496ed" alt="image">
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <a href="https://github.com/2220545672/dsh-unraid/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-unraid?label=tracking&color=orange" alt="tracking"></a>
</p>

<p align="center"><a href="README.md">English</a> · <b>中文说明</b></p>

---

## 这是什么

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（简称 **DSH**）是开源的编码智能体：在浏览器标签页里与它对话，它能读写你的项目文件、在你的服务器上执行命令、保留会话历史，并通过插件扩展能力。

本仓库提供它在 Unraid 上的打包：多架构容器镜像、Community Applications 模板，以及配套文档。

```
ghcr.io/2220545672/dsh:latest
```

## 功能一览

- **沙箱开箱可用。** 工具运行在 `bubblewrap` 里，模板已带上它在 Unraid 上需要的两个启动参数，不必再去查"为什么一直报 `SANDBOX_UNAVAILABLE`"。
- **自动更新。** 每小时检查上游版本，一有新版本就构建、冒烟测试并推送。你只需点一次更新。
- **多架构。** `linux/amd64` 与 `linux/arm64`，附 SBOM 与 provenance 证明。
- **收敛的运行时。** 非 root（uid 1000），不挂载 docker socket，不接触 `/boot`，模板里不要求任何凭据。
- **鉴权在边缘。** 容器内不含密码登录；配合 SWAG + Authelia、VPN 或受信内网使用。
- **有文档。** 安装、沙箱、迁移与排障指南都在 [`docs/`](docs/)。

## 快速开始

### 1. Community Applications（收录后）

在 `Apps` 里搜 **DSH**（描述含 "DeepSeek Harness"，搜 `deepseek` 也能命中）。

### 2. Unraid `Docker → Add Container`（现在就能用）

把 [`templates/dsh.xml`](templates/dsh.xml) 的内容粘进模板编辑器，或直接导入该文件。**不要删掉 `Extra Parameters`：**

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

### 3. Docker Compose

```bash
git clone https://github.com/2220545672/dsh-unraid.git
cd dsh-unraid
DSH_IMAGE=ghcr.io/2220545672/dsh:latest PUBLIC_URL=https://dsh.example.com docker compose up -d
```

### 4. docker run

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

然后打开 `http://<你的服务器>:8080`。**不需要从日志里复制带 token 的 URL**，首次访问会自动完成登录。

## 配置

| 名称 | 默认 | 说明 |
|---|---|---|
| `8080`（容器端口） | — | 唯一需要发布的端口，由镜像内的代理监听。DSH 自己只绑 `127.0.0.1:3080`。 |
| `/data` | — | `DSH_HOME`：会话、凭据、agent home 与代理状态。**必须持久化**，否则重建容器会丢会话。 |
| `/workspace` | — | 智能体的工作目录（`DSH_WORKSPACE`）。 |
| `ALLOWED_CLIENTS` | `127.0.0.1` | **谁可以连接**。逗号分隔：**IP/CIDR** 按连接来源地址匹配，**域名**按 `Host` 头匹配。回环地址永远放行（容器自身的健康检查要用）。默认只允许本机——要让别的机器访问，先把你的网段（如 `127.0.0.1,192.168.0.0/16`）或反向代理的地址加进来。 |
| `TRUSTED_PROXY_CIDRS` | 空 | 可选，仅当前面有反向代理时使用：Caddy 只对这些来源读取 `X-Forwarded-For`，从而按**真实客户端 IP** 匹配 `ALLOWED_CLIENTS`。切勿填写不可信客户端也能发起的网段，否则可伪造该头绕过白名单。 |
| `PUBLIC_URL` | 空 | 对外 origin，例如 `https://dsh.example.com`（只填协议 + 主机名，不要带路径）。设置后进入 **edge 模式**；留空为 **lan 模式**。 |
| `DSH_TRUSTED_HOSTS` | 空 | 额外可信的 authority，逗号分隔（如 `dsh.example.com,192.168.1.10:8080`）。仅 edge 模式生效。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |
| `AUTH_MODE` | `none` | 唯一支持的值；填其它值容器会拒绝启动并说明原因。 |

**卷属主**：启动脚本会把两个卷改成 `1000:1000`（镜像内的 `node` 账户）。**不要**改成 `99:100`。

**两种模式怎么选**

| 模式 | 适用 | 设置 |
|---|---|---|
| **edge** | 前面有东西替你鉴权：SWAG + Authelia、VPN，或任意 HTTPS 反向代理 | `PUBLIC_URL=https://你的域名` |
| **lan** | 只在你能信任的网络里访问 | `PUBLIC_URL` 留空 |

**不要**把 lan 模式暴露到公网。两种模式下容器都会校验每个请求的 Host 与 Origin 并注入安全响应头；细节见 [docs/security.md](docs/security.md)。

## 更新与版本

镜像自动跟随上游：新版本会经过构建、冒烟测试后发布，打上 `dsh-<版本>` 标签，并生成 GitHub Release（附版本锁定模板，供需要可复现部署的人使用）。

| 标签 | 含义 |
|---|---|
| `:<版本>`（如 `:0.2.1-alpha.3`） | 不可变，适合固定版本 |
| `:latest` | 始终指向最新（含预发布） |
| `:alpha` / `:rc` / `:stable` | 跟随对应的上游发布通道 |

在 Unraid 上更新：**Docker → 该容器 → force update**（或等它提示 apply update）。不需要改任何配置，`/data` 与 `/workspace` 里的内容都会保留。

## 常见问题

**界面打不开 / 一直转圈。**
先看 `docker logs dsh | head -30`：entrypoint 会写明模式（edge/lan）、上游版本与启动结果。再确认 `PUBLIC_URL` 与你实际访问的地址一致（协议 + 主机名，不要带路径）。

**命令工具报 `SANDBOX_UNAVAILABLE`。**
`Extra Parameters` 里的两个 `--security-opt` 被删掉了，恢复即可。容器外层被放宽了一点点，是为了让**智能体内层**的沙箱能够工作；完整原理见 [docs/unraid-sandbox.md](docs/unraid-sandbox.md)。

**8080 端口被占用。**
改模板里的宿主端口映射，容器端口保持 8080。

**升级后界面没变化。**
Unraid 只在镜像 digest 变化时才重建容器。先点 **force update**，再用 `docker inspect` 确认 digest。

**放在反向代理后面该怎么配？**
设 `PUBLIC_URL=https://你的域名`，反代指到 `容器名:8080`。若反代会改写 Host（SWAG 默认会），无需其它配置；若它呈现的是别的 authority，用 `DSH_TRUSTED_HOSTS` 补上。

**数据在哪？怎么备份？**
会话与凭据在 `/data`（默认 `appdata/dsh/data`），项目在 `/workspace`（默认 `appdata/dsh/workspace`）。备份这两个目录即可，更新或重建容器都不影响它们。

**为什么容器用 uid 1000 而不是 Unraid 常见的 `99:100`？**
镜像以固定的非 root 账户运行，并在启动时接管卷的属主，这样文件权限在任何宿主上表现一致。

**支持 arm64 吗？**
支持，CI 会构建并推送 `linux/arm64`，但**尚未在 ARM 真机上跑过**；遇到问题欢迎开 issue。

**上游还在预发布阶段吗？**
是。`:latest` 会跟随上游的预发布版本；需要稳定就固定到具体的 `:<版本>` 标签。

## 测试与验证

每次发布前，镜像都会在 CI 里真实启动并通过冒烟断言；仓库与模板也有自动化检查，检查不过就不会发布。

| 检查 | 覆盖范围 |
|---|---|
| 镜像冒烟（每次发布） | lan 模式：`/healthz` = ok、`/` 返回 303 且下发 `dsh-auth*` cookie、跨站 `/api` 被 403、受管端点被 403、两份代理配置均通过校验、容器内 `bwrap` 可用；edge 模式：容器起得来、外来 Origin 被 403、声明的 Origin 可达 DSH |
| 真实 Unraid 主机 | Unraid 7.3.2 / 内核 `6.18.38-Unraid`：edge 模式启动、`/healthz` = ok、`/` 返回 **303** 并下发 cookie、容器内 `bwrap … echo SANDBOX_OK` 输出 **SANDBOX_OK** |
| 发布物 | 多架构 index（amd64 + arm64）与 SBOM/provenance；未登录匿名 `docker pull` 实测成功 |
| 模板与仓库 | CA 字段要求、`ca_profile.xml`、卷与 `Config` 路径一致性、图标一致性，均由脚本断言 |

## 文档

| 文档 | 内容 |
|---|---|
| [docs/unraid-sandbox.md](docs/unraid-sandbox.md) | 为什么 Unraid 上必须这样配沙箱，以及背后的对照实验 |
| [docs/security.md](docs/security.md) | 容器如何校验 Host 与 Origin，两种模式各做了什么 |
| [docs/migrate-from-another-image.md](docs/migrate-from-another-image.md) | 从其它 DSH 镜像迁移过来，最小中断 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 构建、测试、发版，以及模板与图标的维护流程 |
| [docs/ca-submission.md](docs/ca-submission.md) · [docs/ca-pitfalls.md](docs/ca-pitfalls.md) | Community Applications 的提交流程与该生态的坑 |

## 支持与反馈

- **Bug / 功能请求**：[GitHub Issues](https://github.com/2220545672/dsh-unraid/issues)。
- 提问时请附上：`docker logs <容器名> | head -30` 的输出、Unraid 版本、内核版本（`uname -r`）、以及 `PUBLIC_URL` 的设置方式（域名可隐去）。
- DSH 自身的问题（模型、插件、界面行为）请提到上游 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 许可与商标

- 本仓库以 **MIT** 许可发布，见 [LICENSE](LICENSE)。DeepSeek Harness 本身由 DeepSeek 以 MIT 许可发布，本仓库只做打包。
- 图标为原创合成作品：DSH 官方标记与 Unraid 官方标记的组合；素材出处与商标说明见 [templates/img/src/README.md](templates/img/src/README.md)。
- 本仓库是**社区打包**，与 DeepSeek（深度求索）及 Lime Technology 均无隶属、合作或授权关系。命名遵循 DSH 官方品牌规范：项目名使用缩写 **DSH**，`DeepSeek Harness` 仅出现在描述性文字中。
