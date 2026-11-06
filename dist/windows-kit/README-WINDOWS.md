# RemoteDesk · Windows 端使用说明

> 这个包现在是 **M2 阶段**：画面传输（M1）之外，**主控端可以操作被控端的鼠标键盘**。
>
> - **主控端**可以是被控端的网页版、也可以是原生版——发输入只需要捕获本地事件。
> - **被控端必须是原生版**（Windows exe 或 macOS app）：浏览器没有系统输入权限，
>   网页被控端只能共享画面，界面上会明确写"输入注入不可用"。
>
> 所以想真正"远程操作"，需要先把原生版编译出来（路径 B）。

---

## 1. 包内容

```
windows-kit/
├─ 00-RUN-WEB-NOW.cmd          ← 零安装启动（信令 + 网页 + 浏览器）
├─ 01-check-env.cmd            环境体检
├─ 01b-enable-dev-mode.cmd     一键开「开发者模式」（自动提权，pub get 的前置）
├─ 02-install-flutter.cmd      装 Flutter SDK
├─ 03-install-vs-buildtools.cmd 装 VS C++ 工具链
├─ 04-build-windows.cmd        编译原生 exe
├─ 05-run-windows-app.cmd      启动原生 exe
├─ start-signaling.cmd         只起信令服务（前台，便于看日志）
├─ node/node.exe               内置 Node 22（免安装，网页版靠它）
├─ web-preview/                已编译好的网页版（Flutter web release）
├─ src/remotedesk/             完整源码
│   ├─ app/                    Flutter 工程（android / macos / windows / web）
│   └─ server/                 信令服务器（已带 node_modules/ws，离线可跑）
└─ tools/                      脚本与静态服务器
```

`src/remotedesk/` 就是 Mac 上那份工程的完整副本，两端代码完全一致。

---

## 2. 路径 A：网页版（推荐先用这个验证）

### 2.1 启动

双击 `00-RUN-WEB-NOW.cmd`，会：

1. 起信令服务 `ws://0.0.0.0:8787/ws`（另开一个窗口）
2. 起网页服务 `http://localhost:8080/`（另开一个窗口）
3. 打印本机局域网 IP，然后打开 Chrome 到 `http://localhost:8080/?id=win-pc`

那两个新开的黑窗口**就是服务本身**，关掉即停止。

### 2.2 用它做什么

- 「信令服务器」填 `ws://127.0.0.1:8787/ws` → 点「连接」
- 日志出现「注册成功，设备ID: win-pc」就通了
- 同一台机器想试完整链路：再开一个 Chrome 标签，访问
  `http://localhost:8080/?id=win-pc2`（**必须换 ID**，同域名共享 localStorage，
  不换会报 `id_taken`），然后两边互呼。

### 2.3 换 URL 参数

| 参数 | 作用 |
|---|---|
| `?id=win-pc` | 指定设备 ID（多标签/多机测试用） |
| `?server=ws://192.168.1.10:8787/ws` | 预填信令地址 |
| `?peer=mac` | 预填目标设备 ID |
| `?ice=none` | 关掉 STUN（纯局域网、且网络受限时更快） |
| `?ice=stun:your.host:3478` | 指定自己的 STUN |

默认已带两个公共 STUN（Google / Cloudflare），所以**跨网络也能尝试直连**。

---

## 3. 路径 B：原生 Windows 桌面版

按 `START-HERE.md` 的表格顺序执行 01 → 02 → 03 → 04 → 05。

### 3.1 编译前必须先开「开发者模式」

**这是最容易卡住的一步，而且报错信息会误导人。**

Flutter 在 Windows 上要给插件建符号链接。没开开发者模式时，
`flutter pub get` 会以这句结束：

```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```

看着像依赖问题或网络问题，其实是系统权限。**开法**：

- 双击 `01b-enable-dev-mode.cmd` —— 自动提权写注册表，点一次 UAC 的「是」即可，不用重启
- 或者：设置 → 隐私和安全性 → 开发者选项 → 「开发人员模式」打开
- 或者：`start ms-settings:developers`

