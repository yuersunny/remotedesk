/// Whether this machine can actually be reached from outside its own network.
///
/// The app has always been able to serve a relay on port 8787, but "can someone
/// at home reach my office Mac" depends entirely on *which* address that port
/// answers on — and the old UI never said. The user was left to infer it from
/// an IP in an advanced field, which is why "connect over the internet" looked
/// like a feature that simply did not exist.
///
/// This is a pure classifier over the addresses the OS reports, so it can be
/// unit-tested without a network.
library;

/// How far the signalling port can be reached from.
enum ReachKind {
  /// A tailnet address (`100.64.0.0/10`) is present.
  ///
  /// This is the good case: the same address works on the office LAN *and* from
  /// a phone on mobile data, because Tailscale carries the packets. Nothing
  /// needs to be forwarded on any router.
  tailscale,

  /// Only private addresses (`192.168.x`, `10.x`, `172.16–31.x`).
  ///
  /// Works on the same Wi‑Fi or wired network and nowhere else. Reaching it
  /// from outside requires a tunnel (Tailscale) or a port forward — both of
  /// which the UI has to spell out, because neither is discoverable.
  lanOnly,

  /// A public-looking address. Could be reachable from outside, but only if the
  /// router forwards 8787 here — and a carrier-grade NAT hands out addresses
  /// that look public and forward nothing, so this is a "maybe", never a yes.
  publicIp,

  /// No usable address: no network, or the platform does not expose them.
  none,
}

class ReachInfo {
  const ReachInfo({
    required this.kind,
    this.chosen,
    this.addresses = const <String>[],
  });

  static const ReachInfo unknown = ReachInfo(kind: ReachKind.none);

  final ReachKind kind;

  /// The address that will actually be advertised to the other machine.
  final String? chosen;

  /// Every IPv4 address the machine answers on, for the log and the details.
  final List<String> addresses;

  /// One line a non-technical person can act on.
  String get headline => switch (kind) {
        ReachKind.tailscale => '出门也能连',
        ReachKind.lanOnly => '只能在同一个 Wi-Fi 里连',
        ReachKind.publicIp => '可能能从外面连（要看路由器）',
        ReachKind.none => '还没连上网络',
      };

  /// The sentence under [headline]: what this means, not how DNS works.
  String get detail => switch (kind) {
        ReachKind.tailscale =>
          '这台电脑有一个 Tailscale 地址，手机在外面用流量也能连上。'
              '手机端需要装 Tailscale 并登录同一个账号。',
        ReachKind.lanOnly =>
          '现在的地址是局域网地址。在家里或公司同一个网络里没问题；'
              '人在外面就连不到。要让外面也能连，装上 Tailscale 就行。',
        ReachKind.publicIp =>
          '这台电脑看起来有公网地址。要真正连上，还需要在路由器上把 8787 端口'
              '转发到这台电脑，并且网络不是运营商的大内网。',
        ReachKind.none => '没检测到可用地址，先确认这台电脑已经连上网。',
      };

  /// True when a phone on mobile data can reach this machine without any
  /// router configuration.
  bool get worksFromOutside => kind == ReachKind.tailscale;
}

/// Classify the addresses the OS reports.
///
/// Order matters: a tailnet address wins whenever one exists, because it is the
/// only one that answers from *both* sides of the router. That matches what
/// [pickPeerAddress] advertises, so the badge and the pairing code never
/// disagree.
ReachInfo classifyReach(List<String> addresses) {
  // Drop anything that is not a dotted-quad IPv4 first. An empty or malformed
  // entry used to fall through to the "LAN-only" branch and get advertised as
  // the address to connect to — the badge then read "只能在同一个 Wi-Fi 里连"
  // with a blank address under it.
  final valid = addresses.where((a) => _octets(a) != null).toList(growable: false);
  if (valid.isEmpty) return ReachInfo.unknown;

  for (final address in valid) {
    if (_isTailscale(address)) {
      return ReachInfo(
        kind: ReachKind.tailscale,
        chosen: address,
        addresses: valid,
      );
    }
  }

  final public = valid.where(_isPublic).toList(growable: false);
  if (public.isNotEmpty) {
    return ReachInfo(
      kind: ReachKind.publicIp,
      chosen: public.first,
      addresses: valid,
    );
  }

  return ReachInfo(
    kind: ReachKind.lanOnly,
    chosen: valid.first,
    addresses: valid,
  );
}

/// What a single address in a pasted pairing code means to a phone that is
/// NOT on the same Wi-Fi as the computer.
///
/// `classifyReach` answers "can others reach *this* machine"; a dialling phone
/// needs the opposite question answered: "can I even route to this host from
/// here". A `100.x` tailnet address is the common trap — it looks like a normal
/// IP, but outside a connected Tailscale client it is unroutable, so a phone on
/// 4G/5G will sit in a connection attempt with no clue what went wrong.
enum AddressKind { tailnet, lan, publicIp, other }

AddressKind classifyAddress(String host) {
  final value = host.trim();
  if (_octets(value) == null) return AddressKind.other;
  if (_isTailscale(value)) return AddressKind.tailnet;
  if (!_isPublic(value)) return AddressKind.lan;
  return AddressKind.publicIp;
}

/// `100.64.0.0/10`, the range Tailscale (and some carriers) hand out.
bool _isTailscale(String address) {
  final parts = _octets(address);
  if (parts == null) return false;
  return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127;
}

bool _isPublic(String address) {
  final parts = _octets(address);
  if (parts == null) return false;
  final a = parts[0];
  final b = parts[1];

  if (a == 10) return false; // 10.0.0.0/8
  if (a == 127) return false; // loopback
  if (a == 0) return false;
  if (a == 169 && b == 254) return false; // link-local
  if (a == 172 && b >= 16 && b <= 31) return false; // 172.16.0.0/12
  if (a == 192 && b == 168) return false; // 192.168.0.0/16
  if (a == 192 && b == 0 && parts[2] == 0) return false; // 192.0.0.0/24
  if (a == 198 && (b == 18 || b == 19)) return false; // benchmarking
  if (a >= 224) return false; // multicast + reserved
  return true;
}

List<int>? _octets(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    out.add(value);
  }
  return out;
}
