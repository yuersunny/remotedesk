import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

/// Picks the address most likely to reach this machine from *somewhere else*.
///
/// A tailnet address (`100.64.0.0/10`) wins when there is one: it answers both
/// from the office LAN and from home, which is the exact trip this whole
/// feature exists to survive. Picking the first LAN address instead is what
/// makes a correct setup fail the first time it is used from the wrong network
/// — the address is right for the desk and useless from the sofa.
///
/// Without a tailnet, the first remaining address is the best guess available;
/// the caller logs the rest so a wrong pick is one line away from being fixed.
String? pickPeerAddress(List<String> addresses) {
  for (final address in addresses) {
    final parts = address.split('.');
    if (parts.length != 4) continue;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    if (first == 100 && second != null && second >= 64 && second <= 127) {
      return address;
    }
  }
  return addresses.isEmpty ? null : addresses.first;
}

/// Every IPv4 address this machine answers on, loopback excluded.
///
/// Printed in the log so the other machine knows what to type; without it the
/// answer to "which address do I put in 高级设置?" is a separate trip to
/// `ipconfig` on a machine that may not be at hand.
Future<List<String>> localIpv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return <String>[
      for (final nic in interfaces)
        for (final addr in nic.addresses) addr.address,
    ];
  } catch (_) {
    return const <String>[];
  }
}

/// A signaling server that runs inside the app itself.
///
/// Why this exists: the Node server needed a separate process, a Node runtime,
/// and something to keep it alive across reboots. Every one of those is a way
/// for "remote into the office from home" to fail while nobody is there to fix
/// it — and on this machine the login-item route was not even available to test.
/// The machine being controlled already has the app running, so hosting the
/// relay there costs nothing extra and cannot be left behind.
///
/// Protocol is byte-for-byte the same as `server/src/server.js`; both ends only
/// exchange JSON over a WebSocket at `/ws`, so either server can serve either
/// client.
class LocalSignalingServer {
  LocalSignalingServer({this.onLog});

  final void Function(String message)? onLog;

  HttpServer? _http;
  Timer? _sweeper;

  /// Every registered device, keyed by id.
  final Map<String, _Device> _devices = <String, _Device>{};

  /// Connect attempts per caller, so a wrong password cannot be brute-forced by
  /// simply calling again. Mirrors the Node server: 10 per 60 s.
  final Map<String, _Budget> _budgets = <String, _Budget>{};
  static const int _callWindowMs = 60000;
  static const int _callMaxPerWindow = 10;

  bool get running => _http != null;
  int get port => _http?.port ?? 0;
  int get deviceCount => _devices.length;