开完不用重启，直接重跑 `04-build-windows.cmd`。
`01b` / `01` / `04` 都会检查这一项，缺了会直接用中文告诉你，不用等 pub get 报错。

### 3.2 原生版与网页版的差别

| | 网页版 | 原生版 |
|---|---|---|
| 屏幕采集 | 浏览器弹窗选源 | `RTCDesktopCapturer`，可「枚举采集源」后指定 |
| 屏幕采集授权 | Chrome 每次询问 | 无系统授权弹窗（Windows 特性） |
| 启动速度 | 打开浏览器 | 双击即开 |
| **能当被控端被远程操作** | ❌ 不能（浏览器无输入权限） | ✅ 可以 |
| 依赖 | 无 | Flutter + VS C++ 工具链 + 开发者模式 |

**如果原生版点「接受并共享屏幕」后没画面**：先点「枚举采集源」，在下拉里选一个
具体屏幕再接受——部分 Windows 环境下不指定 `deviceId` 会拿不到流。

### 3.3 M2 怎么操作远端

1. 被控机启动原生版，连接信令，记下设备 ID（例如 `win-pc`）
2. 主控机（网页或原生都行）连接同一个信令，填目标 ID，点「呼叫」
3. 被控机点「接受并共享屏幕」
4. 主控端画面出来后：
   - 顶栏有个「**控制中 / 只看不控**」的圆角标签，点一下可随时暂停控制
   - **点一下画面**让输入框获得焦点，之后鼠标移动和键盘就直接作用到远端
   - 画面底部会提示「点击画面后可直接操作远端」

**被控机要把窗口最小化或切到别的窗口**——`SendInput` 注入的是前台窗口，
被控端窗口自己在前面的话，你操作的就是它自己的界面。

#### 被控机先做一次「注入自检」

被控机左下角那行状态是这台机器能不能被操作的唯一结论：

```
输入注入就绪 · 虚拟桌面 2560×1440        [测试注入]
```

点「测试注入」→ 注入器通过 `SendInput` 把光标右移 3 px、读回真实坐标、再复位。
日志出现 **「注入自检通过：光标动了（本机已可被远程控制）」** 才代表链路通。

为什么必须点这一下：**Windows 上注入失败是静默的**（UIPI、安全桌面、权限不足都只是
"没反应"），点一次能把"注入坏了"和"网络坏了"分开。macOS 那边同理，只是它多一道
「辅助功能」授权。

Windows 不需要任何系统授权——这是它比 macOS 省事的地方，也正因为如此，
没有自检就完全没有可观察的信号。

关于权限：**对"以管理员身份运行"的窗口点击无效**，这是 Windows 的 UIPI 保护，
不是 bug。`Ctrl+Alt+Del`、`Win+L` 也送不到（系统在更底层截获）。

---

## 4. Mac ↔ Windows 互连（完整步骤）

### 4.1 谁能连谁

两台都在**同一个局域网**（同一个路由器下）时，WebRTC 会用局域网直连，无需中继。
不在同一网络时会走 STUN 打洞；打洞失败（对称 NAT）时需要 TURN 中继，
那一步的部署文件在 `src/remotedesk/infra/`（coturn + docker-compose），
但**目前还没有 VPS 部署**，所以跨公网仅在有 STUN 直连条件时可用。

### 4.2 步骤

**Windows 侧（作为服务器）**

1. 双击 `00-RUN-WEB-NOW.cmd`
2. 记下窗口里打印的：`This machine LAN IP : 192.168.x.x`
3. 浏览器会打开 `http://localhost:8080/?id=win-pc`
4. 防火墙弹窗 → 选「允许访问」（专用网络）

**Mac 侧**

```bash
cd ~/WorkBuddy/2026-11-05-13-26-18/remotedesk

# 起网页服务（三选一）
cd app/build/web && python3 -m http.server 8080 --bind 127.0.0.1
# 或者：python3 -m http.server 8080 --bind 127.0.0.1 -d app/build/web
```

