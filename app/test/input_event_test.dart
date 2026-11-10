import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/input_event.dart';

void main() {
  group('InputKey id space', () {
    test('every wire id is unique', () {
      final seen = <int, InputKey>{};
      for (final key in InputKey.values) {
        final clash = seen[key.id];
        expect(clash, isNull, reason: '${key.code} reuses id ${key.id} of ${clash?.code}');
        seen[key.id] = key;
      }
    });

    test('every HID usage is unique', () {
      final seen = <int, InputKey>{};
      for (final key in InputKey.values) {
        final clash = seen[key.hidUsage];
        expect(clash, isNull,
            reason: '${key.code} reuses HID 0x${key.hidUsage.toRadixString(16)} of ${clash?.code}');
        seen[key.hidUsage] = key;
      }
    });

    test('letter keys follow the USB HID ordering', () {
      expect(InputKey.keyA.hidUsage, 0x04);
      expect(InputKey.keyZ.hidUsage, 0x1D);
      expect(InputKey.digit1.hidUsage, 0x1E);
      expect(InputKey.digit0.hidUsage, 0x27);
      expect(InputKey.escape.hidUsage, 0x29);
      expect(InputKey.f1.hidUsage, 0x3A);
      expect(InputKey.f12.hidUsage, 0x45);
      expect(InputKey.controlLeft.hidUsage, 0xE0);
    });

    test('resolves wire ids and drops unknown ones', () {
      expect(InputKey.fromId(InputKey.keyQ.id), InputKey.keyQ);
      expect(InputKey.fromId(9999), isNull);
      expect(InputKey.fromId(null), isNull);
    });

    test('resolves HID usages and drops unknown ones', () {
      expect(InputKey.fromHidUsage(0x04), InputKey.keyA);
      expect(InputKey.fromHidUsage(0xE5), InputKey.shiftRight);
      expect(InputKey.fromHidUsage(0x02), isNull);
    });

    // Caught in a real session: Flutter reports the whole 32-bit code, so the
    // first version of this lookup rejected every key on Flutter web and the
    // remote desktop simply never saw a keystroke.
    test('accepts the full 32-bit code Flutter actually reports', () {
      const keyboardPage = 0x00070000;
      expect(InputKey.fromHidUsage(keyboardPage | 0x04), InputKey.keyA);
      expect(InputKey.fromHidUsage(keyboardPage | 0xE5), InputKey.shiftRight);
      expect(InputKey.fromHidUsage(keyboardPage | 0x29), InputKey.escape);
    });

    test('rejects codes from another HID page instead of masking them', () {
      // Consumer page 0x0C, whose low byte happens to look like Shift.
      expect(InputKey.fromHidUsage(0x000C00E1), isNull);
      expect(InputKey.fromHidUsage(0x00040004), isNull);
    });
  });

  group('InputKey.fromCode', () {
    test('accepts the Web code spelling', () {
      expect(InputKey.fromCode('KeyA'), InputKey.keyA);
      expect(InputKey.fromCode('Digit7'), InputKey.digit7);
      expect(InputKey.fromCode('ArrowLeft'), InputKey.arrowLeft);
      expect(InputKey.fromCode('F12'), InputKey.f12);
    });

    test('is case insensitive', () {
      expect(InputKey.fromCode('keya'), InputKey.keyA);
      expect(InputKey.fromCode('ENTER'), InputKey.enter);
    });

    test('accepts a bare letter or digit', () {
      expect(InputKey.fromCode('q'), InputKey.keyQ);
      expect(InputKey.fromCode('3'), InputKey.digit3);
    });

    test('returns null for keys we do not model', () {
      expect(InputKey.fromCode('Numpad0'), isNull);
      expect(InputKey.fromCode(''), isNull);
      expect(InputKey.fromCode(null), isNull);
    });
  });

  group('event encoding', () {
    test('round-trips a pointer move', () {
      final decoded = InputEvent.decode(const PointerMove(0.25, 0.75).encode());
      expect(decoded, isA<PointerMove>());
      expect((decoded! as PointerMove).x, 0.25);
      expect((decoded as PointerMove).y, 0.75);
    });

    test('compact move encoding stays valid JSON', () {
      final decoded = InputEvent.decode(const PointerMove(0.1234567, 0.5).encodeCompact());
      expect(decoded, isA<PointerMove>());
      // Four decimals on purpose: sub-pixel on a 4K target, 20 bytes smaller.
      expect((decoded! as PointerMove).x, closeTo(0.1235, 1e-4));
    });

    test('round-trips a button press', () {
      const event = PointerButtonEvent(
        button: InputButton.right,
        pressed: true,
        x: 0.5,
        y: 0.5,
      );
      final decoded = InputEvent.decode(event.encode())! as PointerButtonEvent;
      expect(decoded.button, InputButton.right);
      expect(decoded.pressed, isTrue);
    });

    test('round-trips a wheel event', () {
      final decoded =
          InputEvent.decode(const PointerWheelEvent(dx: 0, dy: -120).encode())!;
      expect((decoded as PointerWheelEvent).dy, -120);
    });

    test('round-trips a key event with modifiers', () {
      const event = KeyEvent(
        key: InputKey.keyS,
        pressed: true,
        modifiers: InputModifier.control | InputModifier.shift,
      );
      final decoded = InputEvent.decode(event.encode())! as KeyEvent;
      expect(decoded.key, InputKey.keyS);
      expect(decoded.pressed, isTrue);
      expect(decoded.modifiers,
          InputModifier.control | InputModifier.shift);
    });

    test('omits the repeat flag when false', () {
      expect(const KeyEvent(key: InputKey.keyA, pressed: true).toJson().containsKey('r'),
          isFalse);
      expect(const KeyEvent(key: InputKey.keyA, pressed: true, repeat: true).toJson()['r'],
          isTrue);
    });

    test('round-trips the hello handshake', () {
      const event = HelloEvent(
        screenWidth: 2560,
        screenHeight: 1440,
        scaleFactor: 1.5,
        videoWidth: 1920,
        videoHeight: 1080,
      );
      final decoded = InputEvent.decode(event.encode())! as HelloEvent;
      expect(decoded.screenWidth, 2560);
      expect(decoded.screenHeight, 1440);
      expect(decoded.scaleFactor, 1.5);
      expect(decoded.videoWidth, 1920);
      expect(decoded.videoHeight, 1080);
    });
  });

  group('event decoding is defensive', () {
    test('rejects malformed JSON', () {
      expect(InputEvent.decode('not json'), isNull);
      expect(InputEvent.decode(''), isNull);
      expect(InputEvent.decode('[1,2,3]'), isNull);
    });

    test('ignores unknown event types', () {
      expect(InputEvent.decode('{"t":"teleport"}'), isNull);
      expect(InputEvent.decode('{"t":"clip"}'), isNull);
    });

    test('drops key events whose id this build does not know', () {
      // A newer controller pressing a key added after this build shipped must
      // not crash the target, and must not be guessed into some other key.
      expect(InputEvent.decode('{"t":"key","k":4242,"d":true}'), isNull);
    });

    test('clamps out-of-range pointer coordinates', () {
      final move = InputEvent.decode('{"t":"move","x":1.7,"y":-3}')! as PointerMove;
      expect(move.x, 1.0);
      expect(move.y, 0.0);
    });

    test('treats a missing coordinate as the origin rather than NaN', () {
      final move = InputEvent.decode('{"t":"move"}')! as PointerMove;
      expect(move.x, 0.0);
      expect(move.y, 0.0);
    });
  });

  group('RemoteViewFit', () {
    test('letterboxes a 16:9 picture inside a 4:3 box', () {
      final fit = RemoteViewFit.compute(const Size(400, 300), const Size(16, 9));
      expect(fit.visible, isTrue);
      expect(fit.rect.width, 400);
      expect(fit.rect.height, 225);
      expect(fit.rect.top, 37.5);
      expect(fit.rect.left, 0);
    });

    test('pillarboxes a 4:3 picture inside a 16:9 box', () {
      final fit = RemoteViewFit.compute(const Size(1600, 900), const Size(4, 3));
      expect(fit.rect.height, 900);
      expect(fit.rect.width, 1200);
      expect(fit.rect.left, 200);
    });

    test('maps the picture centre to (0.5, 0.5) despite the bars', () {
      final fit = RemoteViewFit.compute(const Size(400, 300), const Size(16, 9));
      final centre = fit.normalise(const Offset(200, 150));
      expect(centre.dx, closeTo(0.5, 1e-9));
      expect(centre.dy, closeTo(0.5, 1e-9));
    });

    test('maps the picture corner, not the widget corner', () {
      final fit = RemoteViewFit.compute(const Size(400, 300), const Size(16, 9));
      // Top-left of the *picture* is 37.5px down from the widget top.
      final topLeft = fit.normalise(const Offset(0, 37.5));
      expect(topLeft.dx, closeTo(0, 1e-9));
      expect(topLeft.dy, closeTo(0, 1e-9));
    });

    test('clamps a pointer that leaves the picture', () {
      final fit = RemoteViewFit.compute(const Size(400, 300), const Size(16, 9));
      final beyond = fit.normalise(const Offset(500, 400));
      expect(beyond.dx, 1.0);
      expect(beyond.dy, 1.0);
    });

    test('contains() ignores the bars', () {
      final fit = RemoteViewFit.compute(const Size(400, 300), const Size(16, 9));
      expect(fit.contains(const Offset(200, 150)), isTrue);
      expect(fit.contains(const Offset(200, 10)), isFalse); // in the top bar
    });

    test('reports invisible when the picture size is unknown', () {
      expect(RemoteViewFit.compute(const Size(400, 300), Size.zero).visible, isFalse);
      expect(RemoteViewFit.compute(Size.zero, const Size(16, 9)).visible, isFalse);
      expect(RemoteViewFit.none.visible, isFalse);
    });
  });

  group('command as control', () {
    test('sends ⌘C as Ctrl+C for a target with no ⌘', () {
      // The whole point: a Mac user pressing ⌘C means "copy", and Windows turns
      // Win+C into a system panel instead.
      expect(metaAsControl(InputKey.metaLeft), InputKey.controlLeft);
      expect(metaAsControl(InputKey.metaRight), InputKey.controlRight);
    });

    test('leaves every other key alone', () {
      expect(metaAsControl(InputKey.keyC), InputKey.keyC);
      expect(metaAsControl(InputKey.controlLeft), InputKey.controlLeft);
      expect(metaAsControl(InputKey.altLeft), InputKey.altLeft);
    });

    test('rewrites the meta modifier bit and keeps the others', () {
      final mask = InputModifier.meta | InputModifier.shift;
      final mapped = modifiersMetaAsControl(mask);
      expect(mapped & InputModifier.meta, 0);
      expect(mapped & InputModifier.control, InputModifier.control);
      expect(mapped & InputModifier.shift, InputModifier.shift);
    });

    test('does not invent a Ctrl when ⌘ is not held', () {
      final mask = InputModifier.shift | InputModifier.alt;
      expect(modifiersMetaAsControl(mask), mask);
      expect(modifiersMetaAsControl(0), 0);
    });
  });
}
