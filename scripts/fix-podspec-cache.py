#!/usr/bin/env python3
"""Backfill CocoaPods trunk specs that this network cannot reach.

Why this exists
---------------
`pod install` fetches specs from https://cdn.cocoapods.org, which for a small
number of pods redirects (or falls back) to https://raw.githubusercontent.com.
On this machine that host is unreachable — every request times out after ~12s
and the install aborts. cdn.jsdelivr.net serves the same mirror and *is*
reachable, so we copy the missing `.podspec.json` files straight into the local
trunk cache.

Usage
-----
    python3 scripts/fix-podspec-cache.py /tmp/macbuild.log

Reads the build log, finds every "CDN: trunk URL couldn't be downloaded: <url>"
line, downloads each from jsdelivr into ~/.cocoapods/repos/trunk, and reports
what it did. Safe to run repeatedly; existing files are left alone unless
--force is passed.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

CACHE = Path.home() / ".cocoapods" / "repos" / "trunk"
RAW = "https://raw.githubusercontent.com/CocoaPods/Specs/master/"
MIRROR = "https://cdn.jsdelivr.net/cocoa/"

LINE = re.compile(r"CDN: trunk URL couldn't be downloaded: (\S+)")


def curl(url: str, dest: Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items()
           if k.lower() not in {"http_proxy", "https_proxy", "all_proxy"}}
    proc = subprocess.run(
        ["curl", "-sS", "--max-time", "30", "-o", str(dest),
         "-w", "%{http_code}", url],
        capture_output=True, text=True, env=env,
    )
    code = (proc.stdout or "").strip()
    if code != "200":
        print(f"    FAIL {code or 'no-code'} {url}")
        if dest.exists() and dest.stat().st_size == 0:
            dest.unlink()
        return False
    return True


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    force = "--force" in sys.argv
    if not args:
        print(__doc__)
        return 2

    log = Path(args[0])
    if not log.exists():
        print(f"log not found: {log}")
        return 2

    urls = sorted(set(LINE.findall(log.read_text(encoding="utf-8", errors="replace"))))
    if not urls:
        print("log 里没有失败的 podspec —— 无需补齐")
        return 0

    print(f"发现 {len(urls)} 个下载失败的 podspec")
    fixed = skipped = failed = 0

    for url in urls:
        if not url.startswith(RAW):
            print(f"  跳过（非 raw 源）: {url}")
            skipped += 1
            continue
        rel = url[len(RAW):]
        dest = CACHE / rel
        if dest.exists() and dest.stat().st_size > 0 and not force:
            print(f"  已存在，跳过: {rel}")
            skipped += 1
            continue
        print(f"  补: {rel}")
        if curl(MIRROR + rel, dest):
            print(f"    ok {dest.stat().st_size} bytes")
            fixed += 1
        else:
            failed += 1

    print(f"\n补齐 {fixed} · 跳过 {skipped} · 失败 {failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
