<h1 align="center">DSH for Unraid</h1>

<p align="center"><a href="https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/">Community Applications</a> 上的 DSH（<a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>，浏览器里用的 AI 编程智能体）模板。容器镜像本身在 <a href="https://github.com/2220545672/dsh-docker">2220545672/dsh-docker</a> 构建；本仓库是 Unraid 那一侧：模板、图标与 CA 相关文档。</p>

<p align="center"><a href="README.md">English</a> · <b>中文说明</b></p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <a href="https://github.com/2220545672/dsh-docker/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-docker?label=image&color=orange" alt="image"></a>
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

---

> **开发者预览。** DeepSeek Harness 处于 _开发者预览_ 阶段，正在快速迭代。**未来将出现破坏兼容性的变更。** —— 引自[上游项目](https://github.com/deepseek-ai/deepseek-harness/blob/main/README.zh.md#开发者预览)。镜像会自动跟随上游发布；想自己掌握节奏，可以钉住版本标签。

## 安装

1. 打开 **Apps** 标签页搜索 **DSH**——已收录进 Community Applications。*feed 还没刷新？* 用 **Docker → Add Container**，把 [`templates/dsh.xml`](templates/dsh.xml) 的内容粘进模板编辑器。
2. **Extra Parameters 不要动**——那两个 `--security-opt` 是智能体的沙箱能在 Unraid 上工作的前提；`--restart=unless-stopped` 让它在 Docker 重启后自动回来。
3. 点 Apply，然后打开 **`http://<你的服务器>:8080`**，用户名 `dsh`，口令用 **Password** 字段里的值。

## 头五分钟

1. **先改口令。** 模板自带 `12345678`，这是公开值：Docker 页 → 该容器 → *Edit* → **Password** → Apply。（留空则由容器首启随机生成并只在日志里打印一次：`docker logs <容器名>`。）
2. **指向你的项目。** 智能体在 `/workspace` 里干活（默认 `appdata/dsh/workspace`）。
3. **填 DeepSeek API Key**：设置面板里的 *Add API key*。用 DeepSeek **账号**登录从任何浏览器也能完成：登录标签页停在打不开的 `127.0.0.1` 页面时，页面里会自动出现粘贴框——详见镜像仓库的 [docs/remote-signin.zh-CN.md](https://github.com/2220545672/dsh-docker/blob/main/docs/remote-signin.zh-CN.md)。

## 模板字段

每个变量的完整说明（以及它背后的安全模型）跟着镜像走：[dsh-docker README](https://github.com/2220545672/dsh-docker/blob/main/README.zh-CN.md#可能会用到的设置) 与 [docs/security.zh-CN.md](https://github.com/2220545672/dsh-docker/blob/main/docs/security.zh-CN.md)。

| 字段 | 默认 | 作用 |
|---|---|---|
| WebUI Port | `0.0.0.0:8080` | 宿主侧绑定。**必须写成 `IP:端口`**——Unraid 会把裸端口号误解析成 IP，容器会卡在 `Created`。 |
| Data Directory | `/mnt/user/appdata/dsh/data` | `DSH_HOME`：会话、凭据、智能体主目录、Caddy 状态。必须持久化。 |
| Workspace Directory | `/mnt/user/appdata/dsh/workspace` | 智能体的工作目录。 |
| Allowed Clients | 私有网段 + Tailscale | 谁能访问界面。想收紧就删掉多余网段；**镜像自身的默认值是仅回环**。 |
| Username / Password | `dsh` / `12345678` | 容器自带门禁的账号口令。**务必改掉口令。** |
| Authentication Mode | `builtin` | `builtin` = 容器自带口令门禁；`none` = 交给前面的反向代理 / SSO（别叠两层登录）。 |
| Trusted Proxy CIDRs | 空 | 仅当前面有反向代理：只对这些来源读取 `X-Forwarded-For`，让白名单看到真实客户端地址。 |
| Public URL | 空 | 反向代理对外提供的 origin（`https://dsh.example.com`）；纯内网留空。 |
| Trusted Hosts | 空 | 额外可信 authority；只在设置了 Public URL 时生效。 |
| Remote Sign-in | `on` | 远程浏览器用 DeepSeek **账号**登录（多一步粘贴）。`off` = 上游行为。 |
| Time Zone | `Asia/Shanghai` | 容器时区。 |
| Extra Parameters | `--security-opt seccomp=unconfined --security-opt systempaths=unconfined --restart=unless-stopped` | **不要删掉那两个 `--security-opt`**，原因见下。 |

## 为什么需要那两个 `--security-opt`

Unraid 内核没有编入 Landlock，DSH 的命令沙箱只剩第二梯队：镜像内置的 bubblewrap。而
`bwrap` 要创建命名空间，容器默认的 seccomp 配置与 `/proc` 掩码会挡住它——这两个参数就是
放行的东西。没有它们，智能体的 bash 工具会拒绝执行并报 `SANDBOX_UNAVAILABLE`。

对照实验、取舍，以及两种会误报的自查方式都在镜像仓库：
[docs/sandbox.zh-CN.md](https://github.com/2220545672/dsh-docker/blob/main/docs/sandbox.zh-CN.md)
（这份文档原先在本仓库，名为 `docs/unraid-sandbox.md`）。

## 更新

**Docker → 你的容器 → force update**（或点「apply update」提示）。`/data` 与 `/workspace` 里的东西都不会动。

| 标签 | 含义 |
|---|---|
| `:latest` | 最新构建（含上游预发布版）——模板用的就是它 |
| `:0.2.1-alpha.4` | 钉住某个确切版本 |
| `:alpha` · `:rc` · `:stable` | 跟随某个上游通道 |

镜像由 [dsh-docker](https://github.com/2220545672/dsh-docker) 的每小时任务在上游一发版就重建并冒烟测试；发布说明也在那边，不在本仓库。

## 常见问题

| 现象 | 处理 |
|---|---|
| 工具报 `SANDBOX_UNAVAILABLE` | **Extra Parameters** 里的两个 `--security-opt` 被删了，补回去。自查时注意：`systempaths=unconfined` **不会**出现在 `docker inspect` 的 `SecurityOpt` 里（它表现为 `MaskedPaths`/`ReadonlyPaths` 变空），而 bwrap **只在 uid 1000 下可用**——用 `docker exec -u 1000 <容器> bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true` 测，必须 exit 0。用 root 测必然失败，那不能说明容器有问题。 |
| 浏览器拿到 `403` | 你的地址不在 **Allowed Clients** 里。 |
| 页面提示 “dsh web authentication required; reopen the URL printed by dsh web” | **刷新页面即可**——容器会自己把失效的会话 Cookie 换新（也可手动打开 `http://<主机>:<端口>/renew`）。 |
| 更新了却没变化 | Unraid 只在镜像 digest 变化时重建容器——用 **force update**。 |
| 页面一直转圈 | **Public URL** 必须与你实际打开的地址一致（协议 + 主机，不带路径）。`docker logs <容器名> \| head -30` 会打印它选定的模式。 |

更多排障（登录粘贴面板、Caddy/DSH 内部、`docker inspect` 细节）见镜像仓库的
[README](https://github.com/2220545672/dsh-docker/blob/main/README.zh-CN.md#常见问题)。

## 从别的 DSH 镜像迁过来

从 `ghcr.io/okxlin/deepseek-harness`（容器常叫 `dsh-web`）等社区镜像切过来、把停机时间压到最小：
[docs/migrate-from-another-image.zh-CN.md](docs/migrate-from-another-image.zh-CN.md)。

## 本仓库内容

```
.
├── templates/dsh.xml   # Community Applications 解析的就是这个文件
├── templates/img/      # CA 图标（以及生成它的素材与脚本）
├── icon.svg            # 仓库图标，CA 目录结构要求
├── ca_profile.xml      # CA 仓库信息（<Profile> 不能为空）
├── scripts/            # 模板自检、图标生成、静态闸门
└── docs/               # CA 提交说明、坑位清单、迁移指南
```

维护说明——模板自检、图标流水线、提交流程，以及唯一一条跨仓库检查——见
[CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

⚠️ **模板是快照。** Community Applications 在用户**安装时**把 `templates/dsh.xml`
复制成 `/boot/config/plugins/dockerMan/templates-user/my-DSH.xml`；此后这里的改动只影响
新安装的用户与目录页，**永远不会**到达已安装的机器。必须让所有人都拿到的行为要放进镜像。
见 [docs/ca-pitfalls.zh-CN.md](docs/ca-pitfalls.zh-CN.md)。

## 支持

- **Unraid 论坛帖：**[DSH — DeepSeek Harness, AI coding agent in your browser](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)——请附上 `docker logs DSH | head -30`、Unraid 与内核版本（`uname -r`）、以及 **Public URL** / **Allowed Clients** 的设置。
- **镜像本身的问题：**[dsh-docker issues](https://github.com/2220545672/dsh-docker/issues)。
- **DSH 自身的问题**（模型、插件、界面）：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 许可

MIT，见 [LICENSE](LICENSE)。DeepSeek Harness 本身由 DeepSeek 以 MIT 发布，本仓库只做 Unraid 侧的打包。

社区打包项目：与 DeepSeek、Lime Technology 均无隶属或授权关系。图标由官方 DSH 标识与官方 Unraid 标识合成（[来源与商标说明](templates/img/src/README.md)）。
