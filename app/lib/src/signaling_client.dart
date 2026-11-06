import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Minimal WebSocket signaling client for RemoteDesk.
///
/// It speaks the protocol documented in `docs/protocol.md` and exposes every
/// inbound frame as a `Map<String, dynamic>` on [events] so the UI can render a
/// live handshake log without knowing message details.
class SignalingClient {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isConnected => _channel != null;
  String? selfId;

  Future<void> connect({
    required String url,
    required String id,
    String name = '',
    String token = '',
  }) async {
    await disconnect();

    final channel = WebSocketChannel.connect(Uri.parse(url));
    _channel = channel;
    await channel.ready;

    _sub = channel.stream.listen(
      _onData,
      onError: (Object e) => _emit({'type': 'transport_error', 'error': '$e'}),
      onDone: () => _emit({'type': 'transport_closed'}),
      cancelOnError: false,
    );

    _emit({'type': 'transport_open'});
    send({'type': 'register', 'id': id, 'name': name, 'token': token});
  }

  void _onData(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is Map<String, dynamic>) {
        if (decoded['type'] == 'registered' && decoded['id'] is String) {
          selfId = decoded['id'] as String;
        }
        _emit(decoded);
      } else {
        _emit({'type': 'bad_frame', 'raw': raw.toString()});
      }
    } catch (_) {
      _emit({'type': 'bad_frame', 'raw': raw.toString()});
    }
  }

  void _emit(Map<String, dynamic> message) {
    if (!_events.isClosed) _events.add(message);
  }

  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void listDevices() => send({'type': 'list'});

  void connectTo(String to, {String? password}) => send({
        'type': 'connect',
        'to': to,
        'password': ?password,
      });

  void accept(String to, {String? password}) => send({
        'type': 'accept',
        'to': to,
        'password': ?password,
      });

  void reject(String to) => send({'type': 'reject', 'to': to});

  void sendOffer(String to, Map<String, dynamic> sdp) =>
      send({'type': 'offer', 'to': to, 'sdp': sdp});

  void sendAnswer(String to, Map<String, dynamic> sdp) =>
      send({'type': 'answer', 'to': to, 'sdp': sdp});

  void sendIce(String to, Map<String, dynamic> candidate) =>
      send({'type': 'ice', 'to': to, 'candidate': candidate});

  void leave(String to) => send({'type': 'leave', 'to': to});

  void ping() => send({'type': 'ping'});

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {
      // channel may already be dead
    }
    _channel = null;
  }

  void dispose() {
    disconnect();
    _events.close();
  }
}
