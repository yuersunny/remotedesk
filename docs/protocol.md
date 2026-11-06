# RemoteDesk 信令协议 (v0)

传输：WebSocket，JSON 文本帧。端点 `ws://<host>:8787/ws`。

## 角色

- **主控端 (controller)**：发起连接、显示远端画面、发送输入事件。
- **被控端 (target)**：接受连接、采集画面、注入本地输入。

同一客户端可同时具备两种角色。

## 消息一览

| 方向 | type | 字段 | 说明 |
|---|---|---|---|
| C→S | `register` | `id?`, `name?`, `token?` | 注册设备；`id` 缺省由服务端生成 |
| S→C | `registered` | `id`, `name` | 注册成功 |
| C→S | `list` | — | 查询在线设备 |
| S→C | `devices` | `devices:[{id,name}]` | 在线设备列表（不含自己） |
| C→S | `connect` | `to`, `password?` | 请求连接目标 |
| S→target | `incoming` | `from`, `fromName`, `requiresPassword`, `password` | 通知被控端有来电；口令原样带上，由被控端自行比对 |
| S→C | `connect_requested` | `to` | 已转发请求 |
| C→S | `accept` | `to`, `password?` | 被控端接受（可附带会话密码） |
| S→C | `accepted` | `from`, `password?` | 主控端收到接受 |
| C→S | `reject` | `to` | 被控端拒绝 |
| S→C | `rejected` | `from` | 主控端收到拒绝 |
| C→S | `offer` | `to`, `sdp` | WebRTC offer |
| S→peer | `offer` | `from`, `sdp` | 转发 |
| C→S | `answer` | `to`, `sdp` | WebRTC answer |
| S→peer | `answer` | `from`, `sdp` | 转发 |
| C→S | `ice` / `candidate` | `to`, `candidate` | ICE 候选 |
| S→peer | `ice` / `candidate` | `from`, `candidate` | 转发 |
| C→S | `leave` | `to` | 结束会话 |
| S→peer | `peer_left` | `from` | 对端离开 |
| C→S | `ping` | — | 应用层心跳 |
| S→C | `pong` | `ts` | 心跳响应 |
| S→C | `peer_offline` | `id` | 某设备断线广播 |
| S→C | `error` | `code`, `message?` | 错误 |

## 错误码

| code | 含义 |
|---|---|
| `bad_json` | 帧不是合法 JSON |
| `bad_token` | `AUTH_TOKEN` 校验失败 |
| `not_registered` | 未注册就发业务消息 |
| `id_taken` | 设备 ID 已被在线占用 |
| `no_target` | 缺少 `to` 字段 |
| `target_offline` | 目标不在线 |
| `unknown_type` | 未知消息类型 |
| `rate_limited` | 同一调用方的 `connect` 超过 10 次/分钟（防口令爆破），`message` 给出建议等待秒数 |

## 会话建立时序

```
主控A                       信令                        被控B
  |-- register(id=A) ------->|                          |
  |<-- registered -----------|                          |
  |-- connect(to=B) -------->|-- incoming(from=A) ----->|
  |<-- connect_requested ----|                          |
  |                         |<-- accept(to=A) ---------|
  |<-- accepted(from=B) -----|                          |
  |-- offer(to=B, sdp) ----->|-- offer(from=A, sdp) --->|
  |<-- answer(from=B, sdp) --|<-- answer(to=A, sdp) ----|
  |-- ice(to=B) ------------>|-- ice(from=A) ---------->|
  |<======= WebRTC P2P / TURN 媒体与数据通道 =======>|
```

信令服务器只做**转发**，不解析 SDP，不接触媒体内容。媒体走后建立好的 WebRTC 通道（P2P 直连或经 coturn 中继），端到端由 WebRTC 的 DTLS-SRTP 加密。

## 无人值守（没人点确认的连接）

被控端可以打开无人值守：来电不再弹确认框，改为**比对口令后自动接受**。

```
主控A                            信令                      被控B（无人值守）
  |-- connect(to=B, password) --->|-- incoming({password}) -->|
  |                               |        B 比对本地口令       |
  |<-- accepted(from=B) ----------|<-- accept(to=A) ----------|   匹配
  |<-- rejected(from=B) ----------|<-- reject(to=A) ----------|   不匹配
```

| 约定 | 取值 | 原因 |
|---|---|---|
| 谁持有口令 | **只有被控端** | 服务端只转发、不保存也不校验，泄露面最小 |
| 口令长度下限 | 6 位 | 短于这个长度时拒绝开启无人值守 |
| 尝试限制 | 同一调用方 10 次/60 秒 | 自动接受意味着没有人能拦住第 N 次猜测，只能由服务端限速 |
| 口令传输 | 随 `connect` 明文走 WebSocket | 所以跨公网必须 `wss://` 或 Tailscale 这类私有网络，否则口令与画面一起裸奔 |

开了无人值守但没设口令时，被控端会**拒绝所有来电**而不是放行 —— 配置残缺时的默认值必须是"关"，不能是"开"。

## M1 实现约定（画面单向传输）

