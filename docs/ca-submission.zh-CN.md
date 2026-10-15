[English](ca-submission.md) · **中文**

# 把模板提交到 Unraid Community Applications

面向本仓库维护者（fork 后同理）。**先读 [ca-pitfalls.md](ca-pitfalls.zh-CN.md)**：那是官方文档 + 论坛实证整理出的坑清单，含"声明不符被下架""模板改动不回流到已安装机器""废弃即失去安全更新"等真实后果。这里只讲操作顺序。

## 一、官方硬性门槛（缺一项就卡在提交环节）

| 要求 | 依据 | 本仓库状态 |
|---|---|---|
| 仓库**公开且活跃** | Submit → Docs → Submission Help | ✅ |
| 根目录有 **OSI 认可许可证** | 同上 | ✅ MIT |
| 根目录有 **`ca_profile.xml` 且 `<Profile>` 非空** | Docs → Repository Information XML | ✅（`<Forum>` 待填支持帖） |
| 每个应用条目有 `<Repository>`（Docker） | Docs → Repository XML Format | ✅ |
| 提交时跑 **Validate → Scan**（入口是 **`/submit/new`**），且每次有意义的 XML 改动后重跑 | Docs → Submission Help / Builder Guide | ⚠️ 只能在你的 Unraid / CA 界面里做 |
| 仓库布局符合官方建议：根目录 `README.md`、`LICENSE`、`.gitignore`、**`icon.svg`**、`ca_profile.xml`，模板放在 `templates/` | Docs → Builder Guide | ✅ 已补齐 `icon.svg`（矢量，由 `scripts/make-icon-svg.mjs` 生成）；布局由 `scripts/check-repo.mjs` 断言 |
| 不能留着 starter 的占位值（官方原文：占位图标"会被提交流程拒绝"） | Docs → Builder Guide | ✅ `check-repo.mjs` 会扫 `YOUR_GITHUB_USERNAME`/`example-app` 等占位值 |

模板里的 minimum/recommended 字段由 `scripts/check-template.mjs` 断言（Name / Repository / Category / Icon / Overview / Project / Support / TemplateURL 一个不空，卷与 Config 路径一致，沙箱参数在位），**validate 工作流与每次 release 资产生成都会跑它**。

> 老路子 `selfhosters/unRAID-CA-templates` 已停止接收新模板（其 PR 模板原文：*"We are no longer accepting new proposals"*），不要在那边花时间。

## 二、提交前的本地核对

```bash
# 0. 仓库布局 + 占位符扫描（对照 Builder Guide）
node scripts/check-repo.mjs

# 1. 模板自检（含 CA 门槛）
node scripts/check-template.mjs templates/dsh.xml

# 2. 镜像匿名可拉（未登录也要成功）
docker pull ghcr.io/<owner>/dsh:latest

# 3. 模板装得起来
#    Unraid: Docker → Add Container → 粘贴 templates/dsh.xml 内容（或导入 release 资产里的 dsh.xml）
#    装完确认：Web UI 打得开、/data 与 /workspace 持久化、
#             在 DSH 里跑一条命令不报 SANDBOX_UNAVAILABLE（沙箱可用，见 unraid-sandbox.md）
```

## 三、开论坛支持帖（CA 对自维护容器的要求）

CA 与模板指南都要求：**你自己维护的容器必须有 Unraid 论坛支持帖**，`<Support>` 要指向它，而不是 GitHub Issues。支持帖里至少写清：

- 这个应用是什么、镜像在哪、如何升级（本仓库是自动跟版，用户只需 force update）；
- **为什么需要那两个 `--security-opt`**（Unraid 内核无 Landlock → bubblewrap 是唯一可用的沙箱层级；见 [unraid-sandbox.md](unraid-sandbox.zh-CN.md)）——这是审核者与用户最可能追问的一点；
- 已知限制（上游仍是预发布，`:latest` 跟随最新版；内置口令门禁没有 2FA/审计，需要这些就把 `AUTH_MODE` 设为 `none` 交给 SSO）；
- **默认安全**：不配任何东西时装出来也是带口令的（`AUTH_MODE=builtin` + 首启生成口令打印一次），不会出现"装完就是一台无认证的可执行命令 Web UI"；CA 审核问起时这就是答案。
- 排障入口（`/healthz`、容器日志里 entrypoint 的前几行会写明模式与启动结果）。

开好之后，把两处 URL 填上：

