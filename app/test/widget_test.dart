import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/rtc_session.dart';
import 'package:remotedesk/src/screen_capture.dart';
import 'package:remotedesk/src/signaling_client.dart';

void main() {
  group('signaling client', () {
    test('starts disconnected with no self id', () {
      final client = SignalingClient();
      expect(client.isConnected, isFalse);
      expect(client.selfId, isNull);
      client.dispose();
    });
  });

  group('SessionStats', () {
    test('renders placeholders when empty', () {
      const stats = SessionStats.empty;
      expect(stats.resolution, '—');
      expect(stats.fpsText, '—');
      expect(stats.kbpsText, '—');
      expect(stats.rttText, '—');
      expect(stats.codecText, '—');
    });

    test('formats real values', () {
      const stats = SessionStats(
        width: 1920,
        height: 1080,
        fps: 30,
        kbps: 4321.7,
        rttMs: 12.4,
        codec: 'video/VP8',
      );
      expect(stats.resolution, '1920×1080');
      expect(stats.fpsText, '30 fps');
      expect(stats.kbpsText, '4322 kbps');
      expect(stats.rttText, '12 ms');
      expect(stats.codecText, 'VP8');
    });
  });

  group('CaptureRequest', () {
    test('copyWith keeps untouched fields', () {
      const base = CaptureRequest(width: 1920, height: 1080, frameRate: 30);
      final next = base.copyWith(frameRate: 15);
      expect(next.frameRate, 15);
      expect(next.width, 1920);
      expect(next.height, 1080);
      expect(next.sourceId, isNull);
    });
  });

  group('RtcSession signaling before the pipeline exists', () {
    late RtcSession session;

    setUp(() {
      session = RtcSession(
        role: SessionRole.target,
        signaling: SignalingClient(),
        peerId: 'peer-1',
      );
    });

    tearDown(() async {
      await session.close();
      session.signaling.dispose();
    });

    test('buffers an offer that arrives before start()', () async {
      await session.handleSignal(<String, dynamic>{
        'type': 'offer',
        'sdp': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      });
      // No crash, and the phase has not jumped to a connected state.
      expect(session.phase, SessionPhase.idle);
    });

    test('drops ICE candidates that arrive before the pipeline', () async {
      await session.handleSignal(<String, dynamic>{
        'type': 'ice',
        'candidate': <String, dynamic>{
          'candidate': 'candidate:1 1 udp 1 127.0.0.1 1 typ host',
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      });
      expect(session.phase, SessionPhase.idle);
    });

    test('reports unhandled frame types so the UI can log them', () async {
      final handled = await session.handleSignal(<String, dynamic>{'type': 'devices'});
      expect(handled, isFalse);
    });
  });
}
