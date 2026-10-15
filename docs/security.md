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

## 两种模式都会做的事

- **受管端点返回 403**：`/api/settings.openDocument`、`/api/settings.openSettingsDocument` 这类"在桌面端打开文件"的端点对远程调用没有意义，且会扩大攻击面，直接拒绝。
- **注入安全响应头**：CSP、`X-Frame-Options: DENY`、`Referrer-Policy`、`X-Content-Type-Options` 等。
- **登录引导**：把 DSH 启动时打印的一次性 token 用内部重写交给首次访问者，换取签名会话 cookie（`dsh-auth-*`）。浏览器地址栏里不会出现 token。

## 谁可以连接：`ALLOWED_CLIENTS`

上面两节讲的是"请求进来之后"如何判定；`ALLOWED_CLIENTS` 决定的是**请求能不能进来**，默认 `127.0.0.1`（只有本机）。

- **IP / CIDR** 按连接来源地址匹配；**域名**按 `Host` 头匹配。两者可以混写：`127.0.0.1,192.168.0.0/16,dsh.example.com`。
- **回环地址永远放行**（`127.0.0.1`、`::1` 会被自动加入），因为容器自身的健康检查就是从回环发起的——否则你把白名单写成只含域名时，容器会一直报不健康。
- 不在白名单的请求得到 `403 Forbidden: this client is not listed in ALLOWED_CLIENTS`，不会到达 DSH。
- 前面有反向代理时，容器看到的对端是**代理的地址**，所以要把代理地址加进白名单（此后由代理自己的鉴权决定谁能进来）；如果你想让白名单按**真实客户端 IP** 判定，再填 `TRUSTED_PROXY_CIDRS`，Caddy 就只对这些来源读取 `X-Forwarded-For`。
  ⚠️ **不要把不可信客户端也能发起的网段填进 `TRUSTED_PROXY_CIDRS`**——那等于允许任何人伪造来源地址绕过白名单。这也是为什么它默认是空的：默认按对端地址判定，伪造不了。

实现位置在 `docker/entrypoint.sh`（解析 + 生成）与 `docker/Caddyfile.{lan,edge}`（标记注入）。规则必须放在 **`handle` 块**里：实测裸 `respond` 会被后面的 `route` 抢走，而裸 `route` 又会输给 `route /healthz`——两种写法都会让外部来源**静默通过**（返回 200）。`scripts/smoke.sh` 因此专门用另一个网络上的客户端容器来断言 403/200，防止以后改坏。

## 容器本身

- 以 uid/gid `1000` 运行（镜像内的非 root 账户），启动时把 `/data`、`/workspace` 的属主调整为 `1000:1000` 再降权。
- **不挂载** docker socket、`/boot` 或任何宿主目录（除用户显式映射的两个卷）。
- 模板里**不要求**任何密钥；模型凭据由你在应用界面里配置，存放在 `/data`。
- `AUTH_MODE` 只接受 `none`：其它取值会让容器拒绝启动，避免出现"看起来有认证、实际很弱"的假象。鉴权明确交给边缘。

## 容器外层为什么放宽了两项

模板的 `Extra Parameters` 里有：

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

这是为了让**容器内层**的 `bubblewrap` 能创建命名空间，从而给智能体的命令执行提供真正的隔离。取舍与对照实验见 [unraid-sandbox.md](unraid-sandbox.md)。
