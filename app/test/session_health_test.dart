import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/input_event.dart';
import 'package:remotedesk/src/session_health.dart';

/// A session that has been left idle is where coordinate and liveness bugs
/// hide: the handshake numbers are stale, and WebRTC can sit in `disconnected`
/// forever. These are the pure decisions, kept out of the widgets on purpose.
void main() {
  group('remotePictureSize picks the freshest frame size', () {
    const rendererW = 1280;
    const rendererH = 720;

    Size? call({
      num? statsW,
      num? statsH,
      num? helloW,
      num? helloH,
      num rw = rendererW,
      num rh = rendererH,
    }) =>
        remotePictureSize(
          rendererWidth: rw,
          rendererHeight: rh,
          statsWidth: statsW,
          statsHeight: statsH,
          helloWidth: helloW,
          helloHeight: helloH,
        );

    test('getStats wins over a stale renderer value', () {
      // The classic drift: capture was rebuilt at 2560x1440, the renderer
      // still reports the old 1280x720. Using the renderer would squeeze the
      // contain-rectangle and shift every normalised click.
      final size = call(statsW: 2560, statsH: 1440);
      expect(size!.width, 2560);
      expect(size.height, 1440);
    });

    test('falls back to the renderer when stats are missing', () {
      final size = call(helloW: 1920, helloH: 1080);
      expect(size!.width, rendererW);
      expect(size.height, rendererH);
    });

    test('falls back to hello before the first frame decodes', () {
      final size = call(rw: 0, rh: 0, helloW: 1920, helloH: 1080);
      expect(size!.width, 1920);
      expect(size.height, 1080);
    });

    test('a half-known pair is not a size', () {
      // With a usable renderer this falls back to the renderer, not hello —
      // so blank it out too to prove the incomplete stats pair was skipped.
      expect(
        call(
                statsW: 1920,
                statsH: null,
                rw: 0,
                rh: 0,
                helloW: 800,
                helloH: 600)!
            .width,
        800,
      );
    });

    test('zero, negative and non-finite values are rejected', () {
      expect(call(rw: 0, rh: 720, helloW: 0, helloH: 0), isNull);
      expect(
        call(statsW: -1, statsH: 720, rw: 0, rh: 0, helloW: 0, helloH: 0),
        isNull,
      );
      expect(
        call(
            statsW: double.nan,
            statsH: 720,
            rw: 0,
            rh: 0,
            helloW: 0,
            helloH: 0),
        isNull,
      );
      expect(
        call(
            statsW: double.infinity,
            statsH: 720,
            rw: 0,
            rh: 0,
            helloW: 0,
            helloH: 0),
        isNull,
      );
    });

    test('nothing known returns null so the caller can assume 16:9', () {
      expect(call(rw: 0, rh: 0, helloW: null, helloH: null), isNull);
    });
  });

  group('geometryChanged keeps a stable session quiet', () {
    const last = HelloEvent(
      screenWidth: 1920,
      screenHeight: 1080,
      videoWidth: 1920,
      videoHeight: 1080,
      platform: 'windows',
    );

    bool changed({
      int sw = 1920,
      int sh = 1080,
      int vw = 1920,
      int vh = 1080,
    }) =>
        geometryChanged(
          last,
          screenWidth: sw,
          screenHeight: sh,
          videoWidth: vw,
          videoHeight: vh,
        );

    test('first handshake always goes out', () {
      expect(
        geometryChanged(null,
            screenWidth: 1920,
            screenHeight: 1080,
            videoWidth: 1920,
            videoHeight: 1080),
        isTrue,
      );
    });

    test('identical geometry is not re-announced every poll', () {
      expect(changed(), isFalse);
    });

    test('a monitor waking at another resolution is detected', () {
      expect(changed(sw: 2560, sh: 1440), isTrue);
    });

    test('a DPI change with the same video size is detected', () {
      expect(changed(sw: 1536, sh: 864), isTrue);
    });

    test('a rebuilt capture track with a new frame size is detected', () {
      expect(changed(vw: 1280, vh: 720), isTrue);
    });

    test('each of the four fields is part of the comparison', () {
      expect(changed(sh: 1200), isTrue);
      expect(changed(vw: 1600), isTrue);
      expect(changed(vh: 900), isTrue);
    });
  });

  group('DisconnectWatch turns a frozen link into an honest failure', () {
    final t0 = DateTime(2026, 11, 17, 10);
    const grace = Duration(seconds: 12);

    test('a healthy link is never stalled', () {
      final watch = DisconnectWatch(grace: grace);
      watch.connected();
      expect(watch.isStalled, isFalse);
      expect(watch.expired(t0.add(const Duration(minutes: 1))), isFalse);
    });

    test('grace is given before declaring the link dead', () {
      final watch = DisconnectWatch(grace: grace);
      watch.disconnected(t0);
      expect(watch.isStalled, isTrue);
      expect(watch.expired(t0.add(const Duration(seconds: 11))), isFalse);
      expect(watch.expired(t0.add(grace)), isTrue);
    });

    test('repeated disconnected callbacks do not push the deadline out', () {
      final watch = DisconnectWatch(grace: grace);
      watch.disconnected(t0);
      watch.disconnected(t0.add(const Duration(seconds: 10)));
      expect(watch.expired(t0.add(grace)), isTrue);
    });

    test('recovering cancels the deadline and re-arms a fresh one', () {
      final watch = DisconnectWatch(grace: grace);
      watch.disconnected(t0);
      watch.connected();
      expect(watch.expired(t0.add(const Duration(minutes: 1))), isFalse);

      final t1 = t0.add(const Duration(minutes: 2));
      watch.disconnected(t1);
      expect(watch.expired(t1.add(const Duration(seconds: 11))), isFalse);
      expect(watch.expired(t1.add(grace)), isTrue);
    });

    test('reset clears a stall', () {
      final watch = DisconnectWatch(grace: grace);
      watch.disconnected(t0);
      watch.reset();
      expect(watch.isStalled, isFalse);
      expect(watch.expired(t0.add(const Duration(minutes: 1))), isFalse);
    });
  });
}
