/// How a peer came to be known.
///
/// The distinction is not cosmetic: it decides what the row can be trusted to
/// mean. A tailnet node that is `offline` still belongs in the list (it exists,
/// it just is not up), while a LAN candidate that failed its probe does not —
/// listing it would turn "对方没开机" into "软件找不到对方".
enum PeerSource {
  /// Found by reading the tailnet's own node list. Carries a real host name and
  /// an authoritative online flag.
  tailscale,

  /// Answered a UDP broadcast on the local network.
  lan,

  /// Typed in, or unpacked from a pairing code.
  manual,

  /// Connected successfully at least once before.
  remembered,
}

/// One RemoteDesk instance this machine can try to reach.
///
/// Everything needed to dial is here — the point is that the UI never has to
/// assemble `ws://host:port/ws` by hand, which was the whole complaint.
class PeerInfo {
  const PeerInfo({
    required this.id,
    required this.host,
    this.port = 8787,
    this.name = '',
    this.source = PeerSource.manual,
    this.online = true,
    this.platform = '',
  });

  /// The device id the peer registered under. This is what `connect` targets.
  final String id;

  /// IP or host name. Tailscale gives both; the LAN path gives an IP.
  final String host;
  final int port;

  /// Human label. Falls back to [id] so a row is never blank.
  final String name;

  final PeerSource source;

  /// False only when the source can say so with authority — currently just
  /// Tailscale reporting the node as offline.
  final bool online;

  final String platform;

  String get serverUrl => 'ws://$host:$port/ws';

  String get displayName => name.isEmpty ? id : name;

  /// Short tag for the row's meta line, e.g. `Tailscale · 100.101.102.103`.
  String get sourceLabel => switch (source) {
        PeerSource.tailscale => 'Tailscale',
        PeerSource.lan => '局域网',
        PeerSource.manual => '手动',
        PeerSource.remembered => '上次连过',
      };

  PeerInfo copyWith({
    String? id,
    String? host,
    int? port,
    String? name,
    PeerSource? source,
    bool? online,
    String? platform,
  }) {
    return PeerInfo(
      id: id ?? this.id,
      host: host ?? this.host,
      port: port ?? this.port,
      name: name ?? this.name,
      source: source ?? this.source,
      online: online ?? this.online,
      platform: platform ?? this.platform,
    );
  }

  /// Identity for de-duplication: the same machine reached over Wi-Fi and over
  /// the tailnet is one row, not two. Device id is the stable key; host is the
  /// fallback for entries that have no id yet (a bare address from the manual
  /// field).
  String get dedupeKey => id.isNotEmpty ? id : '$host:$port';

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'host': host,
        'port': port,
        'name': name,
        'platform': platform,
      };

  static PeerInfo? fromJson(Map<String, Object?> json) {
    final host = json['host'];
    if (host is! String || host.isEmpty) return null;
    final port = json['port'];
    return PeerInfo(
      id: (json['id'] as String?) ?? '',
      host: host,
      port: port is int ? port : 8787,
      name: (json['name'] as String?) ?? '',
      platform: (json['platform'] as String?) ?? '',
      source: PeerSource.remembered,
    );
  }

  @override
  String toString() => 'PeerInfo($id @ $host:$port, ${source.name})';
}

/// Merge candidate lists into what the list should actually show.
///
/// Rules, in order:
///  1. A reachable source beats an unreachable one — being found twice is proof
///     of life, so a LAN hit upgrades a tailnet node that claims to be offline.
///  2. Specific sources beat generic ones (tailnet/lan beat manual, and the
///     remembered entry keeps its place in a separate "last used" slot).
///  3. Order: remembered first, then online, then everything else; ties keep
///     discovery order so the list does not reshuffle between scans.
List<PeerInfo> mergePeers(
  List<PeerInfo> candidates, {
  Set<String> recentIds = const <String>{},
}) {
  final byKey = <String, PeerInfo>{};
  for (final peer in candidates) {
    final existing = byKey[peer.dedupeKey];
    if (existing == null) {
      byKey[peer.dedupeKey] = peer;
      continue;
    }
    // `online: true` from any reachable source wins; otherwise keep whichever
    // description is more specific.
    final preferNew = peer.online && !existing.online;
    byKey[peer.dedupeKey] = preferNew ? peer : existing;
  }

  final merged = byKey.values.toList();
  int rank(PeerInfo p) {
    if (recentIds.contains(p.id) && p.id.isNotEmpty) return 0;
    if (p.online) return 1;
    return 2;
  }

  // Stable sort by rank only — Dart's sort is not stable, so carry the original
  // index as the tie-breaker instead of relying on it.
  final indexed = <(int, PeerInfo)>[
    for (var i = 0; i < merged.length; i++) (i, merged[i]),
  ];
  indexed.sort((a, b) {
    final byRank = rank(a.$2).compareTo(rank(b.$2));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
