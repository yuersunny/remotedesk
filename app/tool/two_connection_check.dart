// End-to-end check of the two-connection model, without a second computer.
//
// Reproduces exactly what the app does now:
//   * every machine serves its own relay and sits registered on it (waiting to
//     be called) — that is the `home` half;
//   * dialling a peer opens a *second* connection to that peer's relay and
//     registers there under `<name>-ctl` — that is the `dial` half.
//
// The two halves must not interfere: the point of the change is that being
// reachable and reaching someone are independent, and that no shared relay is
// needed. Runs on loopback with two servers on different ports, which exercises
// the real WebSocket stack rather than a mock.
//
//   cd app && dart run tool/two_connection_check.dart
// Command-line check, so stdout is the interface.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:remotedesk/src/signaling_client.dart';
import 'package:remotedesk/src/signaling_server_io.dart';

Future<void> main() async {
  final problems = <String>[];
  final homeServer = LocalSignalingServer();
  final peerServer = LocalSignalingServer();
  if (!await homeServer.start(port: 8797)) {
    throw StateError('端口 8797 被占用，先停掉其它实例');
  }
  if (!await peerServer.start(port: 8798)) {
    throw StateError('端口 8798 被占用，先停掉其它实例');
  }
  homeServer.setIdentity(id: 'mac-mini', name: 'mac-mini');
  peerServer.setIdentity(id: 'win', name: 'win');

  // The home half: registered on our own relay, waiting to be called.
  final home = SignalingClient();
  var homeRegistered = false;
  home.events.listen((m) {
    if (m['type'] == 'registered') homeRegistered = true;
  });
  await home.connect(url: 'ws://127.0.0.1:8797/ws', id: 'mac-mini');

  // The peer: registered on its own relay.
  final peer = SignalingClient();
  var peerRegistered = false;
  final peerSaw = <String>[];
  peer.events.listen((m) {
    final type = '${m['type']}';
    if (type == 'registered') peerRegistered = true;
    if (type == 'incoming') {
      peerSaw.add('incoming from ${m['from']}');
      // Answer the way the real app does when unattended mode is on.
      peer.accept('${m['from']}');
    }
  });
  await peer.connect(url: 'ws://127.0.0.1:8798/ws', id: 'win');

  // The dial half: a second connection, to the *peer's* relay.
  final dial = SignalingClient();
  final dialSaw = <String>[];
  var dialRegistered = false;
  dial.events.listen((m) {
    final type = '${m['type']}';
    if (type == 'registered') dialRegistered = true;
    if (type == 'accepted') dialSaw.add('accepted from ${m['from']}');
    if (type == 'error') dialSaw.add('error ${m['code']}');
  });
  await dial.connect(url: 'ws://127.0.0.1:8798/ws', id: 'mac-mini-ctl');
  dial.connectTo('win', password: null);

  await Future<void>.delayed(const Duration(seconds: 2));

  void check(String label, bool ok, String detail) {
    print('${ok ? '✓' : '✗'} $label${detail.isEmpty ? '' : ' — $detail'}');
    if (!ok) problems.add(label);
  }

  check('自己那半注册成功', homeRegistered, '');
  check('对方那半注册成功', peerRegistered, '');
  check('主控那半在对方服务上注册成功', dialRegistered, '');
  check('对方收到呼叫', peerSaw.any((e) => e.startsWith('incoming')), peerSaw.join(', '));
  check('主控收到接受', dialSaw.any((e) => e.startsWith('accepted')), dialSaw.join(', '));
  check('呼叫方 ID 带 -ctl 后缀，不与对方自己的 ID 撞车',
      peerSaw.any((e) => e.contains('mac-mini-ctl')), peerSaw.join(', '));
  check('自己那半仍连着（连别人的同时自己还能被连）', home.isConnected, '');
  check('对方服务上看到两台设备', peerServer.deviceCount == 2,
      'devices=${peerServer.deviceCount}');
  check('自己服务上仍只有自己一台', homeServer.deviceCount == 1,
      'devices=${homeServer.deviceCount}');

  // 反证：如果主控直接用对方的名字注册，对方服务器会拒绝第二台同名设备。
  // 这是 -ctl 后缀存在的理由，值得钉住。
  final clash = SignalingClient();
  String? clashError;
  clash.events.listen((m) {
    if (m['type'] == 'error') clashError = '${m['code']}';
  });
  await clash.connect(url: 'ws://127.0.0.1:8798/ws', id: 'win');
  await Future<void>.delayed(const Duration(milliseconds: 600));
  check('同名注册确实被拒（说明 -ctl 不是多余的）', clashError == 'id_taken', '$clashError');

  await clash.disconnect();
  dial.dispose();
  peer.dispose();
  home.dispose();
  await homeServer.stop();
  await peerServer.stop();

  print('');
  if (problems.isEmpty) {
    print('全部通过');
    return;
  }
  print('失败 ${problems.length} 项：${problems.join('、')}');
  throw StateError('two-connection model broken');
}
