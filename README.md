# RemoteDesk

跨平台远程桌面：**macOS / Windows / Android 一套代码**，局域网点一下就连，跨网络走 Tailscale 或自建中继。

不需要配服务器、不需要记 IP、不需要判断"谁控制谁"——每台机器自己监听，拨号时临时连对方的端口。
真正传画面的是 WebRTC（P2P 直连优先，打不通回落 TURN 中继，DTLS-SRTP 加密），信令只转发不解析。

---

## 一、只想用，不想写代码

去 [Releases](../../releases) 下对应平台的包，或者用发行 zip 里的 `installers/`：

| 平台 | 文件 | 说明 |
|---|---|---|
| macOS 13+ | `RemoteDesk-1.0.7-macos-universal.dmg` | 通用二进制（Intel + Apple Silicon），双击装 |
| Android 7.0+ | `RemoteDesk-1.0.7-android-arm64.apk` | 手机**只能当主控**（手机操作电脑） |
| Windows 10/11 | **无预编译包** | 见下方说明，需在本机编译一次 |

用法三步：两台机器都打开 → 同一个 Wi-Fi 下会自动出现在列表里 → 点一下就连上。
列表里没有就用「配对码」：被控端界面上那行字，复制粘贴过去。

**第一次用、或者要交给不懂技术的人，看 [`docs/使用说明书.md`](docs/使用说明书.md)**——
12 章，讲清了安装、授权、IP 与端口、配对码、失败排查。排好版的 17 页 PDF 在
[Releases](../../releases/latest) 里（`RemoteDesk-1.0.7-manual-zh.pdf`），可直接打印或发微信；
也可以跑 `python3 scripts/build-manual.py` 自己生成。手势、快捷键、速查表见
[`GETTING-STARTED.md`](GETTING-STARTED.md)。

### Windows 为什么没有 exe

本项目在 macOS 上开发，**Flutter 不能交叉编译到 Windows**（需要在 Windows 上跑 MSVC）。
两条路：

1. **浏览器版，开箱即用**（推荐先试这个）：`installers/windows/` 里的 `00-RUN-WEB-NOW.cmd`，
   双击后用 Chrome 打开，功能和桌面版基本一致，不用装任何开发工具。
2. **编译原生 exe**：同一目录下 `03-install-vs-buildtools.cmd` → `02-install-flutter.cmd` →
   `04-build-windows.cmd`，脚本会自动装 VS Build Tools 和 Flutter，全程约 20 分钟、一次性。

---

## 二、想改代码

```bash
git clone <本仓库>
cd remotedesk/app
flutter pub get
flutter run -d macos      # 或 -d windows / -d chrome / 安卓设备
```

代码组织、三端构建、测试、以及"想改某个功能该动哪个文件"，见 [`DEVELOPING.md`](DEVELOPING.md)。
线格式（DataChannel 上到底发了什么字节）见 [`docs/protocol.md`](docs/protocol.md)。

## 架构

```
Flutter 客户端（mac / win / android 同一套）
        │
        ├── flutter_webrtc：屏幕采集 + 传输 + ICE/STUN/TURN（自带 NAT 穿透）
        │
        ├── Node.js 信令服务器：设备注册、ID 撮合、SDP/ICE 转发（不碰媒体）
        │
        └── coturn：P2P 打不通时中继（公网 VPS 部署）
```

媒体走 WebRTC 通道（P2P 直连优先，失败回落 coturn 中继），由 DTLS-SRTP 端到端加密；信令服务器只转发不解析。

## 目录

```
remotedesk/
├── server/        Node.js 信令服务器（已实现 + 5 项测试）
│   └── scripts/m1-smoke.mjs    M1 端到端自检（画面，两个无头 Chrome 真跑）
│   └── scripts/m2-smoke.mjs    M2 端到端自检（控制通道，CDP 打真实鼠标键盘事件）
├── infra/         coturn 配置 + docker compose（VPS 部署）
├── app/           Flutter 客户端（信令 + 画面 + 输入注入）
├── scripts/       mac-preflight.sh、build-macos.sh、check-keymap.py（键位表两端一致性）
├── docs/          协议文档、M1/M2 验证记录、MAC-BUILD.md
└── dist/
    └── windows-kit/ + remotedesk-windows-kit.zip   Windows 机器用的完整交付包
```

