import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/input_event.dart' as proto;
import 'package:remotedesk/src/mobile/hid_text.dart';

void main() {
  group('strokeFor', () {
    test('letters carry their own shift state', () {
      expect(strokeFor('a'), const HidStroke(proto.InputKey.keyA));
      expect(strokeFor('A'), const HidStroke(proto.InputKey.keyA, shift: true));
      expect(strokeFor('z'), const HidStroke(proto.InputKey.keyZ));
    });

    test('digits and their shifted symbols', () {
      expect(strokeFor('7'), const HidStroke(proto.InputKey.digit7));
      expect(strokeFor('!'), const HidStroke(proto.InputKey.digit1, shift: true));
      expect(strokeFor(')'), const HidStroke(proto.InputKey.digit0, shift: true));
    });

    test('punctuation maps to the key a real keyboard would press', () {
      expect(strokeFor('.'), const HidStroke(proto.InputKey.period));
      expect(strokeFor('>'), const HidStroke(proto.InputKey.period, shift: true));
      expect(strokeFor('?'), const HidStroke(proto.InputKey.slash, shift: true));
      expect(strokeFor(' '), const HidStroke(proto.InputKey.space));
      expect(strokeFor('\n'), const HidStroke(proto.InputKey.enter));
    });

    test('anything the channel cannot type is refused, not guessed', () {
      expect(strokeFor('中'), isNull);
      expect(strokeFor('é'), isNull);
      expect(strokeFor('🙂'), isNull);
      expect(strokeFor(''), isNull);
    });
  });

  group('HidTextBridge', () {
    test('typing appends only the new characters', () {
      final sent = <HidStroke>[];
      final bridge = HidTextBridge(sent.add);
      expect(bridge.accept('a'), 'a');
      expect(sent, <HidStroke>[const HidStroke(proto.InputKey.keyA)]);

      sent.clear();
      expect(bridge.accept('ab'), 'ab');
      expect(sent, <HidStroke>[const HidStroke(proto.InputKey.keyB)]);
    });

    test('backspace is sent for deleted characters', () {
      final sent = <HidStroke>[];
      final bridge = HidTextBridge(sent.add);
      bridge.accept('abc');
      sent.clear();
      bridge.accept('a');
      expect(sent, <HidStroke>[
        const HidStroke(proto.InputKey.backspace),
        const HidStroke(proto.InputKey.backspace),
      ]);
    });

    test('replacing the middle of a line backspaces then retypes', () {
      final sent = <HidStroke>[];
      final bridge = HidTextBridge(sent.add);
      bridge.accept('abcd');
      sent.clear();
      bridge.accept('aXd');
      // Common prefix is "a"; the other three characters go away and the new
      // tail is typed, which is exactly what a person would have done by hand.
      expect(sent, <HidStroke>[
        const HidStroke(proto.InputKey.backspace),
        const HidStroke(proto.InputKey.backspace),
        const HidStroke(proto.InputKey.backspace),
        const HidStroke(proto.InputKey.keyX, shift: true),
        const HidStroke(proto.InputKey.keyD),
      ]);
    });

    test('characters that cannot be typed are dropped from the field', () {
      final sent = <HidStroke>[];
      final bridge = HidTextBridge(sent.add);
      // A Chinese IME commits text in one go; showing it in the field while it
      // never reaches the remote machine would be a lie.
      expect(bridge.accept('ab中文cd'), 'abcd');
      expect(bridge.dropped, 2);
      expect(sent.map((s) => s.key), <proto.InputKey>[
        proto.InputKey.keyA,
        proto.InputKey.keyB,
        proto.InputKey.keyC,
        proto.InputKey.keyD,
      ]);
    });

    test('shifted characters press shift around the key', () {
      final sent = <HidStroke>[];
      final bridge = HidTextBridge(sent.add);
      bridge.accept('A');
      expect(sent.single.shift, isTrue);
    });

    test('clear resets the diff baseline', () {
      final sent = <HidStroke>[];
      final bridge = HidTextBridge(sent.add);
      bridge.accept('abc');
      bridge.clear();
      sent.clear();
      bridge.accept('ab');
      expect(sent.where((s) => s.key == proto.InputKey.backspace), isEmpty);
    });
  });
}
