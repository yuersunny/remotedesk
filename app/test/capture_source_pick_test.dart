import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/screen_capture.dart';

/// 挑采集源看起来是件小事，但选错的表现是"连上了、画面全黑、鼠标能动能点"
/// —— 从主控那端看，这和网络断了、权限没给几乎无法区分。所以这里把
/// "什么时候该丢掉上一次的选择"钉死在测试里。
///
/// 真实场景：Windows 上把显示器 HDMI 线拔去给另一台机器用，系统会把输出
/// 从 `\\.\DISPLAY2` 拆掉再按 `\\.\DISPLAY1` 重建。上一次记下的 id 指向一个
/// 已经不存在的 output，抓它就是一帧不来。
void main() {
  CaptureSource screen(String id, String name) =>
      CaptureSource(id: id, name: name, isScreen: true);
  CaptureSource window(String id, String name) =>
      CaptureSource(id: id, name: name, isScreen: false);

  group('挑选采集源', () {
    test('一个源都没有时返回 null，不抛异常', () {
      expect(pickCaptureSource(const <CaptureSource>[], 'screen:0:0'), isNull);
      expect(pickCaptureSource(const <CaptureSource>[], null), isNull);
    });

    test('上次用的源还在列表里 —— 继续用，不要因为顺序变了就换', () {
      final sources = <CaptureSource>[
        screen('screen:1:0', 'Screen 1'),
        screen('screen:0:0', 'Screen 2'),
      ];
      final picked = pickCaptureSource(sources, 'screen:0:0');
      expect(picked?.id, 'screen:0:0', reason: '第二个才是我上次用的那个');
    });

    test('上次的源消失了（显示器编号重排）—— 退回第一个整屏', () {
      final sources = <CaptureSource>[
        window('window:1234', '记事本'),
        screen('screen:0:0', 'Screen 1'),
      ];
      final picked = pickCaptureSource(sources, 'screen:1:0');
      expect(picked?.id, 'screen:0:0');
      expect(picked?.isScreen, isTrue, reason: '不要退回到某个窗口上去');
    });

    test('没有上次记录时选整屏，不选窗口', () {
      final sources = <CaptureSource>[
        window('window:1', '资源管理器'),
        screen('screen:0:0', 'Screen 1'),
      ];
      expect(pickCaptureSource(sources, null)?.id, 'screen:0:0');
    });

    test('整个列表里没有整屏（只有窗口）时，退而取第一个', () {
      final sources = <CaptureSource>[window('window:1', 'A'), window('window:2', 'B')];
      expect(pickCaptureSource(sources, null)?.id, 'window:1');
    });

    test('上次手动选的是窗口，且该窗口还在 —— 尊重这个选择', () {
      final sources = <CaptureSource>[
        screen('screen:0:0', 'Screen 1'),
        window('window:1', '记事本'),
      ];
      expect(pickCaptureSource(sources, 'window:1')?.id, 'window:1');
    });

    test('按 id 比对而不是按名字 —— 重插线后同名不代表同一个输出', () {
      // 名字一样，id 不同：这是"拔了又插，系统给了个新输出"的典型形态。
      final sources = <CaptureSource>[screen('screen:0:0', 'Screen 1')];
      final picked = pickCaptureSource(sources, 'screen:1:0');
      expect(picked?.id, 'screen:0:0');
    });
  });

  /// 会话已经在跑的时候，源被拔掉不会走"挑选"那条路——那时早就选完了。
  /// 这一组固定住"什么时候该认定源没了、要立刻重采"，因为误判的代价是
  /// 把一条好端端的采集反复重启，而漏判的代价是永久黑屏。
  group('判断会话里正在采集的源是否已消失', () {
    test('源还在列表里 —— 不重采', () {
      final sources = <CaptureSource>[
        screen('screen:0:0', 'Screen 1'),
        screen('screen:1:0', 'Screen 2'),
      ];
      expect(captureSourceGone(sources, 'screen:1:0'), isFalse);
    });

    test('源不见了（编号重排）—— 必须重采', () {
      // 拔线后 Windows 把 DISPLAY2 拆掉、按 DISPLAY1 重建：
      // 分辨率一样、名字可能一样，只有 id 能证明换了个输出。
      final sources = <CaptureSource>[screen('screen:0:0', 'Screen 1')];
      expect(captureSourceGone(sources, 'screen:1:0'), isTrue);
    });

    test('枚举返回空 —— 当作"不知道"，不能重采', () {
      // 权限丢失、插件异常、平台不支持都会给空列表。把它当成"源没了"
      // 会让正在出画面的会话被无故打断，反而制造故障。
      expect(captureSourceGone(const <CaptureSource>[], 'screen:1:0'), isFalse);
    });

    test('还没记录当前源 —— 不重采', () {
      final sources = <CaptureSource>[screen('screen:0:0', 'Screen 1')];
      expect(captureSourceGone(sources, null), isFalse);
    });

    test('采集的是窗口，窗口被关掉 —— 同样算消失', () {
      final sources = <CaptureSource>[screen('screen:0:0', 'Screen 1')];
      expect(captureSourceGone(sources, 'window:1'), isTrue);
    });
  });
}
