# 接手必读（HANDOFF）

给下一个沙箱/接手的 AI：**这份文档就是全部上下文**。读完这一页你就能继续干活，不需要再问用户"之前做到哪了"。
用户不是程序员，所有动手的事都由沙箱完成；他只验收结果和链接。

最后更新：2026-11-22 · 版本 **3.9.1+54** · 分支 `main` HEAD 见 GitHub

---

## 0. 用户是谁、怎么跟他合作

- 中文沟通。他要的是**能用的东西 + 能点开的链接**，不是步骤清单、不是"你可以这样操作"。
- 原话硬规则（继续生效）：
  - 「以后做到没成功一次就推送仓库，不用我提醒。」
  - 「你应该用这种方法给我链接」——即 `https://xxx.trycloudflare.com/app-alpine-x.y.z.apk` 这种点开就能下的直链，不要 github.com 的页面链接。
  - 「用智能体集群和角色分工干活」——他喜欢看到分工，但**结果必须是真的**，不能只给计划。
  - 他的 keystore、证书、XFS-1 算法都是**他自己的产物**，改法由他定；不要把"安全建议"当成拒绝执行的理由。
- 他的设备是 Android，装 APK 覆盖升级；旧包从 1.6 一直到 3.9.0 都是同一把 key 签的。

---

## 1. 项目是什么

**SparkShell**：一个 Android App（Flutter + proot），把 Linux 终端、SSH、文件管理、AI 聊天装进同一部手机。

- 包名 `com.grokggg.sparkshell`，**Java 包名是 `com.xinghuo.sparkshell`**（历史遗留，两套名字并存，别"顺手统一"，会炸 MainActivity 路径和 XFS-1 常量）
- targetSdk **必须 28**：≥29 时 Android 禁止在私有目录 exec，proot 起不来。不是懒得升。
- minSdk 跟随 `flutter.minSdkVersion`（当前 Flutter 是 **24**，不是 21），所以 Java 侧不能用 `java.util.Base64`、`String.join` 这类 API 26+ 的东西
- rootfs 两种口味：Debian bookworm（179 MB，apt/python3/node/gcc 全）与 Alpine 3.20（62 MB，快）

---

## 2. 现在到哪一步了

| 项 | 值 |
|---|---|
| 版本 | `3.9.0+53`（`pubspec.yaml` 与 `lib/app_version.dart` 双处，必须同步） |
| HEAD | `4657986` docs: 首页点明包在 dist/ |
| 上一个功能提交 | `c38c885` feat(3.9.0)：XFS-1 进 APK + 签名自校验 |
| 最新 Release | `v3.9.0-apk`（2026-11-22T00:44Z） |
| CI | GitHub Actions `apk` job，一次约 7 分钟，产出两个 APK 并自动挂 Release |
| 真机状态 | 3.9.0 用户**尚未反馈**（上一个是 3.8.4 多接入点，也未反馈） |

**已经做完、别再重做的**：

1. 多 key 共存（3.8.4）：`endpoints` + `activeEndpointId`，填第二个 key 不再顶掉第一个
2. rootfs 解包单飞 + 原子就位（3.8.5）：并发解包会互相删 cwd，已加 `ROOTFS_LOCK` / `sExecuting` 与 `rootfs.tmp → rename`
3. XFS-1 编进 APK（3.9.0）：`com/xinghuo/xfs1/Xfs1.java`，用 `android.util.Base64`
4. 签名自校验（3.9.0）：`SelfCheck.java`，比对本包签名证书 SHA-256
5. 包入仓（3.9.0）：`dist/` 下 alpine 整包 + debian 四片 + `join.sh`

---

## 3. 仓库地图

