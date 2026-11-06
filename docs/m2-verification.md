# M2 验证记录（输入注入 / 远程控制）

日期：2026-11-05 · 机器：macOS（无 Xcode）· 分支：本地工作区

结论先说：**通道链路已端到端验证；Windows 端的真实注入还没跑过**，卡在 Windows 那台
机器的两个前置（开发者模式、VS C++ 工具链），不是代码问题。下面每条都带证据。

## 1. 已验证（可以当事实用）

| 项 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | No issues found |
| 单元测试 | `flutter test` | **37/37 通过**（M1 的 7 个 + M2 新增 30 个） |
| web 构建 | `flutter build web --release` | 成功，40 MB |
| 键位表交叉校验 | `python3 scripts/check-keymap.py` | 83 个 wire id 与 C++ `VkForId` 完全一致 |
| M1 回归（视频） | `node scripts/m1-smoke.mjs` | 640×360 / 20 fps / 309 kbps / rtt 0 ms |
| **M2 通道（本记录重点）** | `node scripts/m2-smoke.mjs` | **PASS：收到 10 帧（移动 5、按键 2、按键/滚轮 3），`hello` 已到达** |

`m2-smoke.mjs` 做的事情：起两个**互相独立的 Chrome**，一个当被控、一个当主控，走真实信令
真实 WebRTC；主控侧用 DevTools 协议 `Input.dispatchMouseEvent` / `dispatchKeyEvent` 打真实
浏览器事件（不是 Dart 后门），然后从被控端的自检标题里读回计数。连跑两次数值完全一致。

因此下面这些路径是**被证明能工作**的：

1. 主控发 offer 前建 `input` DataChannel，被控通过 `onDataChannel` 收到 —— 单轮协商，无二次 renegotiation；
2. 指针移动 / 按键按下抬起 / 滚轮 / 键位事件，编码 → SCTP → 解码全链路；
3. 通道未 open 时的排队与 flush（首帧点击不会丢）；
4. 被控端 `hello` 上报桌面几何，主控 HUD 拿到；
5. 主控端黑边换算：`RemoteViewFit` 只把落在画面内的移动发出去（落在黑边上会被丢弃），
   7 个单测锁着 corner/centre/clamp 三个最容易错的点。

## 2. 过程中发现并修掉的真问题

### 2.1 键位全部丢失（HID 页号，差点上线即废）

第一版 `InputKey.fromHidUsage` 直接拿 `PhysicalKeyboardKey.usbHidUsage` 查表，而表里存的是
`0x04` 这种**低字节**。实测打点：

```
controller key event: hid458756  id97  物理名 null
458756 = 0x00070004        ← Flutter 报的是带页号的完整 32 位码
```

于是查表必然 miss，`_onKeyEvent` 一律 `ignored`：**远端一个键都收不到，而日志里毫无异常**
（指针是另走一条路的，所以用户会看到"鼠标能动、键盘全哑"这种极难定位的现象）。

修法：先判页号再取低位，且**别的页号直接拒绝**而不是掩码 —— 否则 consumer page 的
`0x000C00E1` 会伪装成 Shift。加了两个单测锁住（`0x00070004 → keyA`、`0x000C00E1 → null`）。

### 2.2 取不到视频尺寸就不发 `hello`

`sendHello()` 原本在 `getSettings()` 拿不到宽高时直接 `return`，于是主控端永远收不到几何信息、
HUD 空着、也无法判断对端是否可注入。改成退回已知的屏幕尺寸再发（视频尺寸允许为 0）。

### 2.3 黑边上的指针把远端光标顶到边上

`Listener.onPointerHover` 在整个控件矩形上都触发，包含 `contain` 留出的黑边。原来用 clamp
兜住，结果本地窗口比画面宽时，鼠标一移进黑边远端光标就贴到屏幕最右/最下。改成：黑边上
**不发送**；但按住按键拖拽时继续发（拖出画面应该贴边，而不是卡住）。

### 2.4 `check-env.ps1` 里一行被注释吞掉（回传包带进来的）

回传的 `tools/check-env.ps1` 第 77 行长这样：

```powershell
# ---------- 3. Visual Studio C++ 工具链 ----------$vsWhere = "...\vswhere.exe"
```

赋值整行变成注释 → `$vsWhere` 恒为 `$null` → 环境自检**永远报没装 VS**，误导性极强
（正是我在自己的记忆里记过的"编辑吞换行"那一类）。已拆回两行，并保留原文件的 UTF-8 BOM。

### 2.5 C++ `result->Success()` 显式传值

`Success()` 的无参重载在不同 Flutter 版本里存在与否不一致，改成
`Success(flutter::EncodableValue())`，两边都能编译。这类"本机编译不了、只能靠保守写法"的地方
都是这么处理的。

