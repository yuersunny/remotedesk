@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/signaling_server_io.dart';

/// The relay now runs *inside* the app, so it needs its own proof: a protocol
/// bug here looks like "the other machine never appears", which is exactly the
/// symptom this whole change was meant to remove.
///
/// The peers below are raw WebSocket clients on purpose — that is what the
/// Dart and (former) Node clients are, and it keeps the server tested through
/// its actual wire format rather than through a Dart mirror of it.
class _Peer {
  _Peer(this.ws, this.label);

  final WebSocket ws;
  final String label;
  final List<Map<String, dynamic>> _inbox = <Map<String, dynamic>>[];

  void listen() {
    ws.listen((dynamic raw) {
      _inbox.add(jsonDecode(raw as String) as Map<String, dynamic>);
    });
  }

  void send(Map<String, Object?> payload) => ws.add(jsonEncode(payload));

  /// Waits for the next message of [type], leaving anything else queued.
  Future<Map<String, dynamic>> next(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < _inbox.length; i++) {
        if (_inbox[i]['type'] == type) return _inbox.removeAt(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('$label 等不到 "$type"，收到的只有: '
        '${_inbox.map((m) => m['type']).join(', ')}');
  }

  Future<void> close() => ws.close();
}

void main() {
  late LocalSignalingServer server;
  late _Peer target;
  late _Peer controller;

  setUp(() async {
    server = LocalSignalingServer();
    // Port 0: let the OS pick, so the suite never fights a server already
    // running on 8787 (which is the normal state on the dev machine now).
    final started = await server.start(port: 0);
    expect(started, isTrue, reason: '端口 0 不该被占用');

    target = _Peer(
      await WebSocket.connect('ws://127.0.0.1:${server.port}/ws'),
      'target',
    )..listen();
    target.send(<String, Object?>{'type': 'register', 'id': 'target-1', 'name': '办公室'});
    expect((await target.next('registered'))['id'], 'target-1');

    controller = _Peer(
      await WebSocket.connect('ws://127.0.0.1:${server.port}/ws'),
      'controller',
    )..listen();
    controller.send(<String, Object?>{'type': 'register', 'id': 'home-1', 'name': '家里'});
    expect((await controller.next('registered'))['id'], 'home-1');
  });

  tearDown(() async {
    await controller.close();
    await target.close();
    await server.stop();
  });

  test('设备列表不含自己', () async {
    controller.send(<String, Object?>{'type': 'list'});
    final devices = (await controller.next('devices'))['devices'] as List;
    expect(devices.map((d) => d['id']), <String>['target-1']);
  });

  test('呼叫 → 接受 → offer 原样转交', () async {
    controller.send(<String, Object?>{
      'type': 'connect',
      'to': 'target-1',
      'password': '246810',
    });
    expect(await controller.next('connect_requested'), isNotNull);

    final incoming = await target.next('incoming');
    expect(incoming['from'], 'home-1');
    expect(incoming['password'], '246810');
    expect(incoming['requiresPassword'], isTrue);

    target.send(<String, Object?>{'type': 'accept', 'to': 'home-1', 'password': '246810'});
    final accepted = await controller.next('accepted');
    expect(accepted['from'], 'target-1');
    // The password rides back on `accepted`: the caller needs to prove it knew
    // the password before the target opens a session.
    expect(accepted['password'], '246810');

    final sdp = <String, Object?>{'type': 'offer', 'sdp': 'v=0 fake-offer'};
    controller.send(<String, Object?>{
      'type': 'offer',
      'to': 'target-1',
      'sdp': sdp['sdp'],
    });
    final offer = await target.next('offer');
    expect(offer['from'], 'home-1');
    expect(offer['sdp'], 'v=0 fake-offer');

    controller.send(<String, Object?>{'type': 'ice', 'to': 'target-1', 'candidate': 'cand'});
    expect((await target.next('ice'))['candidate'], 'cand');
  });

  test('呼叫不存在的设备 → target_offline，而不是静默丢弃', () async {
    controller.send(<String, Object?>{'type': 'connect', 'to': 'nobody'});
    final error = await controller.next('error');
    expect(error['code'], 'target_offline');
    expect(error['to'], 'nobody');
  });

  test('同一 ID 重复上线 → id_taken，不会顶掉原来那台', () async {
    final second = _Peer(
      await WebSocket.connect('ws://127.0.0.1:${server.port}/ws'),
      'second',
    )..listen();
    second.send(<String, Object?>{'type': 'register', 'id': 'target-1'});
    expect((await second.next('error'))['code'], 'id_taken');

    // 原来那台仍在，仍能被呼到。
    controller.send(<String, Object?>{'type': 'connect', 'to': 'target-1'});
    expect((await target.next('incoming'))['from'], 'home-1');
    await second.close();
  });

  test('断开后广播 peer_offline', () async {
    await target.close();
    final offline = await controller.next('peer_offline');
    expect(offline['id'], 'target-1');
  });

  test('60 秒内呼叫超过 10 次被限流（挡暴力猜密码）', () async {
    for (var i = 0; i < 10; i++) {
      controller.send(<String, Object?>{'type': 'connect', 'to': 'target-1', 'password': 'x'});
      await target.next('incoming');
    }
    controller.send(<String, Object?>{'type': 'connect', 'to': 'target-1', 'password': 'x'});
    final error = await controller.next('error');
    expect(error['code'], 'rate_limited');
    expect('${error['message']}', contains('秒'));
  });

  test('/health 报告在线设备数', () async {
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    expect(response.statusCode, 200);
    expect(jsonDecode(body)['devices'], 2);
  });

  test('端口被占时 start 返回 false 而不是抛异常', () async {
    final second = LocalSignalingServer();
    expect(await second.start(port: server.port), isFalse);
    expect(second.running, isFalse);
  });

  group('挑一个对方能用的地址', () {
    test('有 tailnet 地址时优先它（回家才连得上）', () {
      expect(
        pickPeerAddress(<String>['192.168.1.10', '100.101.102.103']),
        '100.101.102.103',
      );
      // Tailscale 的 100.64/10 与公网 100.x 不是一回事，边界要卡住：
      // 这两个都不算 tailnet，因此不该被抬到前面去。
      expect(pickPeerAddress(<String>['10.0.0.9', '100.63.0.1']), '10.0.0.9');
      expect(pickPeerAddress(<String>['10.0.0.9', '100.128.0.1']), '10.0.0.9');
    });

    test('没有 tailnet 就用第一个局域网地址', () {
      expect(pickPeerAddress(<String>['192.168.1.5']), '192.168.1.5');
    });

    test('一个都没有时给 null，而不是拼出 ws://:8787/ws', () {
      expect(pickPeerAddress(const <String>[]), isNull);
    });
  });
}
