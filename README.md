# dsh-unraid

给 Unraid 用的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 容器镜像与 Community Applications 模板。

上游一发布就自动重建、自动推送；镜像里内置 `bubblewrap`，因为 **Unraid 内核没有 Landlock**，缺了它 DSH 的 `bash` 工具会直接 fail-closed。

```
ghcr.io/__GHCR_OWNER__/dsh:latest
```

## 为什么还要自己做一个镜像

社区里已经有两个可用的打包（[runzhliu/deepseek-harness-docker](https://github.com/runzhliu/deepseek-harness-docker)、[okxlin 的运行时镜像](https://github.com/okxlin/release-factory)），本仓库存在的理由是三个具体的差异：

1. **跟版信号不进坑**。`@deepseek-ai/dsh` 的 npm `latest` 标签**落后于** `alpha`：2026-10-15 实测 `latest` 仍是 `0.2.0-rc.2`，而 `alpha` 已经是 `0.2.1-alpha.3`。只读 `latest` 的流水线会**静默降级**。本仓库枚举全部已发布版本，按 semver 取最高（预发布按规范参与比较）。
2. **默认适配 Unraid 的沙箱现实**。镜像装 `bubblewrap`，模板默认带上让它在无 Landlock 内核上真正能用的两个参数（下详）。
3. **没有内建密码认证**。鉴权交给边缘（SWAG + Authelia、VPN、或受信局域网）：镜像里 `AUTH_MODE=none` 之外的值一律 fail-closed，避免"看起来有认证、实际很弱"的错觉。

## 快速开始

### Unraid（推荐）

- 有 CA 收录后：`Apps` 里搜 `DSH`（描述里含 “DeepSeek Harness”，搜 `deepseek` 也能命中）。
- 未收录时：`Docker → Add Container`，把 [`templates/dsh.xml`](templates/dsh.xml) 导入（或直接把内容粘进模板编辑器），然后 **不要删掉 `Extra Parameters`**。

创建后容器的 `Extra Parameters` 应为：

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

### Docker Compose

```bash
git clone https://github.com/__GHCR_OWNER__/dsh-unraid.git
cd dsh-unraid
DSH_IMAGE=ghcr.io/__GHCR_OWNER__/dsh:latest PUBLIC_URL=https://dsh.example.com docker compose up -d
```

### docker run

```bash
docker run -d --name dsh --restart unless-stopped \
  -p 8080:8080 \
  -e TZ=Asia/Shanghai \
  -e PUBLIC_URL=https://dsh.example.com \
  -v /mnt/user/appdata/dsh/data:/data \
  -v /mnt/user/appdata/dsh/workspace:/workspace \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  ghcr.io/__GHCR_OWNER__/dsh:latest
```

浏览器打开 `http://<host>:8080`。首次访问会经由 Caddy 注入 DSH 的启动 token，自动换取签名会话 cookie —— **不需要**从日志里复制带 token 的 URL。

## 端口、卷与环境变量

| 名称 | 默认 | 说明 |
|---|---|---|
| `8080`（容器端口） | — | 唯一的发布端口，由 Caddy 监听；DSH 自己只绑 `127.0.0.1:3080`（`dsh web` 拒绝通配地址） |
| `/data` | — | `DSH_HOME`（会话、凭据）+ `/data/dsh/agents` + Caddy 状态。**必须持久化**，否则重建容器就丢会话 |
| `/workspace` | — | 智能体工作目录（`DSH_WORKSPACE`），启动即 `cd` 到此 |
| `PUBLIC_URL` | 空 | 对外 origin，如 `https://dsh.example.com`。设置后进入 **edge 模式**；留空为 **lan 模式** |
| `DSH_TRUSTED_HOSTS` | 空 | 额外的可信 authority，逗号分隔；仅 edge 模式生效 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `AUTH_MODE` | `none` | 唯一支持的值；其它值容器启动即报错退出 |

卷的属主会被启动脚本改成 `1000:1000`（镜像内的 `node` 账户），**不要**按 Unraid 习惯改成 `99:100`。

### 两种模式的安全语义

DSH 自己有一道"浏览器信任栅栏"（`dsh-client-connection`）：Host 必须是 loopback / 监听绑定 IP / 显式 `--trusted-host`，若请求带 `Origin` 则必须与该 Host 同源，且 `Sec-Fetch-Site: cross-site` 一律拒绝。本镜像据此分两种模式：

- **edge 模式**（设了 `PUBLIC_URL`）：Caddy 把 Host 改写成该 authority（同时作为 `--trusted-host` 传给 DSH），保留 `Origin` 并额外拒绝不等于 `PUBLIC_URL` 的 Origin。适合 SWAG + Authelia 这类前置鉴权。
- **lan 模式**（`PUBLIC_URL` 为空）：Caddy 把 Host 固定为 loopback 并**剥掉 `Origin`**。防 DNS rebinding 与防跨站两条防线仍然有效（rebinding 伪造不了 Host；跨站请求由 `Sec-Fetch-Site` 规则拦下），但**不要**把 lan 模式直接暴露到公网。

两种模式都会：把 `/api/settings.openDocument`、`/api/settings.openSettingsDocument` 这类"在桌面端打开文件"的端点返回 403，并注入安全响应头（CSP、`X-Frame-Options: DENY` 等）。

## 沙箱：两个 `--security-opt` 为什么不能删

简短版：Unraid 内核没编 Landlock，DSH 的沙箱链只剩 `bwrap` 一条腿；而 `bwrap` 在容器里要建命名空间，必须放开 seccomp 的 `unshare` 与 `/proc` 掩码。缺任何一个，`bash` 工具就完全不可用——唯一的替代是 `danger-full-access`（无沙箱、无审批），比这更糟。

完整的证据、对照实验与验证命令见 **[docs/unraid-sandbox.md](docs/unraid-sandbox.md)**。

## 自动跟版是怎么工作的

```
cron(每 6 小时) ──► 解析 npm 上 @deepseek-ai/dsh 的最高版本（含 alpha/rc）
                    ├─ 已有 dsh-<version> 标签 → 什么都不做
                    └─ 新版本 → 构建 amd64 → 冒烟测试 → 构建并推送 amd64+arm64
                                → 打标签 dsh-<version> → 发 GitHub Release（附版本锁定的模板 XML）
```

- **标签策略**：`:<version>`（不可变）、`:latest`（始终指向最新，含预发布）、以及通道标签 `:alpha` / `:rc` / `:stable`。
- **冒烟测试**（`scripts/smoke.sh`）逐项断言：`/healthz` 返回 `ok`、`/` 返回 303 且下发 `dsh-auth-*` cookie、跨站 `/api` 请求被 403、受管端点被 403、两个 Caddyfile 都能 `caddy validate`、镜像内有可用的 `bwrap`。
- **手动触发**：Actions → `release` → `Run workflow`，可指定精确版本或 `force=true` 强制重建。

## 已知限制

- **没有内建认证**。必须在边缘或受信网络里解决；`AUTH_MODE` 只接受 `none`。
- **arm64 未在真机验证**。CI 会构建并推送 `linux/arm64`，但没有在 ARM 设备上跑过；遇到问题请开 issue。
- **`Extra Parameters` 放宽了容器外层**（`seccomp` / `systempaths` 各一项）。这是为了换取内层真正有效的沙箱，取舍见上文那篇文档。
- **首次发布后需要手动把 GHCR 包设为 public**（GitHub 默认私有）：`GitHub → 个人头像 → Packages → dsh → Package settings → Change visibility`。否则 Unraid 上 `docker pull` 会 401。
- 上游 DSH 仍在 alpha/rc 阶段，接口与行为都可能变；`:latest` 会跟着它走。
- **镜像解压后约 1.09 GB**（node 运行时 + Caddy + git/ripgrep 等工具 + DSH 的依赖树）。docker.img 落在机械盘上的机器，首次拉取会明显偏慢。
- **国内直连 `ghcr.io` 可能很慢**：实测（中国大陆家宽）首次拉取约 **1 MB/s、约 20 分钟**（1.09 GB，未登录匿名拉取，能成功但不受镜像源加速——那些源只覆盖 Docker Hub）。若嫌慢，可在宿主给 dockerd 配代理，或改成从你信任的镜像/中转拉取。

## 图标与商标

- 图标由 `scripts/make-icon.mjs` 合成：DSH 的蓝色鲸鱼（取自上游 `website/public/favicon.svg）+ 右下角**面积 1/16** 的 Unraid 圆角角标（取自 `unraid/docs` 的官方 mark）。素材出处与商标说明见 [templates/img/src/README.md](templates/img/src/README.md)。
- 本仓库是**社区打包**，与 DeepSeek（深度求索）及 Lime Technology 均无隶属、合作或授权关系。命名遵循 DSH 官方品牌规范：项目名用缩写 **DSH**，只有在描述性文字里才出现 "DeepSeek Harness"。
- **图标宿主必须国内可达**。实测：`raw.githubusercontent.com` 与 `cdn.jsdelivr.net` **超时**，`github.com/.../raw/...` 会 302 跳到 raw（随后一样超时）；`gh-proxy.com` 约 0.2s、`ghproxy.net` 约 1.0–1.9s，两者字节经 sha256 校验与正本一致。模板的 `<Icon>` 因此指向 `gh-proxy.com`，换宿主只需改这一行。

## 验证记录（可复现）

| 项目 | 证据 |
|---|---|
| 多架构发布 | index digest `sha256:a357c91a2f4f86b3ffb6f978017773d2e37684eddcc5e5d9d009f09eb84ce7ab`，`linux/amd64` + `linux/arm64`，另有 2 个 SBOM/provenance attestation manifest |
| 匿名拉取 | 在 Unraid 宿主上未登录 `docker pull ghcr.io/2220545672/dsh:latest` 成功，digest 与上表一致 |
| CI 冒烟（每次发版都跑） | lan 模式：`/healthz`=ok、`/` 返回 303 + `dsh-auth-*`、跨站 `/api` 403、受管端点 403、两个 Caddyfile `caddy validate`、容器内 `bwrap` 可用；edge 模式：容器起得来、外来 Origin 403、声明 Origin 可达 DSH |
| **目标平台验收**（2026-10-15，Unraid 7.3.2 / 内核 `6.18.38-Unraid`） | edge 模式（`PUBLIC_URL` 已设）启动 → `/healthz` = ok；`/` 返回 **303** 且下发 `dsh-auth-*` cookie；容器内 `bwrap … -- /bin/sh -c 'echo SANDBOX_OK'` 输出 **SANDBOX_OK**；验收实例使用独立端口与临时卷，未触碰宿主上正在运行的其他容器 |
| 图标可达性 | 经 `gh-proxy.com` 取回 8658 B，sha256 `fb9b0e37…` 与本地正本一致 |
| 模板自检 | `node scripts/check-template.mjs templates/dsh.xml`：CA 的 minimum/recommended 字段齐全、`ca_profile.xml` 的 `<Profile>` 非空、卷与 `Config` 的宿主机路径一致 |

> 目标平台验收这一步抓出过一个 CI 漏掉的真实 bug：镜像里 token 正则把端口写死成内部端口，而 **edge 模式**下 DSH 按 `--public-url` 打印对外端口 → 正则永不匹配 → Caddy 不启动、界面打不开。修复已在 `:latest`（宽松匹配）并补进 CI 的 edge 模式冒烟断言。

## 维护者手册

| 想做的事 | 怎么做 |
|---|---|
| 本地构建 | `docker build --build-arg DSH_VERSION=0.2.1-alpha.3 --build-arg NODE_VERSION=24.21.0 --build-arg CADDY_VERSION=2.11.7 -t dsh:local .` |
| 本地冒烟 | `bash scripts/smoke.sh dsh:local` |
| 查上游版本解析结果 | `node scripts/resolve-dsh-version.mjs --json` |
| 改图标 | `node scripts/make-icon.mjs`（需要 `sharp`；素材在 `templates/img/src/`），提交生成的 `templates/img/dsh.png` |
| 改模板 | 编辑 `templates/dsh.xml`；`__GHCR_OWNER__` / `__REPO__` / `__IMAGE_TAG__` 由 `scripts/render-template.mjs` 渲染 |
| **首次发布** | 见 [docs/publish.md](docs/publish.md)：建仓库 → 推送 → 两个仓库设置（Workflow permissions 必须为 read/write、首发后把 GHCR 包设为 public）→ 手动触发一次 release |
| 提交到 CA | 见 [docs/ca-submission.md](docs/ca-submission.md)（官方硬性门槛：`ca_profile.xml`、LICENSE、Validate/Scan）与 [docs/ca-pitfalls.md](docs/ca-pitfalls.md)（前人踩过的坑：声明不符被下架、废弃失去安全更新、模板改动不回流、中心 feed 停摆……） |
| 模板自检 | `node scripts/check-template.mjs templates/dsh.xml`（validate 与 release 都会跑；含 CA 的 minimum/recommended 字段与 `ca_profile.xml` 门槛） |
| 迁移现有部署 | 见 [docs/migrate-from-another-image.md](docs/migrate-from-another-image.md)：从其它 DSH 镜像（如 okxlin 的 `dsh-web`）切到本镜像，含"容器名变了要让反代跟着改"与最小中断步骤 |

## English summary

An Unraid-first DeepSeek Harness image: multi-arch, rebuilt automatically from the newest version published on npm (prereleases included, because the `latest` dist-tag lags behind `alpha`), shipping `bubblewrap` plus the two `--security-opt` values it needs on Landlock-less kernels, with no built-in password auth — authentication belongs to an edge proxy or a trusted LAN. See [docs/unraid-sandbox.md](docs/unraid-sandbox.md) for the sandbox rationale and [docs/ca-submission.md](docs/ca-submission.md) for the Community Applications workflow.

## License

MIT（见 [LICENSE](LICENSE)）。DeepSeek Harness 本身由 DeepSeek 以 MIT 许可发布，本仓库只做打包。
