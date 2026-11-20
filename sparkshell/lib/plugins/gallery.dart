// 内置插件仓库：开箱即用的 8 个插件，全部只依赖 Alpine proot 里现成的东西
// （busybox ash + curl + python3），不额外装包、不要 key。
//
// 约定（很重要）：
// 1) 命令模板里 `{{args}}` 会被 PluginStore.buildCommand 替换成「整个 JSON 的单引号
//    字面量」，所以模板里**不要**再给占位符自己加引号，直接写在 argv 位置上。
// 2) 命令里需要读参数时统一用 python3 解 JSON：ash 没有 jq，手写 sed 解 JSON
//    在遇到中文/转义字符时必翻车。python3 是 agent 本来就依赖的运行时。
// 3) 每条命令都要有「缺参数就报错退出」的前置判断，并且上限截断输出（head -c），
//    否则一个 2MB 的网页会把上下文直接吃光。
// 4) translate_stub 是**占位**插件，命令里明确写出「没有翻译能力」，
//    不假装能翻译 —— 假装成功比报错更坑模型。

import 'plugin.dart';

/// 8 个内置插件。每次调用都新建对象：内置列表可以被用户改 enabled，
/// 不能共享可变实例。
List<Plugin> builtinGallery() => <Plugin>[
      Plugin(
        id: 'http_get',
        name: '抓网页',
        description: '用 curl 抓取一个 URL 的正文（前 4000 字），适合看文档、接口返回、纯文本页面。参数：{"url":"https://..."}',
        builtin: true,
        command: r'''
u=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('url',''))" {{args}})
[ -n "$u" ] || { echo "缺少 url 参数"; exit 1; }
curl -sSL --max-time 25 -A "Mozilla/5.0 (Linux; Android 13)" "$u" | head -c 4000
''',
      ),
      Plugin(
        id: 'notes',
        name: '随手记',
        description: '把一段文本追加到 /root/notes.md（自动带时间戳），并回显最后 10 行。参数：{"text":"要记的内容"}',
        builtin: true,
        command: r'''
t=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('text',''))" {{args}})
[ -n "$t" ] || { echo "缺少 text 参数"; exit 1; }
printf '%s %s\n' "$(date '+%F %T')" "$t" >> /root/notes.md
echo "--- /root/notes.md 末尾 10 行 ---"
tail -n 10 /root/notes.md
''',
      ),
      Plugin(
        id: 'todo',
        name: '待办清单',
        description: '读写 /root/todo.txt。参数：{"action":"add|list|done","item":"事项","index":序号}；add 用 item，done 用 index 或 item，list 不用参数。',
        builtin: true,
        command: r'''
python3 -c '
import json, os, sys
a = json.loads(sys.argv[1])
act = a.get("action", "list")
item = a.get("item", "")
p = "/root/todo.txt"
lines = []
if os.path.exists(p):
    lines = [l.rstrip("\n") for l in open(p, encoding="utf-8") if l.strip()]
if act == "add":
    if not item:
        print("缺少 item"); sys.exit(1)
    lines.append("[ ] " + item)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("已添加：" + item)
elif act == "done":
    idx = int(a.get("index", 0) or 0)
    if 0 < idx <= len(lines):
        lines[idx - 1] = lines[idx - 1].replace("[ ]", "[x]", 1)
    elif item:
        for i, l in enumerate(lines):
            if l.startswith("[ ]") and item in l:
                lines[i] = l.replace("[ ]", "[x]", 1)
                break
        else:
            print("没找到待办：" + item); sys.exit(1)
    else:
        print("done 需要 index 或 item"); sys.exit(1)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("已标记完成")
else:
    if not lines:
        print("待办为空（" + p + "）"); sys.exit(0)
    for i, l in enumerate(lines, 1):
        print(str(i) + ". " + l)
' {{args}}
''',
      ),
      Plugin(
        id: 'sysinfo',
        name: '系统信息',
        description: '看一眼容器环境：内核版本、磁盘占用、内存余量。不用参数。',
        builtin: true,
        command: r'''
echo "== 内核 =="; uname -a
echo "== 磁盘 =="; df -h 2>/dev/null | head -n 20
echo "== 内存 =="; free -m 2>/dev/null || head -n 3 /proc/meminfo
''',
      ),
      Plugin(
        id: 'weather',
        name: '天气',
        description: '查一个城市的当前天气（wttr.in 一行摘要，无需 key）。参数：{"city":"北京"}',
        builtin: true,
        command: r'''
c=$(python3 -c "import json,sys,urllib.parse;print(urllib.parse.quote(json.loads(sys.argv[1]).get('city','')))" {{args}})
[ -n "$c" ] || { echo "缺少 city 参数"; exit 1; }
curl -sS --max-time 20 "https://wttr.in/$c?format=3"
''',
      ),
      Plugin(
        id: 'web_search',
        name: '网页搜索',
        description: '用 DuckDuckGo 的 html 版搜关键词（不需要 key），粗提前 10 条标题和链接。参数：{"q":"关键词"}',
        builtin: true,
        command: r'''
q=$(python3 -c "import json,sys,urllib.parse;print(urllib.parse.quote(json.loads(sys.argv[1]).get('q','')))" {{args}})
[ -n "$q" ] || { echo "缺少 q 参数"; exit 1; }
curl -sSL --max-time 25 -A "Mozilla/5.0 (Linux; Android 13)" "https://duckduckgo.com/html/?q=$q" \
  | sed -n 's/.*class="result__a"[^>]*href="\([^"]*\)"[^>]*>\(.*\)<\/a>.*/\2  \1/p' \
  | sed 's/<[^>]*>//g' \
  | head -n 10
''',
      ),
      Plugin(
        id: 'url_short',
        name: '短链接',
        description: '把一个长 URL 换成 is.gd 短链（无需 key）。参数：{"url":"https://..."}',
        builtin: true,
        command: r'''
u=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('url',''))" {{args}})
[ -n "$u" ] || { echo "缺少 url 参数"; exit 1; }
curl -sS --max-time 20 --get --data-urlencode "url=$u" --data "format=simple" "https://is.gd/create.php"
''',
      ),
      Plugin(
        id: 'translate_stub',
        name: '翻译（占位）',
        description: '占位插件：把待翻译文本原样写进 /root/.inbox.txt 并提示，不做任何翻译。参数：{"text":"原文"}',
        builtin: true,
        command: r'''
t=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('text',''))" {{args}})
[ -n "$t" ] || { echo "缺少 text 参数"; exit 1; }
printf '%s\n' "$t" > /root/.inbox.txt
echo "【占位插件，未翻译】原文已写入 /root/.inbox.txt（$(wc -c < /root/.inbox.txt) 字节）。"
echo "本机没有接翻译服务；需要译文请让 agent 直接处理这段文本，或自行配置在线翻译 API。"
''',
      ),
    ];
