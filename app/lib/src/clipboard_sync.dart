import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'input_event.dart' show ClipboardEvent;

/// Where clipboard text is read from and written to.
///
/// Exists so the sync policy can be tested without a real pasteboard: the
/// interesting behaviour is entirely about *when* to send, and a fake backend
/// makes those timings assertable.
abstract class ClipboardBackend {
  Future<String?> read();
  Future<void> write(String text);
}

/// The platform clipboard, through Flutter's services channel.
///
/// Reads and writes work with the app in the background on both desktop
/// platforms: macOS goes through `NSPasteboard`, Windows through
/// `OpenClipboard`, neither of which needs focus. That matters because the
/// target of a session is exactly the case where nobody is looking at the app.
class FlutterClipboardBackend implements ClipboardBackend {
  const FlutterClipboardBackend();

  @override
  Future<String?> read() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (_) {
      // Another program holding the Windows clipboard open makes this throw.
      // Treating it as "nothing new" is right: the next poll will see the
      // content once the owner lets go.
      return null;
    }
  }

  @override
  Future<void> write(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      // Same transient failure. The content is simply not delivered; the next
      // local copy or a manual push retries.
    }
  }
}

/// Keeps two machines' clipboards in step for the length of a session.
///
/// Copy/paste across machines is the one thing every remote-desktop user
/// reaches for first and notices immediately when it is missing — and it cannot
/// be faked by synthesising Ctrl+C/Ctrl+V, because those act on the *remote*
/// clipboard and never carry text across.
///
/// Four decisions carry the weight:
///
/// * **Nothing is pushed at session start.** The two clipboards are almost
///   always different, and pushing on connect silently destroys whatever the
///   other side had. The first push only happens on a real change; anything
///   copied *before* connecting is reachable through [pushNow].
/// * **Our own writes are not echoed back.** Writing remote text changes the
///   local clipboard, which the poller would otherwise see as a local copy and
///   send straight back — an endless ping-pong that also reorders the user's
///   edits. [applyRemote] records the content as [signature] so the next poll
///   recognises it.
/// * **Comparison uses a normalised signature.** The same text arrives as
///   `\r\n` from Windows and `\n` from macOS; without normalising, every
///   delivery looks like a fresh change and the loop never settles.
/// * **Oversized content is dropped with a log line, not truncated.** Half a
///   table pasted into a remote field is worse than nothing, and it is
///   indistinguishable from a paste that worked.
class ClipboardSync {
  ClipboardSync({
    required this.backend,
    required this.onLocalText,
    this.pollInterval = const Duration(milliseconds: 700),
    this.onLog,
  });

  final ClipboardBackend backend;

  /// Called with text the *user* copied locally. The owner ships it to the
  /// peer; this class does not know about sessions or channels.
  final void Function(String text) onLocalText;

  final Duration pollInterval;
  final void Function(String message)? onLog;

  Timer? _timer;
  bool _running = false;

  /// Signature of what we last saw in the local clipboard.
  String? _lastSeen;

  /// Signature of what we last wrote on behalf of the peer. Never sent back.
  String? _suppressed;

  /// Guard against a slow `read()` overlapping the next tick.
  bool _reading = false;

  int sent = 0;
  int received = 0;

  bool get isRunning => _running;

  /// Begin watching. [baseline] takes the current clipboard as already-known,
  /// which is what "don't overwrite on connect" means in practice.
  Future<void> start({bool baseline = true}) async {
    if (_running) return;
    _running = true;
    _suppressed = null;
    _lastSeen = baseline ? signature(await backend.read()) : null;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _lastSeen = null;
    _suppressed = null;
  }

  Future<void> _tick() async {
    if (!_running || _reading) return;
    _reading = true;
    try {
      final text = await backend.read();
      if (!_running) return;
      final sig = signature(text);
      if (sig == _lastSeen) return;
      _lastSeen = sig;
      if (sig == _suppressed) return;
      _emit(text);
    } finally {
      _reading = false;
    }
  }

  /// Ship one local value, applying the size limit.
  void _emit(String? text) {
    if (text == null || text.isEmpty) return;
    final bytes = ClipboardEvent.byteLength(text);
    if (bytes > ClipboardEvent.maxBytes) {
      onLog?.call('剪贴板内容 ${_kb(bytes)}，超过 ${_kb(ClipboardEvent.maxBytes)} 上限，未同步');
      return;
    }
    sent++;
    onLog?.call('剪贴板已发送（${_summary(text)}）');
    onLocalText(text);
  }

  /// Apply text that arrived from the peer.
  Future<void> applyRemote(String text) async {
    if (text.isEmpty) return;
    final sig = signature(text);
    // Record before awaiting: the write itself is what the next poll will see,
    // and that poll may well start while the write is still in flight.
    _suppressed = sig;
    _lastSeen = sig;
    received++;
    onLog?.call('收到远端剪贴板（${_summary(text)}）');
    await backend.write(text);
    // Re-read rather than trusting the write. A write can fail (another program
    // holds the Windows clipboard open) or be normalised by the platform, and
    // in either case `_lastSeen` must describe what is *actually* there — a
    // stale value would make the next poll treat the old local content as a
    // fresh copy and push it back, silently overwriting the peer's clipboard
    // with the text it just replaced.
    final actual = signature(await backend.read());
    if (actual.isEmpty) return;
    _lastSeen = actual;
    _suppressed = actual;
  }

  /// Push whatever is in the clipboard *now*, without waiting for a change.
  ///
  /// This is the answer to the gap created by "never push on connect": text
  /// copied before the session started is otherwise invisible to the peer.
  Future<void> pushNow() async {
    final text = await backend.read();
    final sig = signature(text);
    _lastSeen = sig;
    _suppressed = null;
    _emit(text);
  }

  /// Normalised form used for every comparison.
  ///
  /// Only line endings and trailing whitespace are folded. Leading whitespace
  /// and internal spacing are content — trimming them would make two different
  /// code snippets look identical. Trailing newlines are not: editors and
  /// terminals add them freely, and a stray `\n` on a single line is not worth
  /// a round trip.
  static String signature(String? text) {
    if (text == null || text.isEmpty) return '';
    var value = text;
    if (value.contains('\r')) {
      value = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    var end = value.length;
    while (end > 0 && (value.codeUnitAt(end - 1) == 0x20 || value.codeUnitAt(end - 1) == 0x0A)) {
      end--;
    }
    return value.substring(0, end);
  }

  static String _kb(int bytes) =>
      bytes >= 1024 ? '${(bytes / 1024).toStringAsFixed(0)} KB' : '$bytes B';

  static String _summary(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final head = flat.length <= 24 ? flat : '${flat.substring(0, 24)}…';
    return '${text.length} 字：$head';
  }
}
