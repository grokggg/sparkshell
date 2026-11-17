#!/usr/bin/env python3
"""XFS-1 校验服务（演示用，仅标准库）。

协议：
  POST /v1/verify   {"token": "xfs1.<b64>.<mac16>"}  -> {"ok":true,"license":"...","fp":"..."}
  GET  /healthz

令牌格式（与 com.xinghuo.xfs1.Xfs1 一致）：
  k     = SHA-256("XFS-1" ‖ context ‖ salt)
  blob  = salt(16) ‖ iv(12) ‖ AES-256-GCM(k, payload)
  token = "xfs1." + b64(blob) + "." + hex(HMAC-SHA256(app_key, "xfs1."+b64))[:32]
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # 若无此库请见 README 的纯 stdlib 说明

APP_KEY = bytes.fromhex(os.environ.get("XFS1_APP_KEY", "9f2c41d7a83b06e5c1d94f7b28ae6305d4b81c9f7a2e5d30c6b94f1a8e7d2c05"))
CONTEXT = os.environ.get("XFS1_CONTEXT", "com.xinghuo.sparkshell")
MAX_SKEW = 300  # 秒


def b64d(s: str) -> bytes:
    return base64.b64decode(s + "=" * (-len(s) % 4))


def verify_token(token: str):
    parts = token.split(".")
    if len(parts) != 3 or parts[0] != "xfs1":
        raise ValueError("bad format")
    body_b64, mac = parts[1], parts[2]

    want = hmac.new(APP_KEY, ("xfs1." + body_b64).encode(), hashlib.sha256).hexdigest()[:32]
    if not hmac.compare_digest(want, mac.lower()):
        raise ValueError("bad mac")

    blob = b64d(body_b64)
    salt, iv, ct = blob[:16], blob[16:28], blob[28:]
    k = hashlib.sha256(b"XFS-1" + CONTEXT.encode() + salt).digest()
    pt = AESGCM(k).decrypt(iv, ct, None)
    payload = json.loads(pt.decode())

    now = int(time.time())
    if abs(now - int(payload.get("ts", 0))) > MAX_SKEW:
        raise ValueError("expired")
    return payload


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"ok": True, "service": "xfs1-verify"})
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.path != "/v1/verify":
            return self._send(404, {"ok": False, "error": "not found"})
        n = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
            payload = verify_token(req.get("token", ""))
        except Exception as e:
            return self._send(401, {"ok": False, "error": str(e)})

        license_id = hashlib.sha256(
            (payload.get("fp", "") + str(payload.get("ts"))).encode()).hexdigest()[:24]
        self._send(200, {
            "ok": True,
            "license": "XFS1-" + license_id.upper(),
            "fp": payload.get("fp", "")[:16],
            "pkg": payload.get("pkg"),
            "issued_at": payload.get("ts"),
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8787"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"xfs1-verify listening on :{port}")
    srv.serve_forever()
