import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'peer_info.dart';

/// Finds other RemoteDesk instances without being told an address.
///
/// Two channels, because neither covers the user's actual life on its own:
///
///  * **Tailscale** — the tailnet already knows every machine, its name, and
///    whether it is awake. This is the channel that works from home against an
///    office machine, and it is the only one that can say "that machine exists
///    but is switched off" instead of "not found".
///  * **UDP broadcast** — no account, no client, no configuration. Two machines
///    on the same Wi-Fi find each other in under two seconds. Tailnet traffic is
///    point-to-point, so broadcasts never cross it; that is why both exist.
///
/// Both feed the same list and the result is de-duplicated by device id: the
/// same laptop reached over Wi-Fi and over the tailnet is one row.
class PeerDiscovery {
  PeerDiscovery({this.onLog});

  final void Function(String message)? onLog;

  /// Where LAN presence is announced. Fixed, so two installs agree without
  /// configuration.
  static const int discoveryPort = 8789;
  static const int defaultServerPort = 8787;

  /// Wire format. Versioned so a future change cannot be misread by an old
  /// build as a valid announcement.
  static const String _probe = 'RDSK1?';
  static const String _announcePrefix = 'RDSK1!';

  RawDatagramSocket? _responder;
  Timer? _announceTimer;
  String _selfId = '';
  int _selfPort = defaultServerPort;

  bool get responding => _responder != null;

