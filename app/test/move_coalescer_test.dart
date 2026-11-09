import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/input_channel.dart';
import 'package:remotedesk/src/input_event.dart';

/// The coalescer is the whole reason a remote pointer stops falling behind, and
/// its failure mode is silent — the cursor still moves, just later and later. So
/// the properties are pinned down here rather than eyeballed in a session.
void main() {
  group('MoveCoalescer', () {
    test('keeps only the newest sample between takes', () {
      final coalescer = MoveCoalescer();
      coalescer.submit(const PointerMove(0.1, 0.1));
      coalescer.submit(const PointerMove(0.2, 0.2));
      coalescer.submit(const PointerMove(0.3, 0.3));

      final taken = coalescer.take();
      expect(taken, isNotNull);
      expect(taken!.x, closeTo(0.3, 1e-9));
      expect(taken.y, closeTo(0.3, 1e-9));
      expect(coalescer.dropped, 2,
          reason: '两次覆盖必须被记为丢弃，否则「合并生效」无从证明');
    });

    test('a taken slot is empty until the next submit', () {
      final coalescer = MoveCoalescer();
      coalescer.submit(const PointerMove(0.5, 0.5));
      expect(coalescer.take(), isNotNull);
      expect(coalescer.take(), isNull, reason: '同一帧不能把同一个位置发两次');
      expect(coalescer.hasPending, isFalse);
    });

    test('clear drops the pending sample', () {
      final coalescer = MoveCoalescer();
      coalescer.submit(const PointerMove(0.7, 0.7));
      coalescer.clear();
      expect(coalescer.take(), isNull);
    });

    test('a burst of 120 events collapses to one send', () {
      // 60 fps of mouse input for two seconds. Without coalescing this is 120
      // queued frames; with it, one per tick.
      final coalescer = MoveCoalescer();
      for (var i = 0; i < 120; i++) {
        coalescer.submit(PointerMove(i / 120, i / 120));
      }
      expect(coalescer.dropped, 119);
      final taken = coalescer.take();
      expect(taken!.x, closeTo(119 / 120, 1e-9));
    });
  });
}
