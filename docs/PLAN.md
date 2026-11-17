# SparkShell 路线与角色分工（v1.2 起）

> 本文是"用户意图 → 工程约束 → 角色分工 → 里程碑验收"的唯一事实源。
> 与 dsh-go 无任何代码/资源关系；签名、算法、包名均为自有。

## 0. 需求翻译（用户原话 → 工程约束）

| 用户原话 | 工程含义 | 落到哪一层 |
|---|---|---|
| "签名肯定是要自己的算法" | APK 必须用自签证书（`sparkshell.jks`），运行期有 XFS-1 校验；不复用任何第三方证书/算法 | R5 |
| "我没追求体积越小越好，2 到 3 百 M 不算大" | 体积上限放宽到 **300 MB**；不再为省 20 MB 牺牲能力 | R1 |
| "我要的是越全面越好，剔除冗杂也允许" | 功能优先：能跑的都要能跑；只删真正的死重（重复 ABI、无用资源） | R1/R6 |
| "从原则上来讲 debian 更好…我想要完整功能的" | 用 **Debian bookworm arm64** 作 rootfs，`apt` 可用，glibc 兼容 | R2 |
| "VPS 可选功能，挺好" | VPS 只是可选远端（SSH/远程执行），**不进主链路**；额度到期不影响本地能力 | R1/R3 |
| "不要偏离核心需求" | 核心 = 本地可离线运行的移动 harness：proot Linux + SSH + WebRTC + 聊天 + 工具执行 | 全部 |

## 1. 目标形态（v1.6 完成态）

```
┌──────────────────────────── 手机（APK，自签 + XFS-1） ────────────────────────────┐
│  UI     聊天 / 终端(本地·Debian) / 文件 / 设置 / WebRTC 调试                      │
│  Runtime  Agent 循环：模型 → 工具调用 → 审批 → 执行 → 回灌                        │
│  Tools    bash / read_file / write_file / list_dir / apply_patch（在 proot 内）   │
│  Linux    proot + Debian bookworm arm64（apt / python3 / node / git / gcc）       │
│  安全     XFS-1 令牌 + 设备指纹 + 密钥本地加密（Keystore）                        │
└──────────────────────────────────────────────────────────────────────────────────┘
        │ 可选：SSH 到 VPS / WebRTC 直连（额度到期即失效，不影响上面任何能力）
```

## 2. 角色分工（智能体集群）

| 角色 | 名字 | 职责 | 产出 | 验收标准 |
|---|---|---|---|---|
| **R1** | 架构与接口 | 定目录/接口/版本边界；砍需求、挡跑偏 | `docs/PLAN.md`、接口表、体积预算 | 每版都有"能做/不能做"清单 |
| **R2** | 内核层（Native） | proot 移植、loader 路径、rootfs 打包、PTY 通道、挂载点 | `assets/proot/*`、`rootfs.tar.gz`、`pty_bridge.c` | 真机 `apt update` 成功 |
| **R3** | Agent 运行时 | 工具协议、循环、审批、上下文裁剪、失败重试 | `lib/agent/*.dart` | 一句"修这个 bug"能在 proot 内改完并跑测试 |
| **R4** | 前端 UI/UX | 聊天流式渲染、Markdown/代码块、终端主题、文件浏览 | `lib/ui/*` | 三秒上手，无空白页 |
| **R5** | 安全与签名 | keystore、XFS-1 令牌链路、指纹、权限最小化 | `xfs1-*.aar`、签名配置 | `apksigner verify` + 服务端发 license |
| **R6** | 交付与回归 | CI（Actions）、版本号、Release、真机验收清单 | `.github/workflows/build.yml` | 每次推送出可安装包 + sha256 |
| **R7** | 逆向与情报（可选） | 只读研究参考产品，提炼协议/交互，不复制代码 | 分析笔记 | 结论可落地、可验证 |

执行纪律：**R1 先出接口，R2/R3/R4/R5 才能动手；R6 只认"真机装得上"**。

## 3. 里程碑与验收

| 版本 | 内容 | 验收（真机） | 体积预算 |
|---|---|---|---|
| **v1.2** | proot + Debian rootfs + 「Linux」页 | 打开 Linux → 出现 `root@localhost:~#` → `apt update` 成功 → `python3 -V` 有输出 | ≤ 300 MB |
| v1.2b | 修 v1.2 真机问题（loader/权限/挂载） | 同上，且断网也能进 shell | — |
| v1.3 | 聊天页（OpenAI 兼容，key 本地加密保存），流式 | 能对话；切换模型生效；消息持久化 | +5 MB |
| v1.4 | 工具循环（bash/读写文件/列目录），逐步审批 | "在 /root 建 hello.py 并运行" 全自动完成 | +2 MB |
| v1.5 | 会话树、系统提示、日志、导出 | 会话可回溯、可导出 md | +3 MB |
| v1.6 | XFS-1 设备校验 + 设置页收口 | 无 license 时限流；有 license 全功能 | +2 MB |

## 4. 当前进度（本文件随版本更新）

| 项 | 状态 | 证据 |
|---|---|---|
| proot aarch64 二进制获取 + loader 路径 patch | ✅ | `assets/proot/proot`，loader → `/data/data/com.grokggg.sparkshell/files/proot/loader` |
| 依赖库打包（talloc / android-shmem / termux-exec） | ✅ | `assets/proot/*.so` |
| Debian rootfs（debootstrap --foreign, arm64） | 🟡 构建中 | VPS 上 debootstrap，产出 `rootfs.tar.gz` |
| APK 内解压 + 第二阶段 + 启动脚本 | ✅ 代码完成 | `lib/linux_env.dart` |
| CI 出包 | 🟡 待推 | `.github/workflows/build.yml` |
| 真机验收 | ⬜ 待用户安装 | — |

## 5. 已知技术约束（写下来避免返工）

1. **targetSdk 必须是 28**：Android 10+ 对 `targetSdk ≥ 29` 的应用禁止在私有目录 exec 可执行文件（W^X）。Termux / dsh-go 都用 28。副作用：不能上架 Play，但本项目只侧载。
2. **proot loader 路径编译期写死**：Termux 版写的是 `/data/data/com.termux/...`，必须按我们的包名等长 patch（已完成，52 字节刚好占满）。
3. **不能静态链接**：Android 不支持全静态可执行文件，proot 必须动态链接 bionic，运行时靠 `LD_LIBRARY_PATH` 找到 `libtalloc.so.2` 等。
4. **rootfs 不能放 assets 直接读**：必须解压到 `filesDir`，且符号链接（`/bin → usr/bin`）要还原，否则 Debian 起不来。
5. **debootstrap 第二阶段必须跑**：`--foreign` 只解包不配置，首次启动要执行 `/debootstrap/debootstrap --second-stage`。