  /// Answer other machines' probes. Call once at startup.
  ///
  /// Failure is silent by design: a machine where UDP 8789 is taken (another
  /// copy, a firewall) still works — it just will not be *found*, and the
  /// pairing code covers that case.
  Future<void> startResponder({
    required String selfId,
    int selfPort = defaultServerPort,
  }) async {
    _selfId = selfId;
    _selfPort = selfPort;
    if (_responder != null) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _responder = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final text = utf8.decode(datagram.data, allowMalformed: true).trim();
        if (text != _probe) return;
        _replyTo(socket, datagram.address, datagram.port);
      });
      onLog?.call('局域网发现已开启（UDP $discoveryPort）');
    } catch (e) {
      onLog?.call('局域网发现未能开启（不影响使用，可用配对码）：$e');
    }
  }

  void _replyTo(RawDatagramSocket socket, InternetAddress to, int port) {
    final payload = jsonEncode(<String, Object?>{
      'id': _selfId,
      'name': _selfId,
      'port': _selfPort,
      'platform': Platform.operatingSystem,
    });
    final bytes = utf8.encode('$_announcePrefix$payload');
    try {
      socket.send(bytes, to, port);
    } catch (_) {
      // Peer vanished between probe and reply; nothing to do.
    }
  }

  /// Re-announce ourselves periodically so a machine that starts scanning later
  /// does not have to wait for the other side to restart.
  void startAnnouncing({Duration every = const Duration(seconds: 20)}) {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(every, (_) => _announceOnce());
  }

  Future<void> _announceOnce() async {
    final socket = await _openBroadcastSocket();
    if (socket == null) return;
    try {
      final payload = jsonEncode(<String, Object?>{
        'id': _selfId,
        'name': _selfId,
        'port': _selfPort,
        'platform': Platform.operatingSystem,
      });
      final bytes = utf8.encode('$_announcePrefix$payload');
      for (final target in await _broadcastTargets()) {
        try {
          socket.send(bytes, InternetAddress(target), discoveryPort);
        } catch (_) {}
      }
    } finally {
      socket.close();
    }
  }

  /// One full scan. Returns whatever answered within [timeout]; never throws.
  Future<List<PeerInfo>> scan({
    Duration timeout = const Duration(milliseconds: 1600),
  }) async {
    final results = await Future.wait(<Future<List<PeerInfo>>>[
      _scanLan(timeout: timeout),
      _scanTailscale(timeout: timeout),
    ]);
    return mergePeers(<PeerInfo>[for (final list in results) ...list]);
  }

  /// Ask the local network. Sends a probe, collects announcements for [timeout].
  Future<List<PeerInfo>> _scanLan({required Duration timeout}) async {
    final socket = await _openBroadcastSocket();
    if (socket == null) return const <PeerInfo>[];
    final found = <String, PeerInfo>{};
    // Own probe reaches our own responder too; filter by id.
    void collect() {
      final datagram = socket.receive();
      if (datagram == null) return;
      final text = utf8.decode(datagram.data, allowMalformed: true).trim();
      if (!text.startsWith(_announcePrefix)) return;
      final peer = _peerFromAnnouncement(text, datagram.address.address);
      if (peer == null || peer.id == _selfId) return;
      found[peer.id] = peer;
    }

    final sub = socket.listen((event) {
      if (event == RawSocketEvent.read) collect();
    });
    try {
      final bytes = utf8.encode(_probe);
      for (final target in await _broadcastTargets()) {
        try {
          socket.send(bytes, InternetAddress(target), discoveryPort);
        } catch (_) {}
      }
      await Future<void>.delayed(timeout);
      // Drain anything still queued after the last event.
      while (socket.receive() != null) {}
    } finally {
      await sub.cancel();
      socket.close();
    }
    return found.values.toList();
  }

  PeerInfo? _peerFromAnnouncement(String text, String fromAddress) {
    try {
      final json = jsonDecode(text.substring(_announcePrefix.length));
      if (json is! Map<String, Object?>) return null;
      final id = json['id'];
      if (id is! String || id.isEmpty) return null;
      final port = json['port'];
      return PeerInfo(
        id: id,
        host: fromAddress,
        port: port is int ? port : defaultServerPort,
        name: (json['name'] as String?) ?? id,
        platform: (json['platform'] as String?) ?? '',
        source: PeerSource.lan,
      );
    } catch (_) {
      return null;
    }
  }

  Future<RawDatagramSocket?> _openBroadcastSocket() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      socket.broadcastEnabled = true;
      return socket;
    } catch (_) {
      return null;
    }
  }

  /// Broadcast addresses for this machine.
  ///
  /// `255.255.255.255` alone is unreliable on macOS and on interfaces with a
  /// non-/24 mask, so the per-interface guess (`a.b.c.255`) is included as well.
  /// Tailnet addresses are skipped: they are point-to-point and broadcasting
  /// down one accomplishes nothing.
  Future<List<String>> _broadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final nic in interfaces) {
        for (final addr in nic.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          if (parts[0] == '100') continue; // tailnet / CGNAT
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {}
    return targets.toList();
  }

  // ------------------------------------------------------------- tailscale

  /// Nodes from `tailscale status --json`, verified by probing `/info`.
  ///
  /// The node list is authoritative about existence and wakefulness but says
  /// nothing about whether RemoteDesk is running there. So every node is probed
  /// on the app's port; a node that answers becomes a usable row, and a node
  /// that is online but silent is dropped rather than shown as connectable.
  Future<List<PeerInfo>> _scanTailscale({required Duration timeout}) async {
    final nodes = await _tailscaleNodes();
    if (nodes.isEmpty) return const <PeerInfo>[];
    final probes = nodes.map((node) async {
      final info = await probeInfo(
        node.host,
        port: defaultServerPort,
        timeout: const Duration(milliseconds: 900),
      );
      if (info == null) return null;
      final id = (info['id'] as String?) ?? '';
      if (id.isEmpty) return null;
      return PeerInfo(
        id: id,
        host: node.host,
        port: defaultServerPort,
        // Prefer the tailnet host name: it is what the user calls the machine.
        name: node.name.isNotEmpty ? node.name : id,
        platform: (info['platform'] as String?) ?? node.platform,
        source: PeerSource.tailscale,
      );
    }).toList();
    final settled = await Future.wait(probes);
    return <PeerInfo>[for (final p in settled) ?p];
  }

  /// Raw node list, independent of whether the app runs there.
  Future<List<_TsNode>> _tailscaleNodes() async {
    final raw = await _runTailscale(<String>['status', '--json'], onLog: onLog);
    if (raw == null) return const <_TsNode>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return const <_TsNode>[];
      final peers = decoded['Peer'];
      if (peers is! Map<String, Object?>) return const <_TsNode>[];
      final nodes = <_TsNode>[];
      for (final entry in peers.values) {
        if (entry is! Map<String, Object?>) continue;
        if (entry['Online'] != true) continue;
        final ips = entry['TailscaleIPs'];
        if (ips is! List) continue;
        // IPv4 first: the WebSocket URL has to be dialable, and an IPv6 link
        // would need bracketing that nothing else in this code path expects.
        final v4 = ips.whereType<String>().firstWhere(
              (ip) => !ip.contains(':'),
              orElse: () => '',
            );
        if (v4.isEmpty) continue;
        final hostName = (entry['HostName'] as String?) ?? '';
        nodes.add(_TsNode(
          host: v4,
          name: hostName,
          platform: (entry['OS'] as String?) ?? '',
        ));
      }
      return nodes;
    } catch (e) {
      onLog?.call('解析 Tailscale 节点失败：$e');
      return const <_TsNode>[];
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _responder?.close();
    _responder = null;
  }
}

class _TsNode {
  const _TsNode({required this.host, this.name = '', this.platform = ''});
  final String host;
  final String name;
  final String platform;
}

