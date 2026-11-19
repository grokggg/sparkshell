# proot 启动参数安全对照报告

> 对象：dsh-go 1.0.15 的 `libproot.so`（逆向伪代码）＋ 我们 SparkShell 实际打包的 `assets/proot/proot`
> 结论日期：2026-11-19　｜　未修改 `lib/linux_env.dart`，本文件仅为报告

## 0. 一句话结论

这个 fork 的 CLI 和我们打包的 proot 是**同一份源码（proot 5.1.107.102 的 Termux 分支）**，
19 个选项一一对应。`--kill-on-exit` / `--sysvipc` / `--ashmem-memfd` **三个都真实存在，拼写就是这三个**；
`--shm-helper` 不是普通选项，是 proot 自己 fork+exec 出来的内部服务进程，**我们永远不该手动传**。

- 可立即加：`--kill-on-exit`，但**只加到交互会话 `start.sh`**，不要加到 `execShell()` 那条路（会 SIGKILL 掉 nohup 后台任务）。
- 必须先探测：`--sysvipc`、`--ashmem-memfd`（都改语义，不是"加了更快"的开关）。
- 不能加：`--shm-helper`、任何带 `=` 值的形式、表外的旗标、`-i`（与 `-0` 互斥）。

---

## 1. 证据基础：两个二进制同源

| 项 | dsh-go `libproot.so` | 我们 `assets/proot/proot` |
|---|---|---|
| sha256 | `68f1280728dd…0016b2e`（README §3） | `f3a2b3f22054b13ad8005360df575236e5d534124495d8fd428bbbf91a452fe3` |
| 体积 | 0.24 MB（可执行段被做成 .so） | 259,832 B |
| 架构 | ELF64 / AArch64 | ELF64 / AArch64，e_machine=183 |
| 版本串 | —（伪代码里读不到） | `.data 0x45170` = `5.1.107.102` |

同源硬证据（三组独立指纹，全部命中）：

1. **选项表步长一致**。dsh-go `main`（`0x1158a4`）里遍历选项表用 `plVar1 + lVar8*0x13`（0x13 个 qword = **152 = 0x98 字节/项**）；
   我们二进制 `.data 0x451d0` 起的表实测步长也是 **0x98**，共 19 项（`0x451d0 … 0x45cb8`）。
2. **19 个 handler 的相对尺寸 10/10 完全相同**（见 §2 表，比值列）。
3. **源文件行号指纹一致**：`sysvipc_shm.c:845/849`、`ashmem_memfd.c:98/125`、`kompat.c:1027`、
   `link2symlink.c:1294`、`sysvipc_sem.c:144`、`hidden_files.c:190`、`fix_symlink_size.c:113`、
   `port_switch.c:48`、`cli/proot.c:165/183` 在我们的二进制里逐条都能 grep 到，行号一个不差。

> 含义：dsh-go 那份伪代码读出来的行为，可以放心用来判断我们自己二进制的行为；反之亦然。

---

## 2. dsh-go fork 支持的完整命令行选项（19 项 + 1 个内部模式）

解析逻辑在 `0x1158a4`（`main`）：`argv` 先经 `FUN_0011bd98` 走表；命中后回调 `entry+0x08` 的 handler，
参数放在 `entry+0x20`（名字）之后；同名多别名共享同一个 152 字节 entry。

