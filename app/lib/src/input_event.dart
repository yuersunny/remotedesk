/// Wire protocol for the `input` DataChannel (M2).
///
/// Every event is one JSON object with a short `t` type tag; the schema lives
/// in `docs/protocol.md` (§ M2 输入通道). Two decisions matter more than the
/// rest:
///
/// 1. **Pointer positions are normalised to `[0, 1]` relative to the video
///    picture, not pixels.** The controller may letterbox the remote image
///    (aspect mismatch, resized window, HiDPI) while the target owns a
///    different resolution with its own DPI scaling. Sending a fraction of the
///    picture sidesteps all of those conversions; the target multiplies by its
///    own screen rect exactly once.
/// 2. **Keys travel as a platform-neutral [InputKey] id**, never as a raw
///    virtual-key code. The controller is often a browser (`KeyboardEvent.
///    code`) while the target is native Windows — a shared id space is the
///    only thing both ends can agree on.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Modifier bit flags carried by key events.
class InputModifier {
  const InputModifier._();

  static const int shift = 1 << 0;
  static const int control = 1 << 1;
  static const int alt = 1 << 2;
  static const int meta = 1 << 3;
}

/// Mouse buttons, matching the Web `MouseEvent.button` numbering.
class InputButton {
  const InputButton._();

  static const int left = 0;
  static const int middle = 1;
  static const int right = 2;
}

/// Platform-neutral key identifiers.
///
/// The numeric [id] is what actually goes on the wire, so **ids must never be
/// reused or reordered** — an older peer would otherwise press the wrong key.
/// New keys take the next free id; 27–39, 50–59 and 92–99 are deliberately
/// left as headroom for numpad and media keys.
enum InputKey {
  keyA(1, 'KeyA', 0x04),
  keyB(2, 'KeyB', 0x05),
  keyC(3, 'KeyC', 0x06),
  keyD(4, 'KeyD', 0x07),
  keyE(5, 'KeyE', 0x08),
  keyF(6, 'KeyF', 0x09),
  keyG(7, 'KeyG', 0x0A),
  keyH(8, 'KeyH', 0x0B),
  keyI(9, 'KeyI', 0x0C),
  keyJ(10, 'KeyJ', 0x0D),
  keyK(11, 'KeyK', 0x0E),
  keyL(12, 'KeyL', 0x0F),
  keyM(13, 'KeyM', 0x10),
  keyN(14, 'KeyN', 0x11),
  keyO(15, 'KeyO', 0x12),
  keyP(16, 'KeyP', 0x13),
  keyQ(17, 'KeyQ', 0x14),
  keyR(18, 'KeyR', 0x15),
  keyS(19, 'KeyS', 0x16),
  keyT(20, 'KeyT', 0x17),
  keyU(21, 'KeyU', 0x18),
  keyV(22, 'KeyV', 0x19),
  keyW(23, 'KeyW', 0x1A),
  keyX(24, 'KeyX', 0x1B),
  keyY(25, 'KeyY', 0x1C),
  keyZ(26, 'KeyZ', 0x1D),

  digit1(40, 'Digit1', 0x1E),
  digit2(41, 'Digit2', 0x1F),
  digit3(42, 'Digit3', 0x20),
  digit4(43, 'Digit4', 0x21),
  digit5(44, 'Digit5', 0x22),
  digit6(45, 'Digit6', 0x23),
  digit7(46, 'Digit7', 0x24),
  digit8(47, 'Digit8', 0x25),
  digit9(48, 'Digit9', 0x26),
  digit0(49, 'Digit0', 0x27),

  enter(60, 'Enter', 0x28),
  escape(61, 'Escape', 0x29),
  backspace(62, 'Backspace', 0x2A),
  tab(63, 'Tab', 0x2B),
  space(64, 'Space', 0x2C),
  minus(65, 'Minus', 0x2D),
  equal(66, 'Equal', 0x2E),
  bracketLeft(67, 'BracketLeft', 0x2F),
  bracketRight(68, 'BracketRight', 0x30),
  backslash(69, 'Backslash', 0x31),
  semicolon(70, 'Semicolon', 0x33),
  quote(71, 'Quote', 0x34),
  backquote(72, 'Backquote', 0x35),
  comma(73, 'Comma', 0x36),
  period(74, 'Period', 0x37),
  slash(75, 'Slash', 0x38),
  capsLock(76, 'CapsLock', 0x39),