/// A readable device name for this machine, or '' if nothing usable is found.
///
/// The tailnet's own DNS name is the best source: it is a short, ASCII,
/// human-chosen label (`mac-mini`, `win-pc`) that the other person can recognise and
/// type, and it is identical on every machine that can see this one. Falling
/// back to the hostname gives `yushundongdemac-mini-279` — ugly but unique, and
/// it is only a default the user can edit.
Future<String> suggestedDeviceName() async {
  // A phone reports `localhost` as its hostname and has no tailnet CLI, so the
  // desktop default would name every phone "localhost" — the one name that
  // tells the person on the other end nothing. A short random tag at least
  // distinguishes two phones, and renaming is one tap on the desktop side.
  if (Platform.isAndroid || Platform.isIOS) {
    final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'phone-${tag.substring(tag.length - 4)}';
  }
  final fromTailscale = await _tailscaleSelfName();
  if (fromTailscale.isNotEmpty) return fromTailscale;
  try {
    return sanitizeDeviceName(Platform.localHostname);
  } catch (_) {
    return '';
  }
}

/// First label of the tailnet's DNS name for this node.
Future<String> _tailscaleSelfName() async {
  final raw = await _runTailscale(<String>['status', '--json']);
  if (raw == null) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) return '';
    final self = decoded['Self'];
    if (self is! Map<String, Object?>) return '';
    // DNSName arrives fully qualified and trailing-dotted: `mac-mini.tail….ts.net.`
    final dns = (self['DNSName'] as String?) ?? '';
    return sanitizeDeviceName(dns);
  } catch (_) {
    return '';
  }
}

/// Reduce anything to a name that survives being typed, logged, and put in a
/// URL: lowercase ASCII, no spaces, no dots.
///
/// Non-ASCII is dropped rather than transliterated. `某人的Mac mini` — a real
/// hostname on this machine — becomes `mac-mini`, which is what a person would
/// have typed anyway.
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

/// Run `tailscale <args>` and return stdout, or null if no CLI works.
///
/// Absolute paths come first and a bare `tailscale` comes last, because a GUI
/// app launched from Finder gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — the
/// Homebrew and MacPorts locations are *not* on it. Trying the bare name first
/// (and trusting it) was the bug that kept the tailnet channel silently dead
/// while the LAN channel worked.
///
/// Failures are reported through [onLog] rather than swallowed: this channel
/// going quiet is indistinguishable from "no other machines exist", and that
/// ambiguity is what makes it hard to diagnose.
Future<String?> _runTailscale(
  List<String> args, {
  void Function(String message)? onLog,
}) async {
  final problems = <String>[];
  for (final cli in await _tailscaleCliCandidates()) {
    try {
      final result = await Process.run(
        cli,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) {
        return result.stdout as String;
      }
      final err = (result.stderr as String).trim();
      problems.add('$cli → exit ${result.exitCode}${err.isEmpty ? '' : ': ${err.split('\n').first}'}');
    } catch (e) {
      problems.add('$cli → ${e.runtimeType}');
    }
  }
  onLog?.call('Tailscale 命令行不可用，只能靠局域网发现（${problems.join('; ')}）');
  return null;
}

Future<List<String>> _tailscaleCliCandidates() async {
  final absolute = <String>[
    if (Platform.isWindows) ...<String>[
      r'C:\Program Files\Tailscale\tailscale.exe',
      r'C:\Program Files (x86)\Tailscale\tailscale.exe',
    ] else ...<String>[
      '/usr/local/bin/tailscale',
      '/opt/homebrew/bin/tailscale',
      '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
      '/usr/bin/tailscale',
    ],
  ];
  final found = <String>[
    for (final path in absolute)
      if (await File(path).exists()) path,
  ];
  if (found.isNotEmpty) return found;
  // Last resort: whatever the shell would resolve. Only reached when every
  // absolute path is missing, which is also the case where this is cheap.
  return <String>[Platform.isWindows ? 'tailscale.exe' : 'tailscale'];
}

/// One `GET /info` against a candidate address.
///
/// Returns null for anything that is not a RemoteDesk server: connection
/// refused, timeout, HTML from some other service on 8787, truncated JSON. The
/// caller treats null as "nothing there", which is the safe reading — a wrong
/// positive would put a useless row in the list.
Future<Map<String, Object?>?> probeInfo(
  String host, {
  int port = PeerDiscovery.defaultServerPort,
  Duration timeout = const Duration(milliseconds: 900),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = (_) => 'DIRECT';
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/info'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['app'] != 'remotedesk') return null;
    return decoded;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
