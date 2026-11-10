import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/mobile/mobile_session.dart';
import 'package:remotedesk/src/rtc_session.dart';
import 'package:remotedesk/src/signaling_client.dart';

/// The session screen is the part that cannot be exercised on a desktop, so it
/// gets a phone-sized widget test: layout must survive a 390x844 viewport with
/// the keyboard panel open, and typing must reach the input channel.
///
/// Nothing here uses `pumpAndSettle`: before the first frame arrives the screen
/// shows a progress indicator, which animates forever by design, so "settle"
/// would never happen.
void main() {
  late RtcSession session;

  setUp(() {
    session = RtcSession(
      role: SessionRole.controller,
      signaling: SignalingClient(),
      peerId: 'mac-mini',
    );
  });

  Widget app({SessionPhase phase = SessionPhase.connecting}) => MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: MobileSessionView(
          session: session,
          phase: phase,
          stats: SessionStats.empty,
          onHangUp: () {},
        ),
      );

  void phoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('waits for the picture while the target accepts', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(app());
    await advance(tester);

    expect(find.text('mac-mini'), findsOneWidget);
    expect(find.text('等待电脑画面…'), findsOneWidget);
    expect(find.textContaining('接受并共享屏幕'), findsOneWidget);
  });

  testWidgets('keyboard panel opens and typing becomes key presses',
      (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(app());
    await advance(tester);

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byIcon(Icons.keyboard_alt_outlined));
    await advance(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ab');
    await advance(tester);
    // a down, a up, b down, b up — queued because no data channel exists in a
    // widget test, which is exactly the "channel not open yet" path.
    expect(session.input.pendingCount, 4);

    // Modifier latches are sent as real key transitions, not as a flag.
    await tester.tap(find.text('Ctrl'));
    await advance(tester);
    expect(session.input.pendingCount, 5);
  });

  testWidgets('hanging up asks first', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(app(phase: SessionPhase.live));
    await advance(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await advance(tester);
    expect(find.text('断开连接？'), findsOneWidget);

    await tester.tap(find.text('继续看'));
    await advance(tester);
    expect(find.text('断开连接？'), findsNothing);
  });

  testWidgets('gesture help explains the model', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(app());
    await advance(tester);

    await tester.tap(find.byIcon(Icons.touch_app_outlined));
    await advance(tester);
    expect(find.text('手机怎么操作电脑'), findsOneWidget);
    expect(find.text('单指长按'), findsOneWidget);
  });

  testWidgets('a tap on the picture clicks the remote', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(app(phase: SessionPhase.live));
    await advance(tester);

    await tester.tapAt(const Offset(195, 400));
    await advance(tester);
    // button down + up
    expect(session.input.pendingCount, greaterThanOrEqualTo(2));
  });
}
