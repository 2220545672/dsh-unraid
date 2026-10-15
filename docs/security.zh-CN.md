[English](security.md) · **中文**

# 安全模型

这份文档解释容器在**网络层**做了什么。用户只需要知道结论：把它放在会替你鉴权的边缘之后（或用受信内网），需要时设置 `PUBLIC_URL`，**不要把 lan 模式暴露到公网**。

## DSH 自身的浏览器信任栅栏

DSH 有一道防止"浏览器被第三方页面操纵"的检查（实现位于其 `dsh-client-connection` 包）：

- 请求的 `Host` 必须是 **loopback**、容器的**监听绑定地址**，或显式通过 `--trusted-host` 声明的 authority；
- 如果请求带了 `Origin`，它必须与 `Host` 同源；
- `Sec-Fetch-Site: cross-site` 的请求一律拒绝。

`dsh web` 因此有两个硬性前提：**不能绑定通配地址**（必须给具体 IP），以及**前面必须有一层知道对外 authority 的代理**。本镜像的做法是：DSH 只监听 `127.0.0.1:3080`，对外由内置的 Caddy 监听 `8080`。

## 两种模式

| | edge 模式 | lan 模式 |
|---|---|---|
| 触发条件 | 设置了 `PUBLIC_URL` | `PUBLIC_URL` 为空 |
| Host 处理 | 改写成 `PUBLIC_URL` 的 authority | 固定为 loopback |
| Origin 处理 | 保留，并拒绝任何不等于 `PUBLIC_URL` 的 Origin | **剥掉** Origin |
| 传给 DSH 的参数 | `--public-url <origin> --trusted-host <authority>`（外加 `DSH_TRUSTED_HOSTS` 里的条目） | 无 |
| 适用 | 反代 + SSO、VPN、HTTPS 入口 | 只能从受信网络访问 |

两种模式下防 DNS rebinding 与防跨站都仍然有效：

- **rebinding** 伪造不出合法的 `Host`（edge 模式要求等于 `PUBLIC_URL`，lan 模式固定为 loopback）；
- **跨站请求**由 DSH 的 `Sec-Fetch-Site` 规则与 Origin 校验拦下。

lan 模式**没有**"对外 authority"的概念，所以它无法为公网访问提供正确的 Host/Origin 判定——这就是"不要暴露到公网"的原因，而不是因为少了一层密码。

## 谁可以连接：`ALLOWED_CLIENTS`

容器在代理层维护一份白名单，**不在这份名单里的来源拿不到任何页面**——请求根本到不了 DSH：

- **IP 或 CIDR** 与连接来源地址比对；**主机名**与请求的 `Host` 头比对。两者可以混写：`127.0.0.1,192.168.0.0/16,dsh.example.com`。
- **回环地址永远放行**（`127.0.0.1`、`::1` 会被自动加入）——容器自身的健康检查走回环，收掉它健康检查就会失败。
- 不在白名单的请求得到 `403 Forbidden: this client is not listed in ALLOWED_CLIENTS`。
- 放在反向代理后面时，连接来源是**代理的地址**，所以要把代理地址加进白名单（此后由代理自己的鉴权决定谁能进来）。若想按**真实客户端 IP** 判定，用 `TRUSTED_PROXY_CIDRS` 声明代理所在网段：Caddy 只对这些来源读取 `X-Forwarded-For`。
  ⚠️ **切勿**把不可信客户端也能发起的网段填进 `TRUSTED_PROXY_CIDRS`——那等于允许任何人伪造来源地址绕过白名单。它默认是空的正是这个原因：默认按对端地址判定，伪造不了。

默认值有两个来源，别混淆：

| 场景 | 默认放行 | 说明 |
|---|---|---|
| Unraid 模板 / `compose.yaml` | 回环 + 私有网段（10/8、172.16/12、192.168/16）+ 链路本地 + CGNAT/Tailscale（100.64/10） | 开箱即用；`docker run` 请照抄模板的值 |
| 镜像自身（未设该变量） | 仅回环 | 安全默认；经发布端口访问会得到 `403` |

