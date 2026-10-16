[English](remote-signin.md) · **中文**

# 远程浏览器上用 DeepSeek 账号登录

> 当界面是通过局域网、Tailscale 或反向代理打开时，本容器怎么让「登录账号」这件事可用——而上游在这种情况下根本登录不了。把 `REMOTE_SIGNIN` 设为 `off` 即可回到上游行为。

## 问题（实测）

上游把**浏览器自己的 origin** 当作 OAuth 的 `redirect_uri` 交给平台，而 `@deepseek-ai/dsh-deepseek-account-platform` 只接受带显式端口的回环 HTTP origin。其它值在登录页打开之前就被拒。2026-10-16 对真实平台实测（`POST /auth-api/v0/dsh/auth_init`）：

| `redirect_uri` | 平台返回 |
|---|---|
| `http://127.0.0.1:47821/oauth/callback` | `{"code":0, … "authorize_url": …}`，`expires_in: 600` |
| `https://dsh.meix.top/oauth/callback` | `{"code":50005,"msg":"PAYLOAD_SCHEMA_MISMATCH"}` |

也就是说：DeepSeek **账号**登录只在「浏览器就跑着 DSH 的那台机器上」，或「用 `ssh -L` 把浏览器隧道过去」时可用。Unraid 上没有浏览器可跑，而为了登一次录去搭隧道代价太大。（**API Key** 从来没有这个限制，在界面上填好即可，从哪里访问都行。）

## 为什么不用那些显而易见的替代方案

| 想法 | 为什么不用 |
|---|---|
| 给平台一个公网 `redirect_uri` | 被拒：任何非回环值都返回 `50005`。这不是可配置项，镜像也说服不了平台。 |
| 在容器里跑一个浏览器登录（无头 Chrome + VNC） | 只有能访问那个浏览器的人才用得上，而且为了这一步要塞进一整套浏览器栈——镜像是 0.9 GB 级的。 |
| 改 Web UI，让操作者填一个自己能转发的回环端口 | 浏览器依然**够不到**那个端口；客户端转发器（SSH 隧道、代理、扩展）恰恰是这个容器想省掉的人工步骤。 |
| 继续让人用 `ssh -L` | 可行，本文下方仍然保留这条路——但它要求客户端有 SSH、知道 DSH 发布的端口，还要专门开一个 `http://127.0.0.1:<端口>` 的标签页。 |

## 原理

平台的检查针对的是它拿到的**字符串**，而真正必须访问到那个地址的是浏览器。把这两件事拆开，就是全部技巧：

```
1.  浏览器（https://dsh.meix.top）        你点「登录账号」
        │
        │  account/startSignIn，callbackOrigin = "https://dsh.meix.top"
        ▼
2.  DSH 宿主 + REMOTE_SIGNIN overlay      不是回环 origin，于是换成声明的回环 origin
        │
        │  auth_init(redirect_uri = "http://127.0.0.1:47821/oauth/callback")
        ▼
3.  platform.deepseek.com                 接受这次声明，返回 authorize_url
        │
        │  浏览器打开登录页，你完成登录
        ▼
4.  浏览器                                 平台把它重定向到
        │                                   http://127.0.0.1:47821/oauth/callback?code=…
        ▼                                   那里没人监听 → 浏览器显示自己的错误页，
     「无法访问此网站」                       而 code 与 state 还留在地址栏里
        │
        │  你把那个地址粘到 /remote-login
        ▼
5.  DSH 宿主：/remote-login → /oauth/callback   上游自己的回调路由：校验本进程生成的
        │                                       一次性 `state`，用在内存里的 PKCE
        │                                       verifier 换取凭据并落盘
        ▼
6.  登录对话框变成已登录
```

