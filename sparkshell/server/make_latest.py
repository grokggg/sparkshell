#!/usr/bin/env python3
"""给 /opt/dl 里的 APK 生成 latest.json（App 内的更新检查读它）。

用法：
    python3 make_latest.py 3.0.0 32 app-alpine-3.0.0.apk "本次更新说明"
    # 可选：--base https://xxx/app-alpine-3.0.0.apk 覆盖下载地址

为什么不信 GitHub API：手机在国内打 api.github.com 常被掐，
隧道上的静态 JSON 反而稳定；文件本来就在同一台机器上，顺手算 sha256 不会漂。
"""
import argparse
import hashlib
import json
import os
import sys

DEFAULT_BASE = "https://discretion-stated-bargain-expect.trycloudflare.com"


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("code", type=int)
    ap.add_argument("apk")
    ap.add_argument("notes", nargs="?", default="")
    ap.add_argument("--dir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--base", default=DEFAULT_BASE)
    a = ap.parse_args(argv)

    path = a.apk if os.path.isabs(a.apk) else os.path.join(a.dir, a.apk)
    if not os.path.isfile(path):
        print("找不到 APK: %s" % path, file=sys.stderr)
        return 1

    size = os.path.getsize(path)
    digest = sha256_of(path)
    if size < 1 << 20:
        print("警告：%s 只有 %d 字节，不像完整 APK" % (path, size), file=sys.stderr)

    manifest = {
        "version": a.version,
        "code": a.code,
        "url": "%s/%s" % (a.base.rstrip("/"), os.path.basename(path)),
        "size": size,
        "sha256": digest,
        "notes": a.notes,
    }
    out = os.path.join(a.dir, "latest.json")
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    os.replace(tmp, out)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