| # | 拼写（含别名） | 取值 | dsh-go handler | 我们 handler | 作用 / 备注 |
|---|---|---|---|---|---|
| 0 | `-r` `--rootfs` | path | `0x116424` | `0x169d8` | 设 guest rootfs |
| 1 | `-b` `--bind` `-m` `--mount` | path | `0x116588` / `0x11655c` | `0x16a04` | 绑定；`-m` 是 `--mount` 短写，与 `-b` 同一 entry |
| 2 | `-q` `--qemu` | command | `0x116600` | `0x16a7c` | 断言串直接写着 `int handle_option_q(...)`（`./cli/proot.c:0x8b`） |
| 3 | `-w` `--pwd` `--cwd` | path | `0x116780` | `0x16bfc` | 初始 cwd |
| 4 | **`--kill-on-exit`** | 无 | `0x1167cc` | `0x16c48` | 主命令退出时 SIGKILL 全部 tracee |
| 5 | `-v` `--verbose` | value | `0x1167e0` | `0x16c5c` | 日志级别 |
| 6 | `-V` `--version` `--about` | 无 | `0x116824` | `0x16ca0` | 打印版本+licenses（`_binary_licenses_start`） |
| 7 | `-h` `--help` `--usage` | 无 | `0x116898` | `0x16d14` | 打印用法 |
| 8 | `-k` `--kernel-release` | string | `0x1168c0` | `0x16d3c` | 注册 kompat 扩展 `0x12d6b8` |
| 9 | `-0` `--root-id` | 无 | `0x116974` | `0x16df0` | 注册 fake_id0 `0x131254`（默认身份） |
| 10 | `-i` `--change-id` | string(uid:gid) | `0x116a00` | `0x16e7c` | 注册 fake_id0（指定身份），与 `-0` **互斥** |
| 11 | `--link2symlink`（别名 `-l`） | 无 | `0x116a94` | `0x16f10` | 注册 link2symlink `0x137bec` |
| 12 | **`--sysvipc`** | 无 | `0x116ae0` | `0x16f5c` | 注册 sysvipc `0x1340c0` |
| 13 | **`--ashmem-memfd`** | 无 | `0x116b2c` | `0x16fa8` | 注册 ashmem_memfd `0x12cf4c` |
| 14 | `-H` | 无 | `0x116b78` | `0x16ff4` | hidden_files `0x132f48`（隐藏 `.proot.` 开头的文件） |
| 15 | `-p` | 无 | `0x116b9c` | `0x17018` | port_switch `0x133a14`（绑定被占端口时改高位端口） |
| 16 | `-L` | 无 | `0x116bc0` | `0x1703c` | fix_symlink_size `0x139c78`（修正 lstat 的 symlink 大小） |
| 17 | `-R` | path | `0x116be4` | `0x17060` | 别名：`-r path` + 一组推荐 `-b`（`/etc/host.conf`、`/etc/hosts` …） |
| 18 | `-S` | path | `0x116c94` | `0x17110` | 别名：`-0` + `-r path` + 同一组 `-b` |
| — | **`--shm-helper`** | — | `0x1158a4` 内联分支 | `0x15d44/0x15d48` 引用串 | **不入表**，内部模式，见 §4 |

**handler 尺寸比值 10/10 一致**（用于证明两份表完全同序同项）：
`0x14`(kill→verbose)、`0x74`(V→h)、`0x28`(h→k)、`0x8c`(0→i)、`0x4c`(l2s→sysvipc)、`0x4c`(sysvipc→ashmem)、
`0x4c`(ashmem→H)、`0x24`(H→p)、`0x24`(p→L)、`0xb0`(R→S)。

---

## 3. 三个被点名的旗标：存在性与真实拼写

### 3.1 `--kill-on-exit` ✅ 存在（精确拼写 `--kill-on-exit`，两个连字符，无值）

- dsh-go handler `0x1167cc`，反编译只有一句：`*(undefined1 *)(tracee + 0x22) = 1;`
- 我们二进制同一位置的机器码（`0x16c48`，5 条指令）逐条对上：
  ```
  0x16c48  aa0003e8  mov  x8, x0
  0x16c4c  52800029  mov  w9, #1
  0x16c50  2a1f03e0  mov  w0, wzr
  0x16c54  39008909  strb w9, [x8, #0x22]     ← 就是 tracee+0x22 = 1
  0x16c58  d65f03c0  ret
  ```
- 生效点在 `0x127018`：`+0x21=1`；若 `+0x22==1` → `verbose>0` 打印 `terminating all tracees on exit`，
  然后对 `DAT_00145fa8` 链表里每个 tracee `kill(pid, 9)`。调用方是 tracee 退出路径 `0x129b8c`（`./tracee/event.c`）。
- 帮助文本（我们二进制 `.data 0x45430` entry）：
  > "When the executed command leaves orphean or detached processes around, **proot waits until all processes
  > possibly terminate**. This option forces the immediate termination of all tracee processes when the main command exits."
- 语义确认：事件循环 `0x129764` 是 `while (waitpid(-1, &st, __WALL) >= 0)`，只有 `ECHILD` 才退出；
  并且循环开头 `atexit(FUN_00127dd8)` 注册了**无条件全杀**的兜底。→ **proot 一定会等到最后一个后代进程死掉才退出。**

> 拼写证据等级：行为直接证据（两份实现的 handler 完全一致）＋ 结构等价（同一张表第 5 项）。
> 我们二进制里该字符串原文就在 `.rodata 0x9c09`，可直接 `printf` 验证。

