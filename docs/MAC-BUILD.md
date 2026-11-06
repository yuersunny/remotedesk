# macOS 原生版构建说明

## 现状（2026-11-05 实测）

`flutter build macos` 在本机直接失败：

```
Xcode not installed; this is necessary for iOS and macOS development.
Download at https://developer.apple.com/xcode/.
```

不是代码问题，是**工具链缺两样**，且磁盘不够：

| 项 | 状态 | 要求 |
|---|---|---|
| 完整 Xcode | ❌ 未安装（只有 Command Line Tools） | App Store 下载约 **12 GB**，展开后约 **38 GB** |
| xcode-select 指向 | ⚠️ 指向 `/Library/Developer/CommandLineTools` | 需指向 `/Applications/Xcode.app/Contents/Developer` |
| CocoaPods | ❌ 未安装 | `flutter_webrtc` 等插件编译必需 |
| 磁盘可用 | ⚠️ **13 GB** | 至少 **50 GB** |

随时用预检脚本复核当前状态：

```bash
./scripts/mac-preflight.sh
```

---

## 补齐步骤

### 1. 腾磁盘

这台机器 `/Users` 已用 192 GB / 228 GB。占用大头（实测）：

```
43G  ~/Library/Application Support
36G  ~/Library/Containers
5.2G ~/Library/Caches
```

`Containers` / `Application Support` 是各 App 的数据，**别用 `rm` 手删**。
先看清楚是谁占的再决定：

```bash
du -sh ~/Library/Application\ Support/* | sort -rh | head -10
du -sh ~/Library/Containers/* | sort -rh | head -10
```

微信、Docker、各类 IDE 的缓存通常是大头，走各自 App 的"清理"入口最安全。

### 2. 安装 Xcode

App Store 搜索 `Xcode` → 安装（也可以从 <https://developer.apple.com/download/all/>
下载 `.xip`，需 Apple ID 登录）。

装完后：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

### 3. 安装 CocoaPods

系统自带 ruby 是 2.6，CocoaPods 1.17 要求更新，建议走 Homebrew：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cocoapods
```

装完复核：`pod --version`。

### 4. 编译并启动

```bash
./scripts/build-macos.sh          # release 构建 + 自动 open
./scripts/build-macos.sh debug    # debug 构建
./scripts/build-macos.sh run      # flutter run -d macos（热重载）
```

---

## 首次运行的权限

macOS 的屏幕采集必须由用户手工授权，**无法静默授予**：

1. 第一次点「接受并共享屏幕」时，系统会弹窗要求「屏幕录制」权限
2. 到 `系统设置 → 隐私与安全性 → 屏幕录制` 勾选 RemoteDesk
3. **授予后必须退出 App 再重开**，否则仍然拿不到画面（这是 TCC 的机制）

M2 做输入注入时还会再要「辅助功能」（Accessibility）权限，同样要重开生效。

---

## 不想装 Xcode？先用网页版

macOS 上网页版功能与原生版一致（M1 只有画面传输，采集走浏览器）：

```bash
cd app/build/web
python3 -m http.server 8080 --bind 127.0.0.1
# 浏览器打开 http://localhost:8080/?id=mac
```

只有一点要注意：**必须用 localhost 打开**，不能用局域网 IP
（Chrome 只允许安全来源采集屏幕）。

原生版相对网页版的优势要到 M2 才明显：输入注入需要 `CGEvent`，
网页版做不到对系统级鼠标键盘的注入。

---

## 两个会直接卡住构建的坑（已由 `build-macos.sh` 兜住）

**1. 别让 `PUB_HOSTED_URL` 把镜像地址写进 `pubspec.lock`。**
以前脚本无条件把 `PUB_HOSTED_URL` 默认成 `https://pub.flutter-io.cn`，于是每个包
`description.url` 从 `https://pub.dev` 变成镜像地址，`flutter pub get` 报
**"Changed 65 dependencies!"**——版本一个没动，只是 host 换了。连带后果是 Pods 被判定
过期，Flutter 要去跑 `pod install`，而这台机器没有 CocoaPods，构建就以
`CocoaPods not installed or not in valid state.` 结束。
现在脚本只在外部**显式**设置了 `PUB_HOSTED_URL` 时才用镜像。

**2. 本机没有 CocoaPods，`Pods/Manifest.lock` 必须存在且与 `Podfile.lock` 逐字节相同。**
Flutter 用这两个文件的内容比对来决定要不要跑 `pod install`（不是比 mtime）。
`Pods/` 里其实已经按 `Podfile.lock` 装好了所有 pod，只差这一份清单文件。
脚本会在缺失时把 `Podfile.lock` 复制成 `Pods/Manifest.lock`——
补的是 CocoaPods 自己本该写的那份，不是绕过检查。

**顺带一条**：依赖没变时脚本走 `--no-pub`，判据是 `pubspec.yaml` + `pubspec.lock`
的**内容指纹**（存于 `.dart_tool/pub-inputs.sha`），不是文件时间——
`git checkout` 会把 mtime 刷成当前时间，按时间比会误判成"依赖变了"。
