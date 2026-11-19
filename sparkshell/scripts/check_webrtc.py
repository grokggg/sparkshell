#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WebRTC 远程终端 v1 交付自检。

跑法：python3 sparkshell/scripts/check_webrtc.py
检查项：
  a) 四个交付文件存在且非空
  b) lib/webrtc/rtc_remote.dart 不 import flutter/material（也不碰任何 Flutter UI 包）
  c) lib/webrtc/remote_page.dart 里有 class RtcRemotePage extends StatefulWidget
  d) server/rtc_relay.py 通过 py_compile
  e) 四个文件括号配平（Python 用 tokenize，Dart 跳过字符串与注释后计数，Markdown 先剥代码块）

退出码 0 全过，1 有失败项。
"""

import io
import os
import py_compile
import re
import sys
import tokenize

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = {
    "relay": os.path.join(ROOT, "server", "rtc_relay.py"),
    "logic": os.path.join(ROOT, "lib", "webrtc", "rtc_remote.dart"),
    "page": os.path.join(ROOT, "lib", "webrtc", "remote_page.dart"),
    "doc": os.path.join(ROOT, "lib", "webrtc", "README.md"),
}

PAIRS = {")": "(", "]": "[", "}": "{"}
OPEN = set("([{")
CLOSE = set(")]}")

results = []


def check(name, ok, detail=""):
    results.append((ok, name, detail))
    print("%s  %-46s %s" % ("PASS" if ok else "FAIL", name, detail))


# --------------------------------------------------------------- a) 存在且非空
def check_files():
    for tag, path in FILES.items():
        rel = os.path.relpath(path, ROOT)
        if not os.path.isfile(path):
            check("存在: %s" % rel, False, "文件不存在")
            continue
        size = os.path.getsize(path)
        check("存在且非空: %s" % rel, size > 0, "%d 字节" % size)


# --------------------------------------------------------------- b) 无 material
def check_no_material():
    path = FILES["logic"]
    if not os.path.isfile(path):
        check("rtc_remote.dart 不 import flutter/material", False, "文件缺失")
        return
    src = io.open(path, encoding="utf-8").read()
    imports = re.findall(r"^\s*import\s+['\"]([^'\"]+)['\"]", src, re.M)
    bad = [i for i in imports if i.startswith("package:flutter/")]
    allowed = "package:flutter_webrtc/flutter_webrtc.dart"
    check(
        "rtc_remote.dart 不 import flutter/material",
        not bad,
        "imports=%s" % ", ".join(imports),
    )
    check(
        "rtc_remote.dart 只用 flutter_webrtc（无其它 flutter 包）",
        bad == [] and allowed in imports,
        "flutter_webrtc=%s" % (allowed in imports),
    )
    code = strip_dart(src)  # 注释里提到 material 不算，只看真正的代码
    check(
        "rtc_remote.dart 代码里无 Widget/Material 符号",
        ("Widget" not in code) and ("aterial" not in code),
        "",
    )


# --------------------------------------------------------------- c) 页面类
def check_page_class():
    path = FILES["page"]
    if not os.path.isfile(path):
        check("remote_page.dart 有 RtcRemotePage", False, "文件缺失")
        return
    src = io.open(path, encoding="utf-8").read()
    ok = re.search(
        r"class\s+RtcRemotePage\s+extends\s+StatefulWidget\b", src
    ) is not None
    check("remote_page.dart 有 class RtcRemotePage", ok, "")
    ok2 = re.search(
        r"const\s+RtcRemotePage\s*\(\s*\{\s*super\.key\s*\}\s*\)", src
    ) is not None
    check("remote_page.dart 支持 const RtcRemotePage({super.key})", ok2, "")
    ok3 = "State<RtcRemotePage> createState()" in src
    check("remote_page.dart 有 createState()", ok3, "")


# --------------------------------------------------------------- d) py_compile
def check_pycompile():
    path = FILES["relay"]
    if not os.path.isfile(path):
        check("rtc_relay.py 通过 py_compile", False, "文件缺失")
        return
    pyc = os.path.join(os.path.dirname(path), "__pycache__", "check_tmp.pyc")
    try:
        py_compile.compile(path, cfile=pyc, doraise=True)
        check("rtc_relay.py 通过 py_compile", True, "ok")
    except py_compile.PyCompileError as exc:
        check("rtc_relay.py 通过 py_compile", False, str(exc).splitlines()[0])
    finally:
        try:
            if os.path.exists(pyc):
                os.remove(pyc)
        except OSError:
            pass


# --------------------------------------------------------------- e) 括号配平
def balance_python(src):
    """tokenize 精确到 token，注释和字符串不会误伤。"""
    stack = []
    line = 1
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type == tokenize.OP:
            t = tok.string
            if t in OPEN:
                stack.append((t, tok.start[0]))
            elif t in CLOSE:
                if not stack:
                    return False, "第 %d 行多出 %s" % (tok.start[0], t)
                o, ln = stack.pop()
                if o != PAIRS[t]:
                    return False, "第 %d 行 %s 与第 %d 行 %s 不配对" % (tok.start[0], t, ln, o)
    if stack:
        o, ln = stack.pop()
        return False, "第 %d 行 %s 未闭合" % (ln, o)
    return True, "balanced"


def strip_dart(src):
    """去掉注释/字符串内容，只留代码骨架（本文件里的 ${} 插值不含引号，一并跳过）。"""
    out = []
    i = 0
    n = len(src)
    mode = "code"
    quote = ""
    while i < n:
        c = src[i]
        if mode == "code":
            if c == "/" and i + 1 < n and src[i + 1] == "/":
                mode = "line"
                i += 2
                continue
            if c == "/" and i + 1 < n and src[i + 1] == "*":
                mode = "block"
                i += 2
                continue
            if c in "\"'":
                if src.startswith(c * 3, i):
                    mode = "triple"
                    quote = c * 3
                    i += 3
                    continue
                mode = "str"
                quote = c
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if mode == "line":
            if c == "\n":
                out.append("\n")
                mode = "code"
            i += 1
            continue
        if mode == "block":
            if c == "*" and i + 1 < n and src[i + 1] == "/":
                mode = "code"
                i += 2
                continue
            if c == "\n":
                out.append("\n")
            i += 1
            continue
        if mode == "str":
            if c == "\\":
                i += 2
                continue
            if c == quote:
                mode = "code"
            elif c == "\n":  # 单行字符串没闭合 -> 让他继续，平衡检查另说
                out.append("\n")
                mode = "code"
            i += 1
            continue
        if mode == "triple":
            if src.startswith(quote, i):
                mode = "code"
                i += 3
                continue
            if c == "\n":
                out.append("\n")
            i += 1
            continue
    return "".join(out)


def balance_dart(src):
    code = strip_dart(src)
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in OPEN:
            stack.append((ch, line))
        elif ch in CLOSE:
            if not stack:
                return False, "第 %d 行多出 %s" % (line, ch)
            o, ln = stack.pop()
            if o != PAIRS[ch]:
                return False, "第 %d 行 %s 与第 %d 行 %s 不配对" % (line, ch, ln, o)
    if stack:
        o, ln = stack.pop()
        return False, "第 %d 行 %s 未闭合" % (ln, o)
    return True, "balanced（已剥注释/字符串）"


def balance_markdown(src):
    """剥掉 ``` 代码块与 `行内代码` 后再数括号。"""
    lines = src.split("\n")
    kept = []
    fence = False
    for ln in lines:
        s = ln.strip()
        if s.startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        kept.append(re.sub(r"`[^`]*`", "", ln))
    return balance_plain("\n".join(kept))


def balance_plain(src):
    stack = []
    line = 1
    for ch in src:
        if ch == "\n":
            line += 1
        elif ch in OPEN:
            stack.append((ch, line))
        elif ch in CLOSE:
            if not stack:
                return False, "第 %d 行多出 %s" % (line, ch)
            o, ln = stack.pop()
            if o != PAIRS[ch]:
                return False, "第 %d 行 %s 与第 %d 行 %s 不配对" % (line, ch, ln, o)
    if stack:
        o, ln = stack.pop()
        return False, "第 %d 行 %s 未闭合" % (ln, o)
    return True, "balanced"


def check_brackets():
    handlers = {
        ".py": balance_python,
        ".dart": balance_dart,
        ".md": balance_markdown,
    }
    for tag, path in FILES.items():
        rel = os.path.relpath(path, ROOT)
        if not os.path.isfile(path):
            check("括号配平: %s" % rel, False, "文件缺失")
            continue
        src = io.open(path, encoding="utf-8").read()
        fn = handlers[os.path.splitext(path)[1]]
        ok, detail = fn(src)
        check("括号配平: %s" % rel, ok, detail)


# --------------------------------------------------------------- 额外：接口齐全
def check_api():
    src = io.open(FILES["logic"], encoding="utf-8").read()
    need = [
        ("class RtcSignalClient", r"class\s+RtcSignalClient"),
        ("RtcSignalClient.put", r"Future<void>\s+put\("),
        ("RtcSignalClient.poll", r"Future<RtcPollResult>\s+poll\("),
        ("class RtcLink", r"class\s+RtcLink"),
        ("RtcLink.host", r"Future<void>\s+host\("),
        ("RtcLink.join", r"Future<void>\s+join\("),
        ("RtcLink.incoming", r"Stream<String>\s+get\s+incoming"),
        ("RtcLink.send", r"void\s+send\("),
        ("RtcLink.states", r"Stream<String>\s+get\s+states"),
        ("RtcLink.close", r"Future<void>\s+close\("),
        ("DataChannel 消息类型", r"RTCDataChannelMessage\("),
    ]
    for name, pat in need:
        check("接口: %s" % name, re.search(pat, src) is not None, "")

    page = io.open(FILES["page"], encoding="utf-8").read()
    for name, pat in [
        ("页面默认信令地址", r"39\.106\.140\.144:8899"),
        ("页面引用 RtcLink", r"RtcLink\("),
        ("页面有 xterm TerminalView", r"TerminalView\("),
        ("页面有 PTY 通道", r"com\.xinghuo\.sparkshell/pty"),
        ("页面有错误展示", r"_buildError\("),
    ]:
        check("页面: %s" % name, re.search(pat, page) is not None, "")


def main():
    print("=" * 78)
    print("SparkShell WebRTC 远程终端 v1 自检    root=%s" % ROOT)
    print("=" * 78)
    check_files()
    check_no_material()
    check_page_class()
    check_pycompile()
    check_brackets()
    check_api()
    failed = [r for r in results if not r[0]]
    print("-" * 78)
    print("共 %d 项，通过 %d，失败 %d" % (len(results), len(results) - len(failed), len(failed)))
    if failed:
        for _, name, detail in failed:
            print("  ✗ %s  %s" % (name, detail))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
