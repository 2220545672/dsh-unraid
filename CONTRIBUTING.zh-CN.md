[English](CONTRIBUTING.md) · **中文**

# 维护者手册

面向本仓库的维护者与 fork 者。面向用户的内容在 [README.md](README.md)（英文，默认）与 [README.zh-CN.md](README.zh-CN.md)（中文）；两份内容保持一致，改动时请同时更新。

## 仓库结构

```
.
├── Dockerfile                 # 三段构建：DSH 依赖 → Caddy 二进制 → 运行时
├── docker/
│   ├── entrypoint.sh          # 校验环境、准备卷、选模式、拉起 Caddy + DSH
│   ├── Caddyfile.edge         # PUBLIC_URL 已设：Host 改写为对外 authority，拒绝外来 Origin
│   ├── Caddyfile.lan          # PUBLIC_URL 为空：Host 固定 loopback，剥掉 Origin
│   └── healthcheck.sh         # 容器 HEALTHCHECK
├── templates/
│   ├── dsh.xml                # Unraid 容器模板（CA 解析的就是这份实体文件）
│   └── img/                   # 图标：dsh.png（模板用）+ src/（素材与生成脚本说明）
├── icon.svg                   # 仓库级矢量图标（CA 仓库布局要求，ca_profile.xml 指向它）
├── ca_profile.xml             # CA 仓库信息（必须有非空 <Profile>）
├── scripts/                   # 版本解析、模板渲染/自检、图标生成、静态闸门、冒烟测试
├── docs/                      # 用户与提交文档
└── .github/workflows/         # validate（每次推送）+ release（跟版发布）
```

## 本地构建与自检

```bash
# 构建（版本号取自 npm，见下文）
docker build \
  --build-arg DSH_VERSION=0.2.1-alpha.3 \
  --build-arg NODE_VERSION=24.21.0 \
  --build-arg CADDY_VERSION=2.11.7 \
  -t dsh:local .

# 冒烟：会真的起容器并断言 /healthz、token 引导、跨站 403、Caddy 配置、bwrap
bash scripts/smoke.sh dsh:local

# 静态闸门：与 CI 完全一致（语法、XML/YAML/JSON、CA 布局与模板门槛、图标可复现）
bash scripts/check-static.sh
```

> `check-static.sh` 需要 `python3`（结构校验）。这台开发机上没有时用
> `ALLOW_MISSING_PYTHON=1 bash scripts/check-static.sh` 跳过那一段——**CI 里不允许跳过**，缺 python3 会直接失败。

## 上游版本怎么解析

```bash
node scripts/resolve-dsh-version.mjs --json     # 看解析结果
node scripts/resolve-dsh-version.mjs --version=0.2.1-alpha.3
```

**不要只读 npm 的 `latest` 标签。** 实测 `@deepseek-ai/dsh` 的 `latest` 会落后于 `alpha`（2026-10-15：`latest`=`0.2.0-rc.2`，`alpha`=`0.2.1-alpha.3`），只读 `latest` 的流水线会静默降级。脚本枚举全部已发布版本并按 semver 取最高，预发布按规范参与比较。

## 图标

两个产物、一套素材，**必须一起更新**：

```bash
node scripts/make-icon-svg.mjs            # → icon.svg（纯矢量，无依赖）
node scripts/make-icon.mjs                # → templates/img/dsh.png（栅格化 icon.svg，需要 sharp）
```

- `icon.svg` 是布局的**唯一事实来源**，`make-icon.mjs` 只做栅格化；CI 会重跑生成器并与提交内容 `diff`，**不允许手改**。
- 素材与出处见 [templates/img/src/README.zh-CN.md](templates/img/src/README.zh-CN.md)。DSH 官方标记用 `currentColor`，本仓库固定为黑色；Unraid 角标默认 80px（画布 256px，面积约 1/10.2）。
- 换配色/尺寸：`node scripts/make-icon-svg.mjs --badge=72 --size=256`。

## 模板

