import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/mobile/touch_input.dart';

/// A 16:9 desktop shown in a tall phone: letterboxed top and bottom, which is
/// exactly where an off-by-one mapping bug shows up first.
RemoteViewport _viewport() => RemoteViewport()
  ..viewport = const Size(400, 800)
  ..picture = const Size(1920, 1080);

class _Recorder {
  final List<Offset> moves = <Offset>[];
  final List<(int, bool, Offset)> buttons = <(int, bool, Offset)>[];
  final List<(double, double)> wheels = <(double, double)>[];
  int viewChanges = 0;
  final List<Offset> clicks = <Offset>[];

  late final TouchInput touch = TouchInput(
    viewport: _viewport(),
    onMove: moves.add,
    onButton: (button, pressed, at) => buttons.add((button, pressed, at)),
    onWheel: (dx, dy) => wheels.add((dx, dy)),
    onViewChanged: () => viewChanges++,
    onClickFeedback: clicks.add,
  );

  List<int> get pressedButtons => <int>[
        for (final b in buttons)
          if (b.$2) b.$1,
      ];
}

void main() {
  group('RemoteViewport', () {
    test('contain fit leaves bars on the short axis', () {
      final viewport = _viewport();
      final rect = viewport.baseRect;
      expect(rect.width, closeTo(400, 0.01));
      expect(rect.height, closeTo(225, 0.01));
      expect(rect.top, closeTo(287.5, 0.01));
    });

    test('centre of the picture maps to 0.5/0.5', () {
      final viewport = _viewport();
      final n = viewport.toNormalised(const Offset(200, 400))!;
      expect(n.dx, closeTo(0.5, 0.001));
      expect(n.dy, closeTo(0.5, 0.001));
    });

    test('letterbox is outside the picture but still clamps to an edge', () {
      final viewport = _viewport();
      const bar = Offset(200, 40);
      expect(viewport.containsLocal(bar), isFalse);
      // Clamped, never NaN: a drag leaving the picture must still produce a
      // usable coordinate.
      expect(viewport.toNormalised(bar)!.dy, 0);
    });

    test('zoom keeps the point under the fingers still', () {
      final viewport = _viewport();
      const focal = Offset(120, 360);
      final before = viewport.toNormalised(focal)!;
      viewport.zoomAround(focal, 2.5);
      expect(viewport.scale, closeTo(2.5, 0.001));
      // The same normalised point must still land under the finger: this is
      // what makes "zoom in, then click the small button" work at all.
      final round = viewport.toLocal(before);
      expect(round.dx, closeTo(focal.dx, 0.01));
      expect(round.dy, closeTo(focal.dy, 0.01));
      expect(viewport.toNormalised(focal)!.dx, closeTo(before.dx, 0.001));
    });

    test('zoom never goes below fit size, and reset clears the pan', () {
      final viewport = _viewport();
      viewport.zoomAround(const Offset(200, 400), 0.2);
      expect(viewport.scale, 1);
      expect(viewport.pan, Offset.zero);
      viewport.zoomAround(const Offset(200, 400), 3);
      viewport.panBy(const Offset(-900, -900));
      expect(viewport.scale, greaterThan(1));
      viewport.reset();
      expect(viewport.scale, 1);
      expect(viewport.pan, Offset.zero);
    });

    test('panning cannot push the picture out of view', () {
      final viewport = _viewport();
      viewport.zoomAround(const Offset(200, 400), 6);
      for (final push in <Offset>[const Offset(9999, 9999), const Offset(-9999, -9999)]) {
        viewport.panBy(push);
        final rect = viewport.displayRect;
        expect(rect.left, lessThanOrEqualTo(0.01));
        expect(rect.top, lessThanOrEqualTo(0.01));
        expect(rect.right, greaterThanOrEqualTo(399.99));
        expect(rect.bottom, greaterThanOrEqualTo(799.99));
      }
    });

    test('the axis that does not overflow keeps the picture inside', () {
      final viewport = _viewport();
      viewport.zoomAround(const Offset(200, 400), 1.6);
      viewport.panBy(const Offset(9999, 9999));
      final rect = viewport.displayRect;
      // Wider than the phone at 1.6x, still shorter: it must fill horizontally
      // and stay entirely inside vertically.
      expect(rect.left, lessThanOrEqualTo(0.01));
      expect(rect.right, greaterThanOrEqualTo(399.99));
      expect(rect.top, greaterThanOrEqualTo(-0.01));
      expect(rect.bottom, lessThanOrEqualTo(800.01));
    });
  });

  group('touch gestures', () {
    test('a tap becomes one left click at that point', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerUp(1, const Offset(200, 400));
      expect(r.buttons.length, 2);
      expect(r.buttons[0].$1, 0);
      expect(r.buttons[0].$2, isTrue);
      expect(r.buttons[0].$3.dx, closeTo(0.5, 0.01));
      expect(r.buttons[1].$2, isFalse);
      expect(r.clicks, hasLength(1));
    });

    test('a tap on the letterbox sends nothing', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 40));
      r.touch.pointerUp(1, const Offset(200, 40));
      expect(r.buttons, isEmpty);
    });

    test('a drag presses, moves and releases exactly once', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerMove(1, const Offset(204, 400));
      expect(r.buttons, isEmpty, reason: 'within slop: still a tap');
      r.touch.pointerMove(1, const Offset(240, 410));
      r.touch.pointerMove(1, const Offset(300, 420));
      r.touch.pointerUp(1, const Offset(300, 420));
      expect(r.pressedButtons, <int>[0]);
      expect(r.buttons.last.$2, isFalse);
      expect(r.moves.length, greaterThan(2));
    });

    test('a second finger arriving late does not leave a stray click', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerDown(2, const Offset(200, 500));
      r.touch.pointerMove(2, const Offset(200, 300));
      r.touch.pointerUp(2, const Offset(200, 300));
      r.touch.pointerUp(1, const Offset(200, 400));
      expect(r.buttons, isEmpty, reason: 'two fingers must never click');
    });

    test('two-finger drag scrolls, and fingers down scroll up', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerDown(2, const Offset(200, 500));
      // Both fingers travel together, 10 px per event, the way a real scroll
      // arrives — one finger slightly ahead of the other.
      r.touch.pointerMove(1, const Offset(200, 410));
      r.touch.pointerMove(2, const Offset(200, 510));
      r.touch.pointerMove(1, const Offset(200, 420));
      r.touch.pointerMove(2, const Offset(200, 520));
      expect(r.wheels, isNotEmpty);
      expect(r.wheels.first.$2, greaterThan(0), reason: 'positive dy scrolls up');
      expect(r.buttons, isEmpty);
      expect(r.touch.viewport.scale, 1, reason: 'a scroll must not zoom');
    });

    test('pinch zooms locally and never reaches the remote', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerDown(2, const Offset(200, 460));
      r.touch.pointerMove(2, const Offset(200, 540));
      expect(r.touch.viewport.scale, greaterThan(1.2));
      expect(r.buttons, isEmpty);
      expect(r.wheels, isEmpty, reason: 'a pinch is not a scroll');
      expect(r.moves.length, 1, reason: 'only the initial hover');
    });

    test('two-finger tap is a right click', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerDown(2, const Offset(200, 460));
      r.touch.pointerUp(2, const Offset(200, 460));
      r.touch.pointerUp(1, const Offset(200, 400));
      expect(r.buttons.length, 2);
      expect(r.buttons.first.$1, 2);
      expect(r.buttons.last.$2, isFalse);
    });

    test('long press is a right click, and the release is swallowed', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      expect(r.touch.awaitingLongPress, isTrue);
      r.touch.fireLongPress();
      expect(r.buttons.length, 2);
      expect(r.buttons.first.$1, 2);
      r.touch.pointerUp(1, const Offset(200, 400));
      expect(r.buttons.length, 2, reason: 'no second click from the lift');
    });

    test('disabled control still zooms but sends nothing', () {
      final r = _Recorder();
      r.touch.enabled = false;
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerUp(1, const Offset(200, 400));
      expect(r.buttons, isEmpty);
      r.touch.pointerDown(3, const Offset(200, 400));
      r.touch.pointerDown(4, const Offset(200, 460));
      r.touch.pointerMove(4, const Offset(200, 540));
      expect(r.touch.viewport.scale, greaterThan(1.2));
    });

    test('cancel releases a held button instead of leaving it down', () {
      final r = _Recorder();
      r.touch.pointerDown(1, const Offset(200, 400));
      r.touch.pointerMove(1, const Offset(260, 400));
      expect(r.pressedButtons, <int>[0]);
      r.touch.pointerCancel(1);
      expect(r.buttons.last.$2, isFalse);
    });
  });
}
