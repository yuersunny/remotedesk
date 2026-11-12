#!/usr/bin/env bash
# 把仓库推到 GitHub 并发布 Release。
#
# 前置：先 `gh auth login`（GitHub.com → HTTPS → 用浏览器登录）。
# 用法：./scripts/publish-github.sh [仓库名] [版本号]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-remotedesk}"
DEFAULT_VER="$(awk '/^version:/{print $2}' "$ROOT/app/pubspec.yaml")"
DEFAULT_VER="${DEFAULT_VER%%+*}"
VERSION="${2:-$DEFAULT_VER}"
TAG="v$VERSION"
cd "$ROOT"

# ---- 1. 认证 ----------------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
  echo "[x] 还没登录 GitHub。先跑：gh auth login" >&2
  echo "    选 GitHub.com → HTTPS → Login with a web browser" >&2
  exit 1
fi
OWNER="$(gh api user --jq .login)"
echo "==> 已登录：$OWNER"

# ---- 2. 让提交挂到这个账号下 ------------------------------------------------
# 本地提交的邮箱是占位形式（<用户名>@localhost），GitHub 认不出来（提交不会算到
# 账号下、也没有头像）。.mailmap 只影响显示，不改写历史——比再跑一次
# filter-branch 安全。
# 名字和占位邮箱从本地 git 配置读，脚本因此不绑定某个具体账号。
LOCAL_NAME="$(git config user.name || true)"
LOCAL_EMAIL="$(git config user.email || true)"
LOCAL_NAME="${LOCAL_NAME:-$OWNER}"
LOCAL_EMAIL="${LOCAL_EMAIL:-$OWNER@localhost}"
MAILMAP="$ROOT/.mailmap"
WANT="$LOCAL_NAME <$OWNER@users.noreply.github.com> <$LOCAL_EMAIL>"
if [ ! -f "$MAILMAP" ] || ! grep -qF "$OWNER@users.noreply.github.com" "$MAILMAP"; then
  printf '%s\n' "$WANT" > "$MAILMAP"
  git add .mailmap
  git -c user.name="$LOCAL_NAME" -c user.email="$OWNER@users.noreply.github.com" \
      commit -q -m "加 .mailmap：让历史里的占位邮箱归属到 GitHub 账号

本地提交一直用占位邮箱（<用户名>@localhost），GitHub 认不出这是谁——提交
列表里没有头像、也不算进贡献。.mailmap 只改显示，不改写历史。"
  echo "==> 已加 .mailmap"
fi

# ---- 3. 建仓库并推送 --------------------------------------------------------
# 走 SSH 而不是 HTTPS。有些网络能连通 api.github.com，但 github.com:443 被整段
# 阻断——那种环境下 HTTPS 推送会卡死在握手，而 SSH 的 22（或 ssh.github.com:443）
# 往往还通。gh 建仓库 / 发 Release 走 API，不受影响。
SSH_URL="git@github.com:$OWNER/$REPO.git"

# 注意：认证成功时 ssh -T 的退出码是 1（GitHub 不提供 shell），不能拿退出码判断。
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -T git@github.com 2>&1 \
     | grep -q "successfully authenticated"; then
  echo "[x] git@github.com 的 SSH 认证没通。推送必须走 SSH。" >&2
  echo "    三步挂上公钥（token 带 admin:public_key 时可自动完成）：" >&2
  echo "      test -f ~/.ssh/id_ed25519_remotedesk || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_remotedesk" >&2
  echo "      gh api user/keys -X POST -f title=\"\$(hostname)\" -f key=\"\$(cat ~/.ssh/id_ed25519_remotedesk.pub)\"" >&2
  echo "    再在 ~/.ssh/config 里给 github.com 指定 IdentityFile，然后重跑本脚本。" >&2
  exit 1
fi

if git remote get-url origin >/dev/null 2>&1; then
  echo "==> 已有 origin，统一改成 SSH"
  git remote set-url origin "$SSH_URL"
elif gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "==> 远端仓库已存在，直接关联"
  git remote add origin "$SSH_URL"
else
  echo "==> 新建公开仓库 $OWNER/$REPO"
  # 不要用 gh repo create --push：它会按 gh 里配的协议走 HTTPS。
  gh repo create "$REPO" --public \
    --description "跨平台远程桌面（macOS / Windows / Android）：局域网点一下就连，WebRTC 直连 + 双向剪贴板"
  git remote add origin "$SSH_URL"