```xml
<!-- templates/dsh.xml -->
<Support>https://forums.unraid.net/topic/<帖子ID>/</Support>
```
```xml
<!-- ca_profile.xml -->
<Forum>https://forums.unraid.net/topic/<帖子ID>/</Forum>
```

## 四、在 CA 界面提交

`ca.unraid.net` 的 **Submit** 工作区：填仓库地址 → **Validate**（解析 XML）→ **Scan**（重复应用与门槛检查）→ 预览 listing → 提交。**每次有意义的 XML 改动后都要重跑**，解析器会按最新模板重新生成 feed 条目。

其中"证明仓库归属"这一步会要求你在仓库里放一个 `.unraid/community-apps-claim.json`——**它不是密钥**，只有公开 nonce 与 claim code，由该流程生成后再提交进仓库。本仓库刻意不含此文件：必须由你走一次流程拿到与自己账号对应的那份。

## 五、提交前最后核对一遍

| 项 | 当前值 | 要不要改 |
|---|---|---|
| `<Repository>` | `ghcr.io/<owner>/dsh:latest` | 确认 owner 与仓库一致 |
| `<Registry>` | 对应 GitHub 包页面 | 确认可访问 |
| `<Icon>` | 经 `gh-proxy.com` 指向仓库里的 `templates/img/dsh.png` | 见下方「图标宿主」 |
| `<Category>` | `Tools:` | 按 CA 分类树调整 |
| `<Overview>` / `<Description>` | 中英双语 | ⚠️ 会被钉在用户安装那一刻，别写过期信息（见 ca-pitfalls.md B2） |
| `<ExtraParams>` | 两个 `--security-opt` | **不要删**，删了 bash 工具就废 |
| `<WebUI>` | `http://[IP]:[PORT:8080]/` | 与端口 Config 一致 |
| 卷 | `/data`、`/workspace` → `appdata/dsh/...` | 首次启动会 chown 成 `1000:1000` |
| `<Support>` | [论坛支持帖](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/) | ✅ 已替换（2026-10-15 发布在 Community → Docker Containers） |
| `<TemplateURL>` | 仓库 `main` 的 raw 模板地址 | 官方标为 recommended（identity and review 用） |
| `<ReadMe>` | 经代理指向仓库 README | starter 里带这个字段，Unraid 详情页会展示 |
| `<Requires>` | 保留模板的 Extra Parameters | 官方字段：系统要求文本，正好用来提醒沙箱前提 |
| `<Changes>` | 指向 Releases 页 | 官方字段：变更日志文本 |
| 根目录 `icon.svg` | 矢量版应用图标 | 官方布局要求；`ca_profile.xml` 的 `<Icon>` 指向它 |
| `<Category>` | `Tools:` | starter 注释说明可用 Apps 里的 **Application Categorizer** 插件生成精确分类，再替换 |
| `<ExtraSearchTerms>` | `deepseek harness dsh coding agent ai agent cli` | 让搜 "deepseek" 也能命中名为 DSH 的应用 |
| `<License>` | `MIT` | 详情弹窗展示 |
| `ca_profile.xml` 的 `<Forum>` | 同一个论坛帖 URL | ✅ 已填入并取消注释 |
| `<Beta>` | 未设置 | 见 [ca-pitfalls.md](ca-pitfalls.zh-CN.md) D1：建议先不标，但在支持帖里如实说明上游仍是预发布 |

## 六、之后每次上游发版

`.github/workflows/release.yml` 每天检查 npm 上 `@deepseek-ai/dsh` 的最高版本（含 alpha/rc），有新版本就构建、冒烟、推送镜像，并生成**版本锁定**的模板 XML 作为 release 资产。CA 里用户看到的始终是 `:latest`；要可复现的人可以用 release 资产里的锁定版本模板。

## 图标宿主：为什么不用 raw 链接

实测（中国大陆家宽出口）：

| URL 形态 | 结果 |
|---|---|
| `raw.githubusercontent.com/...` | **超时** |
| `cdn.jsdelivr.net/gh/...` | **超时** |
| `github.com/<owner>/<repo>/raw/...` | 302 跳到 raw（浏览器随后同样超时） |
| `ghproxy.net/https://raw.githubusercontent.com/...` | 200，约 1.0–1.9 s |
| **`gh-proxy.com/https://raw.githubusercontent.com/...`** | **200，约 0.2 s** |
| 自己的域名 | 200 |

代理返回的字节用 sha256 与经 API 直取的正本比对过（一致），不是"能打开就行"。若哪天代理失效：把 `<Icon>` 换成自己的域名托管或另一个代理即可，**图标破图不影响安装**。
