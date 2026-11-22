#!/bin/bash
# 接手自检：新沙箱第一件事跑这个，30 秒内告诉你「环境能不能干活、线上是不是最新」。
# 用法: bash tool/handoff_check.sh
# 依赖: bash / curl / python3 / sha256sum（都不用装东西）

set -u
TUNNEL="https://discretion-stated-bargain-expect.trycloudflare.com"
REPO="grokggg/sparkshell"
ok=0; bad=0

say()  { printf '%-46s %s\n' "$1" "$2"; }
pass() { say "$1" "PASS  $2"; ok=$((ok+1)); }
fail() { say "$1" "FAIL  $2"; bad=$((bad+1)); }

echo "== 1. 本机环境 =="
say "内核/架构" "$(uname -sr) / $(uname -m)"
if command -v python3 >/dev/null; then pass "python3" "$(python3 -V 2>&1)"; else fail "python3" "缺失"; fi
command -v git   >/dev/null && pass "git" "$(git --version)"   || fail "git" "缺失（小改动可走 API）"
command -v java  >/dev/null && pass "java" "$(java -version 2>&1 | head -1)" || say "java" "缺失（预期：编 APK 交给 CI）"
command -v flutter >/dev/null && pass "flutter" "$(flutter --version 2>&1 | head -1)" || say "flutter" "缺失（预期）"

echo
echo "== 2. 出网（沙箱白名单很窄，这里只测用得上的）=="
code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' https://api.github.com/ 2>/dev/null)
[ "$code" = "200" ] && pass "api.github.com" "200" || fail "api.github.com" "$code（可借 VPS 出网）"
code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' "$TUNNEL/latest.json" 2>/dev/null)
[ "$code" = "200" ] && pass "隧道 latest.json" "200" || fail "隧道 latest.json" "$code"
code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' https://storage.flutter-io.cn/ 2>/dev/null)
[ "$code" = "200" ] || [ "$code" = "403" ] && pass "storage.flutter-io.cn" "$code" || say "storage.flutter-io.cn" "$code"
code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' https://github.com/ 2>/dev/null)
[ "$code" = "200" ] && say "github.com" "200（罕见，通常 000）" || say "github.com" "$code（正常，本沙箱基本连不上）"

echo
echo "== 3. 线上版本与哈希 =="
if curl -s -m 15 "$TUNNEL/latest.json" -o /tmp/latest.json 2>/dev/null && [ -s /tmp/latest.json ]; then
  python3 - <<'PY'
import json
d = json.load(open("/tmp/latest.json"))
print("  版本 %s+%s  %s" % (d.get("version"), d.get("code"), d.get("url")))
print("  size %s  sha256 %s" % (d.get("size"), (d.get("sha256") or "")[:16] + "…"))
print("  notes %s" % d.get("notes"))
PY
  pass "latest.json 可解析" "ok"
else
  fail "latest.json" "拿不到（隧道可能重启换域名了：ssh VPS 后 grep trycloudflare /opt/dl/*.log）"
fi

echo
echo "== 4. 仓库里的包（dist/）=="
if [ -d dist ]; then
  if [ -f dist/join.sh ] && ! ls dist/app-debian-*.apk >/dev/null 2>&1; then
    say "debian 分片" "在，需 ./dist/join.sh 拼回整包"
  fi
  if [ -f dist/SHA256SUMS ]; then
    while read -r sum name; do
      [ -z "$sum" ] && continue
      case "$name" in
        *debian-*.apk) say "$name" "哈希见 SHA256SUMS（拼完再校验）" ;;
        *) [ -f "dist/$name" ] && say "$name" "$(echo "$sum" | cut -c1-16)…" || say "$name" "不在本地" ;;
      esac
    done < dist/SHA256SUMS
  fi
  ls -l dist/app-*.apk 2>/dev/null | awk '{printf "  %-40s %10d B\n", $9, $5}'
else
  say "dist/" "本地没有（231 MB，仓库里有；clone 后才有）"
fi

echo
echo "== 5. 版本号是否双处一致 =="
if [ -f sparkshell/pubspec.yaml ] && [ -f sparkshell/lib/app_version.dart ]; then
  pubv=$(grep -m1 '^version:' sparkshell/pubspec.yaml | sed 's/.*version:[[:space:]]*//' | tr -d ' ')
  appv=$(sed -n "s/.*appVersion[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" sparkshell/lib/app_version.dart | head -1)
  appc=$(sed -n "s/.*appCode[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p" sparkshell/lib/app_version.dart | head -1)
  say "pubspec.yaml" "$pubv"
  say "app_version.dart" "${appv:-?}+${appc:-?}"
  if [ -n "$appv" ] && [ "$pubv" = "${appv}+${appc}" ]; then
    pass "两处一致" "$pubv"
  else
    fail "两处一致" "pubspec 与 app_version.dart 对不上"
  fi
else
  say "源码" "不在仓库根目录，跳过（cd 到有 sparkshell/ 的那层）"
fi

echo
echo "----------------------------------------------"
echo "通过 $ok 项，失败 $bad 项"
[ "$bad" -eq 0 ] && echo "环境可用。下一步读 HANDOFF.md 第 13 节，或直接问用户要做什么。" \
                 || echo "有 FAIL：先解决出网/隧道，再干活（详见 HANDOFF.md 第 9 节）。"
exit 0
