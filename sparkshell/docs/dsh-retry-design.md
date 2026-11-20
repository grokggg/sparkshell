# 作者的重试设计：逆向数据里有什么、没什么

写于 v3.6.2。目的是回答一个问题：**dsh-go 的作者到底怎么重试？** 结论先说：逆向库里没有这段逻辑，能拿到的是 AOT 快照里的常量名和文案，据此还原。

## 一、逆向库 `grokggg/dsh-go-1.0.15-rea` 里没有

- `aot.json` 原文：`unsupported_target — Observed unified Dart snapshot exports; this reader supports the legacy split VM/isolate profile (Dart 2.14 FullAOT kind 3). The unified profile is unsupported, not missing legacy data`。
  也就是说 REA 的 `inspect_dart_aot` **解不了** dsh-go 的 unified snapshot，Dart 业务逻辑没有被反出来。
- 库里能读的是 `libproot.so`（路径改写、seccomp）和 `libdartjni.so`（JNI 桥）的函数级伪代码；`dart_inventory.json` 只有 809 个文件路径清单，没有函数体。
- 所以「照作者的代码抄」这条路不存在。能照的只有**行为**和**字符串**。

## 二、源码库 `grokggg/dsh-Go` 里也看不到模型请求重试

- `app/lib/state/provider_backend.dart` 只做 provider 的增删改查（`read/create/update/remove/storeKey`），没有重试。
- 模型请求走的是引擎侧（`packages/dsh_client` 是 RPC 客户端），重试发生在引擎里，Dart 侧只接收 `LlmRetryEvent`。

## 三、从 `libapp.so` 快照里捞到的实证（33,948,552 B，sha256 `d3af09ec…`）

```
chatRequestRetryLimit        # 重试次数上限
chatRequestRetryAttempt      # 当前第几次
retry-after                  # 读响应头
backoff                      # 有退避，但不是唯一手段
LlmRetryEvent / llm/retry    # 重试作为事件上报给 UI
retryAt
429. A breather, then retry  # 429 的处理口径：喘口气再试
Retrying model request (
Request failed, retrying (attempt
```

译成设计语言：

1. **有次数上限**（`Limit`），不是无脑死循环；
2. **429 是「breather」**——短停顿，不是几十秒的指数退避；
3. **读 `Retry-After`**，服务端说多久就多久；
4. **重试是事件**（`LlmRetryEvent`），所以 UI 能显示“第几次”，也能在到上限后不再刷屏。

## 四、我们照着做的实现（v3.6.2）

| 项 | 做法 |
| --- | --- |
| 节奏 | 1 秒起步，1–2.2 秒抖动；**永不指数增长** |
| Retry-After | 有就用，夹在 1–5 秒（头里写 60 秒也不真睡 60 秒） |
| 次数 | 前 8 次逐次报数；第 8 次之后界面不再刷，但后台按同样节奏继续 |
| 退出口 | 只有用户点停止，或 401/403/400 这类重试无意义的错误 |
| 防封 | 不靠拉长间隔，靠「短停顿 + 抖动错峰」；429 本身是廉价响应，不会因为频繁 429 触发封禁，真正会封的是高频成功请求 |

## 五、没做到的部分

- 作者的 `chatRequestRetryLimit` 具体数值（8 还是别的）在快照里是常量，不跟字符串相邻，无法静态读出；8 来自你在真机上的观察。
- 引擎侧是否有「连续限流后降速」的二级保险，快照里没有对应文案，判断为没有。
