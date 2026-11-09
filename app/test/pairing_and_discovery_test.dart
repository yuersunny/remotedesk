import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/pairing_code.dart';
import 'package:remotedesk/src/peer_info.dart';

void main() {
  group('PairingCode 编码', () {
    test('带密码时把三样都写进一行', () {
      const code = PairingCode(
        host: '100.101.102.104',
        id: 'win-pc',
        password: '7Q4WT9',
      );
      expect(code.encode(), 'RDSK1 100.101.102.104:8787 win-pc 7Q4WT9');
      expect(code.serverUrl, 'ws://100.101.102.104:8787/ws');
    });

    test('没有密码时只到 id 为止', () {
      const code = PairingCode(host: '192.168.1.11', id: 'win');
      expect(code.encode(), 'RDSK1 192.168.1.11:8787 win');
    });

    test('自定义端口要保留', () {
      const code = PairingCode(host: '10.0.0.5', port: 9000, id: 'a');
      expect(code.encode(), 'RDSK1 10.0.0.5:9000 a');
    });
  });

  group('PairingCode 解析', () {
    test('编码后再解析回到原值', () {
      const original = PairingCode(
        host: '100.101.102.103',
        id: 'mac-mini',
        password: 'ABC123',
      );
      final back = PairingCode.parse(original.encode())!;
      expect(back.host, original.host);
      expect(back.id, original.id);
      expect(back.password, original.password);
      expect(back.port, original.port);
    });

    test('前缀大小写与多余空白都不影响', () {
      for (final text in <String>[
        'RDSK1 1.2.3.4:8787 win-pc 123456',
        'rdsk1 1.2.3.4:8787 win-pc 123456',
        '  RDSK1   1.2.3.4:8787     win-pc     123456  ',
        'RDSK1\t1.2.3.4:8787\tyu\t123456',
      ]) {
        final code = PairingCode.parse(text)!;
        expect(code.host, '1.2.3.4', reason: text);
        expect(code.id, 'win-pc', reason: text);
        expect(code.password, '123456', reason: text);
      }
    });

    test('接受带 scheme 和 /ws 的地址', () {
      final code = PairingCode.parse('RDSK1 ws://1.2.3.4:8787/ws win-pc 123456')!;
      expect(code.host, '1.2.3.4');
      expect(code.port, 8787);
      expect(code.id, 'win-pc');
    });

    test('没有前缀但地址形状明确时也能认', () {
      final code = PairingCode.parse('ws://1.2.3.4:8787/ws win-pc 123456')!;
      expect(code.host, '1.2.3.4');
      expect(code.id, 'win-pc');
      expect(code.password, '123456');
    });

    test('只有地址时仍给出可用的服务器，id 留空等用户补', () {
      final code = PairingCode.parse('ws://192.168.1.12:8787/ws')!;
      expect(code.host, '192.168.1.12');
      expect(code.id, isEmpty);
      expect(code.serverUrl, 'ws://192.168.1.12:8787/ws');
    });

    test('省略端口时默认 8787', () {
      expect(PairingCode.parse('1.2.3.4')!.port, 8787);
      expect(PairingCode.parse('RDSK1 1.2.3.4 win-pc 1')!.port, 8787);
    });

    test('端口乱填时退回默认值，而不是连到 0 端口', () {
      expect(PairingCode.parse('RDSK1 1.2.3.4:99999 win-pc 1')!.port, 8787);
      expect(PairingCode.parse('RDSK1 1.2.3.4:0 win-pc 1')!.port, 8787);
    });

    test('密码含空格时整段保留', () {
      final code = PairingCode.parse('RDSK1 1.2.3.4 win-pc my pass word')!;
      expect(code.id, 'win-pc');
      expect(code.password, 'mypassword');
    });

    test('无前缀且首项不像地址时拒绝 —— 否则 mac-mini 会被当成主机名', () {
      expect(PairingCode.parse('mac-mini 7Q4WT9'), isNull);
    });

    test('空输入与乱码返回 null', () {
      for (final text in <String>['', '   ', 'RDSK1', 'RDSK1   ', '??']) {
        expect(PairingCode.parse(text), isNull, reason: '「$text」应当解析失败');
      }
    });
  });

  group('mergePeers', () {
    PeerInfo p(String id, {bool online = true, PeerSource? source}) => PeerInfo(
          id: id,
          host: '10.0.0.${id.hashCode.abs() % 200 + 1}',
          name: id,
          online: online,
          source: source ?? PeerSource.lan,
        );

    test('同一台机器两条来源只留一条', () {
      final merged = mergePeers(<PeerInfo>[
        p('mac-mini', source: PeerSource.tailscale),
        p('mac-mini', source: PeerSource.lan),
      ]);
      expect(merged.length, 1);
    });

    test('能联通的一方推翻"离线"的说法', () {
      final merged = mergePeers(<PeerInfo>[
        p('win-pc', online: false, source: PeerSource.tailscale),
        p('win-pc', online: true, source: PeerSource.lan),
      ]);
      expect(merged.single.online, isTrue);
    });

    test('离线不能被离线互相覆盖成"可用"', () {
      final merged = mergePeers(<PeerInfo>[
        p('node', online: false, source: PeerSource.tailscale),
      ]);
      expect(merged.single.online, isFalse);
    });

    test('上次连过的排在最前，其次在线，最后离线', () {
      final merged = mergePeers(
        <PeerInfo>[
          p('off', online: false),
          p('on-1'),
          p('recent'),
          p('on-2'),
        ],
        recentIds: {'recent'},
      );
      expect(merged.first.id, 'recent');
      expect(merged.last.id, 'off');
      expect(merged.map((e) => e.id).take(3), containsAll(<String>['recent']));
    });

    test('同档次内保持发现顺序，避免每次扫描后列表跳动', () {
      final merged = mergePeers(<PeerInfo>[p('a'), p('b'), p('c')]);
      expect(merged.map((e) => e.id).toList(), <String>['a', 'b', 'c']);
    });

    test('没有 id 的手填地址按主机去重', () {
      final merged = mergePeers(<PeerInfo>[
        const PeerInfo(id: '', host: '1.2.3.4'),
        const PeerInfo(id: '', host: '1.2.3.4'),
      ]);
      expect(merged.length, 1);
    });
  });

  group('PeerInfo', () {
    test('serverUrl 直接可用，不用调用方拼字符串', () {
      const peer = PeerInfo(id: 'win-pc', host: '100.101.102.104');
      expect(peer.serverUrl, 'ws://100.101.102.104:8787/ws');
    });

    test('name 为空时显示 id，不留空白行', () {
      const peer = PeerInfo(id: 'win-pc', host: '1.2.3.4');
      expect(peer.displayName, 'win-pc');
    });

    test('json 往返保住所有字段', () {
      const peer = PeerInfo(
        id: 'mac-mini',
        host: '100.101.102.103',
        name: 'mac-mini',
        platform: 'macos',
      );
      final back = PeerInfo.fromJson(peer.toJson())!;
      expect(back.id, peer.id);
      expect(back.host, peer.host);
      expect(back.port, peer.port);
      expect(back.source, PeerSource.remembered);
    });

    test('json 里没有 host 时丢弃这条记录', () {
      expect(PeerInfo.fromJson(<String, Object?>{'id': 'x'}), isNull);
    });
  });
}
