#!/usr/bin/env bash
# 打包 Windows 绿色版：把编译产物组成"解压即用"的目录并打 zip。
#
#   ./scripts/pack-windows-portable.sh <Release目录>        # 本机已有编译产物
#   ./scripts/pack-windows-portable.sh <回传的kit.zip>      # 从 Windows 回传的包里抽取
#   ./scripts/pack-windows-portable.sh                      # 自动找 dist/windows-kit/.../Release
#
# 产物：dist/RemoteDesk-Windows.zip
#
# 两条编码铁律（Windows 上会静默出错，不看不知道）：
#   START.cmd  —— 无 BOM + CRLF + 纯 ASCII。带 BOM 时 cmd.exe 把 BOM 当命令，
#                 首行报「'ï»¿@echo' 不是内部或外部命令」；LF 行尾会让 goto 定位错。
#   README-zh.txt —— UTF-8 with BOM，老记事本才认中文。
# 包内文件名一律 ASCII，避免不同解压工具对中文名的编码解释不一致。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VER="${1:-}"
OUT="$ROOT/dist/RemoteDesk-Windows.zip"
VC_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"

WORK="$(mktemp -d)"
trap "rm -rf '$WORK'" EXIT

# ---- 1. 拿到编译产物 ----
SRC="$WORK/Release"
if [ -z "$VER" ]; then
  echo "==> 未指定输入，自动查找编译产物"
  CAND="$ROOT/dist/windows-kit/src/remotedesk/app/build/windows/x64/runner/Release"
  if [ -d "$CAND" ]; then
    cp -R "$CAND" "$SRC"
  else
    echo "找不到编译产物。请在 Windows 上构建后，把 Release 目录或整个 kit zip 传过来：" >&2
    echo "  $CAND" >&2
    exit 1
  fi
elif [ -d "$VER" ]; then
  echo "==> 从目录取产物：$VER"
  cp -R "$VER" "$SRC"
elif [ -f "$VER" ]; then
  echo "==> 从 zip 抽取产物：$VER"
  # 不用 unzip 的通配符：macOS 自带的 unzip 不认 "--"，且 '*' 不跨目录，
  # 多层路径匹配会静默失败。整包解开再 find，稳。
  mkdir -p "$WORK/x"
  unzip -q -o "$VER" -d "$WORK/x"
  FOUND="$(find "$WORK/x" -type d -name Release -path '*runner*' | head -1)"
  [ -n "$FOUND" ] || { echo "这个 zip 里没有 runner/Release 目录" >&2; exit 1; }
  cp -R "$FOUND" "$SRC"
else
  echo "输入既不是目录也不是文件：$VER" >&2
  exit 1
fi

for f in remotedesk.exe flutter_windows.dll libwebrtc.dll data/app.so; do
  [ -e "$SRC/$f" ] || { echo "产物缺关键文件：$f" >&2; exit 1; }
done

# ---- 2. 组装目录 ----
echo "==> 组装绿色版目录"
PKG="$WORK/RemoteDesk-Windows"
mkdir -p "$PKG"
cp -R "$SRC"/. "$PKG"/

mkdir -p "$PKG/if-missing-vcruntime"
VC="$WORK/vc_redist.x64.exe"
if [ -f "$ROOT/vendor/vc_redist.x64.exe" ]; then
  cp "$ROOT/vendor/vc_redist.x64.exe" "$VC"
else
  echo "    下载 VC++ 运行库兜底（约 24MB）"
  curl -fL -sS -o "$VC" "$VC_URL"
fi

# ---- 3. 说明与启动脚本（编码由 python 保证）----
echo "==> 生成 START.cmd / README-zh.txt"
python3 - "$PKG" "$VC" <<'PY'
import os, shutil, sys

pkg, vc = sys.argv[1], sys.argv[2]
shutil.copy2(vc, os.path.join(pkg, "if-missing-vcruntime", "vc_redist.x64.exe"))

start = (
    "@echo off\r\n"
    "cd /d \"%~dp0\"\r\n"
    "if not exist remotedesk.exe (\r\n"
    "  echo remotedesk.exe not found in this folder.\r\n"
    "  pause\r\n"
    "  exit /b 1\r\n"
    ")\r\n"
    "start \"\" remotedesk.exe\r\n"
    "exit /b 0\r\n"
)
with open(os.path.join(pkg, "START.cmd"), "wb") as f:
    f.write(start.encode("ascii"))