然后 Chrome 打开 `http://localhost:8080/?id=mac`：

1. 「信令服务器」填 `ws://<Windows 的 IP>:8787/ws` → 连接
2. 「目标设备ID」填 `win-pc` → 呼叫
3. Windows 端弹「收到远程协助请求」→ 点「接受并共享屏幕」→ 选屏幕
4. Mac 端出现画面，底部 HUD 显示分辨率 / 帧率 / 码率 / 延迟

**或者反过来**：Mac 起信令（`cd server && node index.js`），
Windows 的信令栏填 `ws://<Mac 的 IP>:8787/ws`。
注意 Mac 若只 `--bind 127.0.0.1` 起网页服务，**信令服务仍要监听 0.0.0.0**（默认就是）。

### 4.3 为什么必须用 localhost 打开网页

Chromium 只允许"安全来源"使用 `getDisplayMedia`：

- `http://localhost` ✅ 视为安全
- `http://192.168.x.x` ❌ 不是安全来源，采集直接失败

所以：**页面各在自己机器上以 localhost 打开，只有信令和数据走 IP。**
画面/数据本身是 WebRTC 的 P2P 通道，跟页面来源无关，所以这样完全可行。

---

## 5. Windows 特有问题

| 现象 | 原因 / 处理 |
|---|---|
| 另一台连不上 8787 | 防火墙拦了。`控制面板 → Windows Defender 防火墙 → 允许应用通过防火墙`，给 `node.exe` 勾上「专用」；或临时关闭 |
| Chrome 提示"你的连接不是私密连接" | 无，localhost 不会；若你改成 IP 访问，就会因非安全来源而采集失败 |
| 4K 屏画面模糊 | M1 采集上限默认 1080p，网页里「采集设置 → 上限分辨率」可调到 4K |
| 多屏只传一个 | 网页版在浏览器弹窗里选屏幕；原生版用「枚举采集源」选 |
| 码率只有 ~300 kbps | WebRTC 起步带宽探测，会逐步爬升；静止画面码率本来就低 |
| 关掉黑窗口后网页还在 | 那个窗口只是服务，网页已加载的 JS 还在跑，但信令会断 |

---

## 6. 已知限制

M2 做完了，但下面这些还在：

- ❌ 无音频
- ❌ 无剪贴板 / 文件传输
- ❌ 无断线重连（断了要重新呼叫）
- ❌ 无密码 / 鉴权（信令支持 `AUTH_TOKEN`，但客户端 UI 还没接）
- ❌ 安卓端仅骨架，没有采集/注入实现（M3）

M2 的平台边界（**不是 bug**）：

| 限制 | 原因 |
|---|---|
| 被控端窗口在前台时，操作打到它自己身上 | `SendInput` 注入前台窗口 |
| 对管理员权限的窗口点击无效 | Windows UIPI |
| `Ctrl+Alt+Del`、`Win+L` 送不到 | 系统在更底层截获 |
| 浏览器作被控端无法被操作 | 网页无系统输入权限 |

---

## 7. 排障顺序

1. `01-check-env.cmd` —— 先看它怎么说
2. 网页左下角日志 —— 「注册成功」有没有出现？「已发送 offer / 已应用 answer」有没有？
3. `http://localhost:8787/health` —— 应返回 `{"ok":true,"devices":N}`
4. 卡在 `connecting` 但不出画面 → 多半是 ICE 走不通：
   同机测试先加 `?ice=none`；跨网络保留默认 STUN；仍失败就是 NAT 太严（需 TURN）

### 补充：`flutter test` 报 `Invalid WebSocket upgrade request`

```
Unable to connect to flutter_tester process:
WebSocketException: Invalid WebSocket upgrade request
```

这不是 Flutter 坏了。**如果这台机器开着全局/系统代理**（尤其是
`127.0.0.1:<端口>` 这种本地代理），它会把本地回环连接也劫持掉，
测试控制台的 WebSocket 就走了代理。

跑测试前清掉当前窗口的代理变量即可（不改系统设置）：