### 排障：界面返回 403

1. 在容器日志里看 `access control: clients …` 这一行——它打印的就是实际生效的白名单；
2. 把你的网段（如 `192.168.0.0/16`）或反向代理的地址加进 `ALLOWED_CLIENTS`；
3. 经代理访问时，再按需设置 `TRUSTED_PROXY_CIDRS`。

实现位置在 `docker/entrypoint.sh`（解析 + 生成）与 `docker/Caddyfile.{lan,edge}`（标记注入）。规则必须放在 **`handle` 块**里：实测裸 `respond` 会被后面的 `route` 抢走，而裸 `route` 又会输给 `route /healthz`——两种写法都会让外部来源**静默通过**（返回 200）。`scripts/smoke.sh` 因此专门用另一个网络上的客户端容器来断言 403/200，防止以后改坏。

## 两种模式都会做的事

- **受管端点返回 403**：`/api/settings.openDocument`、`/api/settings.openSettingsDocument` 这类"在桌面端打开文件"的端点对远程调用没有意义，且会扩大攻击面，直接拒绝。
- **注入安全响应头**：CSP、`X-Frame-Options: DENY`、`Referrer-Policy`、`X-Content-Type-Options` 等。
- **登录引导**：把 DSH 启动时打印的一次性 token 用内部重写交给首次访问者，换取签名会话 cookie（`dsh-auth-*`）。浏览器地址栏里不会出现 token。

## 容器本身

- 以 uid/gid `1000` 运行（镜像内的非 root 账户），启动时把 `/data`、`/workspace` 的属主调整为 `1000:1000` 再降权。
- **不挂载** docker socket、`/boot` 或任何宿主目录（除用户显式映射的两个卷）。
- 模板里**不要求**任何密钥；模型凭据由你在应用界面里配置，存放在 `/data`。
- `AUTH_MODE=builtin`（默认）在容器内提供口令门禁：口令只用于换取一个 HMAC 门禁 Cookie（同时覆盖普通请求与 WebSocket 握手），`/healthz` 保持免认证；改口令或删除 `/data/caddy/data/auth-gate-salt` 会让已签发的 Cookie 全部失效。
- **登录 Cookie 失效时**（跨镜像更新、容器重建、或同主机另一个 DSH 实例——Cookie 不区分端口）：容器会**自动**把文档请求绕一次 `/renew`（带短时标记，不会成环）重放启动 token、签发新会话 ✓ —— 用户通常只需刷新；也可手动访问一次 `/renew`，或清掉该站点 Cookie。
- `AUTH_MODE=none` 才把鉴权交给边缘（**选了它就别再叠容器自带门禁**，否则用户被问两次口令）；其它取值（含同类镜像默认的 `caddy-security`）会让容器**拒绝启动**，避免出现"看起来有认证、实际很弱"的假象。
- ⚠️ 口令经明文 HTTP 传输时可被监听：公网暴露必须由前面的反向代理提供 HTTPS。
- ⚠️ **模板自带默认口令 `12345678`**（为了"装完即可登录"，这是刻意的便利取舍）：默认值是公开的，**在改掉之前门禁形同虚设**——任何能到达该端口的人都能进来。entrypoint 每次启动都会打印 `SECURITY:` 告警，README 与模板描述都把"先改口令"放在第一步；不想用默认值就把 **Password** 留空（首启随机生成并打印一次）。

## 容器外层为什么放宽了两项

模板的 `Extra Parameters` 里有：

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

这是为了让**容器内层**的 `bubblewrap` 能创建命名空间，从而给智能体的命令执行提供真正的隔离。取舍与对照实验见 [unraid-sandbox.zh-CN.md](unraid-sandbox.zh-CN.md)。
