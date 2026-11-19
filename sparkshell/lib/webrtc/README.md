# WebRTC 远程终端（v1）

两台手机都装 SparkShell，通过 VPS 上的信令服务配对，之后终端字节走 **WebRTC DataChannel 点对点直连**，不经服务器。

```
 手机 B（主机）                                          手机 A（客户端）
┌──────────────────────┐                              ┌──────────────────────┐
│ 容器 bash  ←→  PTY   │                              │   xterm 终端视图      │
│        ↕             │       DataChannel            │        ↕             │
│  RtcLink(host)  ◀────┼══════ 直连，P2P ════════════▶─┼──▶ RtcLink(guest)    │
└──────────┬───────────┘                              └───────────┬──────────┘
           │  POST/GET offer·answer·ice（长轮询）                  │
           └───────────────▶  VPS  rtc_relay.py :8899  ◀──────────┘
```

## 1. 部署信令服务（VPS：39.106.140.144）

服务端是**纯 Python 3 标准库**，不装任何包。

```bash
# 本地推到 VPS
scp sparkshell/server/rtc_relay.py root@39.106.140.144:/opt/rtc_relay.py

# VPS 上先手动跑一遍，看日志
ssh root@39.106.140.144 'python3 -m py_compile /opt/rtc_relay.py && python3 /opt/rtc_relay.py'
# 另一个终端验证
curl -s http://39.106.140.144:8899/health     # -> {"ok":true,"rooms":0,"ts":...}
```

### systemd

```ini
# /etc/systemd/system/rtc-relay.service
[Unit]
Description=SparkShell WebRTC signaling relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/rtc_relay.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
# 只用内存和 socket，不需要写文件
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now rtc-relay
journalctl -u rtc-relay -f          # 每请求一行日志
```

### 防火墙

```bash
# ufw
ufw allow 8899/tcp
# 或 firewalld
firewall-cmd --permanent --add-port=8899/tcp && firewall-cmd --reload
```

> 阿里云/腾讯云还要在**控制台安全组**放行 8899/TCP，只在机器上开 ufw 是没用的。
> 服务只监听 8899，STUN 走公网 `stun.l.google.com:19302`，不需要额外端口。
> 如果 VPS 在境内，Google 的 STUN 可能不通；把 `lib/webrtc/rtc_remote.dart` 里的
> `iceServers` 换成一个可达的 STUN（例如自建 coturn 的 3478）即可。

## 2. 两端怎么用

**主机（共享自己终端的那台）**

1. 打开 App 第 5 个 Tab「远控」（`RtcRemotePage`）。
2. 信令地址默认 `http://39.106.140.144:8899`；房间号点 🎲 随机生成 6 位，也可手填。
3. 点「创建（主机）」。首次会先释放 proot + rootfs（和 Linux 页共用一套），进度打在下方日志区。
4. 日志出现 `通道已打开` 即连上；状态栏显示「手机 N 台」。
5. 默认只等一台手机。要再放一台进来，点状态栏的「再加一台」。

**客户端（操作别人终端的那台）**

1. 同一页面，填**相同的信令地址和房间号**。
2. 点「加入（客户端）」，等 `已连上主机，可以操作远端终端了`。
3. 终端里直接敲命令；中文输入法可能吃掉回车，用底部 ⏎ 按钮兜底。
4. 断线时状态栏出现「重连」，点一下按原参数重来。

主机退出时点「断开」，会顺手 `POST /room/<房间>/close`，客户端立刻收到「房间已被主机关闭」。

## 3. 协议速查

```bash
# 写消息（body 是 JSON 对象，上限 64 KB）
curl -X POST -H 'Content-Type: application/json' \
     -d '{"peer":"h1","type":"offer","sdp":"v=0..."}' \
     http://IP:8899/room/123456/host/offer          # 204

# 读消息：since 是队列下标游标；没新消息就挂 25 秒
curl 'http://IP:8899/room/123456/guest/answer?since=0'
# -> {"msgs":[...],"next":1}   房间被关时多一个 "closed":true

# 关房间
curl -X POST http://IP:8899/room/123456/close       # 204
```

`ROLE ∈ {host, guest}`、`KIND ∈ {offer, answer, ice}`，每个 (房间, 角色, kind) 一条独立队列。
`next` 直接当下一轮的 `since` 用即可，不会重复也不会漏。

DataChannel 线格式（`rtc_remote.dart` 内部约定）：

| 前缀 | 内容 |
|---|---|
| `d` + base64 | 终端字节（base64 是为了跨消息劈开的多字节汉字不乱码） |
| `j` + base64 | 提示文本，只进状态流，不写终端 |

信令消息体里带 `peer` 字段：主机每开一个待配对 offer 就有一个 peer id，
answer / ice 都按这个 id 归位，所以主机能同时挂多台手机而不串线。

## 4. 接入 main.dart（主工程师看这里）

第 5 个 Tab 的 body 换成 `const RtcRemotePage()` 即可，页面自己管理所有状态：

```dart
import 'webrtc/remote_page.dart';

// Tab 列表里：
const RtcRemotePage(),
```

不需要改 `pubspec.yaml`（`flutter_webrtc` / `xterm` 已经在），也不需要额外权限：
WebRTC 走的是普通 UDP + 已有的 INTERNET 权限。

页面内已经做了这些事，别在外面重复做：

- 主机侧自己开 PTY（复用 `LinuxEnv.ensureReady` → proot 容器，失败退回 `/system/bin/sh`），
  每 40 ms 读一次，输出同时写本机终端和所有已连上的手机；
- 客户端侧把 `xterm` 的 `onOutput` 直接 `send()` 回主机；
- 断线、ICE 失败、HTTP 错误、PTY 错误全部显示在界面错误条里，不吞异常。

自检：

```bash
python3 scripts/check_webrtc.py     # 文件/import/类名/py_compile/括号配平，31 项
```

## 5. 已知限制（v1 有意为之）

- **没有 TURN**：只有 STUN。双方都在对称 NAT / 运营商级 NAT 后面时，打洞会失败，界面显示「ICE 失败（对称 NAT/防火墙，需要 TURN）」。真要用得稳，得架 coturn 并把 `iceServers` 换成 `turn:...`。
- **信令无鉴权**：房间号就是全部凭据，知道房间号的人都能尝试加入。仅适合自己人临时用，别放敏感终端到公网。
- **内存存储**：信令服务重启即清空，房间 10 分钟无活动自动过期。
- **房间号唯一占用**：默认一个房间只配一台客户端；点「再加一台」可以放第 2–4 台，但两端同时抢同一个待配对 offer 时先到先得，后到的要重连。
- **终端尺寸不同步**：主机 PTY 用的是默认窗口大小，客户端 `xterm` 的宽高不会回传给 PTY，`vim`/`htop` 这类全屏程序排版可能不整齐。
- **明文 HTTP**：信令走 `http://`。DataChannel 本身是 DTLS 加密的，但房间号会明文过网。要遮掩就上 Nginx + HTTPS 反代。
- **主机关屏/被杀**：Android 后台会掐 socket，远端会看到「连接断开」，需要点「重连」。
