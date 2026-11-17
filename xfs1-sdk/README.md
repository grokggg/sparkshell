# XFS-1 SDK (Android AAR)

自研令牌协议 XFS-1 的可复用实现，**密钥可配置**，核心零 Android 依赖（可在 JVM 上单测）。

## 产物

| 文件 | 说明 |
|---|---|
| `xfs1-1.0.0.aar` | 5.4 KB，含 `classes.jar` + `AndroidManifest.xml`(minSdk 21) + `R.txt` |
| `xfs1-core.jar` | 纯 JVM 核心（无 android.* 引用），可用于服务端或单测 |
| `src/` | 源码：`Xfs1.java`（协议）、`Xfs1Device.java`（指纹+远程校验） |

## 协议

```
k     = SHA-256("XFS-1" ‖ context ‖ salt[16])
body  = AES-256-GCM(k, iv[12], payload)      # tag 128 bit
token = "xfs1." + base64(salt‖iv‖body) + "." + hex(HMAC-SHA256(appKey, "xfs1."+b64))[0:32]
```

- `appKey`：32 字节，构造时注入；可远程下发，不写死在 APK。
- `context`：一般用包名，隔离不同应用。
- `open()` 先验 HMAC 再解密：篡改 1 个字符即 `SecurityException`（已实测）。
- `sign(msg)`：给请求头用的 HMAC 签名。

## 接入

```kotlin
val xfs = Xfs1.fromHex(BuildConfig.XFS1_KEY, packageName)
val token = xfs.issue("""{"fp":"$fp","ts":${System.currentTimeMillis()/1000}}""")
```

```gradle
implementation(files("libs/xfs1-1.0.0.aar"))
```

设备指纹 + 远程校验：

```kotlin
val dev = Xfs1Device(context, keyBytes)
val token = dev.issueForServer(context)     // 内含 Build.* + ANDROID_ID + 签名证书 hash
val req = dev.signRequest("/v1/verify", System.currentTimeMillis()/1000)
```

## 自测（JVM，真实执行过）

```
payload   : {"fp":"53534620…","ts":1794945508,"pkg":"com.xinghuo.sparkshell","v":"1.0.0"}
token     : xfs1.AbZTT3F6…(230 chars)
roundtrip : 原文完全一致
tamper    : rejected (SecurityException)
server    : HTTP 200 {"ok":true,"license":"XFS1-9B0C2C7FB208C1A3398E9CBB"}
```
