"""ssh_exec.dart 静态自检：括号配平 / import 白名单 / 必需符号 / 禁止 print(。"""
import re
import sys

PATH = "/workspace/sparkshell/lib/ssh/ssh_exec.dart"
src = open(PATH, encoding="utf-8").read()

ok = True


def report(name, passed, detail=""):
    global ok
    ok = ok and passed
    print(f"[{'PASS' if passed else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


# ---------- (a) 括号配平（跳过字符串/字符/注释，逐字符扫描） ----------
def strip_code(text):
    """把注释和字符串内容替换成占位符，保留引号与换行，方便做括号匹配。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        # 行注释
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j < 0:
                j = n
            out.append(" " * (j - i))
            i = j
            continue
        # 块注释（Dart 支持嵌套）
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            j = i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j]))
            i = j
            continue
        # 三引号字符串
        if text.startswith("'''", i) or text.startswith('"""', i):
            q = text[i:i + 3]
            j = text.find(q, i + 3)
            j = n if j < 0 else j + 3
            out.append(q + "".join("\n" if ch == "\n" else "_" for ch in text[i + 3:j - 3]) + q)
            i = j
            continue
        # 普通字符串（Dart 单/双引号，支持 \ 转义和 ${...} 里的代码——这里只保守处理转义）
        if c in "'\"":
            q = c
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == q:
                    j += 1
                    break
                if text[j] == "\n":
                    break
                j += 1
            out.append(q + "_" * max(0, (j - i) - 2) + (q if j - i >= 2 else ""))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


code = strip_code(src)
pairs = {")": "(", "]": "[", "}": "{"}
stack = []
line = 1
mismatch = None
for ch in code:
    if ch == "\n":
        line += 1
    elif ch in "([{":
        stack.append((ch, line))
    elif ch in ")]}":
        if not stack:
            mismatch = f"第 {line} 行出现多余的 {ch}"
            break
        top, ln = stack.pop()
        if top != pairs[ch]:
            mismatch = f"第 {line} 行 {ch} 与第 {ln} 行 {top} 不配对"
            break
if mismatch is None and stack:
    top, ln = stack[-1]
    mismatch = f"第 {ln} 行的 {top} 没有闭合"

report("(a) 括号配平", mismatch is None, mismatch or "圆括号/方括号/花括号全部配对")

# ---------- (b) import 白名单 ----------
imports = re.findall(r"^\s*import\s+['\"]([^'\"]+)['\"]", src, re.M)
bad = [u for u in imports
       if not (u.startswith("dart:") or u.startswith("package:dartssh2/")
               or (":" not in u))]  # 无 scheme 的一律是相对导入（host_store.dart）
report("(b) import 白名单", not bad, f"{imports}" + (f" | 违规: {bad}" if bad else ""))
report("(b2) 无 flutter UI import", not any(u.startswith("package:flutter/") for u in imports),
       "只 import dart:* / package:dartssh2 / 相对路径")

# ---------- (c) 必需符号 ----------
must = [
    "class SshExec",
    "class SshExecResult",
    "Future<SshExecResult> exec(",
    "execOnSaved",
    "aliases(",
    "try {",
    "finally {",
    "SSHSocket.connect(",
    "onVerifyHostKey",
    "runWithResult",
    "client.execute(",
    ".timeout(",
]
for token in must:
    report(f"(c) 出现 {token!r}", token in src)

# try/finally 必须成对出现在 exec 里：粗查 try 数量 >= 3 且 finally 数量 >= 2
report("(c) try/finally 结构", src.count("try {") >= 3 and src.count("finally {") >= 2,
       f"try={src.count('try {')} finally={src.count('finally {')}")

# (d) 禁止 print(：按「函数调用」匹配，避免误伤 _sameFingerprint( 这类方法名
print_calls = re.findall(r"(?<![\w.$])print\s*\(", src)
report("(d) 无 print(", not print_calls, f"匹配到 {len(print_calls)} 处")

# (c2) 结果类字段与 brief 截断长度
for field in ["final bool ok;", "final int exitCode;", "final String stdout;",
              "final String stderr;", "final int ms;", "String get brief"]:
    report(f"(c2) SshExecResult 含 {field!r}", field in src)
report("(c2) brief 截断到 4000", "_briefLimit = 4000" in src)

# (c3) 超时文案与指纹文案
report("(c3) 超时中文文案", "命令超时（${timeoutSeconds}s），连接已关闭" in src)
report("(c3) 指纹变化中文文案", "主机指纹变了，可能在中间人攻击" in src)

# 额外：不能出现明文凭据泄漏迹象
report("(e) 异常文案不拼 password/pem 变量",
       not re.search(r"\$password|\$\{password\}|\$pem\b|\$\{pem\}", src),
       "message 里没有直接插值密码/私钥变量")

# 私有信息泄露：所有字符串里不能出现 BEGIN ... PRIVATE KEY
report("(f) 无 PEM 字面量", "PRIVATE KEY-----" not in src)

print()
print("总行数:", src.count("\n") + 1)
print("总体:", "全部通过" if ok else "有失败项")
sys.exit(0 if ok else 1)
