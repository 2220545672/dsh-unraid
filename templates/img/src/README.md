# 图标素材出处与商标说明

`dsh.png`（CA 用的应用图标）由 `scripts/make-icon.mjs` 从下面两个上游 SVG 合成：

| 文件 | 来源 | 许可 / 说明 |
|---|---|---|
| `dsh-mark.svg` | `deepseek-ai/deepseek-harness` 仓库的 `website/public/favicon.svg` | DeepSeek Harness 项目素材（上游仓库 MIT）。蓝色鲸鱼即 DSH 的标记 |
| `unraid-mark.svg` | `unraid/docs` 仓库的 `static/img/un-mark-gradient.svg` | Unraid 官方品牌素材（橙色条状 "U" 标） |

## 商标与非官方声明

本仓库是**社区打包**，与 DeepSeek（深度求索）及 Lime Technology（Unraid）**均无隶属、合作或授权关系**。图标把两个上游标记并列，仅用于说明"这是什么应用、跑在什么平台上"，不代表任何一方的背书。

DSH 官方 [品牌素材使用规范](https://github.com/deepseek-ai/deepseek-harness/blob/master/BRAND_GUIDELINES.zh.md) 的要求是：描述性文字里可以如实说明与 DeepSeek Harness 的关系，但**项目名**建议使用缩写 **DSH**、避免直接使用完整商标。因此本仓库用 `dsh-unraid` / `dsh` 命名，描述里才出现 "DeepSeek Harness"。

如果任何一方要求调整，替换这两个文件并重跑 `node scripts/make-icon.mjs` 即可。

## 重新生成

```bash
pnpm add -D sharp          # 或指定已有副本
node scripts/make-icon.mjs --out=templates/img/dsh.png
node scripts/make-icon.mjs --flatten='#f4f4f6' --out=/tmp/preview-light.png   # 看浅色卡片上的观感
node scripts/make-icon.mjs --flatten='#111827' --out=/tmp/preview-dark.png    # 看深色卡片上的观感
```