## 3. 没验证的（别当成能用）

| 项 | 状态 | 原因 / 下一步 |
|---|---|---|
| **Windows 被控端真实注入**（`SendInput`） | **未验证** | Win 机器缺开发者模式 + VS C++ 工具链；包内已加 `01b-enable-dev-mode.cmd`（自动提权）与 `04-install-vs-buildtools.cmd` |
| Windows 原生编译本身 | **未验证** | 同上。这是这套 C++ 的**第一次真实编译**，很可能要修编译错误 |
| macOS 作为被控端 | **已实现，待授权验证** | `CGEvent` 注入器已写好并编译进包（§6）；本机差一个「辅助功能」勾选才能真机点一遍 |
| Android 作为被控端 | **不可用** | 需要 `AccessibilityService.dispatchGesture`，未开始 |
| 拖拽 / 双击 / 三击的语义 | 未验证 | 事件层面已通，但行为要真机点一遍 |
| 多显示器坐标 | 未验证 | C++ 走 `MOUSEEVENTF_VIRTUALDESK`，逻辑对，需真机多屏确认 |

## 4. Windows 上要怎么验（ Checklist ）

先解决两个前置（各一次，之后不用再做）：

1. `01b-enable-dev-mode.cmd` —— 自动提权写注册表，弹一次 UAC；
2. `03-install-vs-buildtools.cmd` —— 装 VS 2022 Build Tools + C++ 组件（4~7 GB，要 UAC）。

然后：

3. `04-build-windows.cmd` —— **第一次真实编译**，报错请原样贴回来（这一步最容易出问题）；
4. `05-run-windows-app.cmd` 出画面；
5. 两台机器（或同一台开两个实例，一个控一个被控）按下表逐项点：

- [ ] 鼠标位置准，尤其画面四个角（验黑边换算）
- [ ] 左键 / 右键 / 中键、拖拽、滚轮方向
- [ ] 字母、数字、`Ctrl+C`、`Shift+方向键`（验修饰键与扩展键位）
- [ ] 从主控窗口切走再切回，远端不残留按下的键
- [ ] 多显示器时坐标落到正确的屏

已知平台边界（不是 bug）：被控端窗口在前台时注入打在它自己身上；对管理员权限窗口无效（UIPI）；
`Ctrl+Alt+Del`、`Win+L` 送不到。

## 5. 复现命令

```bash
# 单测 + 分析
cd app && flutter analyze && flutter test

# 键位表两端一致性
python3 scripts/check-keymap.py

# 端到端（先起信令 8787 + 静态 8080）
cd app/build/web && python3 -m http.server 8080 &
cd server && node index.js &
cd server && node scripts/m1-smoke.mjs   # 画面
cd server && node scripts/m2-smoke.mjs   # 控制通道
```