## 进度

- [x] **M0-a** 信令服务器：注册 / 撮合 / SDP·ICE 转发 / 心跳
- [x] **M0-b** coturn 中继配置 + 容器化部署文件
- [x] **M0-c** Flutter 3.47.9 三端工程骨架（macos / windows / android / web）
- [x] **M0-d** Dart 信令客户端 + M0 UI，`flutter analyze` 0 issue、单测通过
- [x] **M1** 画面单向传输（被控端采集 → WebRTC → 主控端渲染 + 实时 HUD）
  - 已用两个无头 Chrome 实跑通过：分辨率 320×180→640×360、约 20fps、130–320 kbps
  - 桌面采集走 `flutter_webrtc` 的 `desktopCapturer` + `getDisplayMedia`（macOS 13+ 用 ScreenCaptureKit）
  - 默认带公共 STUN（Google / Cloudflare），跨网络可尝试直连；`?ice=none` 可关
- [x] **M2** 桌面输入注入（鼠标/键盘 → 真正可控）—— 代码完成，通道已端到端验证
  - 主控端捕获 → `input` DataChannel → 被控端注入；坐标传画面比例，键位传平台中立 id
  - **已验证**：`flutter test` 37/37、`m2-smoke.mjs` PASS（收到 10 帧：移动 5 / 按键 2 / 滚轮+按键 3）
  - **未验证**：Windows `SendInput` 真机注入（缺编译器，见 `docs/m2-verification.md`）
  - **macOS 被控**：`CGEvent` 注入器已实现并编译进包（`app/macos/Runner/InputInjector.swift`），
    83 个 wire id 与 Windows / Dart 三端一致；差一次「辅助功能」授权后点按钮验证
  - 被控端覆盖 **Windows + macOS**；安卓（AccessibilityService）还没做
- [x] **M3-a 安卓主控**：手机连电脑（`dist/RemoteDesk-1.0.6-android-arm64.apk`）
  - 单指=左键 / 单指按拖=拖动 / 长按=右键 / 双指滑=滚轮 / 双指捏合=放大画面
  - 软键盘面板：英文数字符号、Ctrl·Alt·Shift·Win、方向键、F5、Del/Home/End/PgUp/PgDn
  - 坐标要穿过「放大 + 平移」的变换再归一化，点哪儿就是哪儿（`lib/src/mobile/touch_input.dart`）
  - 手机不中转、不共享本机屏幕：没有前台服务，也没有录屏授权弹窗
- [ ] **M3-b 安卓被控**（MediaProjection 采集 + 无障碍服务注入）—— 未做
- [x] **M3-c 跨机剪贴板**（`lib/src/clipboard_sync.dart`）
  - 纯文本，**双向**；`cb` 事件走同一条 `input` DataChannel
  - 连上时不推送已有内容（会无声覆盖对方），会话前复制的用工具条「推送剪贴板」补发
  - 自己写入的内容不回推；比较前归一化换行（Windows `\r\n` / macOS `\n`）
  - 上限 160 KB（UTF-8 字节）——SCTP 单条 256 KB，超了丢弃并记日志，不截断
  - **⌘ 映射**：macOS 主控 + 非 macOS 被控时，⌘ 作为 Ctrl 发送。否则 ⌘C 到 Windows
    上变成 `Win+C`（弹系统面板），表现就是「从 Mac 复制到 Windows 不生效」
- [ ] **M4** 优化：断线重连、文件传输、多屏

## 本地运行信令服务器

```bash
cd server
npm install
npm start                       # ws://localhost:8787/ws
curl http://localhost:8787/health
```

测试：

```bash
cd server && npm test           # 握手/鉴权/边界 + 结构化 SDP·ICE 转发，5 项
```