`templates/dsh.xml` **不是**模板源文件，而是渲染结果（owner/repo/tag 已替换为本仓库的值）。fork 之后重新渲染：

```bash
node scripts/render-template.mjs --owner=<你的用户名> --repo=dsh-unraid --tag=latest --out=templates/dsh.xml
node scripts/check-template.mjs templates/dsh.xml        # 单个模板自检
```

`check-template.mjs` 会断言：CA 的 minimum/recommended 字段齐全、`ca_profile.xml` 的 `<Profile>` 非空、卷与 `Config` 的宿主机路径一致、沙箱参数在位、**注释成对闭合且根元素正确开闭**（正则匹配会先剥离注释，避免"注释里出现某个标签"把检查骗过去）。

## 发布

两个工作流：

| 工作流 | 触发 | 作用 |
|---|---|---|
| `validate` | 每次推送 | 静态闸门 + shellcheck + hadolint + `caddy validate` + 脚本端到端 |
| `release` | 每天 cron（07:41 UTC）、推送相关路径、手动 | 解析版本 → **静态闸门** → 构建 amd64 → 冒烟 → 推送 amd64+arm64 → 打标签 → 发 Release（附版本锁定模板与图标） |

**闸门是共用的**：`release` 的 verify 跑的就是 `validate` 用的那份 `scripts/check-static.sh`，所以**检查不过的提交不会发布任何东西**（`publish` 与 release 资产 job 会被 skip）。此前两者独立，红着的提交照样能发布——已经修掉，别改回去。

手动发版：Actions → `release` → *Run workflow*。

| 输入 | 说明 |
|---|---|
| `version` | 留空 = 自动解析最高版本；也可指定精确版本 |
| `force` | 勾上 = 即使 `dsh-<version>` 标签已存在也重建（重新发布同一版本、或刷新 Release 资产时用） |

已发布版本再次运行会走 **skip 分支**：`resolve` 发现标签已存在 → `build=false` → 后面全部跳过，不会浪费构建时间。

## 首次发布要确认的两件事

| 设置 | 位置 | 不改会怎样 |
|---|---|---|
| Workflow permissions = **Read and write** | Settings → Actions → General | 推送 GHCR 会 403（只读时 `packages: write` 不被授予） |
| GHCR 包可见性 = **Public** | 个人头像 → Packages → `dsh` → Package settings | Unraid 上匿名 `docker pull` 会 401 |

另外：**公开仓库连续 60 天无活动，定时工作流会被自动停用**。上游若长期停更，去 Actions 页点一次 *Enable workflow*。

## 提交到 Community Applications

见 [docs/ca-submission.zh-CN.md](docs/ca-submission.zh-CN.md)（门槛与流程：仓库公开 + OSI 许可证 + `ca_profile.xml` 非空 `<Profile>` + 论坛支持帖 + `/submit/new` 的 Validate/Scan）。提交前先跑 `bash scripts/check-static.sh`，再按 [docs/ca-pitfalls.zh-CN.md](docs/ca-pitfalls.zh-CN.md) 自查一遍——那里记着下架、废弃、模板改动不回流等真实案例。

## 上机验收（CI 之外）

CI 只证明镜像能起、能通过断言；**目标平台上真实可跑**还要单独验一次（历史上这一步抓出过 CI 漏掉的 edge 模式缺陷）。要点：

```bash
docker pull ghcr.io/2220545672/dsh:latest          # 未登录，确认包是 public
docker run -d --name dsh-acceptance -p 127.0.0.1:18099:8080 \
  -e PUBLIC_URL=http://127.0.0.1:18099 -e TZ=Asia/Shanghai \
  -v /tmp/dsh-accept/data:/data -v /tmp/dsh-accept/workspace:/workspace \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18099/healthz   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18099/          # 303（带 dsh-auth cookie）
docker exec dsh-acceptance bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all -- /bin/sh -c 'echo SANDBOX_OK'
```

用**独立端口与临时卷**验证，不要动正在运行的实例。
