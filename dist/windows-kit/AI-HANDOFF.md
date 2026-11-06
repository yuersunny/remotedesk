# 交接给 AI 助手（Windows 端）

> 这份文档是给运行在 Windows 机器上的 AI 助手看的：读完它你应该能直接接手，
> 不需要再去猜架构和踩过的坑。

## 1. 这是什么

**RemoteDesk** —— 用户自研的跨平台远程桌面工具（Mac / Windows / 安卓同一套 Flutter 代码）。
目标是替代 ToDesk / 向日葵 / BilldDesk，**自用**，但架构按"任意公网穿透"设计。

- 技术栈：Flutter (Dart) UI + `flutter_webrtc` 传输 + Node.js 信令 + coturn（未部署）
- 当前里程碑：
  - **M1 已完成并验证**（被控端屏幕 → 主控端单向视频）
  - **M2 代码已完成，未在真机验证**（主控发鼠标键盘 → 被控端 `SendInput` 注入）
    —— 卡在 Windows 原生编译环境（见 §6），不是代码问题
- 上一个里程碑之后的下一步：断线重连 → 剪贴板 → 文件传输 → 密码鉴权 → TURN 部署

## 2. 目录与关键文件

```
src/remotedesk/
├─ app/lib/main.dart                  三卡控制面板 + 会话编排 + URL 参数
├─ app/lib/src/signaling_client.dart  WebSocket 信令客户端（事件流）
├─ app/lib/src/rtc_session.dart       RtcSession：offer/answer/ICE/轨道/统计/输入通道
├─ app/lib/src/screen_capture.dart    采集抽象（桌面枚举源 / web 交给浏览器）
├─ app/lib/src/session_view.dart      会话界面 + HUD + 主控端输入捕获
├─ app/lib/src/input_event.dart       M2 协议：事件模型/编解码/键位表/黑边换算（纯逻辑）
├─ app/lib/src/input_channel.dart     M2 传输：DataChannel 封装 + 未开通道时排队
├─ app/lib/src/input_injector.dart    M2 注入：Dart 侧分发 → 原生 method channel
├─ app/windows/runner/input_injector.cpp  M2 注入：Windows SendInput 实现
├─ app/test/widget_test.dart          7 个单测（原有）
├─ app/test/input_event_test.dart     28 个单测（M2：编解码/键位/黑边换算）
├─ server/src/server.js               信令服务器（注册/撮合/SDP·ICE 转发/心跳）
├─ server/test/handshake.test.js      5 个服务端测试
├─ server/scripts/m1-smoke.mjs        端到端自检（两个无头 Chrome）
├─ docs/protocol.md                   信令协议规范 + M2 输入通道规范
├─ docs/m1-smoke-test.md              M1 验证记录
└─ infra/                             coturn + docker-compose（待 VPS 部署）
```

## 3. 已验证到什么程度（别重复验证，除非改了相关代码）

| 项 | 结果 |
|---|---|
| `dart analyze`（M2 之后） | **No issues found** |
| `flutter test`（M2 之后） | **37/37 通过**（原 7 + 新增 30） |
| `npm test`（服务端） | 5/5 通过（含结构化 SDP / ICE 顺序转发） |
| `flutter build web --release`（M2 之后） | **成功**，产物已拷进 `web-preview/` |
| 端到端视频（两个独立 Chrome + 真实信令） | 通过，640×360 / ~20fps / 285–316 kbps / rtt 0–1ms（M1 回归） |
| **端到端控制通道（M2）** | **PASS**：`server/scripts/m2-smoke.mjs` 用 DevTools 协议打真实鼠标键盘事件 → 被控端收到 10 帧（移动 5、按键 2、按键/滚轮 3），`hello` 到达；连跑两次数字一致 |
| 键位表两端一致性 | `scripts/check-keymap.py`：Dart `InputKey` 与 C++ `VkForId` 的 83 个 wire id 完全一致 |
| **M2 真实注入（`SendInput`）** | **未验证** —— 卡在 Windows 原生编译（开发者模式 + VS 未装） |
| 注入自检 `pointerSelfTest`（两端） | 已实现并入包：Windows `input_injector.cpp` / macOS `InputInjector.swift`，同一个 `remotedesk/input` 方法、同一套返回字段（`moved` / `origin` / `after`） |
| macOS 原生构建 | 已通过（本机 Xcode 27.2 + 用户空间 CocoaPods），并已用自签名证书重签 |
| Windows 原生构建 | **未验证**（这是第一次真实编译，见 §6 的两个前置） |

"控制通道 PASS"的边界要说清：它证明的是**事件能正确跨过 DataChannel 并被解码**（含排队/补发、
黑边换算、键位映射），**不等于**光标真的动了 —— 注入是原生能力，两个浏览器都注入不了。
详见 `src/remotedesk/docs/m2-verification.md`。

ICE 默认带两个公共 STUN（Google / Cloudflare），可用 `?ice=none` 关掉（纯局域网更快），
`?ice=stun:host:port` 换自己的。这决定跨网络能否直连。

## 4. 三个必须知道的设计决定（都是踩坑后的结论）

