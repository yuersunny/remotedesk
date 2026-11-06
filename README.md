# RemoteDesk

自用跨平台远程控制工具（macOS / Windows / Android），支持任意公网穿透。

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
- [ ] **M3** 安卓被控（MediaProjection + 无障碍注入）
- [ ] **M4** 优化：断线重连、剪贴板、文件传输、多屏

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

## 跨机器（Mac ↔ Windows）

两台机器各在自己机器上打开网页（**必须 localhost**），只把信令指向对方 IP：

```bash
# Mac 侧起网页服务
cd app/build/web && python3 -m http.server 8080 --bind 127.0.0.1
# 浏览器 http://localhost:8080/?id=mac，信令填 ws://<Windows IP>:8787/ws
```

> Chrome 只允许"安全来源"采集屏幕：`http://localhost` 算安全，`http://192.168.x.x` 不算。
> 所以页面必须各自本地打开，只有信令和 WebRTC 数据走局域网 IP。

Windows 侧打包好的东西见 `dist/remotedesk-windows-kit.zip`，
解压后先看里面的 `START-HERE.md`。

## 真机首次运行的权限（绕不过，必须手动授予）

- **macOS 被控**：屏幕录制（系统设置 → 隐私与安全性 → 屏幕录制），授予后**必须重启 App**；M2 还需辅助功能
- **Windows 被控**：普通权限即可；UAC 提权窗口无法注入
- **Android 被控**：每次启动弹 MediaProjection 录屏授权 + 手动开启无障碍服务

## 协议

见 [docs/protocol.md](docs/protocol.md)。M1 的完整时序见 [docs/m1-smoke-test.md](docs/m1-smoke-test.md)。