```powershell
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''
flutter test
```

`01-check-env.cmd` 会检测并提示这一点。

### 补充：`flutter pub get` 卡住或报找不到包

`app/pubspec.lock` 里记录的包源是 `https://pub.flutter-io.cn`（国内镜像）。
如果这台机器访问不到该镜像，`pub get` 会失败。处理：

```powershell
cd src\remotedesk\app
del pubspec.lock
$env:PUB_HOSTED_URL="https://pub.dev"          # 或你所在网络能通的镜像
flutter pub get
```

---

## 8. 交付前已验证（2026-11-05）

这个包不是"写完就交"，交付前在 macOS 上做过一次**干净目录验证**：
把 zip 解压到全新目录，只用包里自带的 `server` 和 `web-preview` 起服务，
再用包里自带的 `m1-smoke.mjs` 驱动两个独立 Chrome 跑完整链路。

| 验证项 | 结果 |
|---|---|
| zip 完整性（`unzip -t`） | 262 个文件全部通过 |
| `node.exe` | PE32+ x86-64，真实 Windows 可执行文件 |
| 包内信令服务（含自带 `ws`） | `/health` → `{"ok":true,"devices":0}` |
| 包内静态服务 | index / flutter_bootstrap.js / main.dart.js / canvaskit.wasm 全 200，MIME 正确 |
| 路径穿越防护 | `GET /../../etc/passwd` → 404 |
| **端到端媒体流** | **PASS：640×360 / 20 fps / 332 kbps / rtt 41 ms** |
| `.cmd` 编码 | 7 个全部纯 ASCII + CRLF（无 BOM） |
| `.ps1` 编码 | 4 个全部 UTF-8 with BOM |
| PowerShell 语法 | 括号/引号平衡、无 PS7-only 语法（PowerShell 5.1 可跑） |

**未验证**：Windows 原生 exe 的编译与运行（出包时本机无 Windows 环境）。
所以到了 Windows 上，`04-build-windows.cmd` 是第一次真实编译——
如果报错，把窗口里的报错发回来。

### m2.2 相对 m2.1 的改动（2026-11-06）

| 改动 | 为什么 |
|---|---|
| Windows 注入器新增 `pointerSelfTest` | 之前只有 macOS 有这个自检，Windows 点「测试注入」会落到 `NotImplemented`；现在两端同一个 channel 方法、同一套返回值 |
| 自检文案统一在 Dart 侧 | C++ 只回 `moved` 等事实，中文文案留在 Dart：MSVC 会把窄字符串按系统代码页编译，中文写进 C++ 会变乱码 |
| 键盘修复随包带上 | `InputKey.fromHidUsage` 之前把 `0x00070004` 整串当低字节查表，导致**键盘全哑**；现在先校验页号 `>> 16 == 0x07` 再取低位 |
| 会话视图修复随包带上 | 黑边 hover 不再外发（本来会把远端光标顶到屏幕边缘）；失焦 / cancel / dispose 三处都释放按下的键，避免"卡住一个 Shift" |
| 应用内状态自动复检 | 之前只在远端事件到达时才复检，空闲时状态行一直停在旧值；现在每 15 秒自检一次，权限/能力一变就自动翻状态并跑一次注入自检 |

### M2 的验证记录（2026-11-05，Windows 本机）

| 验证项 | 结果 |
|---|---|
| `dart analyze` | **No issues found** |
| `flutter test` | **35/35 通过**（原 7 + M2 新增 28） |
| `flutter build web --release` | **成功**，产物已替换进 `web-preview/`（MD5 一致） |
| Flutter SDK | 3.47.9 / Dart 3.13.7，已装到 `%USERPROFILE%\flutter` |
| **M2 真机（鼠标键盘注入）** | **未验证** —— 缺开发者模式 + VS C++ 工具链 |

M2 的 28 个单测覆盖：事件编解码往返、键位 id / HID 唯一性、未知 id 丢弃、
坐标越界钳制、黑边换算（含"画面角 vs 控件角"）、坏 JSON 容错。

