import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/input_event.dart' as proto;
import 'package:remotedesk/src/mobile/mobile_home.dart';
import 'package:remotedesk/src/peer_info.dart';
import 'package:remotedesk/src/rtc_session.dart';

class _FakeHost implements MobileHost {
  _FakeHost({List<PeerInfo>? peers}) : peers = peers ?? <PeerInfo>[];

  @override
  List<PeerInfo> peers;

  PeerInfo? connected;
  String? code;
  String? manual;
  int rescans = 0;

  @override
  bool controlEnabled = true;

  @override
  bool clipboardEnabled = true;

  int clipboardPushes = 0;

  @override
  Future<void> pushClipboard() async => clipboardPushes++;

  @override
  void setClipboardEnabled(bool on) => clipboardEnabled = on;

  @override
  bool get scanning => false;
  @override
  RtcSession? get session => null;
  @override
  SessionPhase get phase => SessionPhase.idle;
  @override
  SessionStats get stats => SessionStats.empty;
  @override
  proto.HelloEvent? get remoteHello => null;
  @override
  bool get signalingUp => true;
  @override
  bool get busy => false;
  @override
  String get selfId => 'pixel-8';
  @override
  List<String> get logLines => const <String>['本机设备ID: pixel-8', '自动查找：找到 1 台'];
  @override
  String get version => '1.0.6';

  @override
  Future<void> rescan() async => rescans++;
  @override
  Future<void> connectPeer(PeerInfo peer) async => connected = peer;
  @override
  Future<void> connectByCode(String raw) async => code = raw;
  @override
  Future<void> connectManual(String target) async => manual = target;
  @override
  Future<void> hangUp() async {}
  @override
  void setControlEnabled(bool on) => controlEnabled = on;
}

/// A real phone viewport (iPhone-ish 390x844 logical px at 3x).
void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Widget _app(MobileHost host) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: MobileHomePage(host: host),
    );

void main() {
  testWidgets('phone home lists a discovered computer and connects on tap',
      (tester) async {
    _usePhoneViewport(tester);
    final host = _FakeHost(peers: <PeerInfo>[
      const PeerInfo(
        id: 'mac-mini',
        host: '192.168.1.10',
        name: 'mac-mini',
        source: PeerSource.lan,
        platform: 'macos',
      ),
    ]);
    await tester.pumpWidget(_app(host));
    await tester.pumpAndSettle();

    expect(find.text('mac-mini'), findsOneWidget);
    expect(find.textContaining('局域网'), findsOneWidget);
    expect(find.text('还没找到电脑'), findsNothing);

    await tester.tap(find.text('mac-mini'));
    await tester.pumpAndSettle();
    expect(host.connected?.id, 'mac-mini');
  });

  testWidgets('empty state explains what to do instead of a blank screen',
      (tester) async {
    _usePhoneViewport(tester);
    await tester.pumpWidget(_app(_FakeHost()));
    await tester.pumpAndSettle();

    expect(find.text('还没找到电脑'), findsOneWidget);
    expect(find.textContaining('配对码'), findsWidgets);
  });

  testWidgets('a pasted pairing code is handed to the host', (tester) async {
    _usePhoneViewport(tester);
    final host = _FakeHost();
    await tester.pumpWidget(_app(host));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'RDSK1 100.101.102.103:8787 mac-mini 4921',
    );
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();

    expect(host.code, contains('mac-mini'));
  });

  testWidgets('logs stay folded away until asked for', (tester) async {
    _usePhoneViewport(tester);
    await tester.pumpWidget(_app(_FakeHost()));
    await tester.pumpAndSettle();

    expect(find.textContaining('本机设备ID'), findsNothing);
    await tester.tap(find.text('运行日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本机设备ID'), findsOneWidget);
  });

  testWidgets('offline machine is dimmed but still tappable', (tester) async {
    _usePhoneViewport(tester);
    final host = _FakeHost(peers: <PeerInfo>[
      const PeerInfo(
        id: 'office-pc',
        host: '10.0.0.8',
        name: 'office-pc',
        source: PeerSource.remembered,
        online: false,
      ),
    ]);
    await tester.pumpWidget(_app(host));
    await tester.pumpAndSettle();

    expect(find.textContaining('现在没连上'), findsOneWidget);
    await tester.tap(find.text('office-pc'));
    await tester.pumpAndSettle();
    expect(host.connected?.id, 'office-pc');
  });
}