fi
git push -u origin HEAD

# ---- 4. Release -------------------------------------------------------------
# GitHub 的 Release 资产名不支持非 ASCII：中文会被洗成连字符，
# "RemoteDesk-<版本>-使用说明书.pdf" 上传后中文会被洗掉，只剩一串连字符。
# 所以上传前复制一份英文名的副本，原文件留着（打包进 zip 时仍用中文名）。
MANUAL_UP="dist/RemoteDesk-$VERSION-manual-zh.pdf"
if [ -f "dist/RemoteDesk-$VERSION-使用说明书.pdf" ]; then
  cp -f "dist/RemoteDesk-$VERSION-使用说明书.pdf" "$MANUAL_UP"
fi

ASSETS=()
for f in \
  "$MANUAL_UP" \
  "dist/RemoteDesk-$VERSION-macos-universal.dmg" \
  "dist/RemoteDesk-$VERSION-android-arm64.apk" \
  "dist/RemoteDesk-$VERSION-full.zip"; do
  [ -f "$f" ] && ASSETS+=("$f")
done
if [ ${#ASSETS[@]} -eq 0 ]; then
  echo "[x] 没有可发布的产物，先跑 pack-release.sh" >&2
  exit 1
fi

NOTES="$(mktemp)"
cat > "$NOTES" <<TXT
## 直接用

| 平台 | 文件 |
|---|---|
| 说明书 | \`RemoteDesk-$VERSION-manual-zh.pdf\`（可打印，**建议先看**） |
| macOS 13+ | \`RemoteDesk-$VERSION-macos-universal.dmg\`（Intel + Apple Silicon 通用） |
| Android 7.0+ | \`RemoteDesk-$VERSION-android-arm64.apk\`（手机只能当主控） |
| Windows | 无预编译包，见下方说明 |

装完先看说明书 PDF。macOS 必须手动给「屏幕录制」和「辅助功能」两个权限，
不给的话要么黑屏、要么画面正常但点不动。

## 全量包

\`RemoteDesk-$VERSION-full.zip\` = 三端产物 + 完整源码（含 git 历史）+ Windows 一键编译套件。

## Windows 为什么没有 exe

本项目在 macOS 上开发，Flutter 不能交叉编译到 Windows（要在 Windows 上跑 MSVC）。
全量包的 \`installers/windows/\` 里有两条路：浏览器版免安装（只能当主控），
或跑一次一键脚本编译原生版（约 20 分钟，装 VS Build Tools + Flutter）。

## 这一版

- **一台被控机可以同时被多台设备连接**。被控端列出「N 台设备正在看这台电脑」，
  可逐个「断开」。多人同时操作时鼠标会互相抢，要稳定操作只留一个人。
- **被控端顶部写明「能不能从外面连」**：绿色「出门也能连」/ 橙色「只能在同一个
  Wi-Fi 里连」，点「怎么连」展开三步 Tailscale 引导。人在外面手机用配对码即可。
- **手机端**：放大后右下角常驻「还原」；连不上时可「停止等待」回列表换一台，
  不用退出 App；拨号 25 秒超时自动判失败。
- 修 Windows 被控端关掉显示器后画面全黑、断开重连也回不来。
- 电脑端界面收敛：「高级设置」改「更多设置」并默认折叠，去掉实现术语。

说明书同步更新（新增 4.4 网络状态条、5.6 多台设备同时看、手机端退出与还原）。

这一版没有改动通信协议，旧版仍能连上；但**多设备同时连、状态条、手机端还原与停止**
这些新行为，要两端都更新到这一版才有。

详见 [CHANGELOG.md](CHANGELOG.md)。
TXT

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release $TAG 已存在，补传产物"
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  echo "==> 创建 Release $TAG"
  gh release create "$TAG" "${ASSETS[@]}" \
    --title "RemoteDesk $VERSION" \
    --notes-file "$NOTES"
fi
rm -f "$NOTES"

echo
echo "==> 完成"
echo "    仓库：https://github.com/$OWNER/$REPO"
echo "    发行：https://github.com/$OWNER/$REPO/releases/tag/$TAG"
