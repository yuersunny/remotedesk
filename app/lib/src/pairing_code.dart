import 'peer_info.dart';

/// Everything needed to dial a machine, packed into one line of text.
///
/// The old flow asked for three things in two places (address in 高级设置,
/// id + password in the connect card) and made the user work out which machine
/// should host the relay. All three values travel together in practice — one
/// person reads them off a screen and the other types them — so they are
/// exchanged as a single line that can be pasted whole.
///
/// Format: `RDSK1 <host>:<port> <id> <password>`
///
///   RDSK1 100.101.102.104:8787 win-pc 7Q4WT9
///
/// The `RDSK1` prefix is what makes parsing unambiguous: once it is present,
/// the field order is known, so an id that looks like a host name (`mac-mini`)
/// cannot be mistaken for one. Without the prefix the parser falls back to
/// shape-sniffing, which is enough for a bare `ws://…` or `host:port`.
class PairingCode {
  const PairingCode({
    required this.host,
    required this.id,
    this.port = 8787,
    this.password = '',
  });

  final String host;
  final int port;
  final String id;
  final String password;

  String get serverUrl => 'ws://$host:$port/ws';

  PeerInfo toPeer() => PeerInfo(
        id: id,
        host: host,
        port: port,
        name: id,
        source: PeerSource.manual,
      );

  /// The line to hand over. Password included: it is already displayed on the
  /// controlled machine's screen for exactly this purpose, and splitting it out
  /// would put the user back to typing two fields.
  String encode() {
    final peer = '$host:$port';
    return password.isEmpty
        ? 'RDSK1 $peer $id'
        : 'RDSK1 $peer $id $password';
  }

  static const String _prefix = 'RDSK1';

  /// Parse anything a user might paste. Returns null when the text carries no
  /// usable address — the caller shows "这行字看不懂" rather than connecting to
  /// a guess.
  static PairingCode? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final tokens = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return null;

    // Strip the prefix case-insensitively: it gets retyped by hand from time to
    // time, and `rdsk1` failing while `RDSK1` works is a pointless difference.
    var hasPrefix = false;
    if (tokens.first.toUpperCase() == _prefix) {
      hasPrefix = true;
      tokens.removeAt(0);
    }
    if (tokens.isEmpty) return null;

    // Without the prefix the field order is not contractual, so the first token
    // has to earn its place by looking like an address. Checked here rather
    // than after the id/password split: otherwise a stray `??` is accepted as a
    // host name and the user gets a timeout instead of "这行字看不懂".
    if (!hasPrefix && !_looksLikeAddress(tokens.first)) return null;

    final address = _parseAddress(tokens.first);
    if (address == null) return null;

    final rest = tokens.sublist(1);
    if (rest.isEmpty) {
      // A bare address. Still useful — the manual field accepts it — but there
      // is no id to target yet, so the caller must ask for one.
      return PairingCode(
        host: address.$1,
        port: address.$2,
        id: '',
      );
    }

    final id = rest.first;
    // Everything after the id is the password. Auto-generated passwords have no
    // spaces, but a hand-typed one might, and dropping the tail silently would
    // produce a "password is wrong" that looks like a server fault.
    final password = rest.length > 1 ? rest.sublist(1).join() : '';

    return PairingCode(
      host: address.$1,
      port: address.$2,
      id: id,
      password: password,
    );
  }

  /// `ws://1.2.3.4:8787/ws`, `1.2.3.4:8787`, `1.2.3.4`, `mac-mini:8787` → tuple.
  static (String, int)? _parseAddress(String token) {
    var value = token;

    if (value.contains('://')) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.host.isEmpty) return null;
      final port = uri.hasPort ? uri.port : 8787;
      return (uri.host, _sanePort(port));
    }

    // Trailing path such as `/ws` on a host that was given without a scheme.
    final slash = value.indexOf('/');
    if (slash > 0) value = value.substring(0, slash);

    final colon = value.lastIndexOf(':');
    if (colon > 0) {
      final host = value.substring(0, colon);
      final port = int.tryParse(value.substring(colon + 1));
      if (port != null && host.isNotEmpty) return (host, _sanePort(port));
    }

    return value.isEmpty ? null : (value, 8787);
  }

  static int _sanePort(int port) =>
      port > 0 && port <= 65535 ? port : 8787;

  static final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// Conservative on purpose. A wrong "yes" here connects to nonsense; a wrong
  /// "no" just means the user has to include the `RDSK1` prefix, which the UI
  /// tells them.
  static bool _looksLikeAddress(String token) {
    if (token.contains('://')) return true;
    if (_ipv4.hasMatch(token.split(':').first)) return true;
    // host:port with a numeric port.
    final parts = token.split(':');
    if (parts.length == 2 && int.tryParse(parts[1]) != null) return true;
    return false;
  }
}
