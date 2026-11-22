# dist — SparkShell 安装包（跟着仓库走）

其他沙箱/机器直接从这里拿，不用碰 GitHub Releases，也不用翻墙。

## 目录

| 文件 | 大小 | 说明 |
|---|---|---|
| `app-alpine-3.9.0.apk` | 62.5 MB | Alpine 版，单文件，装完即用 |
| `app-debian-3.9.0.apk.part*` | 4 × 58 MB | Debian 版被切成 3 片（git 单文件上限 100 MB，179 MB 塞不进） |
| `join.sh` | — | 拼片 + 校验 |
| `SHA256SUMS` | — | 两个包的官方哈希 + 各分片哈希 |

## 用法

```bash
# Alpine：直接装
adb install app-alpine-3.9.0.apk

# Debian：先拼再装
./join.sh
adb install app-debian-3.9.0.apk
```

## 校验

```
alpine  80c4de4a054ea501cd89a76ea59883bd677b1f6d2a2d6fd0d7db3719db068745
debian  745625855d0e0ef6effe980910be91f272d7304d5a4ed3d0bb4441ca5f72c9db
```

两个包的签名证书 SHA-256 都是 `108965710f9fd562757213b4f30ca1baefb4e17e3420e6b748ded8f998c0a83e`
（CN=SparkShell 自签）。应用内「设置 → 安全」会自己比对这一串，对不上就标红。
