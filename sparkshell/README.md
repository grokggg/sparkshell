# SparkShell

一个**自己写的** Flutter + NDK 应用，用来把三条 native 能力串起来：

| Tab | 能力 | 实现 |
|---|---|---|
| 本地 PTY | 真终端（`/system/bin/sh`） | C/NDK：`posix_openpt` + `grantpt` + `unlockpt` + `fork` + `setsid` + `dup2` + `execv`，JNI 暴露 `open/read/write/close` |
| SSH | 远程交互式 shell | `dartssh2` 起 `client.shell(pty: 100x32)`，输出直送 `xterm` |
| WebRTC | P2P 数据通道自检 | `flutter_webrtc` 同进程两条 PeerConnection 互连，建 DataChannel 收发 |

UI 全部 Flutter，无第三方 UI 框架；终端组件用 `xterm`。

## 构建

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

环境（实测通过）：Flutter 3.50.0 / Dart 3.14.0、JDK 17、Android SDK 34 + build-tools 34.0.0、NDK 27.2.12479018、CMake 3.22.1。

签名：`android/keystore/sparkshell.jks`（自签，别用于正式发布），alias/pass 均为 `sparkshell`。

## 代码结构

```
lib/
  main.dart           3 个 Tab 的外壳
  pty_terminal.dart   PTY + xterm，走 MethodChannel com.xinghuo.sparkshell/pty
  ssh_terminal.dart   dartssh2 + xterm
  webrtc_page.dart    双 PeerConnection + DataChannel 自检
android/app/src/main/cpp/pty_bridge.c   JNI 实现（NDK 编译成 libptybridge.so）
android/app/src/main/kotlin/.../MainActivity.kt   MethodChannel 分发
```

## 说明

- 只编 `arm64-v8a`（现代真机），APK 体积因此控制在 30 MB 级。
- PTY 跑的是设备自带的 `/system/bin/sh`，**不需要 root**；要跑 Linux 发行版需要另外塞 proot + rootfs（见根目录 README 的"下一步"）。
- WebRTC 自检在无外网时 ICE 会退化，但 DataChannel 走 host candidate 仍可通。