本机代理会劫持 127.0.0.1，跑测试/自检前清掉 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`。
症状是 `Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`
——看起来像代码坏了，其实是代理剥掉了 `Connection: Upgrade` / `Upgrade: websocket` 两个逐跳头。
清法：

```bash
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
export NO_PROXY="127.0.0.1,localhost"
```

## 6. macOS 被控端（2026-11-06 增补）

Xcode 装好后补齐了唯一缺的一块：`app/macos/Runner/InputInjector.swift`。
和 Windows 那份是同一个 `remotedesk/input` 通道、同一套归一化坐标、同一套 83 个 wire id。

| 项 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | **37/37 通过**（清代理后） |
| `check-keymap.py` | **83 个 wire id 三端一致**（Windows 35 显式 VK + 48 区间，macOS 83 条 keyCodes） |
| `flutter build macos --debug` | 成功，`remotedesk.app` 127 MB / arm64 / adhoc |
| 产物自检 | `MacInputInjector.*` 符号、`remotedesk/input` 通道名、ApplicationServices + CoreGraphics 链接均在 |
| 沙盒 | **已摘除**（签名后可读 entitlements 只剩 jit / get-task-allow / network） |
| 真机注入 | **待授权验证**（见 §6.3） |

### 6.1 为什么必须去掉 App Sandbox

沙盒里的 App **不允许** `CGEventPost` 到别的 App —— 调用会静默返回，什么都不发生。
这是 `DebugProfile.entitlements` 与 `Release.entitlements` 里删掉 `com.apple.security.app-sandbox`
的唯一原因，代价是失去 Mac App Store 分发资格（本项目不走商店）。网络权限两项保留。

### 6.2 实现上四个容易踩的点

1. **坐标空间不是 AppKit 的**。`CGEvent` 用的是 Quartz 全局坐标，原点在主屏**左上**、y 向下；
   `NSScreen.frame` 是左下原点。多屏时联合矩形可能带负坐标，所以取所有活动屏 `CGDisplayBounds` 的并集。
2. **修饰键靠事件标志位传，不靠事件流**。先发一个 Shift 的 keyDown 并不会让之后的合成 `a`
   变成 `A`；每个事件都要带上 `flags`。左右修饰键额外带 `NX_DEVICEL*KEYMASK`
   设备位，否则右 Option 打不出右 Option 的字符。
3. **拖拽是另一个事件类型**。按住键时移动要发 `leftMouseDragged` 等，发 `mouseMoved`
   会让框选和拖窗口变成"只动不拖"。
4. **双击要显式声明 `clickState=2`**。两次独立单击在 AppKit 眼里就是两次单击，
   "双击打开文件"会变成两次重命名。

### 6.3 真机验证只剩一步

被控端第一次要授权：**系统设置 › 隐私与安全性 › 辅助功能** 勾上 `remotedesk`。

App 里做了两个入口，不用记路径：

- 状态行显示「输入注入不可用」时点 **去授权** → 弹系统授权窗；
- 授权后点 **测试注入**（或等它自己跑，见下）→ 注入器把光标挪 3 pt 再复位，
  并读回真实坐标。日志里出现 **「注入自检通过：光标动了（本机已可被远程控制）」**
  才代表这台机器真能被控。
- **不用重启**：`InputInjector` 空闲时每 15 秒复检一次；一旦从"不可用"翻成
  "可用"，它会**自动跑一次自检**并在日志里写明，不必等人点按钮。
- 例外：**签名变了之后必须重启 + 重新授权一次**，见 6.5。

顺带修掉一个真 bug：模板窗口默认 800×600，比这一页短，Flutter 直接报
`BOTTOM OVERFLOWED BY 261 PIXELS`，把注入状态行和日志整块挤到可视区外——
也就是说**没有这个修复，上面两个按钮根本点不到**。现在窄窗口改成整页可滚动，
默认窗口放到 1180×840。

> 这一步的价值：`CGEventPost` 在没权限时**不报错、只沉默**。不点这个按钮，
> 「连上了但鼠标不动」会被误判成网络问题。

真机逐项点一遍（和 Windows 那张表同一套）。

**不用凭手感**：注入器每约 5 秒往同一个日志写一行审计，哪怕只点一下也会落盘
（定时器兜底，不会因为"之后没人再操作"而丢）：

```
audit ptr=312 drag=48 norm=0.000,0.002..0.999,0.997 at=3007,1691
      btn=[L 4/4 M 1/1 R 2/2] click=3 wheel=9 dy=-360..360
      key=8 seq=116d 3d 3u 116u flags=0x100040
```

字段和清单是一一对应的：

| 字段 | 判定什么 |
|---|---|
| `norm=a,b..c,d` | 归一化坐标实际到达的范围。手从一头划到另一头应接近 `0.000,0.000..1.000,1.000`；只到 `0.6x` 就是主控端换算错了，不是注入的事 |
| `at=x,y` | 最后一次落点的全局坐标，应落在启动那行 `geometry union=…` 的矩形内 |
| `btn=[L a/b M c/d R e/f]` | 左/中/右各按下 a 次、抬起 b 次。缺项就是那个键没送到 |
| `drag=` | 按住时移动的次数。按着拖却一直 0 → 事件发成了 `mouseMoved`，框选和拖窗口会失效 |
| `click=` | 见过的最大 `clickState`。双击要到 2、三击到 3；一直 1 就是没声明 |
| `wheel=… dy=a..b` | 滚轮次数与位移区间。上下各滚一次，区间必须跨正负 |
| `key=… seq=…` | 键的 wire id 与方向（`d` 按下 / `u` 抬起）。**只记 id 与方向，不记字符** |
| `flags=0x…` | 所有事件标志位的并集。`0x100000` = maskCommand（`Cmd+C` 看这个），`0x40` = NX_DEVICERALTKEYMASK（右 Option 看这个） |

清单同序对照：

- [ ] 鼠标位置准，尤其四角 → 看 `norm` 是否到底、`at` 是否在 `geometry` 矩形内
- [ ] 左/中/右键 → 看 `btn` 三项都有数
- [ ] 拖拽（含跨窗口拖选）→ 看 `drag` 涨不涨
- [ ] 滚轮方向 → 看 `dy` 区间是否跨正负
- [ ] 字母/数字、`Cmd+C`、`Shift+方向键`、右 Option → 看 `seq` 与 `flags` 的两个位
- [ ] 双击打开文件、三击选中整行 → 看 `click` 到 2 / 3
- [ ] 切走再切回不残留按键 → `seq` 里每个 `d` 都有配对的 `u`
- [ ] 多屏落点 → 看启动行 `geometry displays=N union=…`，多屏时 union 会带负坐标或更宽

审计只写 wire id、方向与标志位，不写任何字符，所以这台机器的日志不构成键盘记录。

已知平台边界（不是 bug）：被控端窗口在前台时注入打在它自己身上；
`Cmd+Tab` 之后焦点在别的 App，事件会到那个 App（这是对的）；
系统级安全输入框（如登录窗、1Password 解锁）会拒收合成事件。

### 6.4 调试入口

```bash
# 看原生侧是否真的被调到（zsh 里 log 是内建 watch 模块，必须写绝对路径）
/usr/bin/log stream --predicate 'process == "remotedesk"' --style compact