### 3.2 `--sysvipc` ✅ 存在（`--sysvipc`，无值）

- handler `0x116ae0`：`FUN_0012cc78(tracee, 0x1340c0, 0)`，失败打印 **`sysvipc not initialized`**
  → 该诊断串本身就含选项名，是拼写的直接证据。
- 实现 `0x1340c0`，源路径 `./extension/sysvipc/sysvipc.c`、`sysvipc_shm.c`、`sysvipc_sem.c`、`sysvipc_msg.c`。
- 帮助文本：*"IPC is handled inside proot and **launching 2 proot instances will lead to 2 different IPC Namespaces**"*。
  → 对"每条命令起一个 proot"的我们是**语义炸弹**：跨 `execShell` 调用不共享 SysV shm/sem/msg。

### 3.3 `--ashmem-memfd` ✅ 存在（`--ashmem-memfd`，无值，注意中间是一个连字符）

- handler `0x116b2c`：`FUN_0012cc78(tracee, 0x12cf4c, 0)`，失败打印 **`ashmem-memfd not initialized`**。
- 实现 `0x12cf4c`，源 `./extension/ashmem_memfd/ashmem_memfd.c`（断言行 98 / 125 与我们二进制完全一致）。
  作用：用 `/dev/ashmem` 冒充 `memfd_create`，并伪造 `fstat.st_size`。
- 相关环境变量（我们二进制里都能找到）：`PROOT_ASSUME_MEMFD_UNSUPPORTED`、`PROOT_DONT_SHARE_LIBANDROID_SHMEM`、
  `PROOT_ASSUME_NEW_SECCOMP`。

### 3.4 明确**不存在**的（写了会开机即失败，exit 1，stderr 打 `unknown option '…'`）

`--no-link2symlink`、`--seccomp`、`--unshare`、`--pid`、`--net`、`--fork`、`--kill-on-exit=1`、`--sysvipc=1`、
`--ashmem-memfd=1`（后三个即使"认识"，也会命中 `0x1158a4` 的 `option '%s' expects no value.` 分支退出）。

---

## 4. `--shm-helper` 的真实调用方式

**判定：`proot [argv0] --shm-helper`，零附加参数，必须在 argv[1]，且绕过全部选项解析。**

1. **入口**（`0x1158a4` 第 44 行，紧接在 `argv[0]="/proc/self/exe"` 处理之后、建 Tracee 之前）：
   ```
   if (param_1 == 2 && strcmp(*(char **)(param_2 + 8), "--shm-helper") == 0) FUN_00137708();
   ```
   即 `argc==2 && argv[1]=="--shm-helper"` → 直接进 helper 主循环并退出，**不会解析 `-r/-0/-b`**。
   我们二进制同样在 `_start/main` 开头就引用该串（`0x15d44 adrp` + `0x15d48 add #0xf2e` → `0xbf2e`）。

2. **服务端 `0x137708`（`proot-shm-helper: …` 系列）**
   - `socket(AF_UNIX=1, SOCK_SEQPACKET=5, 0)`
   - 路径 = `tempdir()/prootshm-<pid>-XXXXXX`（`0x11ea3c` 模板 `"%s/%s-%d-XXXXXX"`，`mktemp`），
     塞进 `sockaddr_un`（`strncpy` 上限 0x6c）；超长打 `proot-shm-helper: Temporary path too long`
   - `bind()` → `listen(fd, 1)`，然后 **`write(1, path, 0x6c)`**：把 108 字节 socket 路径写回 stdout 当作握手
   - 之后从 **stdin** 循环读 24 字节请求头 `{int op; uint arg; off_t size; …}`，op=0..7：
     0=accept 并用 `SCM_RIGHTS` 送 fd、1=创建、2=close、3=shmget、4=shmat、5=shmdt、6=shmctl、7=shmctl(IPC_STAT)
   - `tempdir()` = `getenv("PROOT_TMP_DIR")` 的 `realpath`，**默认 `/data/data/com.termux/files/usr/tmp/`**（`0x11e988`）