  f1(80, 'F1', 0x3A),
  f2(81, 'F2', 0x3B),
  f3(82, 'F3', 0x3C),
  f4(83, 'F4', 0x3D),
  f5(84, 'F5', 0x3E),
  f6(85, 'F6', 0x3F),
  f7(86, 'F7', 0x40),
  f8(87, 'F8', 0x41),
  f9(88, 'F9', 0x42),
  f10(89, 'F10', 0x43),
  f11(90, 'F11', 0x44),
  f12(91, 'F12', 0x45),

  insert(92, 'Insert', 0x49),
  home(93, 'Home', 0x4A),
  pageUp(94, 'PageUp', 0x4B),
  delete(95, 'Delete', 0x4C),
  end(96, 'End', 0x4D),
  pageDown(97, 'PageDown', 0x4E),
  arrowRight(98, 'ArrowRight', 0x4F),
  arrowLeft(99, 'ArrowLeft', 0x50),
  arrowDown(100, 'ArrowDown', 0x51),
  arrowUp(101, 'ArrowUp', 0x52),

  shiftLeft(110, 'ShiftLeft', 0xE1),
  shiftRight(111, 'ShiftRight', 0xE5),
  controlLeft(112, 'ControlLeft', 0xE0),
  controlRight(113, 'ControlRight', 0xE4),
  altLeft(114, 'AltLeft', 0xE2),
  altRight(115, 'AltRight', 0xE6),
  metaLeft(116, 'MetaLeft', 0xE3),
  metaRight(117, 'MetaRight', 0xE7);

  const InputKey(this.id, this.code, this.hidUsage);

  /// Stable wire id. See the class comment: never reuse or reorder.
  final int id;

  /// Web `KeyboardEvent.code` spelling.
  final String code;

  /// USB HID keyboard-page usage code.
  ///
  /// Flutter exposes this on every platform, native and web, through
  /// `PhysicalKeyboardKey.usbHidUsage` — which makes it the dependable way to
  /// identify a *physical* key regardless of layout or IME. The `code` string
  /// is kept for the browser and for logs.
  final int hidUsage;

  static final Map<int, InputKey> _byId = <int, InputKey>{
    for (final key in InputKey.values) key.id: key,
  };

  static final Map<String, InputKey> _byCode = <String, InputKey>{
    for (final key in InputKey.values) key.code: key,
  };

  static final Map<int, InputKey> _byHid = <int, InputKey>{
    for (final key in InputKey.values) key.hidUsage: key,
  };

  /// Resolve an id from the wire. Unknown ids are dropped, never guessed.
  static InputKey? fromId(int? id) => id == null ? null : _byId[id];

  /// Resolve a USB HID usage code, as reported by
  /// `PhysicalKeyboardKey.usbHidUsage`.
  ///
  /// Flutter reports the **whole 32-bit code, page included** — KeyA arrives as
  /// `0x00070004`, not `0x04` — while the table above stores the usage within
  /// the keyboard page (0x07). Strip the page instead of comparing raw: doing
  /// the naive lookup silently rejects every key (seen on Flutter web).
  ///
  /// Codes from another page are rejected rather than masked, because masking
  /// would let, say, consumer-page `0x000C00E1` alias onto Shift.
  static InputKey? fromHidUsage(int? usage) {
    if (usage == null) return null;
    if (usage >> 16 == 0x07) return _byHid[usage & 0xFFFF];
    // Some backends strip the page themselves; accept a bare usage too.
    if (usage <= 0xFFFF) return _byHid[usage];
    return null;
  }

  /// Resolve a Web-style `code` string, case-insensitively, with a fallback
  /// that accepts bare letters and digits (`a`, `7`).
  static InputKey? fromCode(String? code) {
    if (code == null || code.isEmpty) return null;
    final exact = _byCode[code];
    if (exact != null) return exact;

    final lower = code.toLowerCase();
    for (final key in InputKey.values) {
      if (key.code.toLowerCase() == lower) return key;
    }
    if (code.length == 1) {
      final upper = code.toUpperCase();
      final unit = upper.codeUnitAt(0);
      if (unit >= 0x41 && unit <= 0x5A) return _byCode['Key$upper'];
      if (unit >= 0x30 && unit <= 0x39) return _byCode['Digit$upper'];
    }
    return null;
  }
}

