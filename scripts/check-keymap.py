#!/usr/bin/env python3
"""Cross-check the three key tables that must stay in step.

`app/lib/src/input_event.dart` defines the wire ids (`enum InputKey`), and each
platform injector maps those ids to its own native key code:

* `app/windows/runner/input_injector.cpp` — `VkForId` → Windows virtual keys
* `app/macos/Runner/InputInjector.swift`  — `keyCodes` → `kVK_*` codes

Neither native file can import the Dart table, so drift is silent: an id present
in Dart but missing natively is a key that simply does nothing, and an id native
code handles with no Dart counterpart is unreachable.

Run this after touching any table:

    python3 scripts/check-keymap.py

Exit code 0 = all tables agree; 1 = drift (details on stderr).
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DART = ROOT / 'app/lib/src/input_event.dart'
CPP = ROOT / 'app/windows/runner/input_injector.cpp'
SWIFT = ROOT / 'app/macos/Runner/InputInjector.swift'

DART_ENTRY = re.compile(
    # Trailing `,` or `;`: the last enum entry ends the declaration.
    r'^\s*(\w+)\(\s*(\d+)\s*,\s*\'([^\']+)\'\s*,\s*(0x[0-9A-Fa-f]+|\d+)\s*\)\s*[,;]',
    re.MULTILINE,
)
CPP_RANGE = re.compile(r'if \(id >= (\d+) && id <= (\d+)\)')
CPP_SWITCH = re.compile(r'case (\d+):')
CPP_VK = re.compile(
    r'case (\d+):\s*return (VK_\w+|\'[^\']+\'\s*[+-]\s*\(\s*id\s*-\s*\d+\s*\)|\'[0-9A-Z]\')'
)
# The trailing comment is the Dart code name; anything after it is free-form
# prose ("// Insert (Help)"), so the name is only the first token.
SWIFT_ENTRY = re.compile(r'^\s*(\d+):\s*(0x[0-9A-Fa-f]{2}),\s*//\s*(\S+)', re.MULTILINE)


def dart_keys() -> dict[int, tuple[str, str]]:
    text = DART.read_text(encoding='utf-8')
    start = text.index('enum InputKey {')
    end = text.index('\n}', start)
    body = text[start:end]
    keys: dict[int, tuple[str, str]] = {}
    for name, ident, code, _hid in DART_ENTRY.findall(body):
        wire = int(ident)
        if wire in keys:
            sys.exit(f'duplicate wire id {wire} in Dart: {keys[wire][0]} / {name}')
        keys[wire] = (name, code)
    if not keys:
        sys.exit('parsed no keys from input_event.dart')
    return keys


def cpp_ids() -> tuple[set[int], dict[int, str]]:
    text = CPP.read_text(encoding='utf-8')
    start = text.index('WORD VkForId(int id) {')
    end = text.index('\n}', start)
    body = text[start:end]

    ids: set[int] = set()
    for lo, hi in CPP_RANGE.findall(body):
        ids.update(range(int(lo), int(hi) + 1))

    explicit: dict[int, str] = {}
    for ident, vk in CPP_VK.findall(body):
        explicit[int(ident)] = vk
        ids.add(int(ident))
    return ids, explicit


def swift_ids() -> dict[int, tuple[str, str]]:
    text = SWIFT.read_text(encoding='utf-8')
    start = text.index('private static let keyCodes: [Int: CGKeyCode] = [')
    end = text.index('\n  ]', start)
    body = text[start:end]
    entries: dict[int, tuple[str, str]] = {}
    for ident, code, label in SWIFT_ENTRY.findall(body):
        wire = int(ident)
        if wire in entries:
            sys.exit(f'duplicate wire id {wire} in Swift keyCodes')
        entries[wire] = (code, label)
    if not entries:
        sys.exit('parsed no keys from InputInjector.swift')
    return entries


def main() -> int:
    dart = dart_keys()
    cpp, explicit = cpp_ids()
    swift = swift_ids()
    problems: list[str] = []

    for wire in sorted(set(dart) - cpp):
        problems.append(
            f'id {wire:3} {dart[wire][0]:14} ({dart[wire][1]}) -> no case in VkForId'
        )
    for wire in sorted(cpp - set(dart)):
        problems.append(f'id {wire:3} handled in VkForId but absent from InputKey')

    for wire in sorted(set(dart) - set(swift)):
        problems.append(
            f'id {wire:3} {dart[wire][0]:14} ({dart[wire][1]}) -> no entry in Swift keyCodes'
        )
    for wire in sorted(set(swift) - set(dart)):
        problems.append(f'id {wire:3} in Swift keyCodes but absent from InputKey')
    for wire in sorted(set(swift) & set(dart)):
        _code, label = swift[wire]
        if label != dart[wire][1]:
            problems.append(
                f'id {wire:3} named {label} in Swift but {dart[wire][1]} in Dart'
            )

    # Two wire ids landing on one native code means one of them is a copy-paste
    # slip that no compiler will catch.
    seen: dict[str, int] = {}
    for wire in sorted(swift):
        code = swift[wire][0]
        if code in seen:
            problems.append(
                f'Swift code {code} used by both id {seen[code]} and id {wire}'
            )
        else:
            seen[code] = wire

    for line in problems:
        print(f'[x] {line}', file=sys.stderr)
    if problems:
        return 1

    print(
        f'OK: {len(dart)} wire ids agree | '
        f'Windows {len(explicit)} explicit VK + {len(cpp) - len(explicit)} ranged | '
        f'macOS {len(swift)} keyCodes'
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