3. **谁拉起它：proot 自己**（`0x136280`，`./extension/sysvipc/sysvipc_shm.c`）
   ```
   pipe2×2 → fork → 子进程 dup2 管道到 0/1 → 再 fork 让孙进程脱离（daemonize）
        → execl("/proc/self/exe", "proot", "--shm-helper", NULL)
   父进程 read(pipe, &path, 0x6c)，读满 108 字节才算成功
   ```
   调用点全在 sysvipc：`0x136008`(sysvipc_shm.c:288 附近)、`0x1364c8`、`0x136814`(last-attach 回收)、
   `0x136954`、`0x137088`。**不传 `--sysvipc` 就永远不会触发 helper。**

4. **它"绑定"什么目录：不 bind 任何目录**。它只是在 `$PROOT_TMP_DIR` 下**创建一个 AF_UNIX 路径套接字文件**
   （我们路径 `/data/data/<pkg>/files/tmp/prootshm-1234-AbCdEf`，约 60 字符，远低于 108 上限）；
   `-b` 的绑定是另一套（`0x11b510` / `path/binding.c`），和它无关。

---

## 5. 对照 `lib/linux_env.dart`

现状（未改动）：

```dart
// lib/linux_env.dart:120  _proot()
[ '--link2symlink', '-0', '-r', rootfs,
  '-b','/dev','-b','/proc','-b','/sys','-b','/sdcard','-b','/storage', ...args ]
env: LD_LIBRARY_PATH, PROOT_TMP_DIR=$files/tmp, PROOT_L2S_DIR=$files/.l2s, PATH
// lib/linux_env.dart:169  start.sh
exec $base/proot/proot --link2symlink -0 -r $rootfs -b /dev … -w /root /usr/bin/env -i … $SHELL_BIN -l
```

两条路都**只用了表里的 `--link2symlink` / `-0` / `-r` / `-b` / `-w`**，全部合法，没有隐患。

### 判定表

| 旗标 | 判定 | 理由（证据） |
|---|---|---|
| `--kill-on-exit` → 加进 `start.sh` | ✅ **可立即加** | 表内第 5 项（dsh-go `0x1167cc` / 我们 `0x16c48`），无值、无依赖、不需要任何环境变量。交互会话关掉时把 shell 里遗留的后台进程一起 SIGKILL（`0x127018`，signal 9），避免"关终端后 proot 还挂着"的事故现场 |
| `--kill-on-exit` → 加进 `_proot()`（`execShell`） | ❌ **不要** | `execShell` 同时服务于 `TaskStore.start()`（`lib/agent/tools.dart:375` → `task_store.dart:246` 的 `nohup … &`）。`0x127018` 是**无条件对 tracee 链表全杀**，加了之后"后台任务"会在返回瞬间被 SIGKILL（同时还 `atexit` 兜底 `0x127dd8`） |
| `--sysvipc` | ⚠️ **先探测** | 存在但会改写 IPC 语义：帮助文本明说"2 个 proot 实例 = 2 个 IPC namespace"。我们每条命令一个新 proot，跨调用共享 shm 会失效；且会拉起 §4 的 helper，要求 `PROOT_TMP_DIR` 可写且路径 <108 字节（我们满足） |
| `--ashmem-memfd` | ⚠️ **先探测** | 存在但只在"宿主缺 memfd_create（Android seccomp 常拦）且 /dev/ashmem 可用"时才有收益；否则是给 lstat/fstat 加了一层伪造，可能让某些程序算错文件大小 |
| `--shm-helper` | ❌ **绝对不能加** | `argc` 必须恰好为 2、必须在 `argv[1]`，加了 proot 会变成 helper 守护进程，**容器根本不会启动**（`0x1158a4:44`）。它由 `--sysvipc` 自动 fork+exec |
| `-i` / `--change-id` | ❌ 不加 | 与 `-0` 互斥（`0x116a00` 与 `0x116974` 都会先 `FUN_0012cc48` 查重，打 `only the last -i/-0/-S option is enabled`） |
| `-R` / `-S` | 保持现状 | 可用，但会把 rootfs + `/etc/hosts` 等 `-b` 全包了；我们已有自己的 `-b` 清单，改了反而不可控 |
| `-H` / `-p` / `-L` | 不加 | 扩展，各有副作用（隐藏 `.proot.` 文件 / 改端口 / 改 symlink 大小），与本次目标无关 |
| 任何表外旗标 | ❌ | 解析失败 → `fatal error: see 'proot --help'`，exit 1（正是"开机就启不来"） |

---

## 6. 探测办法（真机执行，本机是 x86_64 跑不了 arm64 二进制）

