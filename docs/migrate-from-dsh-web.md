# 从现在的 `dsh-web` 迁移到本仓库的镜像

这份文档假设你目前的部署是 **`dsh-web`**（镜像 `ghcr.io/okxlin/deepseek-harness:latest`，`127.0.0.1:3080→8080`，SWAG 反代 `dsh.meix.top`，`AUTH_MODE=none`），要换成自建的 **`DSH`**（`ghcr.io/2220545672/dsh`）。

## 先想清楚三件事

1. **容器名会变**。Unraid 的容器名取自模板的 `<Name>`，本模板是 `DSH`，而 SWAG 的 `proxy-confs` 里现在写的是 `dsh-web:8080`。**不更新 SWAG 就会 502**。两种做法：
   - 推荐：迁移后把 SWAG 里该站点的 `set $upstream_dsh dsh-web:8080;` 改成 `dsh:8080`，`docker exec swag nginx -t && docker exec swag nginx -s reload`；
   - 或者：新建容器时把名字手动改成 `dsh-web`（模板编辑里改 `<Name>`），SWAG 就不用动。
   > SWAG 与容器必须在同一 docker 网络（你这台是 `proxy-net`）才能解析容器名。
2. **数据可以原地复用**。模板默认把 `/data` 指到 `/mnt/user/appdata/dsh/data`，但你现在用的是 `/mnt/user/appdata/deepseek-harness/data`。不想搬数据就把模板里两个 Path 改回旧路径（`…/deepseek-harness/{data,workspace}`），**会话与凭据原样保留**。想用新路径就 `mv`，注意保持属主为 `1000:1000`。
3. **切换会中断当前会话**。你现在这个 DSH 会话就跑在 `dsh-web` 里，停旧容器 = 页面断线。建议：先建好新容器（换一个宿主端口，例如 `127.0.0.1:3081`），验证通过后再把端口与 SWAG 切过去，最后删旧容器。**不要在会话里直接 `docker rm -f dsh-web`**。

## 迁移步骤（最小中断）

### 1. 先建新容器（不动旧的）

Unraid `Docker → Add Container` → 导入 `templates/dsh.xml`，然后改这几处：

| 字段 | 建议值 | 理由 |
|---|---|---|
| 名称 | `DSH`（或 `dsh-web`，见上） | 决定容器名 |
| 端口 | 先 `127.0.0.1:3081` | 避开正在跑的 3080，可并行验证 |
| `/data` | 旧路径 `…/deepseek-harness/data` | 免搬数据 |
| `/workspace` | 旧路径 `…/deepseek-harness/workspace` | 同上 |
| `PUBLIC_URL` | `https://dsh.meix.top` | 你现有的对外地址，走 edge 模式 |
| Extra Parameters | **保持默认**（两个 `--security-opt`） | 否则 bash 工具在 Unraid 上不可用 |

### 2. 验证

```bash
ssh unraid 'docker ps --filter name=DSH --format "{{.Names}} {{.Status}} {{.Ports}}"'
ssh unraid 'docker logs --tail 40 DSH'
ssh unraid 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3081/healthz'   # 期望 200
```

再在浏览器打开 `http://<宿主IP>:3081`，确认能进界面、且随便让它跑一条命令（例如 `pwd`）**不报 `SANDBOX_UNAVAILABLE`** —— 这一步是在验证 bubblewrap 真的可用（见 [unraid-sandbox.md](unraid-sandbox.md)）。

### 3. 切换

```bash
# 3.1 把新容器端口改回 3080（Unraid GUI 里编辑容器 → 改端口 → Apply）
# 3.2 改 SWAG 上游（若容器名变了）
ssh unraid 'grep -rn "dsh-web" /mnt/user/appdata/swag/nginx/proxy-confs/ | head'
#     改完：
ssh unraid 'docker exec swag nginx -t && docker exec swag nginx -s reload'
# 3.3 浏览器验证 https://dsh.meix.top
# 3.4 确认无误后删掉旧容器（它本来就是"无主容器"，删了才干净）
ssh unraid 'docker rm -f dsh-web'
```

顺手跑一遍无主容器审计（应输出「审计结束」且无 ❌）：

```bash
ssh unraid 'for c in $(docker ps -aq); do n=$(docker inspect $c --format "{{.Name}}"|tr -d /); m=$(docker inspect $c --format "{{index .Config.Labels \"net.unraid.docker.managed\"}}"); p=$(docker inspect $c --format "{{index .Config.Labels \"com.docker.compose.project\"}}"); [ "$m" = dockerman ] || [ -n "$p" ] || echo "❌ 无主: $n"; done; echo "审计结束"'
```

新的 `DSH` 容器由模板创建，自带 `net.unraid.docker.managed=dockerman`，从此 Docker 页有正常的**更新入口**。

### 4. 回滚

旧容器删掉之前，回滚就是"把 SWAG 上游改回 `dsh-web:8080` + 启动旧容器"。旧容器删掉之后，用 `my-dsh-web.xml` 模板仍可重建（你的 `templates-user/` 里有它的备份）——但注意它现在指向 okxlin 的镜像，不是本仓库的。

## 之后每次上游发版

本仓库的镜像**自动跟版**：每 6 小时检查 npm 上 `@deepseek-ai/dsh` 的最高版本（含 alpha/rc），有新版本就构建、冒烟、推送，并建 `dsh-<版本>` 标签与 Release。你只需要在 Unraid 的 Docker 页点一次 **force update**（或等它提示 apply update）即可拿到新镜像，不需要改任何配置。