  /// Try to listen. Returns false when the port is taken — which normally means
  /// another instance (or the Node server) is already serving and this machine
  /// should just connect to it rather than racing for the port.
  Future<bool> start({int port = 8787}) async {
    if (running) return true;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _http = server;
      unawaited(_accept(server));
      _sweeper = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _sweepBudgets(),
      );
      onLog?.call('本机信令服务器已启动（端口 $port）');
      return true;
    } on SocketException catch (e) {
      onLog?.call('端口 $port 已被占用，不再启动本机服务器（$e）');
      return false;
    } catch (e) {
      onLog?.call('启动本机服务器失败: $e');
      return false;
    }
  }

  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
    for (final device in _devices.values) {
      try {
        await device.ws.close();
      } catch (_) {}
    }
    _devices.clear();
    final server = _http;
    _http = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _accept(HttpServer server) async {
    await for (final request in server) {
      try {
        if (request.uri.path == '/health') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(<String, Object?>{
              'ok': true,
              'devices': _devices.length,
            }));
          await request.response.close();
          continue;
        }

        if (request.uri.path == '/ws' &&
            WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          _attach(socket, request);
          continue;
        }

        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await request.response.close();
      } catch (e) {
        onLog?.call('处理请求失败: $e');
      }
    }
  }

  void _attach(WebSocket socket, HttpRequest request) {
    final peer =
        '${request.connectionInfo?.remoteAddress.address ?? '?'}:'
        '${request.connectionInfo?.remotePort ?? '?'}';
    onLog?.call('[conn] $peer');

    // Dead peers behind a NAT would otherwise linger as "online" forever.
    socket.pingInterval = const Duration(seconds: 30);

    String? deviceId;

    socket.listen(
      (dynamic raw) {
        final msg = _decode(raw);
        if (msg == null) {
          _send(socket, <String, Object?>{'type': 'error', 'code': 'bad_json'});
          return;
        }
        final type = msg['type'];
        onLog?.call('[msg] $type from ${deviceId ?? '(unregistered)'} $peer');

        if (type == 'register') {
          deviceId = _register(socket, msg, peer);
          return;
        }

        if (deviceId == null) {
          _send(socket, <String, Object?>{'type': 'error', 'code': 'not_registered'});
          return;
        }

        _devices[deviceId!]?.lastSeen = DateTime.now();
        _dispatch(socket, deviceId!, msg);
      },
      onDone: () {
        if (deviceId == null) {
          onLog?.call('[gone] $peer (never registered)');
          return;
        }
        final entry = _devices[deviceId];
        if (entry != null && identical(entry.ws, socket)) {
          _devices.remove(deviceId);
          onLog?.call('断开 $deviceId');
          _broadcast(
            <String, Object?>{'type': 'peer_offline', 'id': deviceId},
            exceptId: deviceId,
          );
        }
      },
      onError: (Object e) => onLog?.call('通道错误 $peer: $e'),
    );
  }

  Map<String, dynamic>? _decode(dynamic raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  String? _register(WebSocket socket, Map<String, dynamic> msg, String peer) {
    var id = (msg['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) id = _randomId();

    final existing = _devices[id];
    if (existing != null &&
        !identical(existing.ws, socket) &&
        existing.ws.readyState == WebSocket.open) {
      onLog?.call('[register rejected] id_taken $id $peer');
      _send(socket, <String, Object?>{
        'type': 'error',
        'code': 'id_taken',
        'message': 'device id "$id" already online',
      });
      return null;
    }

    _devices[id] = _Device(
      ws: socket,
      name: (msg['name'] as String?) ?? '',
    );
    _send(socket, <String, Object?>{
      'type': 'registered',
      'id': id,
      'name': (msg['name'] as String?) ?? '',
    });
    onLog?.call('注册 $id ${msg['name'] ?? ''}');
    return id;
  }

  void _dispatch(WebSocket socket, String selfId, Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'list':
        final list = <Map<String, Object?>>[
          for (final entry in _devices.entries)
            if (entry.key != selfId)
              <String, Object?>{'id': entry.key, 'name': entry.value.name},
        ];
        _send(socket, <String, Object?>{'type': 'devices', 'devices': list});
        return;

      case 'connect':
        final to = msg['to'];
        if (to is! String || to.isEmpty) {
          _send(socket, <String, Object?>{'type': 'error', 'code': 'no_target'});
          return;
        }
        final budget = _checkBudget(selfId);
        if (!budget.ok) {
          onLog?.call('[connect throttled] $selfId -> $to');
          _send(socket, <String, Object?>{
            'type': 'error',
            'code': 'rate_limited',
            'message': '尝试过于频繁，请 ${budget.retryAfter} 秒后重试',
          });
          return;
        }
        final target = _devices[to];
        if (target == null) {
          _send(socket, <String, Object?>{
            'type': 'error',
            'code': 'target_offline',
            'to': to,
          });
          return;
        }
        // The password travels with the call: only the target can check it, and
        // the server has no business storing it. The attempt limit above is the
        // server's part.
        final password = (msg['password'] as String?) ?? '';
        _send(target.ws, <String, Object?>{
          'type': 'incoming',
          'from': selfId,
          'fromName': _devices[selfId]?.name ?? '',
          'requiresPassword': password.isNotEmpty,
          'password': password,
        });
        _send(socket, <String, Object?>{'type': 'connect_requested', 'to': to});
        return;

      case 'accept':
      case 'reject':
        final to = msg['to'];
        if (to is! String || to.isEmpty) {
          _send(socket, <String, Object?>{'type': 'error', 'code': 'no_target'});
          return;
        }
        final payload = <String, Object?>{
          'type': msg['type'] == 'accept' ? 'accepted' : 'rejected',
          'from': selfId,
        };
        if (msg['type'] == 'accept' && msg['password'] is String) {
          payload['password'] = msg['password'];
        }
        if (!_deliver(to, payload)) {
          _send(socket, <String, Object?>{
            'type': 'error',
            'code': 'target_offline',
            'to': to,
          });
        }
        return;

      case 'offer':
      case 'answer':
      case 'ice':
      case 'candidate':
        final to = msg['to'];
        if (to is! String || to.isEmpty) {
          _send(socket, <String, Object?>{'type': 'error', 'code': 'no_target'});
          return;
        }
        final payload = <String, Object?>{'type': msg['type'], 'from': selfId};
        if (msg.containsKey('sdp')) payload['sdp'] = msg['sdp'];
        if (msg.containsKey('candidate')) payload['candidate'] = msg['candidate'];
        if (!_deliver(to, payload)) {
          _send(socket, <String, Object?>{
            'type': 'error',
            'code': 'target_offline',
            'to': to,
          });
        }
        return;

      case 'leave':
        final to = msg['to'];
        if (to is String && to.isNotEmpty) {
          _deliver(to, <String, Object?>{'type': 'peer_left', 'from': selfId});
        }
        return;

      case 'ping':
        _send(socket, <String, Object?>{'type': 'pong', 'ts': DateTime.now().millisecondsSinceEpoch});
        return;

      default:
        _send(socket, <String, Object?>{
          'type': 'error',
          'code': 'unknown_type',
          'got': '${msg['type']}',
        });
    }
  }

  bool _deliver(String toId, Map<String, Object?> payload) {
    final target = _devices[toId];
    if (target == null) return false;
    _send(target.ws, payload);
    return true;
  }

  void _broadcast(Map<String, Object?> payload, {String? exceptId}) {
    for (final entry in _devices.entries) {
      if (entry.key == exceptId) continue;
      _send(entry.value.ws, payload);
    }
  }

  void _send(WebSocket ws, Map<String, Object?> payload) {
    if (ws.readyState != WebSocket.open) return;
    try {
      ws.add(jsonEncode(payload));
    } catch (e) {
      onLog?.call('发送失败: $e');
    }
  }

  ({bool ok, int retryAfter}) _checkBudget(String callerId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = _budgets[callerId];
    if (entry == null || now >= entry.resetAt) {
      _budgets[callerId] = _Budget(count: 1, resetAt: now + _callWindowMs);
      return (ok: true, retryAfter: 0);
    }
    if (entry.count >= _callMaxPerWindow) {
      return (ok: false, retryAfter: ((entry.resetAt - now) / 1000).ceil());
    }
    entry.count += 1;
    return (ok: true, retryAfter: 0);
  }

  void _sweepBudgets() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _budgets.removeWhere((_, entry) => now >= entry.resetAt);
  }

  static String _randomId() {
    const alphabet = 'abcdef0123456789';
    final random = Random.secure();
    return List<String>.generate(
      8,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }
}

class _Device {
  _Device({required this.ws, required this.name});

  final WebSocket ws;
  final String name;
  DateTime lastSeen = DateTime.now();
}

class _Budget {
  _Budget({required this.count, required this.resetAt});

  int count;
  final int resetAt;
}