readme = """RemoteDesk  Windows 绿色版
================================

不需要安装。整个文件夹解压到任意位置，双击 START.cmd 即可运行。
（直接双击 remotedesk.exe 也行，START.cmd 只多一层路径保护。）


一、它是什么
------------
自用的跨平台远程桌面。信令服务器只负责撮合两台机器，
画面和键鼠走 WebRTC 加密通道；P2P 打不通时回落中继。

同一份程序既能当「主控端」（控制别人），也能当「被控端」（被控制），
界面上选角色，不需要装两套。


二、怎么连
----------
1. 先让一台机器跑信令服务器（macOS 版仓库里的 server 目录，或任意装 Node.js 的机器）：

       cd server && node index.js

   局域网地址形如   ws://192.168.1.10:8787/ws
   跨网络地址形如   ws://100.x.x.x:8787/ws

   ★ 地址末尾的 /ws 不能漏，这是最常犯的错。
   ★ 两台机器的设备 ID 不能相同。

2. 两台机器都打开 RemoteDesk：
   - 被控端：填服务器地址 + 设备 ID（如 mac），点「连接」
   - 主控端：填同一地址 + 自己的 ID（如 win），点「连接」，
     在线设备列表里会出现对方，选中它，点「建立主控会话」

3. 被控端要允许屏幕录制与输入控制（系统会弹窗，同意即可）。


三、双击没反应 / 提示缺少 DLL
-----------------------------
Windows 10/11 多数机器已自带 VC++ 运行库，正常情况不用管。

若提示「找不到 MSVCP140.dll」或「VCRUNTIME140.dll」：
   进入 if-missing-vcruntime 目录，双击 vc_redist.x64.exe 装一次，
   然后重新启动程序。这是微软官方运行库安装包，装完不需要重启。


四、已知限制
------------
- 被控端窗口在前台时，注入的鼠标键盘会打在程序自己身上（系统机制，不是缺陷）。
  被控端请把窗口最小化，或切到别的应用。
- 被控端不能睡眠，否则连不上。Windows 上：
       powercfg /change standby-timeout-ac 0
- 公司网络若只放行 80/443，可能连不上信令；改用 Tailscale 组网可绕开。
- 信令是明文 ws://，只在可信网络里用；跨公网请给服务器设 AUTH_TOKEN。


五、卸载
--------
删掉这个文件夹即可，不写注册表、不留后台服务。
"""
with open(os.path.join(pkg, "README-zh.txt"), "wb") as f:
    f.write(b"\xef\xbb\xbf" + readme.replace("\n", "\r\n").encode("utf-8"))
PY

# ---- 4. 打包 ----
echo "==> 打 zip"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
( cd "$WORK" && zip -r -q "$OUT" "RemoteDesk-Windows" )

# ---- 5. 自检 ----
echo
echo "==> 自检"
fail=0
check_present() {
  if unzip -Z1 "$OUT" | grep -qxF "RemoteDesk-Windows/$1"; then
    echo "    ✓ $1"
  else
    echo "    ✗ 缺 $1"; fail=1
  fi
}
for f in remotedesk.exe flutter_windows.dll libwebrtc.dll flutter_webrtc_plugin.dll \
         data/app.so data/icudtl.dat START.cmd README-zh.txt \
         if-missing-vcruntime/vc_redist.x64.exe; do
  check_present "$f"
done

python3 - "$OUT" <<'PY'
import subprocess, sys, zipfile
z = sys.argv[1]
names = subprocess.run(["unzip", "-Z1", z], capture_output=True, text=True).stdout.splitlines()
bad = [n for n in names if any(ord(c) > 127 for c in n)]
print(f"    {'✓' if not bad else '✗'} 文件名全 ASCII（{len(names)} 条目）" if not bad
      else f"    ✗ 有 {len(bad)} 个非 ASCII 文件名，Windows 解压可能乱码")
with zipfile.ZipFile(z) as zf:
    cmd = zf.read("RemoteDesk-Windows/START.cmd")
    print(f"    {'✓' if not cmd.startswith(b'\xef\xbb\xbf') else '✗'} START.cmd 无 BOM")
    print(f"    {'✓' if all(b < 128 for b in cmd) else '✗'} START.cmd 纯 ASCII")
    lf = cmd.count(b"\n") - cmd.count(b"\r\n")
    print(f"    {'✓' if lf == 0 else '✗'} START.cmd 全 CRLF（裸 LF {lf} 处）")
    rd = zf.read("RemoteDesk-Windows/README-zh.txt")
    print(f"    {'✓' if rd.startswith(b'\xef\xbb\xbf') else '✗'} README 带 UTF-8 BOM")
    try:
        rd.decode("utf-8"); print("    ✓ README 可解码为 UTF-8")
    except UnicodeDecodeError:
        print("    ✗ README 不是合法 UTF-8")
PY

echo
echo "完成：${OUT}（$(du -h "$OUT" | cut -f1)，解压后 $(du -sh "$PKG" | cut -f1)）"
[ "$fail" -eq 0 ] || { echo "有自检项未通过，见上" >&2; exit 1; }
