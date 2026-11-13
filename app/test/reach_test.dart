import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/reach.dart';

/// The badge on the "这台电脑" card decides what the user does next: install a
/// tunnel, or nothing. Getting the classification wrong is therefore worse than
/// showing nothing — it either sends someone to configure a router they do not
/// need, or promises a connection that will not happen.
void main() {
  group('private ranges are LAN-only', () {
    test('192.168.x.x', () {
      expect(classifyReach(<String>['192.168.1.20']).kind, ReachKind.lanOnly);
      expect(classifyReach(<String>['192.168.1.20']).worksFromOutside, isFalse);
    });

    test('10.x.x.x', () {
      expect(classifyReach(<String>['10.0.0.5']).kind, ReachKind.lanOnly);
    });

    test('172.16–31.x.x but not 172.32', () {
      expect(classifyReach(<String>['172.16.0.1']).kind, ReachKind.lanOnly);
      expect(classifyReach(<String>['172.31.255.254']).kind, ReachKind.lanOnly);
      // 172.32 is outside 172.16.0.0/12 — treating it as private would hide a
      // genuinely public address behind a "cannot work from outside" badge.
      expect(classifyReach(<String>['172.32.0.1']).kind, ReachKind.publicIp);
    });

    test('link-local is not public', () {
      expect(classifyReach(<String>['169.254.10.10']).kind, ReachKind.lanOnly);
    });
  });

  group('tailnet wins over everything', () {
    test('100.64.0.0/10 is the tailnet range', () {
      expect(classifyReach(<String>['100.64.0.1']).kind, ReachKind.tailscale);
      expect(classifyReach(<String>['100.127.255.254']).kind, ReachKind.tailscale);
      expect(classifyReach(<String>['100.101.102.103']).worksFromOutside, isTrue);
    });

    test('just outside the range is not a tailnet', () {
      expect(classifyReach(<String>['100.63.0.1']).kind, ReachKind.publicIp);
      expect(classifyReach(<String>['100.128.0.1']).kind, ReachKind.publicIp);
    });

    test('a LAN address plus a tailnet address reports the tailnet', () {
      final reach = classifyReach(<String>['192.168.1.20', '100.90.1.2']);
      expect(reach.kind, ReachKind.tailscale);
      expect(reach.chosen, '100.90.1.2',
          reason: '广告出去的那个地址必须是出门也能用的那个');
    });
  });

  group('public addresses are a maybe, never a yes', () {
    test('a routable address is publicIp, not tailscale', () {
      final reach = classifyReach(<String>['203.0.113.9']);
      expect(reach.kind, ReachKind.publicIp);
      // A carrier-grade NAT hands out addresses like this and forwards nothing,
      // so claiming "works from outside" here would be a lie.
      expect(reach.worksFromOutside, isFalse);
    });
  });

  group('no addresses', () {
    test('empty list is unknown, not LAN-only', () {
      final reach = classifyReach(const <String>[]);
      expect(reach.kind, ReachKind.none);
      expect(reach.chosen, isNull);
      expect(reach.worksFromOutside, isFalse);
    });

    test('garbage entries are skipped rather than crashing', () {
      expect(classifyReach(<String>['', 'not-an-ip']).kind, ReachKind.none);
      expect(
        classifyReach(<String>['999.1.1.1', '192.168.1.5']).kind,
        ReachKind.lanOnly,
      );
    });
  });

  test('the chosen address matches what pickPeerAddress advertises', () {
    // Both end up on screen at once (badge + pairing code); if they disagreed
    // the user would be told "出门也能连" while copying a 192.168 address.
    const addresses = <String>['192.168.1.20', '100.90.1.2'];
    expect(classifyReach(addresses).chosen, '100.90.1.2');
  });

  group('a single pasted address (phone, dialling out)', () {
    test('100.64–127 is a tailnet address', () {
      expect(classifyAddress('100.90.1.2'), AddressKind.tailnet);
      expect(classifyAddress('100.64.0.1'), AddressKind.tailnet);
      expect(classifyAddress('100.127.255.254'), AddressKind.tailnet);
    });

    test('just outside the tailnet range is public, not tailnet', () {
      expect(classifyAddress('100.63.0.1'), AddressKind.publicIp);
      expect(classifyAddress('100.128.0.1'), AddressKind.publicIp);
    });

    test('RFC1918 and loopback are LAN', () {
      expect(classifyAddress('192.168.1.20'), AddressKind.lan);
      expect(classifyAddress('10.0.0.8'), AddressKind.lan);
      expect(classifyAddress('172.16.4.2'), AddressKind.lan);
      expect(classifyAddress('127.0.0.1'), AddressKind.lan);
    });

    test('host names and junk are neither LAN nor a route to promise', () {
      expect(classifyAddress('mac-mini'), AddressKind.other);
      expect(classifyAddress(''), AddressKind.other);
      expect(classifyAddress('999.1.1.1'), AddressKind.other);
      // PairingCode strips the port before this is called, but tolerate one.
      expect(classifyAddress('100.90.1.2:8787'), AddressKind.other);
    });
  });
}
