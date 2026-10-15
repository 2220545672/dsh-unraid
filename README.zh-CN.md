<p align="center"><img src="https://gh-proxy.com/https://raw.githubusercontent.com/2220545672/dsh-unraid/main/templates/img/dsh.png" width="128" alt="DSH for Unraid"></p>

<h1 align="center">DSH for Unraid</h1>

<p align="center">把 <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>（浏览器里用的 AI 编程智能体）跑在你的 Unraid 上：一个容器、命令沙箱在 Unraid 内核上直接可用、跟随上游自动更新。</p>

<p align="center"><a href="README.md">English</a> · <b>中文说明</b></p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <a href="https://github.com/2220545672/dsh-unraid/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-unraid?label=tracking&color=orange" alt="tracking"></a>
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

---

## 安装

**Unraid 上（推荐）**

1. 打开 **Apps** 标签页，搜索 **DSH**。*还没上架？* 用 **Docker → Add Container**，把 [`templates/dsh.xml`](templates/dsh.xml) 的内容粘贴进模板编辑器。
2. **Extra Parameters 不要动**——那两个 `--security-opt` 是智能体的沙箱能在 Unraid 上工作的前提。
3. 点 Apply，然后打开 **`http://<你的服务器>:8080`**。

**用 Docker / Compose**

```bash
docker run -d --name dsh --restart unless-stopped -p 8080:8080 \
  -e ALLOWED_CLIENTS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 \
  -v /mnt/user/appdata/dsh/data:/data \
  -v /mnt/user/appdata/dsh/workspace:/workspace \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

自己写命令时 `ALLOWED_CLIENTS` **不能省**：不写就只有回环能连，浏览器会得到 `403`。用 compose 的话，[`compose.yaml`](compose.yaml) 里已经带好了。

## 头五分钟

1. **打开界面**：首次访问会自动登录，不需要去日志里复制 token。
2. **先改口令**：模板自带的是 `12345678`，这是公开值。对应字段是 **访问口令** / `DSH_PASSWORD`（留空则容器首启随机生成并在日志里打印一次：`docker logs <容器名>`）。用户名默认 `dsh`。
3. **填 DeepSeek API Key**：同一个面板里的 *Add API key*。用 DeepSeek **账号**登录只在回环地址下可用，见「常见问题」。
4. **指向你的项目**：智能体在 `/workspace` 里干活（默认 `appdata/dsh/workspace`）。

## 更新

Unraid：**Docker → 你的容器 → force update**（或点「apply update」提示）。`/data` 与 `/workspace` 里的东西都不会动。

| 标签 | 含义 |
|---|---|
| `:latest` | 最新构建（含上游预发布版） |
| `:0.2.1-alpha.3` | 钉住某个确切版本 |
| `:alpha` · `:rc` · `:stable` | 跟随某个上游通道 |

每天有定时任务检查上游、重建并做冒烟测试，全部通过才发布。上游目前只有 alpha/rc，`:latest` 更新较频繁——想自己掌握节奏就钉版本标签。

## 常见问题

| 现象 | 处理 |
|---|---|
| 页面提示 “dsh web authentication required; reopen the URL printed by dsh web” | 打开一次 `http://<主机>:<端口>/renew`——这是旧容器（或同主机另一个 DSH 实例）留下的失效登录 Cookie 挡住了自动登录。清掉该站点 Cookie 也行。 |
| 工具报 `SANDBOX_UNAVAILABLE` | **Extra Parameters** 里的两个 `--security-opt` 被删了，补回去。 |
| 浏览器拿到 `403` | 你的地址不在 `ALLOWED_CLIENTS` 里；裸 `docker run` 默认只放行回环。 |
| 用 DeepSeek 账号登录报「登录失败 / 操作未完成」 | 上游只接受**回环**来源。改用 API Key，或先开隧道登录一次：`ssh -L 3081:127.0.0.1:3081 root@<服务器>` 后打开 `http://127.0.0.1:3081`。 |
| 更新了却没变化 | Unraid 只在镜像 digest 变化时重建容器——用 **force update**。 |
| 页面一直转圈 | `PUBLIC_URL` 必须与你实际打开的地址一致（协议 + 主机，不带路径）。`docker logs` 会打印它选定的模式。 |

## 可能会用到的设置

| 设置 | 默认 | 作用 |
|---|---|---|
| `8080` | — | 唯一需要发布的端口。DSH 自身只监听容器内的 `127.0.0.1:3080`，由内置代理对外提供 `:8080`。 |
| `/data` · `/workspace` | — | 会话、凭据、智能体主目录 · 你的项目。**两者都必须持久化。** |
| `ALLOWED_CLIENTS` | 仅回环 | 谁能连进来：IP/CIDR（也可以写域名，按 `Host` 匹配）。 |
| `PUBLIC_URL` | 空 | 前面有反向代理时填对外地址（`https://dsh.example.com`）；只在局域网/Tailscale 用就留空。 |
| `AUTH_MODE` | `builtin` | `builtin` = 容器内口令门禁；`none` = 交给前面的代理鉴权。填其它值容器会拒绝启动。 |
| `DSH_PASSWORD` | 模板里是 `12345678` | 口令门禁的密码（也可用 `DSH_PASSWORD_FILE`）。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |

已经上了 SSO（SWAG + Authelia、Authentik 等）？把 `AUTH_MODE` 设为 `none` 并填 `PUBLIC_URL`，**不要再叠一层登录**——详见 [docs/security.md](docs/security.md)。

卷的属主会被接管为 `1000:1000`，别改成 Unraid 习惯的 `99:100`。

## 更多文档

| 文档 | 内容 |
|---|---|
| [docs/security.md](docs/security.md) | 口令门禁、Host/Origin 校验、`ALLOWED_CLIENTS`、403 排障 |
| [docs/unraid-sandbox.md](docs/unraid-sandbox.md) | 为什么 Unraid 需要那两个 `--security-opt` |
| [docs/migrate-from-another-image.md](docs/migrate-from-another-image.md) | 从别的 DSH 镜像迁过来 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 构建、测试、发布与模板流程 |
| [docs/ca-submission.md](docs/ca-submission.md) | Community Applications 提交说明 |

**已知限制。** 单用户设计：没有账户体系，能打开界面的人就是同一个工作区主人。用 DeepSeek **账号**登录需要回环地址（请用 API Key）。上游仍是预发布阶段。镜像约 0.9 GB。

## 支持

- **Unraid 论坛帖：**[DSH — DeepSeek Harness, AI coding agent in your browser](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)
- **Bug 与建议：**[GitHub Issues](https://github.com/2220545672/dsh-unraid/issues)——请附上 `docker logs <容器名> | head -30`、Unraid 与内核版本（`uname -r`）、以及 `PUBLIC_URL` 的设置方式。
- **DSH 自身的问题**（模型、插件、界面）：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 许可

MIT，见 [LICENSE](LICENSE)。DeepSeek Harness 本身由 DeepSeek 以 MIT 发布，本仓库只做打包。

社区打包项目：与 DeepSeek、Lime Technology 均无隶属或授权关系。图标由官方 DSH 标识与官方 Unraid 标识合成（[来源与商标说明](templates/img/src/README.md)）。