## 运行客户端

```bash
cd app
flutter pub get
flutter run -d macos            # 需完整 Xcode
flutter run -d windows          # 需 Windows + Visual Studio
flutter run -d chrome           # 无 Xcode/VS 也能验证画面链路
```

## 安卓端（手机当主控）

和桌面端同一套 Dart 代码，只是壳不同：手机上的入口是 `lib/src/mobile/`，
桌面仍是 `main.dart` 里的三张卡片；信令、发现、会话完全共用，所以两端不会各走各的。

```bash
./scripts/build-android.sh              # 出 arm64 安装包到 dist/
./scripts/build-android.sh --universal  # 所有 ABI 一个包（大 30MB）
python3 scripts/make-android-icon.py    # 重画图标（改了配色再跑）
```

- 要求：Android 7.0（API 24）以上；Flutter 3.47 需要 `compileSdk 36`
- 装机：把 apk 传到手机点开装，允许一次「未知来源」
- 签名：用项目自带密钥（`app/android/keystore/`），版本能覆盖安装；密钥丢了就要先卸载再装
- 为什么只有主控：共享手机屏幕要 `MediaProjection` 授权 + 常驻前台服务，
  操作手机还要无障碍服务；这一版不做，界面上也不会摆一个按不动的开关

手机怎么连（用户视角）：

1. 电脑先开 RemoteDesk，停在主界面
2. 手机同一个 Wi-Fi 打开就有列表，点一下进
3. 没有列表就粘配对码（电脑「这台电脑」卡片那一行）
4. 跨网络：两台都上同一个 Tailscale，配对码里 100.x 地址照样连

已知边界：输入通道传的是**按键**不是文本，所以中文/表情打不进去；要中文得在电脑上切输入法。

Web 版可直接验证 M1：开两个标签页，分别用
`http://localhost:8080/?id=aaa` 与 `http://localhost:8080/?id=bbb`
（`?id=` 覆盖设备 ID，避免两个标签页抢同一个 localStorage ID）。

`app/README.md` 之外的操作流程：

1. 两个窗口都填 `ws://127.0.0.1:8787/ws` → 点「连接」
2. 主控窗口填对端 ID → 「呼叫」
3. 被控窗口弹窗 → 「接受并共享屏幕」→ 浏览器/系统弹出采集源选择 → 选中整个屏幕
4. 主控窗口出现画面，底部 HUD 显示分辨率/帧率/码率/延迟

## M1 端到端自检

不依赖任何手动点击，两个无头 Chrome 自动跑完整链路：

```bash
# 先起信令服务器(8787) 和静态站点(8080，指向 app/build/web)
cd server && node scripts/m1-smoke.mjs
```

详见 [docs/m1-smoke-test.md](docs/m1-smoke-test.md)。

## 部署到公网 VPS

```bash
cd infra
cp .env.example .env            # 设置 AUTH_TOKEN
# 编辑 coturn/turnserver.conf：改 user 密码；NAT 云主机需填 external-ip
docker compose up -d
```

防火墙放行：`8787/tcp`（信令）、`3478/tcp+udp`、`5349/tcp+udp`、`49152-65535/udp`（TURN 中继）。

## 客户端构建前提

| 平台 | 需要 | 现状 |
|---|---|---|
| macOS | **完整 Xcode**（约 50 GB）+ CocoaPods | ✅ 已装（Xcode + 用户空间 CocoaPods 1.17），`flutter build macos` 通过。过程见 [docs/MAC-BUILD.md](docs/MAC-BUILD.md) |
| Windows | Visual Studio（C++ 桌面开发）+ Flutter | 交给 `dist/windows-kit/`，脚本会自动装 |
| Android | Android SDK + NDK | 未开始 |

macOS 侧先跑预检，它会打印确切缺什么、怎么补：

```bash
./scripts/mac-preflight.sh     # 只检查不改动
./scripts/build-macos.sh       # 装好 Xcode + CocoaPods 后一键构建并启动
```

