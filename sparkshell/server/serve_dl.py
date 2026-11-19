#!/usr/bin/env python3
"""静态文件服务（APK 分发）+ WebRTC 信令反代。

为什么要反代：这台 VPS 只有 Cloudflare 隧道（→ 8080）能从公网进来，
腾讯云安全组把 8899 挡在外面。所以 /rtc/* 走同一条隧道转发到本地信令服务，
App 里信令地址填 https://<隧道域名>/rtc 即可，不用再开端口。

文件服务保持原样：Range（手机断点续传）、HEAD、Content-Disposition。
"""
import http.client
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("DL_ROOT", "/opt/dl")
RTC_HOST = "127.0.0.1"
RTC_PORT = int(os.environ.get("RTC_PORT", "8899"))
RTC_PREFIX = "/rtc"
# 信令是 25 秒长轮询，代理超时必须比它长，否则客户端每次都被代理掐断
RTC_TIMEOUT = 45


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # ---------- 文件 ----------
    def _path(self):
        p = self.path.split("?")[0].lstrip("/")
        full = os.path.realpath(os.path.join(ROOT, p))
        if not full.startswith(os.path.realpath(ROOT)) or not os.path.isfile(full):
            return None
        return full

    def _send_head(self, body=True):
        full = self._path()
        if full is None:
            self.send_error(404, "not found")
            return
        size = os.path.getsize(full)
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        code = 200
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = int(m.group(2))
                if start > end or start >= size:
                    self.send_error(416, "bad range")
                    return
                code = 206
        self.send_response(code)
        self.send_header("Content-Type", "application/vnd.android.package-archive")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Disposition",
                         'attachment; filename="%s"' % os.path.basename(full))
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if not body:
            return
        with open(full, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(262144, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(chunk)

    # ---------- 信令反代 ----------
    def _is_rtc(self):
        return self.path.startswith(RTC_PREFIX + "/") or self.path == RTC_PREFIX

    def _proxy(self):
        target = self.path[len(RTC_PREFIX):] or "/"
        if not target.startswith("/"):
            target = "/" + target
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        conn = http.client.HTTPConnection(RTC_HOST, RTC_PORT, timeout=RTC_TIMEOUT)
        try:
            conn.request(self.command, target, body=body,
                         headers={"Content-Type": self.headers.get("Content-Type",
                                                                  "application/json")})
            resp = conn.getresponse()
            data = resp.read()
        except socket.timeout:
            self.send_error(504, "signaling timeout")
            conn.close()
            return
        except Exception as exc:  # 信令挂了要回 502，App 端才能显示真实原因
            self.send_error(502, "signaling unreachable: %s" % exc)
            conn.close()
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        conn.close()

    # ---------- 路由 ----------
    def do_GET(self):
        self._proxy() if self._is_rtc() else self._send_head(True)

    def do_HEAD(self):
        self._send_head(False)

    def do_POST(self):
        if self._is_rtc():
            self._proxy()
        else:
            self.send_error(405, "method not allowed")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
