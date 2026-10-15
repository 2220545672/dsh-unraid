# 把这个仓库发到 GitHub 并跑通第一次发布

本机（DSH 容器）里**没有** GitHub 凭据：`ssh -T git@github.com` 与 `ssh -T git@gitee.com` 都是 `Permission denied (publickey)`，`/data/git/.git-credentials` 里也没有这两个站点的条目。所以推送这一步必须由你完成（或者把凭据交给我）。

## 1. 建仓库

在 GitHub 上新建 **公开** 仓库（CA 与图标 URL 都要求公开可读）：

- 名称：`deepseek-harness-unraid`
- 不要勾选 "Add a README"（本地已有历史）

## 2. 推送

```bash
cd /workspace/unraid/deepseek-harness-unraid
git remote add origin git@github.com:<你的用户名>/deepseek-harness-unraid.git   # 或 https://github.com/<你的用户名>/deepseek-harness-unraid.git
git push -u origin main
```

> 本容器的 HOME 不持久，SSH 配置在重建后会丢；母本在 `/data/git/.ssh/config`。若 `git@github.com` 不通，先照 `AGENTS.md` 的办法恢复 `~/.ssh/config`，或在宿主机上推送。

## 3. 两个必须改的仓库设置（否则流水线会失败）

| 设置 | 位置 | 为什么 |
|---|---|---|
| **Workflow permissions = Read and write** | Settings → Actions → General → Workflow permissions | 新建仓库默认是只读。只读时 workflow 里写 `packages: write` 也**不会**被授予，推送 GHCR 会 403。 |
| **把 GHCR 包设为 public** | 首次发布成功后：个人头像 → Packages → `deepseek-harness` → Package settings → Change visibility | GHCR 包默认是私有的，Unraid 上匿名 `docker pull` 会 401。 |

另外记一条 GitHub 行为：**公开仓库连续 60 天无活动，定时工作流会被自动停用**。本仓库的 cron 每 6 小时跑一次上游检查，只要上游一直在发版就不会触发；如果 DSH 长期停更，去 Actions 页面点一次 "Enable workflow"。

## 4. 触发第一次发布

Actions → **release** → *Run workflow*：

- `version` 留空（自动解析为 npm 上最高版本；2026-10-15 是 `0.2.1-alpha.3`）
- `force` 勾上（第一次没有 `dsh-<version>` 标签，其实不勾也会跑；勾上更直观）

流程会依次执行：解析版本 → 构建 amd64 → 冒烟测试 → 构建并推送 amd64+arm64 → 建标签 `dsh-<version>` → 发 GitHub Release（附**版本锁定**的模板 XML 与图标）。

失败时先看失败的 job：`verify` 挂通常是镜像启动/冒烟断言，日志里会打出容器日志。

## 5. 让模板指向你的命名空间

仓库里的 `templates/deepseek-harness.xml` 用的是占位符（`__GHCR_OWNER__`、`__REPO__`、`__IMAGE_TAG__`），一是避免硬编码，二是方便 fork。**提交 CA 之前**要渲染一次并提交：

```bash
cd /workspace/unraid/deepseek-harness-unraid
node scripts/render-template.mjs --owner=<你的GitHub用户名> --repo=deepseek-harness-unraid --tag=latest \
  --out=templates/deepseek-harness.xml
git add templates/deepseek-harness.xml && git commit -m "chore: render template for <owner>" && git push
```

（`scripts/make-icon.mjs` 生成的图标已经在仓库里；想换风格就重跑它。）

## 6. 然后才是 CA

见 [ca-submission.md](ca-submission.md)：CA 的 claim 只能在你的 Unraid 上生成 `.unraid/community-apps-claim.json`，另外别忘了按官方要求开一个 Unraid 论坛支持帖并把模板的 `<Support>` 指过去。