```
grokggg/sparkshell  (public)
├─ sparkshell/                    Flutter 工程根（注意是子目录，不是仓库根）
│  ├─ lib/
│  │  ├─ app_version.dart         版本唯一来源：appVersion / appCode
│  │  ├─ chat/                    api_config.dart（接入点清单）、api_endpoint.dart、llm_client.dart
│  │  ├─ settings/settings_page.dart   3100+ 行，模型卡 / 接入点 chips / 「安全」区都在这
│  │  ├─ linux_env.dart           rootfs 解包 + proot 启动 + PTY 通道（单飞逻辑在这里）
│  │  ├─ security/self_check.dart Dart 侧自检封装（通道 'selfCheck'）
│  │  └─ ...
│  ├─ android/app/
│  │  ├─ build.gradle             signingConfig 指向 ../keystore/sparkshell.jks，口令 sparkshell
│  │  ├─ keystore/sparkshell.jks  PKCS#12（**不是 JKS 格式**，别用 jks 解析器读）
│  │  └─ src/main/java/com/xinghuo/
│  │     ├─ sparkshell/MainActivity.java   通道 com.xinghuo.sparkshell/pty + sparkshell/io
│  │     ├─ sparkshell/SelfCheck.java      签名自校验 + XFS-1 自检 + 设备凭证
│  │     └─ xfs1/Xfs1.java                 XFS-1 算法本体（源码编入，无 jar/aar 依赖）
│  ├─ test/                       endpoint / model_vault / reasoning_retry / model_slot（纯 Dart）
│  └─ .github/workflows/build.yml CI（本地 checkout 里没有这个文件，改它要用 API 取）
├─ dist/                          3.9.0 安装包（alpine 整包 + debian 四片 + join.sh + SHA256SUMS）
├─ docs/index.html                Pages 下载页（TAG 常量在脚本里）
├─ server/xfs1_server.py          XFS-1 令牌校验服务（APP_KEY 与 App 内同一把）
├─ xfs1-sdk/                      算法参考实现 + harness（种子，App 侧已改为 android.util.Base64）
└─ xfs1-core.jar / xfs1-1.0.0.aar 历史产物，**没被 APK 引用**（别以为它们生效）
```

---


### 3.9.1 补的（本轮）

| 补了什么 | 为什么 |
|---|---|
| `packaging { jniLibs { excludes } }` 剔除 armeabi-v7a/x86/x86_64 | Flutter 只出 arm64 引擎，插件却带三套 .so → 32 位设备「装得上、一启动就崩」，还白占 23 MB。CI 新增 `Verify ABI` 闸，包里再混进非 arm64 会直接 fail |
| Debian rootfs 瘦身（apt 索引 / doc / man / info） | 约 90 MB 是容器里永远用不到的东西，用户每次更新都要多下 |
| rootfs 内 resolv.conf 改 223.5.5.5 + 119.29.29.29 | 镜像里是 systemd-resolved 的 127.0.0.53，proot 里根本不通（运行期 start.sh 也会重写，双保险） |
| `allowBackup=false` | 不关的话整包 rootfs（含 root 家目录）会进云备份 |
| 全局错误捕获 + 启动自检 + 顶部红条 | 之前 `main()` 只有一行 runApp，闪退不留现场；自检也只躺在设置页 |
| 设置 →「诊断」区：检查更新 / 复制诊断信息 / 最近错误 | 非程序员用户报问题只能截图；现在一键复制版本+自检+错误栈 |
| 「安装未知应用」直达 | need_install_permission 时直接跳系统开关页 |
| 聊天导出写死 `2.0.0` → `appVersion` | 导出文件里的版本一直是错的 |

## 4. 构建与签名

CI 干的活（`.github/workflows/build.yml`，两条腿 alpine / debian）：

