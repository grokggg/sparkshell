# dist — SparkShell 安装包（跟着仓库走）

其他沙箱/机器直接从这里拿，不用碰 GitHub Releases，也不用翻墙。

## 目录

| 文件 | 大小 | 说明 |
|---|---|---|
| `app-alpine-3.9.1.apk` | 37.5 MB | Alpine 版，单文件，装完即用 |
| `app-debian-3.9.1.apk.part*` | 3 片（58+58+18 MB） | Debian 版切片（git 单文件上限 100 MB，134 MB 塞不进） |
| `join.sh` | — | 拼片 + 校验 |
| `SHA256SUMS` | — | 两个包的官方哈希 + 各分片哈希 |

## 用法

```bash
adb install app-alpine-3.9.1.apk     # Alpine：直接装
./join.sh && adb install app-debian-3.9.1.apk   # Debian：先拼
```

## 校验

```
alpine  c07b3751b2449c30a2165439547713e800a2b7f3cddda703658c98de4a7007bd
debian  a407318ac881262d19c28fe3d8ecccd5dee81f7547ce4a2a8b9c370359055e48
```

签名证书 SHA-256 `108965710f9fd562757213b4f30ca1baefb4e17e3420e6b748ded8f998c0a83e`（CN=SparkShell 自签）。
应用「设置 → 安全」会自己比对这一串，对不上首页就红条。

3.9.1 只出 arm64 单架构（32 位手机装不上，而不是装上就崩）。
