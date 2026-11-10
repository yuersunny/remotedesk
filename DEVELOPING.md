# 二次开发

给要改代码的人。假设你会 Flutter，但没碰过这个项目。

---

## 1. 环境

| 目标平台 | 需要什么 | 备注 |
|---|---|---|
| 都需要的 | Flutter **3.47.x**（Dart 3.9+） | 更老的版本 `flutter_webrtc` 装不上 |
| macOS | Xcode 完整版（不是 Command Line Tools） | `xcodebuild -version` 有输出才算 |
| Windows | VS Build Tools（勾「C++ 桌面开发」）+ 系统设置里打开「开发者模式」 | 开发者模式不打开，Flutter 无法建符号链接，`flutter pub get` 会失败 |
| Android | Android SDK 36 + Build Tools 36 + JDK 17 或 21 | Gradle 会自己下，第一次 20 分钟起 |

```bash
flutter doctor -v          # 先跑这个，红叉逐个消掉再继续
cd app && flutter pub get
flutter run -d macos       # 或 -d windows / -d chrome / 连着手机就跑 -d <设备id>
```

`flutter run -d chrome` 可以在没有 Xcode/VS 的机器上验证画面链路（浏览器版只能当主控）。

## 2. 代码地图

一份文件一句话，按"我要改什么"查。

**入口与状态**

| 文件 | 行数 | 负责 |
|---|---|---|
| `app/lib/main.dart` | 2400 | 整个应用状态：三张卡片的主界面、自连（`_client`）+ 拨号（`_dial`）双连接模型、会话生命周期、路由远端事件 |
| `app/lib/src/platform_kind.dart` | 35 | 判断当前是桌面还是手机。手机端不中转、不广播、不共享屏幕 |

**连接**

| 文件 | 负责 |
|---|---|
| `signaling_server_io.dart` | 本机内置信令服务器（`/health`、`/info`、`/ws`）。**每台机器自己监听 8787**，拨号时临时连对方 |
| `signaling_client.dart` | 信令 WebSocket 客户端 |
| `discovery_io.dart` | 自动发现：Tailscale `status --json` + 局域网 UDP 8789 广播 |
| `peer_info.dart` | 设备模型 + 合并去重（能联通就推翻"离线"） |
| `pairing_code.dart` | 配对码 `RDSK1 <host>:<port> <id> <password>` 的解析与生成 |

**媒体与输入**

| 文件 | 负责 |
|---|---|
| `rtc_session.dart` | WebRTC 会话：SDP/ICE、建 DataChannel、统计、`hello` 握手 |
| `screen_capture.dart` | 采集约束（光标、帧率、deviceId）。**排除系统光标**就靠这里 |
| `session_view.dart` | 桌面端画面 + 工具条 + 键鼠捕获 → 事件 |
| `input_channel.dart` | `input` DataChannel 的收发，可靠/不可靠两条通道分流 |
| `input_event.dart` | 全部线格式事件定义（`hello`/`move`/`btn`/`wheel`/`key`/`cb`）+ 编解码 + 视图变换工具 |
| `input_injector.dart` | 把事件翻译成平台调用（MethodChannel） |
| `clipboard_sync.dart` | 跨机剪贴板：轮询、去重、归一化、上限 |

**手机端**（只在 `isHandheld` 时走这些）

| 文件 | 负责 |
|---|---|
| `mobile/mobile_home.dart` | 手机首页：设备列表、配对码、手动地址 |
| `mobile/mobile_session.dart` | 全屏画面 + 顶部状态条 + 键盘面板 |
| `mobile/touch_input.dart` | 触摸 → 鼠标事件的状态机，含放大/平移变换 |
| `mobile/hid_text.dart` | 文本框内容差分 → 按键序列 |

**原生注入器**（这是唯一必须按平台各写一遍的部分）

| 文件 | 平台 | 手段 |
|---|---|---|
| `app/macos/Runner/InputInjector.swift` | macOS | `CGEvent.post` |
| `app/windows/runner/input_injector.cpp` | Windows | `SendInput` |

## 3. 一次点击是怎么走到远端的

```
手机/桌面 UI
  └─ touch_input.dart / session_view.dart    触摸或鼠标 → 归一化坐标 [0,1]
      └─ input_event.dart                    ButtonEvent(b, d, x, y)
          └─ input_channel.dart              打包 JSON → DataChannel
              └─ 网络（WebRTC, DTLS-SRTP 加密）
                  └─ input_channel.dart      解包
                      └─ main.dart 路由     按类型分发
                          └─ input_injector.dart   MethodChannel
                              └─ 原生注入器      CGEvent / SendInput
```

**坐标一律是画面内的比例**，不是像素。这样两台机器分辨率不同、窗口被缩放，都不需要换算。

**键位传的是 usbHidUsage**（物理键位），不是字符。这样对端输入法、键盘布局都不影响——
但也意味着**中文打不过去**，因为中文不是"按哪个键"能表达的。

## 4. 常见改动菜谱

