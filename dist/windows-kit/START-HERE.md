# Windows 端怎么跑

这个文件夹在发行包里位于 `installers/windows/`，完整源码在 `../../source/`。
下面两条路，按你的需求选一条。

---

## A. 浏览器版 —— 不用装任何东西（只能当主控）

双击 **`00-RUN-WEB-NOW.cmd`**。

它会用包内自带的 `node\node.exe` 在 `http://localhost:8080` 起一个静态服务，然后打开浏览器。
不需要 Node，不需要 Flutter，不需要编译。

打开后在页面里点「手动指定」，填**对方机器**的地址：

```
192.168.1.20            同一个 Wi-Fi
192.168.1.20:8787       端口不同时带上
```

或者直接粘对方界面上那行配对码（`RDSK1 100.x.x.x:8787 <名字> <密码>`）。

**两个必须知道的限制**：

1. **只能当主控**。浏览器版能操作别人，但别人看不到、也操作不了这台机器。
   要被控，走下面的 B 路。
2. **页面必须开在 `localhost`**，不能通过局域网 IP 访问。Chrome 只在 localhost 或 https
   下允许屏幕采集，用 `192.168.x.x:8080` 打开会拿不到画面。

一个黑色的命令行窗口会出现——它就是 Web 服务本身，关掉窗口服务就停了。

---

## B. 原生 exe —— 编译一次，之后和普通软件一样

需要装开发工具，20 分钟左右，一次性。脚本都放在这个目录，按顺序双击：

| 顺序 | 脚本 | 干什么 | 要多久 |
|---|---|---|---|
| 1 | `01-check-env.cmd` | 检查现在缺什么，只读不改 | 5 秒 |
| 2 | `01b-enable-dev-mode.cmd` | 打开 Windows「开发者模式」（Flutter 要建符号链接，不开会失败） | 10 秒 |
| 3 | `03-install-vs-buildtools.cmd` | 装 Visual Studio Build Tools + C++ 桌面开发组件 | 10–20 分钟 |
| 4 | `02-install-flutter.cmd` | 装 Flutter SDK（解压到 `%USERPROFILE%\flutter`） | 5–10 分钟 |
| 5 | `04-build-windows.cmd` | 编译，产物在 `..\..\source\app\build\windows\x64\runner\Release\` | 3–8 分钟 |
| 6 | `05-run-windows-app.cmd` | 普通权限启动刚编出来的 exe | — |
| 7 | `06-run-as-admin.cmd` | **以管理员身份启动**（当被控端、要操作管理员窗口时用） | — |

**第 3、4 步装完必须关掉窗口重开**，PATH 才会生效。装完可以再跑一次 `01-check-env.cmd` 确认全绿。

**这台机器要被别人控制时，用第 7 个脚本启动**：会弹 UAC，点「是」，然后把
RemoteDesk 窗口最小化。理由见下面「连上了，但点不动某些窗口」。

编译完的 `Release\` 整个文件夹就是绿色版，可以拷到任何 Windows 机器上直接跑
（目标机器可能需要 VC++ 运行库，微软官网下 `vc_redist.x64.exe`）。

---

## 常见问题

**双击 .cmd 一闪就没了**
说明脚本在 `pause` 之前就退出了。在这个目录按住 Shift 右键 →「在此处打开 PowerShell 窗口」，
手动敲 `.\04-build-windows.cmd`，就能看到完整的报错。

**防火墙弹窗**
第一次运行会问是否允许网络访问，勾「专用网络」。不允许的话对方连不上 8787。

**连上了，但点不动某些窗口（任务管理器关不掉）**
Windows 从 Vista 起禁止低权限进程向**以管理员身份运行**的窗口发送输入（UIPI 隔离）。
任务管理器在管理员账户 + UAC 开启时会被系统自动提升，所以点 X、按 Alt+F4 都像没按一样，
而且失败是**静默**的：注入器只往调试输出写一行，控制端收不到任何提示。

解法：**完全退出 RemoteDesk，改用 `06-run-as-admin.cmd` 启动**（UAC 点「是」），
再把 RemoteDesk 窗口最小化，让对方重连一次。先点任务管理器的「性能」标签验一下，能切换就通了。
想每次都生效，右键 `remotedesk.exe` → 属性 → 兼容性 → 勾「以管理员身份运行此程序」。
前提是 Windows 登录账户本身是管理员。

这不是「任何远程软件都一样」：TeamViewer、ToDesk 在安装时注册了一个提权的后台服务，
由那个服务注入输入，所以能操作管理员窗口。RemoteDesk 是绿色版、不装服务，因此把提权
这一步留给了使用者——脚本已经替你做好了，只是过去没放进套件里。

**编译报 `C2220` 或 `C4819`**
中文 Windows 的 ANSI 代码页是 936，而插件源码是 UTF-8，Flutter 模板又开了「警告即错误」。
本仓库已经在 `app/windows/CMakeLists.txt` 里加了 `/utf-8 /wd4819`。
如果你从别处拿到的是旧版本代码，把这个补上即可。注意 `chcp 65001` **没用**——
它只改控制台，不改编译器读文件用的代码页。

**编译报找不到 `pubspec.yaml`**
`04-build-windows.cmd` 会在两个位置找源码：套件自带的 `src\remotedesk`，或者发行包里并列的
`source\`。两个都没有，说明压缩包没解压完整。

**`flutter pub get` 失败，报符号链接错误**
第 2 步的开发者模式没开，或者开了没重启终端。

---

## 这个目录里还有什么

```
tools\check-env.ps1          环境体检
tools\install-vs-buildtools.ps1
tools\install-flutter.ps1
tools\enable-dev-mode.ps1
tools\build-windows.ps1      真正的编译逻辑
tools\serve.mjs              A 路用的静态服务（含 localhost 安全上下文说明）
tools\lan-info.mjs           打印本机各网卡地址，方便告诉对方填哪个
node\node.exe                Node 运行时（83 MB，A 路靠它，不用单独装 Node）
web-preview\                 A 路用的网页版产物（flutter build web 的结果）
```

删掉 `node\` 和 `web-preview\` 不影响 B 路，能省 100 MB。