`build-macos.sh` 末尾会自动调 `./scripts/mac-sign.sh`，用本机自签名证书重签。
**这一步不是可选的**：adhoc 签名的"指定要求"是二进制哈希，重建即变，
系统里的「辅助功能」授权会显示已开却对新二进制无效（详见
[docs/m2-verification.md](docs/m2-verification.md) §6.5）。换成证书签名后授权只需给一次。

Windows 套件用它重新打包（会把当前源码快照进包，并跑一遍自检）：

```bash
./scripts/pack-windows-kit.sh m2.2   # → dist/remotedesk-windows-kit-m2.2.zip
```

### 出可执行程序（给没装开发工具链的机器）

上面那个 kit 是**开发套件**：源码 + 构建脚本，目标机还得装 Visual Studio 和 Flutter。
要交给一台干净机器直接用的，用下面两个：

```bash
./scripts/pack-macos-dmg.sh 1.0.0                                # → dist/RemoteDesk-1.0.0-macos-universal.dmg
./scripts/pack-windows-portable.sh <Release目录 或 回传的kit.zip>  # → dist/RemoteDesk-Windows.zip
```

| | macOS | Windows |
|---|---|---|
| 形态 | dmg，拖进 Applications | zip，解压即用，不写注册表 |
| 架构 | Universal（Intel + Apple Silicon） | x64 |
| 体积 | 34 MB（app 73 MB） | 45 MB（解压 72 MB） |
| 前提 | macOS 12+ | Win10 1809+ |
| 兜底 | 镜像内含清隔离标记的 `.command` | 内含 `vc_redist.x64.exe`（缺运行库时用） |

两边的说明文件都随包，讲清了权限、`/ws` 后缀、设备 ID 不能重复这些必踩的坑。

两根编码红线（踩过，会静默出错）：
- `START.cmd` 必须**无 BOM + CRLF + 纯 ASCII**。带 BOM 时 cmd.exe 把 BOM 当命令，
  首行报 `'ï»¿@echo' 不是内部或外部命令`；LF 行尾会让 `goto` 定位失败。
- macOS 的 `.command` 反过来**绝不能有 BOM**，否则 shebang 失效、双击无反应。
  另外 `.command` 里也不要用 `$VAR` 紧跟中文标点——bash 会把全角字节吞进变量名，
  报 `unbound variable`，所以一律写 `${VAR}`。

Windows 那份必须在 Windows 上编译（本机没有 MSVC），
把 `app/build/windows/x64/runner/Release` 目录、或整个回传的 kit zip 传进来即可。
脚本会自己从 zip 里找 `runner/Release`，不依赖固定层级。

## 怎么用

**两台都打开 app，什么都不用填。**

被控那台把「允许远程控制」打开（密码会自动生成）。操作那台在
「连接另一台电脑」里点对方的名字 —— 列表是自动找出来的，点一下就进。

就这么简单。没有 IP，没有服务器地址，也不用想谁当服务器。

### 找不到对方时

列表空了再想别的办法，按顺序：

1. **两台要在同一个 Wi-Fi，或同一个 Tailscale 网络里。** 跨网络时 Tailscale 是必须的。
2. **让对方先打开 app。** 只有开着的那台才会出现在列表里。
3. **点「配对码」**（就在对方那台的「这台电脑」卡片上，点一下即复制）。
   它长这样，一行字里带着名字、密码和地址：

   ```
   RDSK1 100.101.102.103:8787 mac-mini 7Q4WT9
   ```

   发给对方，让对方粘进「或者粘贴对方给你的配对码」那个框，点「连」。
   这一条对网络没有任何要求 —— 不在同一个网里也能用，只要你俩能互通。

### 为什么不用再管"谁当服务器"

以前要指定一台机器跑中转服务，因为只有连到同一个服务上的两台才能互相看见。
现在每台机器都给自己当中转：自己连自己（等着被呼叫），要连别人时临时连到
**对方那台**的服务上完成握手。握手完就是点对点直连，中转就不再参与了。