**想改手势** → `mobile/touch_input.dart`。状态机有两个必须遵守的约束：
按下的瞬间**不能**立刻发按键（超过 8px 才算拖动），否则双指滚动时第二根手指晚到几毫秒，
每次滚动都会在远端留一次误点；双指手势要**一次定性**（指间距变化 >26px 判缩放，
否则看中点位移 >8px 判滚动），因为两根手指永远不是完全同步移动的，按帧比较会把滚动全判成缩放。

**想加新事件** → 三处一起改，缺一个就是静默失效：
1. `input_event.dart` 定义类 + `fromJson` + 在 `decode()` 的 switch 里注册；
2. 发送侧构造并 `channel.send(...)`；
3. `main.dart` 的接收路由里处理，通常再串到 `input_injector.dart`。

**想加按键映射** → 三端的键位表必须一致，`scripts/check-keymap.py` 会校验。
macOS 在 `InputInjector.swift`，Windows 在 `input_injector.cpp`，Dart 侧在 `input_event.dart`。

**想改剪贴板行为** → `clipboard_sync.dart`。四个不变量别破坏，注释里都写了为什么：
连上时不推送、自己写入的不回推、比较前归一化换行、写入后重读一次再记状态。

**想让 Windows 上也能被点击控制提权窗口** → 做不到。Windows 从 Vista 起禁止低权限进程向高权限窗口
`SendInput`，唯一合规做法是把被控端也以管理员身份运行，或者写一个提权服务。这不是本项目能绕过的。

## 5. 测试

```bash
cd app
flutter analyze          # 必须是 0 issue
flutter test             # 140 条
```

**注意**：如果你的机器设了 `HTTP_PROXY`，`flutter test` 会连不上测试进程，需要：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy flutter test
```

测试覆盖的都是"不看屏幕也能判断对错"的部分：坐标变换、手势状态机、按键映射、
剪贴板去重、配对码解析、设备合并、信令服务器端口占用。**UI 效果和真机注入必须人工验。**

`app/tool/two_connection_check.dart` 是双连接模型的自检（10 项，含"同名设备被拒绝"的反证）。

## 6. 打包

| 脚本 | 产物 |
|---|---|
| `./scripts/pack-macos-dmg.sh 1.0.8` | `dist/RemoteDesk-1.0.8-macos-universal.dmg`（通用二进制 + 签名） |
| `./scripts/build-android.sh` | `dist/RemoteDesk-<版本>-android-arm64.apk` |
| `./scripts/pack-windows-kit.sh m3.2` | Windows 机器用的套件（源码 + 一键编译脚本） |

安卓签名：`app/android/key.properties` + `keystore/`。**这两个文件不在仓库里**（公开仓库放
release key 等于让别人能签一个覆盖安装的包），本机保留即可。缺了不会构建失败，会退回 debug 签名，
但 debug 签名的包不能覆盖正式签名的包——要给同一个用户升级，必须用同一个密钥。

## 7. 已经踩过的坑（省你几个小时）

| 现象 | 真实原因 |
|---|---|
| Windows 编译报 `C2220` / `C4819` | 中文 Windows 的 ANSI 代码页是 936，插件源码是 UTF-8，而 Flutter 模板开了 `/W4 /WX`。`chcp 65001` **没用**（那只改控制台，不改编译器读文件的代码页）。解法在 `app/windows/CMakeLists.txt`：加 `/utf-8 /wd4819`，**目录级和函数内两处都要加** |
| GUI 启动的 App 里 `tailscale` 找不到 | Finder 启动的进程 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，没有 `/usr/local/bin`。必须用绝对路径，且候选路径要逐个试、失败要打日志——先试裸名就 `return` 会让这条通道静默死掉 |
| macOS 15+ 上 UDP 广播发不出去 | 缺 `NSLocalNetworkUsageDescription`，系统**静默丢弃**本地网络流量，不报错 |
| 采集卡在 30fps | 插件只认 `video.mandatory.frameRate`，且只接受 double。写在顶层、或传 int，都会被忽略 |
| 点了鼠标出现两个光标 | 采集时把系统光标烘进了画面，主控端又画了一个。要发 `video['cursor'] = 'never'`，**桌面端也要**，不只是 web |
| 打包脚本报 unbound variable | `set -u` + bash 3.2 + 空数组。写成 `${ARR[@]+"${ARR[@]}"}` |
| 配对码把乱码当主机名 | 校验位置在解析地址之后。无 `RDSK1` 前缀时，首项必须"长得像地址"才接受 |

## 8. 下一步可以做什么

按难度排：

1. **文件传输**——复用现有 DataChannel，加分片和进度。
2. **断线重连**——WebRTC 的 ICE restart，会话状态机已经有地方挂了。
3. **多屏切换**——`screen_capture.dart` 只取第一个屏幕，改成枚举。
4. **中文输入**——需要给协议加文本事件（而不是按键事件），并在三端注入器里实现文本插入。
5. **安卓被控**——MediaProjection 采集 + 前台服务 + 无障碍服务注入。工作量最大，
   而且手机上还要单独处理"用户随时可能撤销授权"。
