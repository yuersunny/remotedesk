/// Web build: nothing can listen on a socket from a browser tab.
///
/// Kept as a same-shaped no-op rather than an `if (kIsWeb)` in the caller, so
/// the UI code has exactly one path and `flutter build web` still compiles
/// (a browser has no `HttpServer` to reference at all).
class LocalSignalingServer {
  LocalSignalingServer({this.onLog});

  final void Function(String message)? onLog;

  bool get running => false;
  int get port => 0;
  int get deviceCount => 0;

  /// `false`, not an exception: "could not host here" is a normal outcome for
  /// a browser tab and the caller only ever branches on it.
  Future<bool> start({int port = 8787}) async {
    onLog?.call('网页版不能当服务器：请在两台电脑上用桌面版，或直接连对方地址');
    return false;
  }

  Future<void> stop() async {}
}

/// A browser tab has no address of its own to offer.
Future<List<String>> localIpv4Addresses() async => const <String>[];

/// Nothing to advertise, so nothing to pick — `null` keeps the caller from
/// building `ws://:8787/ws` out of an empty string.
String? pickPeerAddress(List<String> addresses) => null;
