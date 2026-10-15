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
