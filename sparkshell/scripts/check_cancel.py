#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SparkShell 中断能力静态自检（沙箱没有 dart 编译器，只能这么做）。

检查项：
  (a) 三个改动的文件括号配平（先剔除注释和字符串字面量，避免误判）
  (b) CancelToken 类存在，AgentRunner 构造参数里有 this.cancel
  (c) llm_client 的重试循环里，在退避 delay 之前判断了取消
  (d) chat_page 里有 Icons.stop，且有点 _token?.cancel()
  (e) 列出所有 AgentRunner( / LlmClient( 调用点，核对命名参数兼容
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = {
    "runner": os.path.join(ROOT, "lib/agent/agent_runner.dart"),
    "token": os.path.join(ROOT, "lib/agent/cancel_token.dart"),
    "llm": os.path.join(ROOT, "lib/chat/llm_client.dart"),
    "page": os.path.join(ROOT, "lib/chat/chat_page.dart"),
}

FAIL = []


def read(key):
    with open(FILES[key], encoding="utf-8") as f:
        return f.read()


def mask_dart(src):
    """把注释和字符串换成占位符，保留换行，方便做括号配平和结构查找。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j
            seg = src[i:j + 2]
            out.append(" " * (len(seg) - seg.count("\n")) + "\n" * seg.count("\n"))
            i = j + 2
            continue
        raw = c == "r" and i + 1 < n and src[i + 1] in "'\""
        if raw or c in "'\"":
            qpos = i + 1 if raw else i
            q = src[qpos]
            delim = q * 3 if src.startswith(q * 3, qpos) else q
            j = qpos + len(delim)
            while j < n:
                if not raw and src[j] == "\\":
                    j += 2
                    continue
                if src.startswith(delim, j):
                    j += len(delim)
                    break
                j += 1
            seg = src[i:j]
            out.append(" " * (len(seg) - seg.count("\n")) + "\n" * seg.count("\n"))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_brackets(key):
    src = mask_dart(read(key))
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for idx, ch in enumerate(src):
        if ch in "([{":
            stack.append((ch, idx))
        elif ch in ")]}":
            if not stack:
                FAIL.append(f"(a) {key}: 多余的 '{ch}' @ line {src.count(chr(10), 0, idx) + 1}")
                return
            op, oi = stack.pop()
            if op != pairs[ch]:
                line = src.count("\n", 0, idx) + 1
                FAIL.append(f"(a) {key}: '{op}' 与 '{ch}' 不配对 @ line {line}")
                return
    if stack:
        op, oi = stack[-1]
        FAIL.append(f"(a) {key}: '{op}' 未闭合 @ line {src.count(chr(10), 0, oi) + 1}")
    else:
        print(f"  (a) {os.path.relpath(FILES[key], ROOT):32s} 括号配平 OK")


def check_token():
    tok = read("token")
    runner = mask_dart(read("runner"))
    ok = True
    if not re.search(r"class\s+CancelToken\s*\{", tok):
        FAIL.append("(b) cancel_token.dart 里没有 `class CancelToken {`")
        ok = False
    for member in ["bool get isCancelled", "void cancel()", "Future<void> get whenCancelled", "Completer"]:
        if member not in tok:
            FAIL.append(f"(b) CancelToken 缺少 {member}")
            ok = False
    ctor = re.search(r"AgentRunner\(\{(.*?)\}\)\s*;", runner, re.S)
    if not ctor:
        FAIL.append("(b) 没找到 AgentRunner 构造函数")
        ok = False
    elif "this.cancel" not in ctor.group(1):
        FAIL.append("(b) AgentRunner 构造参数里没有 this.cancel")
        ok = False
    if "final CancelToken? cancel;" not in runner:
        FAIL.append("(b) AgentRunner 没有 `final CancelToken? cancel;` 字段")
        ok = False
    if ok:
        print("  (b) CancelToken 类 / isCancelled / cancel() / whenCancelled / this.cancel  全部存在")


def check_retry_cancel():
    src = mask_dart(read("llm"))
    m = re.search(r"for \(var attempt = 1;.*?\n    \}\n    throw last", src, re.S)
    if not m:
        FAIL.append("(c) 没定位到 _open 的重试循环")
        return
    body = m.group(0)
    sleep_at = body.find("_sleep(")
    delay_at = body.find("delayFor(")
    cancel_checks = [mm.start() for mm in re.finditer(r"isCancelled", body)]
    if sleep_at < 0:
        FAIL.append("(c) 重试循环里找不到 _sleep(...) 退避等待")
        return
    before = [p for p in cancel_checks if p < sleep_at]
    if not before:
        FAIL.append("(c) delay 之前没有 isCancelled 判断")
        return
    # 再确认捕获异常那条路径也被归类成取消（不是当网络故障重试）
    if "throw const _Cancelled()" not in body:
        FAIL.append("(c) 循环里没有抛 _Cancelled 直接退出")
        return
    if "close(force: true)" not in src:
        FAIL.append("(c) llm_client 没有 close(force: true)")
        return
    print(f"  (c) 重试循环：delay 前有 {len(before)} 处 isCancelled 判断，"
          f"取消路径抛 _Cancelled（共 {len(cancel_checks)} 处判断），强制断 socket 存在")


def check_page():
    src = mask_dart(read("page"))
    ok = True
    if "Icons.stop" not in src:
        FAIL.append("(d) chat_page 里没有 Icons.stop")
        ok = False
    if "_token?.cancel()" not in src:
        FAIL.append("(d) chat_page 里没有 _token?.cancel()")
        ok = False
    if "正在停止…" not in read("page"):
        FAIL.append("(d) chat_page 里没有「正在停止…」状态文案")
        ok = False
    if "cancel: token" not in src:
        FAIL.append("(d) chat_page 没把 token 传给 AgentRunner / chat()")
        ok = False
    if ok:
        print("  (d) chat_page：Icons.stop / _token?.cancel() / 「正在停止…」/ cancel: token 均存在")


def call_sites(name):
    """扫描全仓 .dart，找出 `name(` 调用点，返回 (文件:行, 顶层命名参数集合, 位置参数数)。"""
    hits = []
    for dirpath, _, files in os.walk(os.path.join(ROOT, "lib")):
        for fn in files:
            if not fn.endswith(".dart"):
                continue
            path = os.path.join(dirpath, fn)
            src = mask_dart(read_path(path))
            for m in re.finditer(r"\b" + name + r"\(", src):
                # 排除定义处 `class X {`、`X(this.cfg` 这种：定义处前面通常是空白或 class/ 括号
                start = m.end()
                depth = 1
                i = start
                while i < len(src) and depth:
                    if src[i] in "([{":
                        depth += 1
                    elif src[i] in ")]}":
                        depth -= 1
                    i += 1
                args = src[start:i - 1]
                # 跳过构造函数/方法声明本身（`AgentRunner({required this.cfg…})`、
                # `LlmClient(this.cfg, {this.onRetry})`）
                if args.lstrip().startswith("{") or "this." in args:
                    continue
                # 按顶层逗号切
                parts, depth, cur = [], 0, ""
                for ch in args:
                    if ch in "([{":
                        depth += 1
                    elif ch in ")]}":
                        depth -= 1
                    if ch == "," and depth == 0:
                        parts.append(cur)
                        cur = ""
                    else:
                        cur += ch
                if cur.strip():
                    parts.append(cur)
                named, positional = [], 0
                for p in parts:
                    p = p.strip()
                    if not p:
                        continue
                    mm = re.match(r"^([A-Za-z_]\w*)\s*:(?!:)", p)
                    if mm:
                        named.append(mm.group(1))
                    else:
                        positional += 1
                line = src.count("\n", 0, m.start()) + 1
                hits.append((os.path.relpath(path, ROOT), line, named, positional, " ".join(args.split())[:90]))
    return hits


def read_path(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def check_calls():
    allowed_runner = {"cfg", "onText", "onToolResult", "approve", "onTool", "maxSteps", "onStatus", "cancel"}
    required_runner = {"cfg", "onText", "onToolResult", "approve"}
    ok = True

    print("  (e) AgentRunner( 调用点：")
    for path, line, named, pos, brief in call_sites("AgentRunner"):
        # 构造函数声明本身会被扫到（参数是 this.xxx，没有命名参数形状）
        tag = "OK"
        bad = [n for n in named if n not in allowed_runner]
        miss = [r for r in required_runner if r not in named]
        if bad or miss:
            tag = f"!! 未知参数={bad} 缺必填={miss}"
            ok = False
        print(f"      {path}:{line}  named={sorted(named)}  → {tag}")
        if not named:
            print(f"        原文: {brief}")

    print("  (e) LlmClient( 调用点（第一个位置参数 cfg，命名参数只允许 onRetry）：")
    for path, line, named, pos, brief in call_sites("LlmClient"):
        tag = "OK"
        bad = [n for n in named if n not in {"onRetry"}]
        if pos < 1:
            tag = "!! 缺 cfg 位置参数"
            ok = False
        if bad:
            tag = f"!! 未知命名参数={bad}"
            ok = False
        print(f"      {path}:{line}  cfg位置参数={pos} named={sorted(named)}  → {tag}")

    if not ok:
        FAIL.append("(e) 存在参数不兼容的调用点")


def main():
    print("SparkShell 中断能力自检")
    print("-" * 62)
    for key in ("token", "runner", "llm", "page"):
        check_brackets(key)
    check_token()
    check_retry_cancel()
    check_page()
    check_calls()
    print("-" * 62)
    if FAIL:
        print(f"失败 {len(FAIL)} 项：")
        for f in FAIL:
            print("  ✗ " + f)
        return 1
    print("全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
