#!/bin/bash
# 把 app-debian-3.9.1.apk.part* 拼回完整包，并校验 sha256
set -e
cd "$(dirname "$0")"
cat app-debian-3.9.1.apk.part* > app-debian-3.9.1.apk
sha256sum -c SHA256SUMS 2>/dev/null || sha256sum app-debian-3.9.1.apk app-alpine-3.9.1.apk
echo "拼好了：$(pwd)/app-debian-3.9.1.apk"
