# 把模板提交到 Unraid Community Applications

## 先看清楚：哪条路已经关了

- **`selfhosters/unRAID-CA-templates`（老路）已经停止接收新模板**。该仓库的新模板 PR 模板原文：*"We are no longer accepting new proposals, this issue will be closed."* README 也写明原作者维护意愿下降，并建议作者"拿到自己的 template repo in CA"。别把 PR 花在这里。
- **现在的正规做法是"自建模板仓库 + CA 里 claim"**：仓库根目录提交 `.unraid/community-apps-claim.json`，CA 就会把它当作模板仓库收录。这个文件里只有一个公开 nonce 与 claim code，**不是密钥**，由 CA 的 claim 页面生成。

## 步骤

### 1. 先把镜像和模板验证一遍

- 镜像公开可拉：`docker pull ghcr.io/<owner>/dsh:latest`（在**未登录**的机器上试，确认包是 public）。
- 模板能装：Unraid `Docker → Add Container`，把 `templates/dsh.xml` 的内容粘进去（或先 `scp` 到 `/boot/config/plugins/dockerMan/templates-user/`）。
- 装完确认三件事：Web UI 打得开、`/data` 与 `/workspace` 持久化、容器能跑一条 bash 命令（即沙箱可用，见 [unraid-sandbox.md](unraid-sandbox.md)）。
- 容器必须带 `net.unraid.docker.managed=dockerman` 标签（用模板创建自然就有）。审计命令：

  ```bash
  ssh unraid 'docker inspect dsh --format "{{index .Config.Labels \"net.unraid.docker.managed\"}}"'
  ```

### 2. 在 CA 里跑 claim 流程

在 Unraid 的 Community Applications 里找到"提交/认领模板仓库"的入口（CA 设置内的 submit/claim 页），填入本仓库地址，它会给出 `.unraid/community-apps-claim.json` 的内容。把它提交到本仓库根目录后，CA 即可收录。

> 注意：这个 claim 页面在 CA 插件内部，**无法离线伪造**——nonce 必须由 CA 生成后与仓库对上。这就是为什么本仓库默认**没有**这个文件：第一次必须由你在自己的 Unraid 上生成。
> 参考实现：[TheBlackBush/bambulab_metrics_exporter#67](https://github.com/TheBlackBush/bambulab_metrics_exporter/pull/67)、[2CrAZYTV/multi-coin-paper-daytrader#37](https://github.com/2CrAZYTV/multi-coin-paper-daytrader/pull/37)。

### 3. 开一个 Unraid 论坛支持帖（CA 的硬要求）

[官方模板指南](https://selfhosters.net/docker/templating/templating/) 说得很直白：**如果你是给自己维护的容器写模板，就必须在 Unraid 论坛开支持帖，并把 `<Support>` 指向它**，不要指向 GitHub Issues。

因此提交前请把模板里这一行改掉：

```xml
<Support>https://forums.unraid.net/topic/<你的帖子ID>/</Support>
```

（当前默认指向本仓库 Issues，便于开发期收集问题。）

### 4. 提交前逐项核对

| 项 | 当前值 | 要不要改 |
|---|---|---|
| `<Repository>` | `ghcr.io/__GHCR_OWNER__/dsh:latest` | 渲染后确认 owner 正确 |
| `<Registry>` | GitHub 包页面 | 确认可访问 |
| `<Icon>` | `gh-proxy.com` 代理到本仓库 `main` 的 `templates/img/dsh.png` | 见下方「图标宿主」 |
| `<Category>` | `Tools:` | CA 的分类树，按需调整（例如加 `Productivity:`） |
| `<Overview>` / `<Description>` | 中英双语 | CA 会展示，欢迎润色 |
| `<ExtraParams>` | 两个 `--security-opt` | **不要删**，删了 bash 工具就废 |
| `<WebUI>` | `http://[IP]:[PORT:8080]/` | 端口与模板一致 |
| 卷 | `/data`、`/workspace` → `appdata/dsh/...` | 首次启动会 chown 成 `1000:1000` |
| `<Support>` | 仓库 Issues | **提交前必须换成论坛支持帖** |

### 5. 之后每次上游发版

`.github/workflows/release.yml` 每 6 小时检查一次 npm 上 `@deepseek-ai/dsh` 的最高版本（含 alpha/rc）；有新版本就构建、冒烟、推送镜像，并生成一个**版本锁定**的模板 XML 作为 release 资产。CA 里用户看到的始终是 `:latest`，需要可复现的人可以用 release 资产里的 pinned 模板。

### 图标宿主：为什么不用 raw 链接

实测（从本机 Unraid 宿主机发起，等同你家宽带的出口网络）：

| URL 形态 | 结果 |
|---|---|
| `raw.githubusercontent.com/...` | **超时**（国内直连不可用） |
| `cdn.jsdelivr.net/gh/...` | **超时** |
| `github.com/<owner>/<repo>/raw/...` | 302 跳到 raw（浏览器随后同样超时） |
| `ghproxy.net/https://raw.githubusercontent.com/...` | 200，约 1.0–1.9 s |
| **`gh-proxy.com/https://raw.githubusercontent.com/...`** | **200，约 0.2 s** |
| 自己域名（如 `www.meix.top`） | 200 |

代理返回的字节用 sha256 与经 API 直取的正本比对过（一致），不是"能打开就行"。若哪天代理失效：把 `<Icon>` 换成自己的域名托管或另一个代理即可，**图标破图不影响安装**。