1. **被控端先采集，再发 `accept`**。发完 accept 主控立刻发 offer，被控端必须已经有
   视频轨道才能一次协商成功。浏览器又要求 `getDisplayMedia` 必须在用户手势内调用，
   所以流程是"点『接受并共享屏幕』→ 当场采集 → 再 accept"。
2. **ICE 候选要缓存后按序 flush**。`setRemoteDescription` 之前调 `addCandidate` 会抛错，
   所以 `RtcSession` 把候选排队，`_flushCandidates()` 在远端描述落地后再放。
   注意 `sdpMLineIndex: 0` **不能被当成假值丢掉**（服务端测试专门锁了这条）。
3. **`close()` 必须 stop 本地轨道**，否则系统/浏览器的"正在共享屏幕"指示器不会消失。

## 4.1 M2 输入注入的五个设计决定

1. **坐标传"画面的比例"（0~1），不传像素。** 主控端可能带黑边显示（宽度比不
   符）、窗口尺寸任意、HiDPI；被控端分辨率和 DPI 又是另一套。传比例后，
   被控端只做一次乘自己屏幕尺寸的换算。

   **主控端必须先算出画面实际占用的矩形**——`RTCVideoView` 用 `contain`
   会留黑边，按控件矩形算会让点击朝中心偏移，越靠边越明显。这段换算抽成了
   `input_event.dart` 里的 `RemoteViewFit`，有 7 个单测锁着（含"画面角 vs
   控件角"这个最容易写错的点）。

2. **键位传平台中立 id，不传虚拟键码。** 主控常常是浏览器
   （`KeyboardEvent.code`），被控是原生 Windows（`VK_*`）。主控用
   `PhysicalKeyboardKey.usbHidUsage` 取键（物理键位，不受输入法/布局影响），
   映射成 `InputKey` 的稳定 id 传过去。**id 只增不改**——旧端遇到不认识的
   id 直接丢弃，不猜。

   `input_event.dart` 的 `InputKey` 和 `input_injector.cpp` 的 `VkForId`
   必须同步改；单测 `every wire id is unique` / `every HID usage is unique`
   能挡住手滑重复。

3. **通道没打开时事件要排队，不能丢。** 主控在画面刚出来时就开始捕获输入，
   这时 SCTP 往往还没连好。丢弃会让"连上后第一次点击"变成空操作。
   `InputChannel` 用一个上界 120 的队列兜住，open 后按序补发。

4. **失焦时必须主动释放所有按下的键。** 不然被控端会留下"粘住的 Ctrl"，
   之后每个键都变成 Ctrl+X，用户完全不知道为什么。`SessionView._releaseAll()`
   在 `onFocusChange(false)`、`onPointerCancel`、`dispose` 三处调用，
   并且记住按下的按钮顺序——因为 pointer-up 的 bitmask 已经清掉了那个按钮，
   光看 mask 分不出是右键还是左键抬起（会把远程右键菜单拖住不放）。

5. **两端都要有"一键证明注入真的能工作"的自检。** 注入失败在各平台都是
   **静默**的：Windows 上 `SendInput` 被 UIPI 丢掉、macOS 上没有辅助功能权限，
   表现都只是"鼠标不动"，和网络问题长得一模一样。所以通道里有 `pointerSelfTest`：
   通过**真实注入路径**把光标移 3 px、读回坐标、再复位，返回 `moved`。

   - 不要用 `SetCursorPos` 实现自检：它绕过注入路径，注入被拦时也会"成功"，
     那这个自检就成了摆设。
   - 中文文案留在 Dart 侧，C++ 只回事实：MSVC 按系统代码页编译窄字符串，
     中文写进 `.cpp` 会变乱码。

### 4.2 一个"上线即废"的坑（已修，别再犯）

`PhysicalKeyboardKey.usbHidUsage` 返回的是**带页号的完整 32 位码**：KeyA = `0x00070004`。
而 `InputKey` 表里存的是低字节 `0x04`。第一版直接查表 → 一律 miss → 远端**一个键都收不到**，
而日志干干净净（指针走另一条路，现象是"鼠标能动、键盘全哑"）。

修法：先判页号（`usage >> 16 == 0x07`）再取低位；**别的页号直接拒绝**，不要掩码，
否则 consumer page 的 `0x000C00E1` 会伪装成 Shift。两个单测锁住。

## 5. 怎么在本机复现验证

```powershell
# 服务端测试（用内置 node 或系统 node 都行）
cd src\remotedesk\server
node --test

# Flutter 侧（需先装 Flutter，见 §6）
cd src\remotedesk\app

# 关键：先清掉代理，否则 flutter_tester 的 WebSocket 会被本地代理劫持
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''

flutter analyze      # 或 dart analyze（后者不受 symlink 影响，环境没配好时更好用）
flutter test         # 37 个
```

键位表一致性（改了 `InputKey` 或 `VkForId` 必跑）：

```
python src\remotedesk\scripts\check-keymap.py
```