/// Base class for everything that crosses the input channel.
sealed class InputEvent {
  const InputEvent();

  /// Short wire type tag.
  String get type;

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  /// Decodes one wire frame. Returns `null` for anything unrecognised, so a
  /// newer peer can never crash an older one.
  static InputEvent? decode(String raw) {
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;
    return fromJson(Map<String, Object?>.from(parsed));
  }

  static InputEvent? fromJson(Map<String, Object?> json) {
    switch (json['t']) {
      case 'hello':
        return HelloEvent.fromJson(json);
      case 'move':
        return PointerMove.fromJson(json);
      case 'btn':
        return PointerButtonEvent.fromJson(json);
      case 'wheel':
        return PointerWheelEvent.fromJson(json);
      case 'key':
        return KeyEvent.tryFromJson(json);
      default:
        return null;
    }
  }

  static double _d(Object? v, [double fallback = 0]) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static int _i(Object? v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static double _unit(Object? v) {
    final d = _d(v);
    return d.isNaN ? 0 : d.clamp(0.0, 1.0);
  }
}

/// Target → controller handshake: what the remote desktop actually looks like.
///
/// Sent when the data channel opens and again whenever the target's screen
/// geometry changes (resolution switch, DPI change).
class HelloEvent extends InputEvent {
  const HelloEvent({
    required this.screenWidth,
    required this.screenHeight,
    this.scaleFactor = 1.0,
    this.videoWidth = 0,
    this.videoHeight = 0,
  });

  /// Target screen size in physical pixels.
  final int screenWidth;
  final int screenHeight;

  /// Target DPI scale (1.0 = 96 DPI). Informational, shown in the controller
  /// HUD; the wire format does not need it because positions are normalised.
  final double scaleFactor;

  /// Encoded video size when known — the controller prefers this over its own
  /// viewport when computing the picture aspect ratio.
  final int videoWidth;
  final int videoHeight;

  @override
  String get type => 'hello';

  factory HelloEvent.fromJson(Map<String, Object?> json) => HelloEvent(
        screenWidth: InputEvent._i(json['w']),
        screenHeight: InputEvent._i(json['h']),
        scaleFactor: InputEvent._d(json['s'], 1),
        videoWidth: InputEvent._i(json['vw']),
        videoHeight: InputEvent._i(json['vh']),
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': type,
        'w': screenWidth,
        'h': screenHeight,
        's': scaleFactor,
        'vw': videoWidth,
        'vh': videoHeight,
      };

  @override
  String toString() =>
      'Hello(${screenWidth}x$screenHeight @${scaleFactor}x, '
      'video ${videoWidth}x$videoHeight)';
}

/// Pointer moved. [x] and [y] are fractions of the video picture.
class PointerMove extends InputEvent {
  const PointerMove(this.x, this.y);

  final double x;
  final double y;

  @override
  String get type => 'move';

  factory PointerMove.fromJson(Map<String, Object?> json) => PointerMove(
        InputEvent._unit(json['x']),
        InputEvent._unit(json['y']),
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': type,
        'x': x,
        'y': y,
      };

  /// Hand-rolled so a 60 Hz move stream does not pay `jsonEncode`'s overhead.
  /// Four decimals is still sub-pixel on a 4K target.
  String encodeCompact() =>
      '{"t":"move","x":${x.toStringAsFixed(4)},"y":${y.toStringAsFixed(4)}}';
}

/// Mouse button pressed or released at a picture-relative position.
class PointerButtonEvent extends InputEvent {
  const PointerButtonEvent({
    required this.button,
    required this.pressed,
    required this.x,
    required this.y,
  });

  final int button;
  final bool pressed;
  final double x;
  final double y;

  @override
  String get type => 'btn';

