# 前人踩过的坑 —— 提交 CA 之前必须规避的清单

来源有两类：**官方文档**（`ca.unraid.net` Submit → Docs，2026-10-15 抓取）与**论坛实证**（维护者与 CA 作者的帖子，含具体后果）。
每条都标注了对本仓库的处置：✅ 已规避 / ⚠️ 需要你注意 / ❓ 需要你决定。

---

## A. 硬性门槛（不满足就是提交流程走不下去）

| # | 坑 | 依据 | 我们的处置 |
|---|---|---|---|
| A1 | **仓库根目录必须有 `ca_profile.xml`，且 `<Profile>` 非空**，否则"CA will block submission finalization" | 官方《Repository Information XML》 | ✅ 已补 [`ca_profile.xml`](../ca_profile.xml)（含 Profile / Icon / WebPage，`<Forum>` 留注释待填） |
| A2 | 仓库必须**公开、活跃**，且根目录有 **OSI 认可许可证** | 官方《Submission Help》 | ✅ 公开仓库 + MIT `LICENSE` |
| A3 | 每个应用条目必须有 `<Repository>`（Docker）或 `<PluginURL>`（插件） | 官方《Repository XML Format》 | ✅ `<Repository>` 指向 `ghcr.io/2220545672/dsh:latest` |
| A4 | 提交后要跑 **Validate / Scan**，且"每次有意义的 XML 改动后都要重跑" | 官方《Submission Help》 | ⚠️ 这一步只能在你的 Unraid 上做（见 [ca-submission.md](ca-submission.md)） |
| A5 | **`:latest` 标签不存在会被拉黑**（实例：`ntop/ntopng is blacklisted with ":Latest tag does not exist"`） | 论坛 | ✅ 流水线**永远**同时推 `:latest` 与 `:<版本>`；不要改成只推版本号 |
| A6 | **声明与实际不符会被下架**：Unspin 因 `PluginURL` 与 .plg 内声明不一致被 CA 移除，修好后**仍需 moderator 手工重新上架**，等了数天 | 论坛 | ⚠️ `<Repository>`/`<TemplateURL>`/`<Registry>`/`<Icon>` 一律指向稳定、真实、短期内不会迁移的位置；**镜像与仓库名一旦提交就不要改** |

## B. 上架之后才发现就晚了

| # | 坑 | 依据 | 我们的处置 |
|---|---|---|---|
| B1 | **模板改动不会同步到已安装的机器**：CA 安装时把模板**拷贝**一份到 `templates-user/my-*.xml`，"Nothing you change updates existing installations. Installing makes a copy of what it was at that time, done." | 论坛（CA 作者帖） | ⚠️ 因此：① 需要长期存在的关键行为必须落在**镜像**里，而不是模板字段；② 目前唯一依赖模板字段的关键项是 `ExtraParams` 里那两个 `--security-opt`——**万一将来要改，老用户不会自动获得**，所以镜像在沙箱不可用时必须给出可执行的报错（现在是 `SANDBOX_UNAVAILABLE` + 文档链接）；③ 真要改模板时，先在支持帖里发公告 |
| B2 | 连**纯信息字段**也会被钉住：维护者更新 `<Overview>` 后，CA 里显示新的，但已安装机器的 **Docker 页面仍显示旧文案**（`my-*.xml` 里是安装那一刻的副本） | 论坛（PassForge 维护者实测） | ⚠️ 所以 `<Overview>` 不要写"最新版本是 X"这类会过期的内容；我们把版本信息交给镜像标签与 Release |
| B3 | **CA 中心 feed 会停摆**：2026-09-13→09-15 中心 feed 未重建，维护者改了模板在 CA 里看不到（不是你的错） | 论坛 | ⚠️ 若提交后长时间不出现，先查 CA 状态面板的 "Last Change To Application Feed"，别急着反复改模板 |
| B4 | **审核是人工的，且有等待**：Claude Code 插件"sent in the application last night"次日才出现；OpenClaw 长时间"still waiting on approval" | 论坛 | ⚠️ 预留数天；这期间不要反复提交 |
| B5 | **被标记废弃 = 用户失去安全更新**：Paperclip 模板因停止维护被 deprecated，作者明说"you won't receive updates, including security fixes" | 论坛 | ✅ 我们的跟版流水线每天检查上游并自动构建推送；维护成本被压到"上游发版即自动" |

