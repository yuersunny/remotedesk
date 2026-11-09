import 'peer_info.dart';

/// Browser build: there is no UDP, no subprocess, and no server on this side to
/// announce — a tab is not a machine. Discovery therefore finds nothing, and
/// the UI falls back to the pairing code, which is the only path that makes
/// sense in a browser anyway.
class PeerDiscovery {
  PeerDiscovery({this.onLog});

  final void Function(String message)? onLog;

  static const int discoveryPort = 8789;
  static const int defaultServerPort = 8787;

  bool get responding => false;

  Future<void> startResponder({
    required String selfId,
    int selfPort = defaultServerPort,
  }) async {}

  void startAnnouncing({Duration every = const Duration(seconds: 20)}) {}

  Future<List<PeerInfo>> scan({
    Duration timeout = const Duration(milliseconds: 1600),
  }) async =>
      const <PeerInfo>[];

  Future<void> stop() async {}
}

/// The browser cannot reach a LAN address on a different origin (CORS plus
/// private-network blocking in Chrome), so probing is not attempted.
Future<Map<String, Object?>?> probeInfo(
  String host, {
  int port = PeerDiscovery.defaultServerPort,
  Duration timeout = const Duration(milliseconds: 900),
}) async =>
    null;

/// No hostname, no tailnet, no subprocess in a tab — the caller falls back to a
/// random id, which is the right answer for a browser session anyway.
Future<String> suggestedDeviceName() async => '';

/// Kept identical to the IO implementation so both builds can share tests.
String sanitizeDeviceName(String raw) {
  var value = raw.trim().toLowerCase();
  final dot = value.indexOf('.');
  if (dot > 0) value = value.substring(0, dot);
  value = value.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  value = value.replaceAll(RegExp(r'-+'), '-');
  value = value.replaceAll(RegExp(r'^-|-$'), '');
  if (value.length > 24) value = value.substring(0, 24);
  return value;
}
