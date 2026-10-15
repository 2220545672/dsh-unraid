# 发布到 GitHub 并跑通第一次发布

面向 fork 本仓库的人（也作为本仓库维护者的操作手册）。整条链路是：**GitHub 仓库 → GitHub Actions 构建 → GHCR 镜像 → Release 里的版本锁定模板 → Community Applications**。

## 1. 建仓库并推送

新建 **公开** 仓库（CA 要求公开可读，图标 URL 也必须是公开地址），名称建议 `dsh-unraid`，**不要**勾选 "Add a README"（本地已有提交历史）：

```bash
git remote add origin git@github.com:<你的用户名>/dsh-unraid.git   # 或 https://github.com/<你的用户名>/dsh-unraid.git
git push -u origin main
```

## 2. 两个必须确认的仓库设置

| 设置 | 位置 | 不改会怎样 |
|---|---|---|
| **Workflow permissions = Read and write** | Settings → Actions → General → Workflow permissions | 新建仓库默认只读。只读时 workflow 里写 `packages: write` 也**不会**被授予，推送 GHCR 直接 403。 |
| **GHCR 包可见性 = Public** | 首次发布成功后：个人头像 → Packages → `dsh` → Package settings → Change visibility | GHCR 包关联公开仓库时通常自动公开；若仍是私有，Unraid 上匿名 `docker pull` 会 401。 |

另外两条 GitHub 行为值得知道：

- **公开仓库连续 60 天无活动，定时工作流会被自动停用。** 本仓库每 6 小时查一次上游，只要上游持续发版就不会触发；若上游长期停更，去 Actions 页面点一次 *Enable workflow*。
- 工作流之间按 `concurrency` 分组：同一分支上新的 release 运行会让**排队中**的旧运行直接作废，所以不会出现多个构建同时抢发布。

## 3. 第一次发布

推送本身就会触发 `release`（`push` 的 `paths` 覆盖 `Dockerfile` / `docker/**` / `scripts/**` / 工作流自身）。也可以手动：Actions → **release** → *Run workflow*。

| 输入 | 说明 |
|---|---|
| `version` | 留空 = 自动解析 npm 上 `@deepseek-ai/dsh` 的**最高 semver**（含 alpha/rc） |
| `force` | 勾上 = 即使 `dsh-<version>` 标签已存在也重建（用于重新发布同一版本） |

流程：解析版本 → 构建 amd64 → **冒烟测试**（不通过就不推）→ 构建并推送 amd64+arm64（`:版本`、`:latest`、`:alpha|rc|stable`）→ 建标签 `dsh-<version>` → 发 Release（附**版本锁定**的模板 XML 与图标）。

排障入口：

- `verify` 失败 = 镜像启动或冒烟断言没过，日志里会带出容器日志（`/healthz`、token 引导、跨站 403、两个 Caddyfile、`bwrap`）。
- `publish` 失败 = 多数是第 2 步的 Workflow permissions 没放开。
- `publish release and template` 失败 = 权限（`contents: write`）或 `gh` 缺失；该 job 对已存在的 Release 走 **clobber 更新**，重复发同一版本不会报错。

## 4. 让模板指向你的命名空间

仓库里的 `templates/dsh.xml` 保留 `__GHCR_OWNER__` / `__REPO__` / `__IMAGE_TAG__` 占位符，既避免硬编码也方便 fork；但 **CA 解析的是仓库里的实体文件**，所以提交 CA 前要渲染一次并提交（本仓库当前已按 `2220545672` 渲染）：

```bash
node scripts/render-template.mjs --owner=<你的用户名> --repo=dsh-unraid --tag=latest --out=templates/dsh.xml
node scripts/check-template.mjs templates/dsh.xml     # 提交前自检
git add templates/dsh.xml && git commit -m "chore: render template for <owner>" && git push
```

图标已提交在 `templates/img/dsh.png`。要换风格需先装 `sharp`：

```bash
pnpm add -D sharp && node scripts/make-icon.mjs --out=templates/img/dsh.png
node scripts/make-icon.mjs --flatten='#f4f4f6' --out=/tmp/preview-light.png   # 看浅色卡片观感
```

素材出处与商标说明见 `templates/img/src/README.md`。

## 5. 最后一步是 CA

镜像、模板、自动跟版都跑通之后，才轮到 Community Applications：见 [ca-submission.md](ca-submission.md)（硬性门槛、Validate/Scan 流程）与 [ca-pitfalls.md](ca-pitfalls.md)（会被下架/废弃的真实案例）。