## C. 审核者会盯的点（AI 类应用尤其）

| # | 坑 | 依据 | 我们的处置 |
|---|---|---|---|
| C1 | **"AI 生成、缺少人工审查"是明确的扣分项**：CA 社区开发者原话——"both plugins give me a very solid sense of 'this was AI-coded without a substantial human review / understanding of what it does'"，并指出不符合约定会引发"quality/safety"担忧 | 论坛（Community Developer） | ✅ 代码量小且可解释：Dockerfile + 两个 Caddyfile + 一个 entrypoint + 三个脚本；有冒烟测试、模板自检、沙箱对照实验文档。**你本人要能讲清每一处**（尤其两个 `--security-opt`） |
| C2 | **"别人会替我审代码"是错误预期**："It's your plugin. You write it, not the CA team… This expectation that someone else will do a code review for you is wrong." | 论坛 | ⚠️ 上架即你负责；支持帖要给出排障路径 |
| C3 | **容器比插件更被鼓励**："Plugins which are better suited as a docker application are not eligible for inclusion in CA"，且容器"better from a security/safety standpoint" | 论坛（Community Developer 转述 CA 政策） | ✅ 我们走 Docker 模板路线（正确的那条） |
| C4 | **root / docker.sock / `/boot` / 模板里的凭据**是审核重点：社区明确列出 `/boot`、`/var/run/docker.sock` 属于应当排除的宿主路径；另一帖强调"Claude Code running as root has unrestricted ability…" | 论坛 | ✅ 容器内先 root 初始化再降权到 **uid 1000**；不挂 docker socket、不挂 `/boot`；**模板里不要求任何 API key**（模型凭据由 DSH 自己在 `/data` 里管理） |
| C5 | **运行时下载可执行文件会被要求整改**：OpenClaw 为符合 CA 标准改成"Homebrew no longer automatically downloaded" | 论坛 | ✅ 所有外部二进制（Caddy、Node 依赖）都在**构建期**获取；容器启动时只读现有文件 |
| C6 | **CVE 与依赖面**会被拿来质疑（MCP 相关三枚 CVE 被反复引用） | 论坛 | ⚠️ 我们的依赖面是官方 npm 包 `@deepseek-ai/dsh` 的封闭依赖树 + Caddy 官方 release；镜像开启 `sbom` 与 `provenance` 证明，可在支持帖里给出 |

## D. 需要你决定的一件事

| # | 事项 | 建议 |
|---|---|---|
| D1 | 是否标记 `<Beta>true</Beta>` | 官方字段说明里 `<Beta>` 是"Legacy beta marker. Only true survives"；**上游 DSH 目前只有 alpha/rc 版本**（我们跟的是最高 semver，含预发布），但**这个打包本身是稳定的**。我的建议：**先不标**，改为在支持帖标题与 `<Overview>` 里如实写明"上游仍是预发布、镜像跟随最新版"。若审核者建议标 Beta，再改（注意 B1：改模板不影响已安装机器，但影响新用户） |

---

## 提交前的自查命令

```bash
# 1. 官方门槛：ca_profile.xml 存在且 <Profile> 非空；模板带齐 minimum/recommended 字段
node scripts/check-template.mjs templates/dsh.xml

# 2. 渲染一份"发布用"模板并再查一遍（release 资产就是这么生成的）
node scripts/render-template.mjs --owner=2220545672 --repo=dsh-unraid --tag=latest --out=/tmp/dsh.xml
node scripts/check-template.mjs /tmp/dsh.xml

# 3. 镜像匿名可拉 + 多架构
curl -s "https://ghcr.io/token?scope=repository:2220545672/dsh:pull&service=ghcr.io" | head -c 80

# 4. 图标必须国内可达（raw 与 jsdelivr 都不行，见 docs/ca-submission.md）
curl -sI "https://gh-proxy.com/https://raw.githubusercontent.com/2220545672/dsh-unraid/main/templates/img/dsh.png" | head -1
```