所以"谁当服务器"这个问题不存在了，两台同时也互不影响。

密码在这一版是**自动生成**的：打开开关时如果没有密码会自动给一个 6 位数，
也可以点旁边的刷新按钮换一个，或者自己填。关闭开关则每次都要人在那台机器上
点「接受」。

三道约束让"允许远程控制"不等于"谁都能进"：

| 约束 | 位置 | 说明 |
|---|---|---|
| 口令 | 被控端本地 | 服务端不保存也不校验，只转发；空口令时**拒绝所有来电** |
| 限流 | 服务端 | 同一调用方 10 次/60 秒，超过返回 `rate_limited`（界面会提示"等一分钟"） |
| 传输加密 | 你的网络 | 口令随 `connect` 走 WebSocket。**ws:// 是明文**，跨公网必须用 `wss://`，或把信令放在 Tailscale / WireGuard 这类私有网络里，并给服务器设 `AUTH_TOKEN` |

> 口令不要用 `123456`，也不要把 8787 直接暴露在公网上。

## 连不上时按这个顺序查

窗口最上面有一段红字会写清它试的是哪个地址 —— 先看那个地址对不对。

**1. 网络通不通**
先在操作那台上测对方那台的 8787 端口。自动发现走的是 Tailscale 节点列表和
局域网 UDP 广播，两者都不通时列表必然为空。

```powershell
Test-NetConnection 192.168.1.10 -Port 8787      # Windows
```

`TcpTestSucceeded : True` 才算网络通。False 就是网络层的事，跟软件无关。

**2. Windows 作为被控端：防火墙**

这一条有两件事，都归 Windows 防火墙管：

- **8787 入站**：app 自己就是服务器，对方要能连上这个端口，否则列表里根本看不到这台机器；
- **WebRTC 的 UDP 入站**：连上之后画面和鼠标走这条路，被拦的表现是"提示已连接但黑屏/鼠标不动"。

第一次运行 `remotedesk.exe` 时系统会弹一次"是否允许此应用通过防火墙"，
**必须勾上"专用网络"并允许**。如果当时点了取消，手动放行：

```
控制面板 → 系统和安全 → Windows Defender 防火墙 → 允许应用通过防火墙
→ 找到 remotedesk → 勾上「专用」
```

或者用管理员 PowerShell 一条命令：

```powershell
New-NetFirewallRule -DisplayName "RemoteDesk" -Direction Inbound -Program "C:\path\to\remotedesk.exe" -Action Allow
```

**3. 看日志**

「高级设置」最下面有「打开日志目录」。日志位置：

| 平台 | 路径 |
|---|---|
| Windows | `%LOCALAPPDATA%\RemoteDesk\logs\app-YYYY-MM-DD.log` |
| macOS | `~/Library/Logs/RemoteDesk/app-YYYY-MM-DD.log` |

日志里每一步都有记录：注册成功与否、采集源选了哪个、收到几条轨道、
ICE 是否连上、被拒的原因。**"连不上"和"连上了但被拒"在日志里是两件不同的事**，
以前这两件事看起来一模一样。

## 旧版本（网页版）怎么跑

网页版仍可用，用于自检：两台机器各在自己机器上打开
`http://localhost:8080`（必须是 localhost —— Chrome 只对安全来源开放屏幕采集），
只把信令指向对方 IP。原生版不需要这些限制。

## 真机首次运行的权限（绕不过，必须手动授予）

- **macOS 被控**：屏幕录制（系统设置 → 隐私与安全性 → 屏幕录制），授予后**必须重启 App**；M2 还需辅助功能
- **Windows 被控**：普通权限即可；UAC 提权窗口无法注入
- **Android 被控**：每次启动弹 MediaProjection 录屏授权 + 手动开启无障碍服务

## 协议

见 [docs/protocol.md](docs/protocol.md)。M1 的完整时序见 [docs/m1-smoke-test.md](docs/m1-smoke-test.md)。