| 约定 | 取值 | 原因 |
|---|---|---|
| `sdp` 字段形态 | 对象 `{type, sdp}`，不是字符串 | 直接喂 `RTCSessionDescription`；服务端原样转发 |
| `candidate` 字段形态 | 对象 `{candidate, sdpMid, sdpMLineIndex}` | 同上，且 `sdpMLineIndex` 必须保留（0 不能被当成假值丢掉） |
| 谁发 offer | **主控端**，收到 `accepted` 之后 | 协商由主控驱动 |
| 谁先有画面 | 被控端在**发 `accept` 之前**完成采集 | 发完 accept 主控立刻发 offer，被控必须已有轨道才能一次协商成功 |
| 早期 ICE | 接收方在 `setRemoteDescription` 之前先缓存，之后按序 flush | `addCandidate` 早于 remote SDP 会抛错 |
| 单向性 | 只有被控端 `addTrack`，主控端 `offerToReceiveVideo: true` | M1 不做双向 |

时序（`accept` 之后才出现的采集延迟已被上面的"先采集后 accept"消除）：

```
被控B                         主控A
  |-- 采集屏幕（用户手势，含系统授权） 
  |-- accept(to=A) ----------->|
  |                            |-- offer(to=B) -->|
  |<-- offer(from=A) ----------|
  |-- answer(to=A) ----------->|
  |<======== 视频流 B -> A =========>|
```

## M2 输入通道

输入不走信令服务器，走 WebRTC 的 **DataChannel**，标签 `input`，可靠有序。

### 谁建通道

**主控端**在发 offer 之前 `createDataChannel('input')`，被控端通过
`onDataChannel` 收到。这样只需一轮协商；若在连线后再建，需要二次
renegotiation。

### 事件格式

JSON 文本帧，字段名压缩到 1~2 字符（指针移动最高 60 Hz，每字节都算钱）。

| `t` | 方向 | 字段 | 说明 |
|---|---|---|---|
| `hello` | 被控 → 主控 | `w`,`h` 屏幕物理像素；`s` DPI 缩放；`vw`,`vh` 视频尺寸 | 通道打开即发，分辨率变化时重发 |
| `move` | 主控 → 被控 | `x`,`y` ∈ [0,1] | 指针移动 |
| `btn` | 主控 → 被控 | `b` 按钮，`d` 按下/抬起，`x`,`y` | 0 左 1 中 2 右 |
| `wheel` | 主控 → 被控 | `dx`,`dy`，单位 `WHEEL_DELTA`=120 | 正数向上 |
| `key` | 主控 → 被控 | `k` 键 id，`d` 按下/抬起，`m` 修饰位，`r` 重复 | 见下表 |

修饰位：`shift=1, control=2, alt=4, meta=8`。

示例：

```json
{"t":"move","x":0.5123,"y":0.4408}
{"t":"btn","b":2,"d":true,"x":0.5123,"y":0.4408}
{"t":"key","k":19,"d":true,"m":2}
{"t":"hello","w":2560,"h":1440,"s":1.5,"vw":1920,"vh":1080}
```

### 三条必须遵守的约定

1. **坐标是"画面的比例"，不是像素。** 主控端可能带黑边显示（宽高比不符）、
   窗口尺寸任意、HiDPI；被控端分辨率不同、DPI 也不同。传比例让被控端只做
   一次乘以自己屏幕尺寸的换算，避免两边各自踩 DPI 的坑。

   主控端必须先算"画面实际占用的矩形"（`contain` 会留黑边），再把鼠标位置
   映射到该矩形内。按控件矩形算会朝中心偏移，越靠边越明显。

2. **键位传平台中立的 id，不传虚拟键码。** 主控常常是浏览器
   （`KeyboardEvent.code`），被控是原生 Windows（`VK_*`）。id 空间是两端唯一
   能对齐的东西。主控用 `PhysicalKeyboardKey.usbHidUsage` 取键——这是物理键位，
   不受输入法和键盘布局影响。

   id 分配见 `app/lib/src/input_event.dart` 的 `InputKey`，**只增不改**：
   旧客户端遇到不认识的 id 直接丢弃，而不是猜成别的键。

3. **通道未打开时的帧要排队，不能丢。** 主控在画面刚出来时就开始捕获输入，
   此时 SCTP 往往还没连好。丢弃会让"连上后第一次点击"变成空操作。

### 已知限制（不是 bug，是平台边界）

| 限制 | 原因 |
|---|---|
| 被控端窗口在前台时，注入打在它自己身上 | `SendInput` 注入的是前台窗口。被控端要最小化或切到别的窗口 |
| 对管理员权限的窗口点击无效 | Windows UIPI：低完整性进程不能向高完整性窗口注入 |
| `Ctrl+Alt+Del`、`Win+L` 送不到 | 这些由系统在更底层截获，非 UIPI 范畴 |
| 浏览器作被控端无法注入 | 网页没有操作系统输入权限，界面会明确提示不可用 |
| 多显示器坐标 | 归一化坐标映射到**整个虚拟桌面**，不是主显示器 |


