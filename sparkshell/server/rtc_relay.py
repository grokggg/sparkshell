#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SparkShell WebRTC 信令中转（纯标准库，无第三方依赖）。

它只做一件事：把两端的 SDP / ICE 消息在一个房间里转手。
媒体和终端字节都不经过它，走 WebRTC DataChannel 直连。

协议
----
POST /room/<ROOM>/<ROLE>/<KIND>      body 为 JSON 对象，存进对应队列，返回 204
GET  /room/<ROOM>/<ROLE>/<KIND>?since=N
                                     返回 {"msgs": [...], "next": M}，
                                     无新消息时最多挂 25 秒（长轮询）
POST /room/<ROOM>/close              标记房间关闭，返回 204（60 秒后清理；
                                     仍挂在长轮询上的对端会立刻收到 closed:true）
GET  /health                         存活探测

ROLE ∈ {host, guest}，KIND ∈ {offer, answer, ice}。
消息按 (room, role, kind) 分队列，since 是该队列的下标游标，天然幂等、不丢不乱序。

内存存储：进程重启即清空；房间 10 分钟无读写活动自动过期。
同一房间号被 close 之后仍可重新 POST 重开（队列从头计数）。
"""

import json
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOST = "0.0.0.0"
PORT = 8899

MAX_BODY = 64 * 1024        # 单个请求体上限，SDP 一般 3–6 KB
LONG_POLL = 25.0            # 长轮询最长挂起秒数
ROOM_IDLE = 600.0           # 房间空闲多久算过期
CLOSE_GRACE = 60.0          # 关闭后保留多久（让还在轮询的对端读到 closed）
SWEEP_EVERY = 20.0          # 过期清理周期

ROLES = ("host", "guest")
KINDS = ("offer", "answer", "ice")
ROOM_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


# --------------------------------------------------------------------------- 存储
class Room:
    """一个房间：三个队列，各自一个 since 游标空间。"""

    __slots__ = ("lock", "cond", "msgs", "updated", "closed", "closed_at")

    def __init__(self):
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.msgs = {r: {k: [] for k in KINDS} for r in ROLES}
        self.updated = time.time()
        self.closed = False
        self.closed_at = 0.0


class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self._rooms = {}

    def get(self, room_id, fresh=False):
        """取房间；不存在就建。

        fresh=True 表示"我要往里写"：已关闭的房间会被换成全新的一个，
        这样主机关房后还能用同一个房间号重开。读请求用 fresh=False，
        好让还在轮询的对端读到 closed，而不是傻等 25 秒。
        """
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None or (fresh and room.closed):
                room = Room()
                self._rooms[room_id] = room
            return room

    def count(self):
        with self._lock:
            return len(self._rooms)

    def sweep(self):
        """淘汰空闲房间；先唤醒挂在长轮询上的请求，让它们干净退出。"""
        now = time.time()
        with self._lock:
            dead = [
                rid
                for rid, r in self._rooms.items()
                if now - r.updated > ROOM_IDLE
                or (r.closed and now - r.closed_at > CLOSE_GRACE)
            ]
            victims = []
            for rid in dead:
                victims.append(self._rooms.pop(rid))
        for room in victims:
            with room.cond:
                room.closed = True
                room.cond.notify_all()
        return len(victims)


STORE = Store()


def _sweeper():
    while True:
        time.sleep(SWEEP_EVERY)
        try:
            n = STORE.sweep()
            if n:
                _say("sweep", "清理 %d 个空闲房间" % n)
        except Exception as exc:  # 后台线程不能死
            _say("sweep", "清理异常: %r" % (exc,))


def _say(tag, msg):
    sys.stdout.write("%s [%s] %s\n" % (time.strftime("%H:%M:%S"), tag, msg))
    sys.stdout.flush()


# --------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "SparkSignal/1.0"
    protocol_version = "HTTP/1.1"

    # ---------------------------------------------------------------- 工具
    def _json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        return status, len(body)

    def _empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return status, 0

    def _log(self, status, nbytes, extra=""):
        took = (time.time() - getattr(self, "_t0", time.time())) * 1000.0
        _say(
            self.client_address[0],
            '%s %s -> %s %dB %.0fms%s'
            % (self.command, self.path, status, nbytes, took, (" " + extra) if extra else ""),
        )

    def _route(self):
        """拆出 (room, role|None, kind|None)；不合法返回 None。"""
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not parts or parts[0] != "room":
            return None
        if len(parts) == 2:  # /room/<ROOM>
            return (parts[1], None, None) if ROOM_RE.match(parts[1]) else None
        if len(parts) == 3:  # /room/<ROOM>/close
            if parts[2] != "close" or not ROOM_RE.match(parts[1]):
                return None
            return (parts[1], "close", None)
        if len(parts) == 4:  # /room/<ROOM>/<ROLE>/<KIND>
            room, role, kind = parts[1], parts[2], parts[3]
            if not ROOM_RE.match(room) or role not in ROLES or kind not in KINDS:
                return None
            return (room, role, kind)
        return None

    def _query_since(self):
        q = parse_qs(urlparse(self.path).query)
        raw = (q.get("since") or ["0"])[0]
        try:
            return max(0, int(raw))
        except (TypeError, ValueError):
            return 0

    def _read_body(self):
        """返回 (obj, err)。err 非空表示该回 4xx。"""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            return None, (400, "Content-Length 无效")
        if length < 0:
            return None, (400, "Content-Length 无效")
        if length > MAX_BODY:
            # 没读就走，keep-alive 会把剩下的 body 当成下一个请求，直接断开这条连接。
            self.close_connection = True
            return None, (413, "body 超过 %d 字节" % MAX_BODY)
        data = self.rfile.read(length) if length else b""
        if not data:
            return None, (400, "body 为空，需要 JSON")
        try:
            obj = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            return None, (400, "body 不是合法 JSON: %s" % exc)
        if not isinstance(obj, dict):
            return None, (400, "body 必须是 JSON 对象")
        return obj, None

    # ---------------------------------------------------------------- 方法
    def do_POST(self):
        self._t0 = time.time()
        route = self._route()
        if route is None:
            return self._log(*self._json(404, {"error": "未知路径"}))

        room_id, role, kind = route

        if role == "close":
            # 不直接删：留在表里 60 秒，让还挂在长轮询上的对端读到 closed=true。
            room = STORE.get(room_id)
            with room.cond:
                room.closed = True
                room.closed_at = time.time()
                room.updated = room.closed_at
                room.cond.notify_all()
            return self._log(*self._empty(204), extra="room=%s closed" % room_id)

        obj, err = self._read_body()
        if err is not None:
            return self._log(*self._json(err[0], {"error": err[1]}), extra="body")

        room = STORE.get(room_id, fresh=True)
        with room.cond:
            room.msgs[role][kind].append(obj)
            room.updated = time.time()
            room.cond.notify_all()
            depth = len(room.msgs[role][kind])

        return self._log(*self._empty(204), extra="room=%s %s/%s #%d" % (room_id, role, kind, depth))

    def do_GET(self):
        self._t0 = time.time()
        path = urlparse(self.path).path

        if path == "/health":
            return self._log(*self._json(200, {"ok": True, "rooms": STORE.count(), "ts": int(time.time())}))

        route = self._route()
        if route is None:
            return self._log(*self._json(404, {"error": "未知路径"}))

        room_id, role, kind = route
        if role in (None, "close"):
            return self._log(*self._json(405, {"error": "该路径只接受 POST"}))

        since = self._query_since()
        room = STORE.get(room_id)  # 已关闭的房间原样返回，立刻给 closed

        with room.cond:
            room.updated = time.time()
            buf = room.msgs[role][kind]
            since = min(since, len(buf))
            deadline = time.time() + LONG_POLL
            while not room.closed and len(buf) <= since and time.time() < deadline:
                room.cond.wait(deadline - time.time())
                buf = room.msgs[role][kind]
            out = {"msgs": buf[since:], "next": len(buf)}
            if room.closed:
                out["closed"] = True

        status, n = self._json(200, out)
        return self._log(status, n, extra="room=%s %s/%s since=%d got=%d"
                         % (room_id, role, kind, since, len(out["msgs"])))

    def do_OPTIONS(self):
        # 浏览器里调试时用得上，手机上不需要。
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_one_request(self):
        # 客户端在 25 秒长轮询里提前断开是常态，不该刷一屏 traceback。
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
            _say(self.client_address[0], "%s %s -> 客户端已断开" % (self.command, self.path))

    def log_message(self, fmt, *args):  # 关掉默认的双行日志，统一走 _log
        pass


# --------------------------------------------------------------------------- 入口
def main(argv):
    global PORT
    if len(argv) > 1:
        try:
            PORT = int(argv[1])
        except ValueError:
            _say("boot", "端口参数无效: %s" % argv[1])
            return 2

    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True

    def _stop(signum, frame):
        _say("boot", "收到信号 %s，退出" % signum)
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    threading.Thread(target=_sweeper, daemon=True).start()
    _say("boot", "信令中转启动 http://%s:%d  (长轮询 %.0fs, 房间 %ds 过期)"
         % (HOST, PORT, LONG_POLL, ROOM_IDLE))
    try:
        srv.serve_forever(poll_interval=0.5)
    finally:
        srv.server_close()
        _say("boot", "已停止")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
