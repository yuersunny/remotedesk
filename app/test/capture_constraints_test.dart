import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/screen_capture.dart';

/// The capture constraints are the difference between one cursor and two, and
/// between 60 fps and 30 fps. Both failures are silent: the stream still works,
/// it just looks wrong. So the shape is pinned here instead of being eyeballed
/// in a live session on a Windows machine.
void main() {
  group('桌面采集约束', () {
    test('光标必须显式关掉 —— 否则主控会看到两个箭头', () {
      final video = buildVideoConstraints(
        const CaptureRequest(sourceId: 'screen:0:0'),
        isWeb: false,
      );
      expect(video['cursor'], 'never');
    });

    test('打开 showCursor 时才传 always（谁想改成显示对方光标，得改这个值）', () {
      final video = buildVideoConstraints(
        const CaptureRequest(showCursor: true),
        isWeb: false,
      );
      expect(video['cursor'], 'always');
    });

    test('帧率必须放在 mandatory 里，而且必须是 double', () {
      final video = buildVideoConstraints(
        const CaptureRequest(frameRate: 60),
        isWeb: false,
      );
      final mandatory = video['mandatory'] as Map<String, dynamic>;

      // 少走一层（顶楼 frameRate）和写成 int 都读不到：插件侧
      // findDouble() 只认 TypeIs<double>，int 会当成"没传"。
      expect(mandatory['frameRate'], isA<double>());
      expect(mandatory['frameRate'], 60.0);
      expect(video.containsKey('frameRate'), isFalse);
    });

    test('给了 sourceId 才带 deviceId', () {
      final withId = buildVideoConstraints(
        const CaptureRequest(sourceId: 'window:1234:0'),
        isWeb: false,
      );
      expect((withId['deviceId'] as Map)['exact'], 'window:1234:0');

      final without = buildVideoConstraints(const CaptureRequest(), isWeb: false);
      expect(without.containsKey('deviceId'), isFalse);
    });

    test('桌面不带 width/height —— 那边本来就忽略，写了是假承诺', () {
      final video = buildVideoConstraints(const CaptureRequest(), isWeb: false);
      expect(video.containsKey('width'), isFalse);
      expect(video.containsKey('height'), isFalse);
    });
  });

  group('网页采集约束', () {
    test('用标准约束形状，不带 mandatory', () {
      final video = buildVideoConstraints(
        const CaptureRequest(width: 1280, height: 720),
        isWeb: true,
      );
      expect(video['cursor'], 'never');
      expect(video['frameRate'], 60);
      expect((video['width'] as Map)['ideal'], 1280);
      expect((video['height'] as Map)['ideal'], 720);
      expect(video.containsKey('mandatory'), isFalse);
    });
  });
}
