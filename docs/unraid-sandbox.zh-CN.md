[English](unraid-sandbox.md) · **中文**

# 为什么 Unraid 上必须带 bubblewrap（以及那两个 `--security-opt`）

这份文档解释本镜像最重要的一个非默认决定。如果你只想"能跑起来"，看结论即可；想知道为什么不能照抄上游 compose，请读完。

## 结论

在 Unraid（以及其它没有启用 Landlock 的内核）上运行 DSH，必须同时满足两条：

1. **镜像里要有 `bubblewrap`**（本镜像已内置；很多社区镜像没有）。
2. **容器要以 `--security-opt seccomp=unconfined --security-opt systempaths=unconfined` 启动**（本仓库的 Unraid 模板已经把它们写进 `Extra Parameters`，`compose.yaml` 里也已写死）。

缺第一条：沙箱两条腿都断，DSH 的 `bash` 工具直接 fail-closed。
缺第二条：`bwrap` 在容器内起不来（`No permissions to create a new namespace` / `Can't mount proc on /proc`）。

## 机制：DSH 的沙箱是"两条腿"的

`@deepseek-ai/dsh-sandbox-local` 在 Linux 上按固定顺序找后端：

```js
const PLATFORM_CHAINS = { linux: ["bwrap", "landlock"], darwin: ["seatbelt"], win32: ["windows-acl"] }
```

- **第一梯队 `bwrap`**：本镜像内置。
- **第二梯队 `landlock`**：`landlock-run` 二进制随 DSH 一起发布，但它要求内核编入 `CONFIG_SECURITY_LANDLOCK`。Unraid 7.3.2（内核 `6.18.38-Unraid`）**没有**编入 —— 对 `landlock_create_ruleset` 系统调用返回 `ENOSYS`，不是"LSM 被禁用"，而是根本不存在。

于是宿主上出现的就是这条报错：

```
Error: sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host;
refusing to run the command unconfined. Install bubblewrap or run a Landlock-enforcing kernel (Linux),
... otherwise switch the consumer to danger-full-access.
```

注意最后那句：唯一的替代是 `danger-full-access` —— 那等于**完全没有沙箱、也没有审批**。所以"装 bwrap"不是可选项，它是"有笼子"和"没笼子"的区别。

## 为什么光装 bwrap 还不够

`bwrap` 需要创建用户/挂载命名空间，而容器默认的 seccomp 配置会拦掉 `unshare`，Docker 的默认 `/proc` 掩码又会挡住命名空间内重新挂载 procfs。社区已经把组合穷举过一遍（[runzhliu/deepseek-harness-docker#35](https://github.com/runzhliu/deepseek-harness-docker/issues/35)，报告环境正是 Unraid 7.3.2 + 内核 6.18.38）：

| 在默认安全配置之上增加 | 结果 |
|---|---|
| 只装 bwrap | `bwrap: No permissions to create a new namespace` |
| `seccomp=unconfined` | `bwrap: Can't mount proc on /proc` |
| `systempaths=unconfined` | `bwrap: No permissions to create a new namespace` |
| **两者都给** | **`SANDBOX_OK`** |
| 两者 + `cap_add: SYS_ADMIN` | `SANDBOX_OK`（与上一行无差别） |
| 只给 `cap_add: SYS_ADMIN` | `bwrap: pivot_root: Operation not permitted` |

两个关键点，避免你走弯路：

1. **`SYS_ADMIN` 既非必要也非充分**。可用配置不需要任何额外 capability，`cap_drop: ALL`、`no-new-privileges`、只读根文件系统、非 root 用户全部可以保留。网上"加 SYS_ADMIN 就行"的说法是错的。
2. 两个 flag 拦的是**不同的东西**：`seccomp` 拦的是命名空间系统调用；`systempaths` 掩的是 `/proc` 里的路径，导致命名空间内挂载 procfs 失败。所以只给一个都不行。

## 代价与取舍

- `seccomp=unconfined` 会放宽容器内的系统调用面；`systempaths=unconfined` 会暴露部分 `/proc` 条目（例如 `/proc/sys`，但在没有 `CAP_SYS_ADMIN` 的情况下依然不可写）。
- 换来的是**内层真正的隔离**：模型生成的 shell 命令跑在 bwrap 的笼子里，工作区之外不可写。
- 这是**用外层更宽的壳换内层有效的笼**。对你的威胁模型来说（不可信的是模型生成的命令，而不是宿主），这笔交易通常是划算的；但它应该是一个**显式选择**，所以我们把它写进模板的 `Extra Parameters` 并在 README 里说明，而不是藏在镜像里。

## 怎么验证你的宿主机

在 Unraid 上（DSH 容器内没有 docker CLI，所以走 `ssh unraid`）：

```bash
# 1. 宿主内核到底有没有 Landlock
ssh unraid 'grep -c CONFIG_SECURITY_LANDLOCK /boot/config/$(uname -r) 2>/dev/null; \
  grep -i landlock /proc/kallsyms | head -3'

# 2. 镜像里有没有 bwrap
ssh unraid 'docker run --rm --entrypoint bwrap ghcr.io/<owner>/dsh:latest --version'

# 3. 带两个 security-opt 时能不能真的建命名空间（应输出 SANDBOX_OK）
ssh unraid 'docker run --rm \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  --entrypoint setpriv ghcr.io/<owner>/dsh:latest \
  --reuid 1000 --regid 1000 --init-groups \
  bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent \
    --tmpfs /tmp --bind /workspace /workspace -- /bin/sh -c "echo SANDBOX_OK"'
```

在 DSH 里验证（最直接）：随便让它跑一条命令，例如"执行 `pwd` 并列出当前目录"。如果沙箱不可用，你会看到上文那条 `SANDBOX_UNAVAILABLE` 报错；可用时命令直接返回。

**手工自查前要知道两件事**（都出过误报）：

* **必须用 uid 1000 测，不能用 root。** `docker exec` 默认身份是 root，而容器里的 root 没有 `CAP_SYS_ADMIN`，bwrap 在那里**必然**报 `Creating new namespace failed: Operation not permitted`。DSH 自己是以 uid 1000 运行的（`docker top <容器> -o user,args` 可查），uid 1000 下 bwrap 正常。DSH 自己的就绪探测就是 `bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true`（read-only 策略）——退出码 0 就说明 DSH 会选中 bwrap 且 enforcement=full。
* **`systempaths=unconfined` 在 `docker inspect` 里看不见。** 它不出现在 `HostConfig.SecurityOpt`（那里只有 `seccomp=unconfined`），它的表现是 `MaskedPaths` 与 `ReadonlyPaths` 变成**空数组**；如果是 `null`，才是这个参数真的没生效。

`--cap-add SYS_ADMIN` 和 `--privileged` **都不需要**——它们只是让 bwrap 能在 *root* 下工作，而 DSH 从不用 root 跑命令，两者还会削弱容器隔离。

## 参考

- 沙箱链与失败模式：[`runzhliu/deepseek-harness-docker` #35](https://github.com/runzhliu/deepseek-harness-docker/issues/35)（Unraid 7.3.2 实测）
- 非 root 运行与 NAS 权限（含 Unraid）：[`samuelrubiodev/deepseek-harness-community` #16](https://github.com/samuelrubiodev/deepseek-harness-community/pull/16)
- DSH 自身的浏览器信任栅栏（与本镜像的 Caddy 配置配套）：`@deepseek-ai/dsh-client-connection` 的 `isTrustedApiRequest`