# 更直接：从终端起二进制，stdout 直接能看
./app/build/macos/Build/Products/Debug/remotedesk.app/Contents/MacOS/remotedesk
```

注册时会打 `input channel registered (trusted=0|1)`，自检时会打 origin/after 坐标。


### 6.5 签名 → 授权为什么会互相坑（本机真实踩坑）

现象：在系统设置里勾了 `remotedesk`，开关显示"已开"，但 App 一直报「输入注入不可用」，
`AXIsProcessTrusted()` 返回 `false`。

根因在**指定要求（Designated Requirement）**：

```bash
$ codesign -d -r- remotedesk.app
# designated => cdhash H"45827d28..."        ← adhoc 签名
```

adhoc 签名的 DR 是**二进制哈希**。`flutter build` 每次重编译都会换 cdhash，
而 TCC 里那条授权记录仍指向旧哈希：列表里留着、显示已开、对新二进制无效。
更坑的是它**不报错**，看起来完全像"授权没保存"。

解法：给本机配一张**自签名代码签名证书**，DR 就变成证书指纹，重建不再失效。

```bash
./scripts/mac-sign.sh debug     # 首次会自动建证书 + 钥匙串，之后只做重签
# ==> 指定要求：identifier "com.remotedesk.remotedesk" and certificate root = H"1f6e556e..."
# ==> OK：指定要求绑在证书上，重建后授权不会失效
```

- 证书与钥匙串：`~/Library/Keychains/remotedesk-dev.keychain-db`，身份名 `RemoteDesk Dev`
- `scripts/build-macos.sh` 已经接了这一步，正常构建不用手工跑
- 换证书（删了钥匙串重来）会**再次**让授权失效——证书指纹变了

**换签名后的一次性动作**（只做一次）：系统设置里把 `remotedesk`
**关掉再打开**。不是重新勾选一个已勾的框——只有关→开才会把授权行重写成当前签名。

验证是否真的换过来了：

```bash
codesign -d -r- app/build/macos/Build/Products/Debug/remotedesk.app
# 出现 cdhash  → 还在坑里
# 出现 certificate root → 已出坑
```

顺带一个环境坑：`tccutil reset Accessibility <bundleid>` 在沙箱终端里会被拒
（`Operation not permitted from sandbox`），所以清理旧授权行只能在界面里做。

#### 6.5.1 别信终端里的 `AXIsProcessTrusted()`（差一步就误报通过）

在终端直接跑 `remotedesk.app/Contents/MacOS/remotedesk`，日志会打印
`trusted=1` 且自检 `moved=1`；但同一个二进制用 `open` 启动时是 `trusted=0`。

原因：TCC 把权限检查算在**责任进程（responsible process）**头上。从终端起的进程，
责任方是**终端**——终端自己早就授权过了，于是子进程"看起来"有权限，
`CGEventPost` 也确实能落下去。这个绿灯是假的，它证明的是终端有权限。

判据只有一个：**用 `open` 起 .app，看它自己写的日志**。

```bash
rm -f ~/Library/Logs/RemoteDesk/input.log
open app/build/macos/Build/Products/Debug/remotedesk.app
sleep 5
cat ~/Library/Logs/RemoteDesk/input.log
# input channel registered (trusted=1, bundle=..., pid=...)   ← 这才算数
```

为什么要单独写文件：`NSLog` 在窗口化 app 里既进不了 `log show`
（`log show --predicate 'process == "remotedesk"'` 返回 0 行，沙箱下读不到统一日志），
也拿不到 stderr（`open --stdout` 抓不到 NSLog）。不落盘的话，
"授权到底生效没有"就只能靠看界面，而这恰恰是最不可靠的那个来源。

授权生效后 ≤15 秒，日志里会出现 `self-test ... moved=1` —— 那是
`_startWatching()` 复检到状态翻转后自动跑的，不用手点按钮。
