import 'dart:async';

import 'diag_log_stub.dart' if (dart.library.io) 'diag_log_io.dart' as platform;
import 'diag_log_types.dart';

/// Append-only diagnostic log on disk.
///
/// The in-app panel only exists while the window is open, and the platform
/// messages that matter most — permission refusals, ICE failures, "the other
/// machine never reached the server" — are exactly the ones a person cannot
/// transcribe from a screenshot. Windows had no file log at all, so every
/// remote report was untraceable: "连不上" could be a blocked port, a wrong
/// address, or a rejected registration, and all three looked identical.
///
/// Nothing here throws: a log that breaks the app is worse than no log.
class DiagLog {
  DiagLog._();

  static DiagWriter? _writer;
  static Timer? _flushTimer;

  /// Absolute path of the current log file, or null when logging is off.
  static String? get path => _writer?.path;

  /// Folder holding the logs, for the "打开日志目录" action.
  static String? get directory => platform.logDirectory();

  static bool get enabled => _writer != null;

  /// Open the log. Safe to call more than once; later calls are no-ops.
  static Future<void> start() async {
    if (_writer != null) return;
    try {
      _writer = await platform.openLogWriter();
      if (_writer != null) {
        write('--- 启动 ${DateTime.now().toIso8601String()} ---');
      }
    } catch (_) {}
  }

  /// Append one line.
  ///
  /// Buffered and flushed on a short timer rather than per line: the pointer
  /// path logs dozens of lines a second during a session, and a synchronous
  /// flush there would stutter the very interaction it is meant to explain.
  static void write(String line) {
    final writer = _writer;
    if (writer == null) return;
    try {
      writer.writeLine(line);
    } catch (_) {
      return;
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 600), () {
      _flushTimer = null;
      final active = _writer;
      if (active == null) return;
      try {
        active.flush();
      } catch (_) {}
    });
  }

  /// Force buffered lines to disk now.
  ///
  /// Used on the way out of a failure path: the buffered-timer design is right
  /// for the pointer stream but wrong for "something just broke, and the process
  /// may not be alive in 600 ms".
  static Future<void> forceFlush() async {
    final writer = _writer;
    if (writer == null) return;
    try {
      await writer.flush();
    } catch (_) {}
  }

  /// Reveal the folder in Finder/Explorer. Returns false when unavailable.
  static Future<bool> reveal() => platform.revealLogDirectory();

  static Future<void> close() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final writer = _writer;
    _writer = null;
    if (writer == null) return;
    try {
      await writer.close();
    } catch (_) {}
  }
}
