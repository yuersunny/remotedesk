import 'package:flutter_test/flutter_test.dart';
import 'package:remotedesk/src/clipboard_sync.dart';
import 'package:remotedesk/src/input_event.dart' show ClipboardEvent, HelloEvent;

/// Stands in for the platform pasteboard.
///
/// Counts reads and writes because the behaviour under test is not "does the
/// text arrive" — that is one line — but *how many times* we push, which is
/// exactly what a ping-pong bug inflates.
class FakeBackend implements ClipboardBackend {
  FakeBackend([this.value]);

  String? value;
  int reads = 0;
  int writes = 0;

  /// Simulates the platform rewriting what we wrote (e.g. adding a trailing
  /// newline), which is how a naive echo check starts a loop.
  String? rewriteOnWrite;

  /// Simulates `OpenClipboard` failing because another program holds it.
  bool failWrite = false;

  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String text) async {
    writes++;
    if (failWrite) return;
    value = rewriteOnWrite ?? text;
  }
}

void main() {
  // Long enough for one poll at the short interval used below.
  const tick = Duration(milliseconds: 25);
  const settle = Duration(milliseconds: 90);

  late FakeBackend backend;
  late List<String> sent;
  late List<String> logs;

  ClipboardSync build({Duration interval = tick}) => ClipboardSync(
        backend: backend,
        pollInterval: interval,
        onLog: logs.add,
        onLocalText: sent.add,
      );

  setUp(() {
    backend = FakeBackend('already here');
    sent = <String>[];
    logs = <String>[];
  });

  group('signature', () {
    test('folds CRLF, which is the only difference between the platforms', () {
      expect(ClipboardSync.signature('a\r\nb'), ClipboardSync.signature('a\nb'));
      expect(ClipboardSync.signature('a\rb'), ClipboardSync.signature('a\nb'));
    });

    test('ignores trailing whitespace', () {
      expect(ClipboardSync.signature('abc  \n\n'), 'abc');
      expect(ClipboardSync.signature('   '), '');
      expect(ClipboardSync.signature(null), '');
    });

    test('keeps leading and internal whitespace', () {
      // Indentation is content: two code snippets that differ only in leading
      // spaces are different snippets.
      expect(ClipboardSync.signature('  abc'), isNot('abc'));
      expect(ClipboardSync.signature('a  b'), isNot('a b'));
    });
  });

  test('connecting does not push what is already on the clipboard', () async {
    final sync = build();
    await sync.start();
    await Future<void>.delayed(settle);
    expect(sent, isEmpty, reason: 'baseline content is not news');
    expect(backend.reads, greaterThan(0), reason: 'it did poll');
    await sync.stop();
  });

  test('a local copy is sent once', () async {
    final sync = build();
    await sync.start();
    backend.value = 'copied text';
    await Future<void>.delayed(settle);
    expect(sent, <String>['copied text']);
    await sync.stop();
    // Repeated polls over unchanged content must not re-send.
    await Future<void>.delayed(settle);
    expect(sent.length, 1);
  });

  test('text written from the peer is never echoed back', () async {
    final sync = build();
    await sync.start();
    await sync.applyRemote('from the other machine');
    await Future<void>.delayed(settle);
    expect(backend.writes, 1);
    expect(sent, isEmpty, reason: 'our own write is not a user copy');
    await sync.stop();
  });

  test('the echo check survives the platform rewriting the text', () async {
    // Windows may hand back \r\n for the \n we wrote. Comparing raw strings
    // would see a change on every poll and bounce the text back and forth.
    backend.rewriteOnWrite = 'from the other machine\r\n';
    final sync = build();
    await sync.start();
    await sync.applyRemote('from the other machine');
    await Future<void>.delayed(settle);
    expect(sent, isEmpty);
    await sync.stop();
  });

  test('a failed write does not bounce the old local text back', () async {
    // If the write did not land, the clipboard still holds what it held before.
    // Treating that as a user copy would push it to the peer and overwrite the
    // text it had just sent.
    backend.failWrite = true;
    final sync = build();
    await sync.start();
    await sync.applyRemote('from the other machine');
    await Future<void>.delayed(settle);
    expect(backend.value, 'already here', reason: 'the write really did fail');
    expect(sent, isEmpty);
    await sync.stop();
  });

  test('oversized text is dropped, not truncated', () async {
    final sync = build();
    await sync.start();
    // Multi-byte on purpose: the limit is bytes, not characters.
    backend.value = '中' * (ClipboardEvent.maxBytes ~/ 3 + 100);
    await Future<void>.delayed(settle);
    expect(sent, isEmpty);
    expect(logs.any((line) => line.contains('上限')), isTrue);
    await sync.stop();
  });

  test('pushNow sends content that was copied before connecting', () async {
    final sync = build();
    await sync.start();
    await sync.pushNow();
    expect(sent, <String>['already here']);
    await sync.stop();
  });

  test('an empty clipboard is not sent', () async {
    backend.value = '';
    final sync = build();
    await sync.start();
    await sync.pushNow();
    expect(sent, isEmpty);
    await sync.stop();
  });

  test('stopping stops polling', () async {
    final sync = build();
    await sync.start();
    await sync.stop();
    final readsAfterStop = backend.reads;
    backend.value = 'later';
    await Future<void>.delayed(settle);
    expect(backend.reads, readsAfterStop);
    expect(sent, isEmpty);
  });

  test('counters track both directions', () async {
    final sync = build();
    await sync.start();
    backend.value = 'out';
    await Future<void>.delayed(settle);
    await sync.applyRemote('in');
    expect(sync.sent, 1);
    expect(sync.received, 1);
    await sync.stop();
  });

  group('hello reports the platform', () {
    test('a Windows target is not a Mac', () {
      const hello = HelloEvent(
        screenWidth: 1920,
        screenHeight: 1080,
        platform: 'windows',
      );
      expect(hello.isMacTarget, isFalse);
      expect(hello.toJson()['p'], 'windows');
    });

    test('an older peer decodes as unknown, not as Windows', () {
      // Crucially empty rather than a guess: the controller must not rewrite ⌘
      // to Ctrl for a peer whose platform it does not know.
      final hello = HelloEvent.fromJson(<String, Object?>{'t': 'hello', 'w': 1, 'h': 1});
      expect(hello.platform, '');
      expect(hello.isMacTarget, isFalse);
      expect(hello.toJson().containsKey('p'), isFalse);
    });
  });

  group('clipboard event', () {
    test('round-trips through the wire format', () {
      const event = ClipboardEvent('多行\n文本 with spaces');
      final decoded = ClipboardEvent.fromJson(event.toJson());
      expect(decoded.text, event.text);
    });

    test('counts bytes rather than characters', () {
      expect(ClipboardEvent.byteLength('中'), 3);
      expect(ClipboardEvent.byteLength('a'), 1);
    });

    test('survives an empty payload from a future peer', () {
      expect(ClipboardEvent.fromJson(<String, Object?>{}).text, '');
    });
  });
}