端到端自检脚本 `server\scripts\m1-smoke.mjs` 是给 macOS/Linux 写的，
它靠无头 Chrome + CDP 驱动。**在 Windows 上跑它需要改路径里的 Chrome 位置**
（`C:\Program Files\Google\Chrome\Application\chrome.exe`）以及
`--user-data-dir` 的临时目录写法；不强求，手工双窗口测更省事。

## 6. 环境现状与已知阻塞（2026-11-05 本机实测）

### 已解决

- **Flutter 3.47.9 / Dart 3.13.7 已装**：`C:\Users\yushu\flutter`（3.3 GB）。
  **没有写进系统 PATH**，脚本会自动去 `%USERPROFILE%\flutter` 找。
  要在临时窗口用，先执行：
  ```powershell
  $env:PATH = "C:\Users\yushu\flutter\bin\mingit\cmd;C:\Users\yushu\flutter\bin;" + $env:PATH
  ```
  （`mingit\cmd` 必须带上：`dart.bat` 内部要调 `git` 判断 engine 版本，
  没有 git 就报 `Unable to determine engine version`。）

### 两个硬阻塞（都必须在那台 Windows 上做，AI 无法代劳）

1. **开发者模式未开** → `flutter pub get` / `build windows` 直接失败：
   `Building with plugins requires symlink support.`
   - **现在双击 `01b-enable-dev-mode.cmd` 就行**：自动提权写注册表，点一次 UAC，不用重启
   - 手动：设置 → 隐私和安全性 → 开发者选项 → 开发人员模式；或 `start ms-settings:developers`
   - **这不是网络或依赖问题**，别去折腾 pub 镜像。

2. **VS 2022 Build Tools 未装** → 没有 C++ 工具链，编译不了原生版。
   - 跑 `03-install-vs-buildtools.cmd`（需点 UAC，4~7 GB）
   - 当前会话是非管理员，无法静默安装。

### 本机踩过的三个坑（会重复出现的）

| 症状 | 真实原因 | 处理 |
|---|---|---|
| `flutter test` 报 `Unable to connect to flutter_tester process: Invalid WebSocket upgrade request` | 系统代理是 `127.0.0.1:<port>`，**把本地回环也劫持了**，测试控制台的 WebSocket 走了代理 | 跑测试前 `$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''`（只影响当前进程）。端口每次会变，`env \| grep -i proxy` 查当前值 |
| `curl` 下载报 `CRYPT_E_REVOCATION_OFFLINE` | Windows schannel 吊销检查服务器连不上 | 加 `--ssl-no-revoke` |
| `02-install-flutter.cmd` 下载一秒就退出 | 脚本 `$ErrorActionPreference='Stop'`，而 `curl` 的进度条走 stderr，被 PowerShell 当成致命错误 | 已在脚本里改成 `2>&1 \| Out-Null`（本次已修） |

- **macOS 机器上没有完整 Xcode**（只有 Command Line Tools），磁盘也只剩约 10 GB，
  所以 `flutter build macos` 直接报 `Xcode not installed`。mac 端目前只能用网页版。
- 磁盘：C: 剩余 235 GB，够用。
- 网络：Flutter 下载走国内镜像 `https://storage.flutter-io.cn`（比官方源快两个数量级）。
  本机有代理时走代理更快（实测 12 MB/s vs 9 MB/s）。

## 7. 下一步该做什么（按优先级）

1. **补齐 Windows 原生编译环境**（`01b` + `03`，见 §6），然后
   `04-build-windows.cmd` → `05-run-windows-app.cmd`。
   **这一步是这套 C++ 的第一次真实编译，报错概率不低**，把报错原样贴回来最快。
2. **真机验证 M2 注入**。两台机器上跑，一台当被控（原生 Windows），一台当主控。
   通道链路已经用 `m2-smoke.mjs` 证明过了，所以这里只需要验"手上的动作"：
   - [ ] 鼠标移动位置准（尤其画面边缘，验证黑边换算）
   - [ ] 左键/右键/中键、拖拽、滚轮方向
   - [ ] 键盘字母/数字/修饰键组合（Ctrl+C、Shift+方向键选字）
   - [ ] 从主控窗口切走再切回，远端不残留按下的键
   - [ ] 多显示器时坐标是否落到正确的屏
3. **macOS / 安卓作为被控端**（目前都只能当主控）：
   - macOS 需要 `CGEvent` 注入 + 辅助功能授权，且必须在有 Xcode 的机器上编译验证；
   - 安卓需要 `AccessibilityService.dispatchGesture`（点/滑可以，键盘要额外做 IME 注入）。
4. M1 遗留但没做的：**断线重连**、剪贴板、文件传输、密码鉴权、TURN 部署。

已知的平台边界（不是 bug，别去修）：被控端窗口在前台时注入打在它自己身上；
对管理员权限窗口注入无效（UIPI）；`Ctrl+Alt+Del` / `Win+L` 送不到。
详见 `docs/protocol.md` 的「已知限制」。

## 8. 沟通约定

- 用中文；结论优先、给证据（命令输出 / 日志行），不要只说"应该可以"。
- 改动后要回源验证（`flutter analyze` + `flutter test` 至少跑一遍）。
- 用户偏好可直接执行的脚本（双击即用），而不是让他手敲命令。
