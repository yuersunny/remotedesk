#!/usr/bin/env bash
# 把仓库推到 GitHub 并发布 Release。
#
# 前置：先 `gh auth login`（GitHub.com → HTTPS → 用浏览器登录）。
# 用法：./scripts/publish-github.sh [仓库名] [版本号]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-remotedesk}"
VERSION="${2:-1.0.7}"
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
# 本地提交的邮箱是占位的 yushundong@localhost，GitHub 认不出来（提交不会算到账号下、
# 也没有头像）。.mailmap 只影响显示，不改写历史——比再跑一次 filter-branch 安全。
MAILMAP="$ROOT/.mailmap"
WANT="yushundong <$OWNER@users.noreply.github.com> <yushundong@localhost>"
if [ ! -f "$MAILMAP" ] || ! grep -qF "$OWNER@users.noreply.github.com" "$MAILMAP"; then
  printf '%s\n' "$WANT" > "$MAILMAP"
  git add .mailmap
  git -c user.name="yushundong" -c user.email="$OWNER@users.noreply.github.com" \
      commit -q -m "加 .mailmap：让历史里的占位邮箱归属到 GitHub 账号

本地提交一直用 yushundong@localhost，GitHub 认不出这是谁——提交列表里没有头像、
也不算进贡献。.mailmap 只改显示，不改写历史。"
  echo "==> 已加 .mailmap"
fi

# ---- 3. 建仓库并推送 --------------------------------------------------------
if git remote get-url origin >/dev/null 2>&1; then
  echo "==> 已有 origin：$(git remote get-url origin)"
  git push -u origin HEAD
elif gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "==> 远端仓库已存在，直接关联并推送"
  git remote add origin "https://github.com/$OWNER/$REPO.git"
  git push -u origin HEAD
else
  echo "==> 新建公开仓库 $OWNER/$REPO 并推送"
  gh repo create "$REPO" --public --source=. --remote=origin --push \
    --description "跨平台远程桌面（macOS / Windows / Android）：局域网点一下就连，WebRTC 直连 + 双向剪贴板"
fi

# ---- 4. Release -------------------------------------------------------------
ASSETS=()
for f in \
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
| macOS 13+ | \`RemoteDesk-$VERSION-macos-universal.dmg\`（Intel + Apple Silicon 通用） |
| Android 7.0+ | \`RemoteDesk-$VERSION-android-arm64.apk\`（手机只能当主控） |
| Windows | 无预编译包，见下方说明 |

装完先看 [GETTING-STARTED.md](GETTING-STARTED.md)。macOS 必须手动给「屏幕录制」和
「辅助功能」两个权限，不给的话要么黑屏、要么画面正常但点不动。

## 全量包

\`RemoteDesk-$VERSION-full.zip\` = 三端产物 + 完整源码（含 git 历史）+ Windows 一键编译套件。

## Windows 为什么没有 exe

本项目在 macOS 上开发，Flutter 不能交叉编译到 Windows（要在 Windows 上跑 MSVC）。
全量包的 \`installers/windows/\` 里有两条路：浏览器版免安装（只能当主控），
或跑一次一键脚本编译原生版（约 20 分钟，装 VS Build Tools + Flutter）。

## 这一版

双向剪贴板同步（纯文本，上限 160 KB）；修 macOS 的 ⌘ 在 Windows 上被当成 Win 键
（⌘C 变成 Win+C）导致「从 Mac 复制到 Windows 不生效」。

**注意**：跨机剪贴板要两端都是这一版才生效。

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