本镜像安装并钉住的那个[插件](https://github.com/2220545672/dsh-remote-signin)里对应两半：

* **声明（claim）**——`src/index.js` 包住 `deepseekAccount.startSignIn`，把非回环的浏览器 origin 换成 `REMOTE_SIGNIN_ORIGIN`（默认 `http://127.0.0.1:47821`）。本来就在回环上的浏览器原样放行，所以桌面应用和 `ssh -L` 会话的行为与上游完全一致。
* **回传路径**——`assets/inpage.js` 被注入 DSH 文档，在有登录等待时把粘贴框放进页面；`assets/bridge.html` 是同样功能的独立页面 `/remote-login`。两者都只从你粘贴的地址里取 `code` 和 `state`，发到**你此刻正在使用的这个 origin** 上的 `/oauth/callback`。除此之外不发给任何地方，两者也没法被当作跳板。

镜像本身只决定**是否**加载插件、以及**用哪个声明**（`REMOTE_SIGNIN`、`REMOTE_SIGNIN_ORIGIN`，以及入口脚本传给 launcher 的 `--patch`）。插件的代码、面板与页面都在它自己的仓库里维护。

## 它刻意不做的事

* **不放松任何校验。** 结束登录的是本服务器上上游自己的路由，用上游的一次性 `state` 校验和上游的 PKCE verifier。插件只决定「注册哪个回环**字符串**作为重定向目标」。
* **不改动已经处于回环的浏览器。** 隧道 / 桌面应用那条路径没有任何行为变化，不需要重新验证、也没有新的风险。
* **不保存、不打印 code / state / token。** 它每次尝试只写一行日志：本次声明用的 origin。
* **不开放任何端口。** 声明只是一个字符串：服务器和你本机都没有任何东西监听 `127.0.0.1:47821`。
* **绝不会成为容器起不来的原因。** 插件缺失、资源读不到、语法错误，或将来上游改名，容器都只会退回上游行为并在日志里留一行。

## 安全说明

* `/remote-login` 与界面其余部分在同一道门禁之后（`AUTH_MODE=builtin`，或前面代理的鉴权）。必须如此：它会把一个带凭据的 URL 交给服务器。
* 你粘贴的地址里含**授权码**。它一次性有效、绑定本次尝试的 PKCE verifier，并随本次尝试一起过期（上游 10 分钟）。页面只把它发到本 origin，不会回显进 DOM，并且设置了 `Referrer-Policy: no-referrer`，避免通过 referrer 泄露。
* `/oauth/callback` **只在有登录尝试等待时存在**；没有进行中的尝试时该路径返回 `404`（`scripts/smoke.sh` 有断言）。所以单靠这个页面什么也完成不了。
* 声明的端口刻意选在操作者机器上不太可能被占用的位置（`47821`）。这一点有意义：如果你自己的电脑恰好有东西监听那个端口，浏览器就会把授权码交给它，而不是显示错误页。介意的话把 `REMOTE_SIGNIN_ORIGIN` 指到别的端口即可——看着空闲的端口都行，改它没有代价。

## 使用步骤

1. 在 DSH 界面点 **Sign in** 用 DeepSeek 账号登录。登录页在新标签页打开，在那里完成登录。
2. 那个标签页随后会停在 `127.0.0.1` 的「无法访问此网站」错误页。**这一步是预期的。** 选中它的地址栏，复制整个地址。
3. 回到 DSH 标签页：**右下角已经自己出现了粘贴面板**（只要有一次登录在等待，插件就会把它显示出来）。把地址粘进去，点 **完成登录**。面板会把授权码发出去，并把服务器的回答就地显示：已登录 / 已过期 / "这不是等待中登录的回调地址"。
4. 那个标签页里的登录对话框会变成已登录，登录标签页会自己关闭。

**不需要跳转、也不需要记住任何地址**——面板就是流程本身。`/remote-login` 提供同样功能的独立页面，用于面板不在的场合（浏览器扩展拦了脚本、页面加载后 `REMOTE_SIGNIN` 被关掉等）；它的地址在启动日志里。

请**在约 10 分钟内、并且针对同一个容器**完成：授权码属于那次登录，随它一起过期；重建容器（更新、改设置）也会把它作废。真超了也不算故障——重新点一次登录即可。

`docker logs <容器名> | head -30` 会打印独立页面的地址，插件加载时也会自报声明与自身版本：

```
[entrypoint] remote sign-in: on — a remote browser finishes the sign-in in the DSH page;
             the standalone page is https://dsh.example.com/remote-login
[remote-signin] active — v0.1.1, claim http://127.0.0.1:47821, panel at
             /remote-signin/inpage.js, page at /remote-login
```

（没设 `PUBLIC_URL` 时容器无从知道你发布的宿主端口，所以那一行只给路径和"你自己的端口"，不做猜测。）

### 无缝替代方案（不用粘贴）

如果你不想粘贴，就用自己的回环 origin 打开界面——那条路完全是上游流程，不涉及声明、也没有面板：

```bash
ssh -N -L 3081:127.0.0.1:3080 root@<服务器>     # 后面这个端口是你把 8080 映射到的那个
```

然后用 `http://127.0.0.1:3081` 打开界面并在那里登录。凭据存在服务端，所以这是一次性动作。两条路的终点相同；面板只是为"手边没有隧道"的时刻准备的。

## 设置

| 变量 | 默认值 | 含义 |
|---|---|---|
| `REMOTE_SIGNIN` | `on` | `on` = 加载[插件](https://github.com/2220545672/dsh-remote-signin)（声明回环 origin、把面板注入页面、提供 `/remote-login`）；`off` = 上游的「仅回环」行为。填其它值容器拒绝启动。 |
| `REMOTE_SIGNIN_ORIGIN` | `http://127.0.0.1:47821` | 向平台声明的回环 origin。必须是 `http://` + `127.0.0.1` / `localhost` / `[::1]` 之一 + 显式端口；那里不能有任何监听。 |

插件版本由 [Dockerfile](../Dockerfile) 的 `REMOTE_SIGNIN_VERSION` 构建参数钉住（当前 `v0.1.1`）：镜像拿到的是它构建时测试过的那个版本，而插件自身的 CI 负责验证它。

## 排障

| 现象 | 含义 |
|---|---|
| 面板一直不出现 | 插件没加载：`docker logs <容器名> \| grep remote-signin` 会说明原因（`off`、包缺失，或 `INACTIVE`）；`/remote-login` 仍然可以手动粘贴。 |
| 对话框一直停在 *waiting for browser* | 在你往面板里粘贴之前就是这样；10 分钟后过期。 |
| 面板说这不是回调地址 | 复制错了标签页，或地址被截断：必须同时含 `code=` 与 `state=`，形如 `http://127.0.0.1:<端口>/oauth/callback?…`。 |
| 面板（或页面）说**没有正在等待的登录**（`404`） | 这次登录已经没了——面板会把服务器自己的回答显示出来，而不是把你丢在一个空白错误页上。两种常见原因：① 超过约 10 分钟过期；② 它属于**另一个 DSH 实例**——重建/升级容器会作废它，而前一个实例遗留的标签页看上去还停在"等待登录"。请在**你正在用的那个标签页**里重新发起登录。 |
| 面板说 state 不匹配（`400`） | 地址来自另一次尝试，或这个 code 已经被用掉了。重新点一次 **Sign in**。 |
| 登录标签页显示 DeepSeek 报错而不是登录表单 | 插件没加载，声明没生效，上游拒了这个 origin。`docker logs <容器名> \| grep remote-signin` 会说明原因。 |
| 想回到旧行为 | `REMOTE_SIGNIN=off`（或移除插件），然后重建容器。 |

## 各部件的位置

| 镜像内路径 | 在哪维护 | 作用 |
|---|---|---|
| `/app/node_modules/dsh-remote-signin/src/index.js` | [dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin) → `src/index.js` | 声明、静态资源路由、面板注入。 |
| `/app/node_modules/dsh-remote-signin/assets/inpage.js` | 同一仓库 → `assets/inpage.js` | 出现在 DSH 页面里的面板。 |
| `/app/node_modules/dsh-remote-signin/assets/bridge.html` | 同一仓库 → `assets/bridge.html` | `/remote-login` 的独立页面。 |
| `/app/node_modules/dsh-remote-signin/cordis.patch.yml` | 同一仓库 → `cordis.patch.yml` | 入口脚本用 `--patch` 传入的加载条目。 |
| `/usr/local/bin/entrypoint.sh` | 本仓库 | 决定是否加载插件、校验 `REMOTE_SIGNIN_ORIGIN`、在日志里给独立页面地址。 |
| `/etc/caddy/Caddyfile.{edge,lan}` | 本仓库 | 不为插件单独开路由：`/remote-login` 与 `/remote-signin/*` 与其它路径一样走反代，并同样处于门禁之后。 |

镜像钉住插件仓库的 **tag**（`REMOTE_SIGNIN_VERSION`，当前 `v0.1.1`）：插件自己的 CI 验证它，镜像拿到的是构建时使用的那个版本。上游处于开发者预览阶段——若 `deepseekAccount.startSignIn` 或平台的回调契约发生变化，插件会自行停止生效（并在日志里说明），而不是让容器坏掉；届时只是不再提供粘贴这条路径，`REMOTE_SIGNIN=off` 是显式回到上游行为的方式。
