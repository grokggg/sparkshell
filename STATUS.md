# 执行流水（2026-11-17）

| # | 动作 | 结果 |
|---|---|---|
| 1 | Flutter 3.50.0 下载解压（xz 缺失 → python lzma 解） | ✅ 3.5 GB |
| 2 | Flutter 需 git → 从 aliyun 拉 git .deb 解包到 /tmp/apt/root | ✅ git 2.47.3 |
| 3 | NDK 27.2.12479018 + cmake 3.22.1 | ✅ 4.1 GB |
| 4 | flutter create + pub add xterm dartssh2 flutter_webrtc | ✅ 39 依赖 |
| 5 | Gradle 9.5.0（官方 307→github 被拦）→ 腾讯镜像 + file:// | ✅ |
| 6 | AGP 9.3.1 + Kotlin DSL 内存峰值 1.93 GB / 2 GB → daemon 被杀 | ❌ ×4 |
| 7 | 改 Groovy DSL + Java Activity（去 Kotlin 编译） | ✅ 配置阶段通过 |
| 8 | flutter_webrtc 模块 compileReleaseJavaWithJavac 单独执行 | ✅ 无错 |
| 9 | 全量 assembleRelease | ❌ daemon 被杀（cgroup 2 GB） |
| 10 | flutter_webrtc 要求 NDK 28.2，磁盘仅剩 1.8 GB | ⛔ |
| 11 | XFS-1 核心 + AAR + 校验服务 | ✅ 端到端验证 |