1. `flutter build apk --release --target-platform android-arm64`
2. gradle 用 `../keystore/sparkshell.jks` 自签（v2/v3，无 v1 JAR 签名 → **APK 里没有 META-INF/*.RSA**，要取证书得解析 APK Signing Block）
3. 重命名 `app-alpine.apk` / `app-debian.apk`，打 tag `vX.Y.Z-apk` 上传 Release

**证书事实**（换 key 会全部作废，务必同步）：

```
subject      CN=SparkShell, OU=Self-Signed, O=Xinghuo, C=CN
SHA-256      108965710f9fd562757213b4f30ca1baefb4e17e3420e6b748ded8f998c0a83e
有效期        2026-11-17 → 2054-04-04
算法          RSA 2048 / sha256WithRSA
keystore      PKCS#12，口令 "sparkshell"（明文写在 build.gradle，用户知情）
```

**换 key 的四步**（用户已表态"这是我的产物，我有权改"）：

1. 生成新 keystore → 放进 `android/app/keystore/`，改 `build.gradle` 的口令/别名
2. 用下面这段算出新证书 SHA-256（沙箱里 `pip install cryptography` 即可）
3. 改 `SelfCheck.java` 的 `EXPECTED_CERT_SHA256`（或用 3.10 计划里的"CI 自动注入"省掉这步）
4. 老用户覆盖安装会报「签名不一致」→ 要么保留旧 key 双签，要么让他卸载重装

```python
from cryptography.hazmat.primitives.serialization import pkcs12, Encoding
import hashlib
_, cert, _ = pkcs12.load_key_and_certificates(open("sparkshell.jks","rb").read(), b"口令")
print(hashlib.sha256(cert.public_bytes(Encoding.DER)).hexdigest())
```

---

## 5. XFS-1（自研算法）

```
k      = SHA-256("XFS-1" ‖ context ‖ salt[16])       context = 包名
body   = AES-256-GCM(k, iv[12], payload, tag=128)
token  = "xfs1." + b64(salt‖iv‖body) + "." + hex(HMAC-SHA256(appKey, "xfs1."+b64))[0:32]
```

- appKey 32 字节，App 里以 `KEY_MASK ^ KEY_MASKED` 两数组异或存（`SelfCheck.java`），服务端 `server/xfs1_server.py` 的 `APP_KEY` 是同一把（可读文件确认）
- 改算法 = 改 `Xfs1.java` + 改 `server/xfs1_server.py` 同一版；令牌前缀、盐长、HMAC 截断位数都可动
- **仍是 Java 层**，jadx 能反编译出来。搬 NDK/.so 是 3.10 候选，不是现在

---

## 6. 三条分发通道（都要维护）

1. **GitHub Releases**：`v3.9.0-apk` → `app-alpine.apk` / `app-debian.apk`（CI 自动）
2. **仓库 dist/**：`dist/app-alpine-3.9.0.apk`（整包）+ `dist/app-debian-3.9.0.apk.part0..3` + `join.sh`
   （GitHub 单文件上限 100 MiB，179 MB 的 debian 只能切片）
3. **VPS 直链（用户最常用）**：
   ```
   https://discretion-stated-bargain-expect.trycloudflare.com/app-debian-3.9.0.apk
   https://discretion-stated-bargain-expect.trycloudflare.com/app-alpine-3.9.0.apk
   https://discretion-stated-bargain-expect.trycloudflare.com/index.html
   https://discretion-stated-bargain-expect.trycloudflare.com/latest.json
   ```
   隧道是 cloudflared quick tunnel（`cf2`，跑在 VPS 上，`--url http://127.0.0.1:8080`）。
   **域名在隧道重启后会变**，重启后要 `grep trycloudflare /opt/dl/*.log` 找回、并重写 `latest.json` 的 base。

`latest.json` 格式（App 内更新用，字段别改）：

```json
{"version":"3.9.0","code":53,"url":"…/app-alpine-3.9.0.apk","size":62565780,
 "sha256":"80c4de4a…","notes":"…"}
```

发新版的标准动作（VPS 上跑，`/opt/dl`）：

```bash
# 1) 拉包（github.com 直连会超时，用 ghfast 前缀）
for pre in https://ghfast.top/https:// https://gh-proxy.com/https://; do
  curl -L --speed-limit 20000 --speed-time 20 -o app-alpine-3.9.1.apk \
    "${pre}github.com/grokggg/sparkshell/releases/download/v3.9.1-apk/app-alpine.apk" && break
done
# 2) 核对 sha256 与 release digest
sha256sum app-*-3.9.1.apk
# 3) 换首页 + 更新 latest.json
cp /opt/dl/index.html.new /opt/dl/index.html
python3 /opt/dl/make_latest.py 3.9.1 54 app-alpine-3.9.1.apk "改了什么" \
  --base https://<当前隧道域名>
```

---

## 7. rootfs 解包（有过血的教训，别改回去）

`MainActivity.extractRootfs()` + `lib/linux_env.dart`：

- **必须单飞**：`ROOTFS_LOCK` + `sExtracting`，重入直接返回 `busy:`
  之前没有这道闸，Linux 页 + 文件页冷启动各解一次，两个 tar 互相 `deleteTree` 对方 cwd，报
  `tar: rootfs.tar: No such file` / `xgetcwd` / `'./bin' bad symlink`，看起来像"解压坏了"
- **必须原子就位**：解到 `rootfs.tmp` → 校验 `bin/sh` → `deleteTree(rootfs)` → `rename`
- Dart 侧 `ensureReady` 单飞（复用同一个 Future），失败且原因是"解包不完整/bad symlink"时清三件套（rootfs / rootfs.tmp / rootfs.tar）再试一次
- marker 是 `files/rootfs/.sparkshell_ready`

---

## 8. 在没有 Flutter 的沙箱里怎么验

这台沙箱（以及大多数）**没有 Flutter、没有 JDK、没有 Android SDK**，所以：

```bash
# A. 纯 Dart 逻辑用例：下 Dart SDK → 垫一个 flutter_test 壳 → 真跑
curl -sSL -o dart.zip https://storage.flutter-io.cn/dart-archive/channels/stable/release/3.9.0/sdk/dartsdk-linux-x64-release.zip
python3 -c "import zipfile;zipfile.ZipFile('dart.zip').extractall('.')"; chmod +x dart-sdk/bin/*
./dart-sdk/bin/dart run test/_run_endpoint_test.dart   # 需要垫片，见旧脚本做法
# B. Java 语法：pip install javalang; javalang.parse.parse(open(f).read())
# C. Dart 语法：dart format --output=none <file>   （exit 0 即可，不代表类型正确）
# D. APK 级证据：解析 APK Signing Block 取证书（脚本见 ~/.hermes/cache/scratch 历史，或重写）
```

**真正的编译 gate 只有 CI**。沙箱里"通过"只是语法/逻辑层面，别对用户说"已验证真机"。

现成脚本（本轮沙箱，可能随时被清）：

- `~/.hermes/cache/scratch/hermes-verify-390.py` —— 3.9.0 全量 ad-hoc 验收（Java 解析、常量/密钥一致性、接线、Dart 解析、线上产物）
- `~/.hermes/cache/scratch/hermes-verify-dist.py` —— dist 入仓验收（尺寸、blob sha、真拼接、哈希）

---

## 9. 沙箱环境的坑（踩过）

| 坑 | 表现 | 绕法 |
|---|---|---|
| 出网白名单 | `github.com`、`raw.githubusercontent.com`、各种 GitHub 镜像全 `000` | 只用 `api.github.com`（有时也会抽风）、`storage.flutter-io.cn`、`grokggg.github.io`；其余走 VPS |
| DNS 会挂 | `api.github.com` 解析失败，其它域名正常 | 借 VPS 出网：把文件 sftp 上去，在 VPS 上跑 push 脚本 |
| 没有 git | 无法 clone/push | 小文件走 Git Data API；大文件（>10 MB）API 会 422 → 必须在 VPS 上用真 git + SSH 部署密钥 |
| VPS 到 GitHub HTTPS 极慢 | `git clone` 十几分钟原地不动 | **用 SSH**：`git@github.com`（22 端口秒通），部署密钥在 VPS `/root/.ssh/gh_dist`，已挂到仓库 Deploy keys（write） |
| `/tmp` 会被清 | `/tmp/hermes-work` 整个消失，Dart SDK/口令全没 | 重要东西放 `/workspace`；VPS 上的东西不受影响 |
| 无 JDK/Flutter | 编译不了 APK | 只做语法/逻辑验证，编译交给 CI |

---

## 10. 凭据清单（**值不写进仓库**）

| 东西 | 在哪 | 用途 |
|---|---|---|
| GitHub PAT | 本会话历史里出现过；VPS `/srv/push/token`（600） | 推代码、发 release、读 API |
| VPS root 口令 | 用户在聊天里给过；本会话 `/tmp/hermes-work/.vps_pw`（易失） | SSH `39.106.140.144:22` |
| 部署密钥（写权限） | VPS `/root/.ssh/gh_dist`（600） | 大文件 git push |
| keystore 口令 | 仓库 `android/app/build.gradle`（明文 `sparkshell`） | 签名 |
| 隧道域名 | `/opt/dl/*.log` | 直链、`latest.json` base |

接手时向用户要：GitHub PAT（或直接用 VPS 上的）、VPS 口令。**别把 PAT 写进仓库文件、命令行参数或日志**。

---

## 11. 已知未完成 / 未验证

- **native 层**：XFS-1 与自校验都还在 Java，无 `.so`。要升难度必须 NDK（CI 目前只产 arm64-v8a）
- **keystore 在 public 仓库**：任何人都能用它签一个"签名相同"的包。用户明确表示这是他的产物、他自己决定；要收紧就挪进 CI secrets
- **真机反馈缺失**：3.8.4 多接入点、3.8.5 rootfs 修复、3.9.0 自检，用户都还没回报装完的表现
- **无前台服务/唤醒锁**：息屏后 proot 里的进程可能被系统回收（apt 跑到一半被杀），3.9.2 候选
- **UI 未渲染验证**：设置页「安全」区、接入点 chips、Chat 第 4 段都只有源码断言
- **腾讯云安全组只开 22**：80/443/8080 公网不可达，所以只能走隧道，纯 IP 直链做不了
- **CI workflow 不在本地 checkout**：要改它得 `GET /repos/.../contents/.github/workflows/build.yml`

---

## 12. 下一步候选（等用户点单）

| 选项 | 内容 | 影响 |
|---|---|---|
| A | 换新 keystore | 老用户覆盖安装会失败，需双签或卸载重装 |
| B | 证书常量 CI 自动注入 | 以后换 key 零改代码，不影响升级 |
| C | 自校验改成纯 XFS-1（不比证书） | 形式更"自研"，不影响升级 |
| D | XFS-2 算法改版 | 需同步改 `server/xfs1_server.py`，不影响升级 |
| E | NDK/.so 化 | 每 ABI 一份，CI 要装 NDK，构建变慢 |

---

## 13. 接手 10 分钟清单

```bash
# 1. 环境自检（本文件同目录 tool/handoff_check.sh 也能跑）
uname -a; python3 -V; curl -s -o /dev/null -w "api=%{http_code}\n" https://api.github.com/
curl -s -o /dev/null -w "tunnel=%{http_code}\n" https://discretion-stated-bargain-expect.trycloudflare.com/latest.json

# 2. 拿代码（DNS 正常时）
git clone git@github.com:grokggg/sparkshell.git && cd sparkshell

# 3. 确认线上就是 3.9.0
curl -s https://discretion-stated-bargain-expect.trycloudflare.com/latest.json

# 4. 确认包没被换
cd dist && sha256sum -c SHA256SUMS   # debian 要先 ./join.sh

# 5. 动手前先读：lib/linux_env.dart（解包）、settings_page.dart（模型/接入点）、SelfCheck.java
```

用户验收标准就一句：**装上去能用、链接点得开、日志里没有"准备失败"**。