  factory PointerButtonEvent.fromJson(Map<String, Object?> json) =>
      PointerButtonEvent(
        button: InputEvent._i(json['b']),
        pressed: json['d'] == true || json['d'] == 1,
        x: InputEvent._unit(json['x']),
        y: InputEvent._unit(json['y']),
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': type,
        'b': button,
        'd': pressed,
        'x': x,
        'y': y,
      };
}

/// Wheel / trackpad scroll.
///
/// [dx] and [dy] use the Windows `WHEEL_DELTA` convention (120 per notch), so
/// the Windows target forwards the number without another conversion. A
/// positive [dy] scrolls up, matching both `MouseEvent.deltaY` inverted and
/// `MOUSEEVENTF_WHEEL`'s sign.
class PointerWheelEvent extends InputEvent {
  const PointerWheelEvent({this.dx = 0, this.dy = 0});

  final double dx;
  final double dy;

  @override
  String get type => 'wheel';

  factory PointerWheelEvent.fromJson(Map<String, Object?> json) =>
      PointerWheelEvent(
        dx: InputEvent._d(json['dx']),
        dy: InputEvent._d(json['dy']),
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': type,
        'dx': dx,
        'dy': dy,
      };
}

/// A single key transition.
class KeyEvent extends InputEvent {
  const KeyEvent({
    required this.key,
    required this.pressed,
    this.modifiers = 0,
    this.repeat = false,
  });

  /// Resolve a key from a Web `code` string, or `null` if we do not model it.
  static KeyEvent? forCode(
    String? code, {
    required bool pressed,
    int modifiers = 0,
    bool repeat = false,
  }) {
    final key = InputKey.fromCode(code);
    if (key == null) return null;
    return KeyEvent(
      key: key,
      pressed: pressed,
      modifiers: modifiers,
      repeat: repeat,
    );
  }

  final InputKey key;
  final bool pressed;
  final int modifiers;
  final bool repeat;

  @override
  String get type => 'key';

  /// `null` when the wire carries an id this build does not know.
  static KeyEvent? tryFromJson(Map<String, Object?> json) {
    final key = InputKey.fromId(InputEvent._i(json['k'], -1));
    if (key == null) return null;
    return KeyEvent(
      key: key,
      pressed: json['d'] == true || json['d'] == 1,
      modifiers: InputEvent._i(json['m']),
      repeat: json['r'] == true,
    );
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': type,
        'k': key.id,
        'd': pressed,
        'm': modifiers,
        if (repeat) 'r': true,
      };

  @override
  String toString() => 'KeyEvent(${key.code}, pressed=$pressed)';
}

/// Where the video picture actually sits inside a widget of a different aspect
/// ratio.
///
/// `RTCVideoView` uses `contain`, so a 16:9 stream in a 4:3 box leaves bars on
/// two sides. Pointer positions must map against the *picture* rect, not the
/// widget rect, or every click lands offset toward the centre.
class RemoteViewFit {
  const RemoteViewFit({required this.rect, required this.visible});

  /// Picture rectangle in widget-local logical pixels.
  final Rect rect;

  /// False when the aspect ratio is not known yet; callers ignore input then.
  final bool visible;

  static const RemoteViewFit none = RemoteViewFit(
    rect: Rect.zero,
    visible: false,
  );

  /// Fits [content] (the video frame size) inside [container].
  factory RemoteViewFit.compute(Size container, Size content) {
    if (container.isEmpty ||
        content.width <= 0 ||
        content.height <= 0 ||
        !container.width.isFinite ||
        !container.height.isFinite) {
      return RemoteViewFit.none;
    }
    final scale = math.min(
      container.width / content.width,
      container.height / content.height,
    );
    final w = content.width * scale;
    final h = content.height * scale;
    return RemoteViewFit(
      rect: Rect.fromLTWH(
        (container.width - w) / 2,
        (container.height - h) / 2,
        w,
        h,
      ),
      visible: true,
    );
  }

  /// True when [local] (widget-local) lands on the picture.
  bool contains(Offset local) => visible && rect.contains(local);

  /// Converts a widget-local offset into the normalised `[0, 1]` pair the wire
  /// format carries. Clamped, so a drag leaving the picture still reports a
  /// sane edge position.
  Offset normalise(Offset local) {
    if (!visible) return Offset.zero;
    final x = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final y = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
    return Offset(x, y);
  }
}
