import ApplicationServices
import Cocoa
import FlutterMacOS

/// Native input injection for the macOS target (M2).
///
/// The counterpart of `windows/runner/input_injector.cpp`: same
/// `remotedesk/input` method channel, same normalised pointer coordinates, same
/// platform-neutral wire key ids from `app/lib/src/input_event.dart`.
///
/// Four macOS-specific facts drive the implementation:
///
/// * **Synthetic events need the Accessibility permission.** Without it
///   `CGEventPost` returns happily and nothing happens — indistinguishable from
///   a working injector aiming at the wrong place. So `available` is reported as
///   the real permission state, and `requestAccessibility` is the only thing
///   that shows the system prompt (the controller role must never see it).
/// * **Positions are Quartz global points**, origin at the top-left of the main
///   display, y growing *downward*. This is not AppKit's bottom-left space, and
///   a multi-monitor layout can start at negative coordinates — hence the union
///   of all display bounds rather than `NSScreen.main.frame`.
/// * **Modifier state rides in the event flags, not in the event stream.**
///   Posting a Shift key-down does not make a later synthetic `a` arrive as `A`;
///   every event has to carry the flags itself.
/// * **Dragging is its own event type.** Moving with a button held must post
///   `leftMouseDragged` and friends, or selection and window dragging silently
///   turn into inert hover.
enum MacInputInjector {

  // MARK: - Registration

  private static var channel: FlutterMethodChannel?
  private static var promptedForAccessibility = false