> 三组探针都只读、零副作用，可以在 App 里临时用一个隐藏按钮/调试入口跑，不必改发布逻辑。

### A. 零成本"认不认识这个旗标"（不需要 rootfs，秒级）

```sh
cd /data/data/<pkg>/files
./proot/proot --sysvipc --help >/dev/null 2>&1; echo "sysvipc rc=$?"
./proot/proot --ashmem-memfd --help >/dev/null 2>&1; echo "ashmem rc=$?"
./proot/proot --kill-on-exit --help >/dev/null 2>&1; echo "kill rc=$?"
```
- `rc=0` 且打印 usage ⇒ 认识（`--help` 的 handler `0x116898` 走 `exit 0`，不需要 `-r`）
- `rc=1` 且 stderr 有 `unknown option '--xxx'.` ⇒ 不认识
- 反向验证：`./proot/proot --no-link2symlink --help` 应当 `rc=1`（确认探针本身有效）

### B. `--kill-on-exit` 语义 / 后台任务存活（决定要不要加，最关键）

```sh
t0=$(date +%s)
./proot/proot --link2symlink -0 -r rootfs -b /dev -b /proc /bin/sh -c \
  'nohup sleep 20 >/dev/null 2>&1 & echo $! > /root/.probe.pid'
echo "elapsed=$(( $(date +%s) - t0 ))"
```
- `elapsed≈20` ⇒ 证实 proot 会等所有后代（即你们现在的 `bash_background` 其实会阻塞到任务结束）
- 再跑一次，前面加 `--kill-on-exit`：
  ```sh
  ./proot/proot --kill-on-exit --link2symlink -0 -r rootfs -b /dev -b /proc /bin/sh -c \
    'nohup sleep 600 >/dev/null 2>&1 & echo $! > /root/.probe.pid'
  P=$(cat rootfs/root/.probe.pid); sleep 1; kill -0 $P 2>/dev/null && echo ALIVE || echo KILLED
  ```
- `elapsed≈0` 且 `KILLED` ⇒ 印证"加到 `execShell` 会杀掉后台任务"。这条结果直接决定 §5 的判定。

### C. `--sysvipc` 功能探测

```sh
./proot/proot --link2symlink -0 --sysvipc -r rootfs -b /dev -b /proc -v 2 /bin/sh -c \
  'ipcmk -M 4096; ipcs -m; ls -l /dev/shm; python3 - <<EOF
import multiprocessing as m, os
print("mp start:", m.Process(target=lambda: None).start())
EOF'
```
- stderr 出现 `sysvipc not initialized` ⇒ 注册失败，直接放弃
- 同时开另一个终端 `ps -A | grep -- --shm-helper`，应能看到 helper 进程（证明 §4 的拉起路径成立）
- 对比加/不加时 `ipcs -m` 输出与 `/dev/shm` 的 `statfs`

### D. `--ashmem-memfd` 探测

```sh
ls -l /dev/ashmem                      # 宿主侧：不存在就没收益
./proot/proot --link2symlink -0 --ashmem-memfd -r rootfs -b /dev -b /proc /bin/sh -c \
  'python3 -c "import os,stat;fd=os.memfd_create(\"x\");print(fd, os.fstat(fd).st_size)"'
```
- 不加该旗标时若报 `EPERM/EINVAL`（Android seccomp 拦 memfd_create），而加了能出 fd ⇒ 值得加
- 若 `os.fstat(fd).st_size` 明显不对（ashmem 伪造），说明会带来新问题

---

## 7. 建议（不改代码，只给结论）

1. **`start.sh` 加 `--kill-on-exit`**（放在 `--link2symlink` 之后即可，顺序无关）：
   `exec $base/proot/proot --link2symlink --kill-on-exit -0 -r $rootfs …`
   收益：关会话即清理，不留 tracee 僵尸；风险：会话里 `nohup … &` 的守护进程会一起死（App 场景通常正是想要的）。
2. **`_proot()` 一行都不要动**，直到探针 B 证明后台任务模型可以接受被杀。
3. `--sysvipc` / `--ashmem-memfd` 走"探针 → 只对有需求的镜像/场景开启"（例如 alpine 里跑 postgres、python 多进程），
   不要作为全局默认；一旦开启必须保证 `PROOT_TMP_DIR` 存在且可写（现有代码已满足）。
4. 任何情况下都不要把 `--shm-helper` 写进命令行，也不要给三个无值旗标加 `=1`。
