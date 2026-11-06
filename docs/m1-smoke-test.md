# M1 验证说明（画面单向传输）

M1 的目标不是"能编过"，而是**被控端的画面真的能到主控端**。编译通过说明不了这件事——媒体管线只有跑起来才知道通不通。

验证分两层：

| 层 | 手段 | 覆盖什么 | 需要人工？ |
|---|---|---|---|
| 传输管线 | `server/scripts/m1-smoke.mjs`（两个无头 Chrome） | 采集 → 编码 → SDP/ICE 协商 → RTP → 解码 → 远端渲染 | 否，全自动 |
| 真实屏幕采集 | 浏览器/桌面手动点一次 | `getDisplayMedia` 的系统授权与源选择 | 是（系统权限只能人给） |

自动化那层用**同一个 `RtcSession`**，只是把采集源换成 Chrome 的假摄像头（`--use-fake-device-for-media-stream`）。屏幕采集与假摄像头在拿到 `MediaStream` 之后走的代码路径完全一致，所以它验证的正是 M1 的技术不确定点。

## 跑之前

1. 信令服务器在 8787：
   ```bash
   cd server && npm start
   ```
2. 静态站点在 8080，指向已构建的 web 产物：
   ```bash
   cd app && flutter build web
   cd app/build/web && python3 -m http.server 8080 --bind 127.0.0.1
   ```
3. 然后：
   ```bash
   cd server && node scripts/m1-smoke.mjs
   ```

## 它做了什么

1. 起两个**独立**的无头 Chrome（不同 `--user-data-dir`，互不共享存储）
2. 分别以 `id=tgt1`（被控）和 `id=ctrl1`（主控）进入自检模式：
   `?autojoin=1&capture=fake&role=...&peer=tgt1`
3. 两侧自动注册 → 主控呼叫 → 被控自动接受并用假摄像头采集 → 走真实信令交换 offer/answer/ICE
4. 每 1 秒通过 DevTools 协议读一次 `document.title`

自检模式下 App 把实时状态写进标题：

```
RemoteDesk|主控|live|640×360|20 fps|285 kbps|0 ms
          角色  阶段 分辨率   帧率    码率       RTT
```

判定条件：主控侧 `phase == live`、分辨率与帧率都已出数，**并持续保持** `HOLD_MS`（默认 12s）——只看一帧就过容易被"闪一下"骗过。

## 实测结果

```
target     live        640×360    19 fps   316 kbps    rtt=1 ms
controller live        640×360    20 fps   285 kbps    rtt=0 ms

PASS: controller receives video
```

分辨率从 320×180 一路爬到 640×360，是 WebRTC 的带宽探测（BWE）在爬坡，符合预期；帧率约 20fps 是软件编码（SwiftShader）的上限，真机会更高。

## 参数

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `APP_URL` | `http://127.0.0.1:8080` | 静态站点地址 |
| `SIGNAL_URL` | `ws://127.0.0.1:8787/ws` | 信令地址 |
| `TIMEOUT_MS` | `60000` | 总超时 |
| `HOLD_MS` | `12000` | 进入 live 后要保持多久才算过 |
| `CHROME_PATH` | macOS 默认路径 | Chrome 可执行文件 |

## 关于 Chrome 启动参数

无头 Chrome 在受限 shell 里会报 `sandbox initialization failed: Operation not permitted`，所以脚本固定带：

- `--no-sandbox`：Chrome 自身沙箱在受限环境起不来
- `--disable-gpu` + `--enable-unsafe-swiftshader`：没有 GPU 进程时用软件 WebGL，否则 CanvasKit 起不来
- `--use-fake-device-for-media-stream` + `--use-fake-ui-for-media-stream`：假摄像头且不弹权限框

这几项只影响自检，不影响构建出的 App。

## 桌面真机采集（需人工那一步）

macOS 13+ 走 ScreenCaptureKit，Windows 走 `RTCDesktopCapturer`，两条都在 `flutter_webrtc` 内部选择，代码侧统一是：

```dart
// 枚举（桌面才有；web 由浏览器自己弹选择框）
final sources = await desktopCapturer.getSources(
  types: [SourceType.Screen, SourceType.Window],
);

// 采集
await navigator.mediaDevices.getDisplayMedia({
  'video': {
    'deviceId': {'exact': sourceId},   // 桌面：指定屏幕/窗口
    'width': {'max': 1920, 'ideal': 1920},
    'height': {'max': 1080, 'ideal': 1080},
    'frameRate': 30,
  },
  'audio': false,
});
```

对应实现在 `app/lib/src/screen_capture.dart`。

**权限（绕不过）**：

- macOS：系统设置 → 隐私与安全性 → 屏幕录制 → 勾选本 App → **重启 App** 才生效
- Web：`getDisplayMedia` 必须在用户手势里调用，所以设计成"点『接受并共享屏幕』→ 立刻采集"，不能延后到收到 offer 之后
- Windows：无需授权

## 已知问题（上游）

macOS 13+ 在 Retina 屏上，`flutter_webrtc` 早期版本用 point 而非 pixel 配置 `SCStreamConfiguration`，导致采集分辨率只有一半（4K 屏拿到 2240×1260）。上游 issue #2241 已在 flutter-webrtc PR #2242 修正。当前锁的是 `flutter_webrtc 1.6.3`，若真机发现画面偏软，先升级到含该修复的版本，再排查别处。

## M1 的边界

- 只有**视频**，没有声音、没有输入注入（那是 M2）
- 单向：被控 → 主控。主控不发画面
- 没有断线重连、没有码率/分辨率自适应开关（M4）