  /// Holds the channel for the process lifetime, mirroring the Windows side:
  /// the engine may outlive the window during shutdown.
  static func register(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let channel = FlutterMethodChannel(name: "remotedesk/input", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "screenInfo":
        result(screenInfo())
      case "pointer":
        handlePointer(call.arguments, result: result)
      case "wheel":
        handleWheel(call.arguments, result: result)
      case "key":
        handleKey(call.arguments, result: result)
      case "requestAccessibility":
        result(requestAccessibility())
      case "pointerSelfTest":
        result(pointerSelfTest())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    // Proves the channel reached the native side even when the UI cannot be
    // looked at; also the first place to check for a missing grant.
    log("input channel registered (trusted=\(trusted ? 1 : 0), "
        + "bundle=\(Bundle.main.bundlePath), pid=\(ProcessInfo.processInfo.processIdentifier))")
  }

  // MARK: - Diagnostics

  /// Log file for this build: `~/Library/Logs/RemoteDesk/input.log`.
  ///
  /// `NSLog` alone is not enough to answer "did the grant take effect": for a
  /// windowed app it goes to the unified log, which `log show` cannot read
  /// without extra entitlements, and it never reaches stderr even when the
  /// bundle is launched through `open --stdout`. So the only observable was
  /// the UI - exactly what was unreadable when the permission question came
  /// up. A plain file on disk always works.
  private static let logURL: URL? = {
    let fm = FileManager.default
    guard let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = base.appendingPathComponent("Logs/RemoteDesk", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("input.log")
  }()

  private static func log(_ message: String) {
    NSLog("%@", "[remotedesk] \(message)")
    guard let url = logURL else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  // MARK: - Permission

  /// True when this process may post events into other applications.
  private static var trusted: Bool { AXIsProcessTrusted() }

  /// Ask the system to show the Accessibility prompt. Returns the state at the
  /// time of the call — the user usually needs to visit System Settings, so the
  /// caller should not expect `true` straight away.
  private static func requestAccessibility() -> Bool {
    if trusted { return true }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trustedNow = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    promptedForAccessibility = true
    log("accessibility prompt shown (trusted=\(trustedNow ? 1 : 0))")
    return trustedNow
  }

  /// Move the real cursor a few points and read it back.
  ///
  /// This is the only honest answer to "does injection work on this machine":
  /// it exercises the same permission and the same `CGEventPost` path a remote
  /// pointer move takes, and unlike a log line it cannot succeed by accident.
  private static func pointerSelfTest() -> [String: Any] {
    guard trusted else {
      log("self-test skipped: AXIsProcessTrusted() == false")
      return [
        "trusted": false,
        "moved": false,
        "message": "还没有辅助功能权限，注入不会生效",
      ]
    }
    let source = CGEventSource(stateID: .hidSystemState)
    let origin = CGEvent(source: source)?.location ?? .zero
    let union = displayUnion()
    // Stay inside the desktop: probing 3 pt to the right of the right edge is
    // clamped by the system and would look like a failure.
    let dx: CGFloat = origin.x + 3 < union.maxX ? 3 : -3
    let probe = CGPoint(x: origin.x + dx, y: origin.y)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                 mouseCursorPosition: probe, mouseButton: .left))
    usleep(60_000)
    let after = CGEvent(source: source)?.location ?? .zero
    // Put the cursor back where the user left it.
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                 mouseCursorPosition: origin, mouseButton: .left))
    let moved = abs(after.x - origin.x) > 0.5 || abs(after.y - origin.y) > 0.5
    log("self-test origin=\(Int(origin.x)),\(Int(origin.y)) "
        + "after=\(Int(after.x)),\(Int(after.y)) moved=\(moved ? 1 : 0)")
    return [
      "trusted": true,
      "moved": moved,
      "origin": "\(Int(origin.x)),\(Int(origin.y))",
      "after": "\(Int(after.x)),\(Int(after.y))",
      "message": moved
        ? "注入自检通过：光标动了（本机已可被远程控制）"
        : "注入自检失败：有权限但光标没有移动，事件被系统吞掉了",
    ]
  }

  // MARK: - Geometry

  /// Union of every active display, in Quartz global points.
  private static func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
  }

  private static func displayUnion() -> CGRect {
    let ids = activeDisplayIDs()
    guard !ids.isEmpty else { return fallbackBounds() }
    var union = CGRect.null
    for id in ids {
      union = union.union(CGDisplayBounds(id))
    }
    return union.isNull ? fallbackBounds() : union
  }

  private static func fallbackBounds() -> CGRect {
    let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    return CGRect(x: 0, y: 0, width: size.width, height: size.height)
  }

  private static func screenInfo() -> [String: Any] {
    let union = displayUnion()
    let available = trusted
    let scale = NSScreen.main?.backingScaleFactor ?? 1.0
    return [
      // Reported in points, the space the injector actually uses. On a Retina
      // panel this equals the "looks like" resolution the user sees in System
      // Settings, not the backing-pixel count.
      "available": available,
      "width": Int(union.width.rounded()),
      "height": Int(union.height.rounded()),
      "scale": Double(scale),
      "trusted": available,
      "displays": activeDisplayIDs().count,
      "reason": available
        ? ""
        // No "restart the app" here on purpose: Dart re-probes every 15 s, so
        // ticking the box takes effect without a relaunch.
        : "需要「系统设置 › 隐私与安全性 › 辅助功能」中勾选 remotedesk（授权后 15 秒内自动生效）",
    ]
  }

  /// Normalised [0,1] over the whole desktop → Quartz global point.
  private static func point(x: Double, y: Double) -> CGPoint {
    let union = displayUnion()
    // Extent-1 matches the Windows injector: normalised 1.0 has to land on the
    // last addressable pixel, not one past it.
    let width = max(union.width - 1, 0)
    let height = max(union.height - 1, 0)
    let cx = x.isFinite ? min(max(x, 0), 1) : 0
    let cy = y.isFinite ? min(max(y, 0), 1) : 0
    return CGPoint(x: union.minX + cx * width, y: union.minY + cy * height)
  }

  // MARK: - Pointer

  private static var pressedWireButton: Int?
  private static var clickState = 1
  private static var lastClickAt: TimeInterval = 0
  private static var lastClickPoint = CGPoint.zero

  private static func handlePointer(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "expected a map argument", details: nil))
      return
    }
    let action = int(args["action"])
    let target = point(x: double(args["x"]), y: double(args["y"]))

    if action == 0 {
      moveCursor(to: target)
      result(nil)
      return
    }

    let wire = int(args["button"])
    let pressed = action == 1
    // A press must find the cursor already there; the click event carries the
    // position, but a hover-only move keeps apps' tracking areas honest.
    if bool(args["moved"]) {
      moveCursor(to: target)
    }
    postButton(wire: wire, pressed: pressed, at: target)
    result(nil)
  }

  private static func moveCursor(to target: CGPoint) {
    let type: CGEventType
    let button: CGMouseButton
    switch pressedWireButton {
    case 0:
      type = .leftMouseDragged
      button = .left
    case 1:
      type = .otherMouseDragged
      button = .center
    case 2:
      type = .rightMouseDragged
      button = .right
    default:
      type = .mouseMoved
      button = .left
    }
    post(CGEvent(mouseEventSource: source, mouseType: type,
                 mouseCursorPosition: target, mouseButton: button))
  }

  private static func postButton(wire: Int, pressed: Bool, at target: CGPoint) {
    let type: CGEventType
    let button: CGMouseButton
    switch wire {
    case 0:
      type = pressed ? .leftMouseDown : .leftMouseUp
      button = .left
    case 1:
      type = pressed ? .otherMouseDown : .otherMouseUp
      button = .center
    case 2:
      type = pressed ? .rightMouseDown : .rightMouseUp
      button = .right
    default:
      return
    }

    if pressed {
      // Double-click has to be stated as clickState 2 — a second lone click is
      // two single clicks, and every "open by double-click" lands as a rename.
      let now = ProcessInfo.processInfo.systemUptime
      let nearLast = hypot(target.x - lastClickPoint.x, target.y - lastClickPoint.y) <= 4
      if nearLast && now - lastClickAt <= NSEvent.doubleClickInterval {
        clickState = clickState >= 3 ? 1 : clickState + 1
      } else {
        clickState = 1
      }
      lastClickAt = now
      lastClickPoint = target
      pressedWireButton = wire
    } else if pressedWireButton == wire {
      pressedWireButton = nil
    }

    guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: target, mouseButton: button) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    post(event)
  }

  // MARK: - Wheel

  private static func handleWheel(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "expected a map argument", details: nil))
      return
    }
    // The wire carries Windows' WHEEL_DELTA units (120 per notch, positive =
    // content up). macOS pixel scrolling has no such constant: 120 wire units
    // should move roughly three text lines, so a notch becomes ~60 px.
    let pixelsPerDelta = 0.5
    let dy = Int32((double(args["dy"]) * pixelsPerDelta).rounded())
    let dx = Int32((double(args["dx"]) * pixelsPerDelta).rounded())
    if dx == 0 && dy == 0 {
      result(nil)
      return
    }
    let count = UInt32(dy != 0 && dx != 0 ? 2 : 1)
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                             wheelCount: count, wheel1: dy, wheel2: dx, wheel3: 0) else {
      result(nil)
      return
    }
    // Continuous signals make AppKit track momentum/precision instead of
    // snapping to whole "clicks".
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.location = lastCursorPoint()
    post(event)
    result(nil)
  }

  /// Scroll events land wherever the cursor is; CGEvent defaults to (0,0) when
  /// the position is not set, which scrolls the top-left window instead.
  private static func lastCursorPoint() -> CGPoint {
    CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: 0)
  }

  // MARK: - Keys

  private static var pressedModifiers = Set<Int>()

  private static func handleKey(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "expected a map argument", details: nil))
      return
    }
    postKey(wire: int(args["id"]), down: bool(args["down"]))
    result(nil)
  }

  private static func postKey(wire: Int, down: Bool) {
    guard let code = keyCodes[wire] else { return }
    // Update the modifier set *before* building the event, exactly like a real
    // keyboard: the Shift key-down itself already reports maskShift.
    if familyMasks[wire] != nil {
      if down {
        pressedModifiers.insert(wire)
      } else {
        pressedModifiers.remove(wire)
      }
    }
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
      return
    }
    event.flags = currentFlags()
    post(event)
  }

  private static func currentFlags() -> CGEventFlags {
    var flags = CGEventFlags()
    for wire in pressedModifiers {
      if let family = familyMasks[wire] { flags.insert(family) }
      // Device-dependent bits let an app tell left from right — without them
      // Right-Option produces the same character as Left-Option.
      if let bits = deviceMasks[wire] { flags.insert(CGEventFlags(rawValue: bits)) }
    }
    // Caps Lock is not on the wire; read it back so remote typing obeys it.
    if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) {
      flags.insert(.maskAlphaShift)
    }
    return flags
  }

  /// Same standard modifier for both sides of the keyboard.
  private static let familyMasks: [Int: CGEventFlags] = [
    110: .maskShift, 111: .maskShift,
    112: .maskControl, 113: .maskControl,
    114: .maskAlternate, 115: .maskAlternate,
    116: .maskCommand, 117: .maskCommand,
  ]

  /// `NX_DEVICExxxKEYMASK` from IOKit's ev_keymap.h, spelled out so this file
  /// needs no IOKit import.
  private static let deviceMasks: [Int: UInt64] = [
    110: 0x0000_0002,  // NX_DEVICELSHIFTKEYMASK
    111: 0x0000_0004,  // NX_DEVICERSHIFTKEYMASK
    112: 0x0000_0001,  // NX_DEVICELCTLKEYMASK
    113: 0x0000_2000,  // NX_DEVICERCTLKEYMASK
    114: 0x0000_0020,  // NX_DEVICELALTKEYMASK
    115: 0x0000_0040,  // NX_DEVICERALTKEYMASK
    116: 0x0000_0008,  // NX_DEVICELCMDKEYMASK
    117: 0x0000_0010,  // NX_DEVICERCMDKEYMASK
  ]

  /// Wire id → ANSI virtual key code (`kVK_*`). Keep in step with
  /// `enum InputKey`; `scripts/check-keymap.py` enforces that.
  ///
  /// These are hardware codes, not characters: what a key *produces* is decided
  /// by the layout plus the flags set above, which is why Shift+A yields "A"
  /// without a single character table here.
  private static let keyCodes: [Int: CGKeyCode] = [
    1: 0x00,    // KeyA
    2: 0x0B,    // KeyB
    3: 0x08,    // KeyC
    4: 0x02,    // KeyD
    5: 0x0E,    // KeyE
    6: 0x03,    // KeyF
    7: 0x05,    // KeyG
    8: 0x04,    // KeyH
    9: 0x22,    // KeyI
    10: 0x26,   // KeyJ
    11: 0x28,   // KeyK
    12: 0x25,   // KeyL
    13: 0x2E,   // KeyM
    14: 0x2D,   // KeyN
    15: 0x1F,   // KeyO
    16: 0x23,   // KeyP
    17: 0x0C,   // KeyQ
    18: 0x0F,   // KeyR
    19: 0x01,   // KeyS
    20: 0x11,   // KeyT
    21: 0x20,   // KeyU
    22: 0x09,   // KeyV
    23: 0x0D,   // KeyW
    24: 0x07,   // KeyX
    25: 0x10,   // KeyY
    26: 0x06,   // KeyZ

    40: 0x12,   // Digit1
    41: 0x13,   // Digit2
    42: 0x14,   // Digit3
    43: 0x15,   // Digit4
    44: 0x17,   // Digit5
    45: 0x16,   // Digit6
    46: 0x1A,   // Digit7
    47: 0x1C,   // Digit8
    48: 0x19,   // Digit9
    49: 0x1D,   // Digit0

    60: 0x24,   // Enter
    61: 0x35,   // Escape
    62: 0x33,   // Backspace
    63: 0x30,   // Tab
    64: 0x31,   // Space
    65: 0x1B,   // Minus
    66: 0x18,   // Equal
    67: 0x21,   // BracketLeft
    68: 0x1E,   // BracketRight
    69: 0x2A,   // Backslash
    70: 0x29,   // Semicolon
    71: 0x27,   // Quote
    72: 0x32,   // Backquote
    73: 0x2B,   // Comma
    74: 0x2F,   // Period
    75: 0x2C,   // Slash
    76: 0x39,   // CapsLock

    80: 0x7A,   // F1
    81: 0x78,   // F2
    82: 0x63,   // F3
    83: 0x76,   // F4
    84: 0x60,   // F5
    85: 0x61,   // F6
    86: 0x62,   // F7
    87: 0x64,   // F8
    88: 0x65,   // F9
    89: 0x6C,   // F10
    90: 0x67,   // F11
    91: 0x6D,   // F12

    92: 0x72,   // Insert (Help)
    93: 0x73,   // Home
    94: 0x74,   // PageUp
    95: 0x75,   // Delete (forward delete)
    96: 0x77,   // End
    97: 0x79,   // PageDown
    98: 0x7C,   // ArrowRight
    99: 0x7B,   // ArrowLeft
    100: 0x7D,  // ArrowDown
    101: 0x7E,  // ArrowUp

    110: 0x38,  // ShiftLeft
    111: 0x3C,  // ShiftRight
    112: 0x3B,  // ControlLeft
    113: 0x3E,  // ControlRight
    114: 0x3A,  // AltLeft
    115: 0x3D,  // AltRight
    116: 0x37,  // MetaLeft
    117: 0x36,  // MetaRight
  ]

  // MARK: - Posting

  private static let source = CGEventSource(stateID: .hidSystemState)

  private static func post(_ event: CGEvent?) {
    guard let event else { return }
    // `.cghidEventTap` is the closest thing to real hardware: below it, apps
    // that use an event tap of their own still see the events as native input.
    event.post(tap: .cghidEventTap)
  }

  // MARK: - Argument coercion
  //
  // StandardMethodCodec hands numbers over as Int or Double depending on how
  // Dart boxed them; the Windows injector has the same two casts.

  private static func double(_ value: Any?) -> Double {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return 0
  }

  private static func int(_ value: Any?) -> Int {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d.rounded()) }
    if let n = value as? NSNumber { return n.intValue }
    return 0
  }

  private static func bool(_ value: Any?) -> Bool {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return false
  }
}
