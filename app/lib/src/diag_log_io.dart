import 'dart:io';

import 'diag_log_types.dart';

/// Directory that holds diagnostic logs for the current platform.
///
/// - Windows: `%LOCALAPPDATA%\RemoteDesk\logs` — no admin rights needed, and it
///   is the folder support will ask the user to open.
/// - macOS:   `~/Library/Logs/RemoteDesk` — the same place the native injector
///   writes `input.log`, so both halves of a session land together.
/// - Linux:   `$XDG_STATE_HOME` or `~/.local/state`.
String? logDirectory() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  try {
    if (Platform.isWindows) {
      final base = env['LOCALAPPDATA'] ?? (home == null ? null : '$home\\AppData\\Local');
      if (base == null) return null;
      return '$base\\RemoteDesk\\logs';
    }
    if (Platform.isMacOS) {
      if (home == null) return null;
      return '$home/Library/Logs/RemoteDesk';
    }
    final state = env['XDG_STATE_HOME'] ?? (home == null ? null : '$home/.local/state');
    if (state == null) return null;
    return '$state/remotedesk';
  } catch (_) {
    return null;
  }
}

class _FileWriter implements DiagWriter {
  _FileWriter(this.path, this._sink);

  @override
  final String path;
  final IOSink _sink;

  @override
  void writeLine(String line) => _sink.writeln(line);

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() async {
    try {
      await _sink.flush();
      await _sink.close();
    } catch (_) {}
  }
}

/// Open (creating if needed) today's log file, appending.
///
/// Returns null when there is no usable directory rather than throwing: the app
/// must keep working on a machine where the profile folder is read-only.
Future<DiagWriter?> openLogWriter() async {
  final dir = logDirectory();
  if (dir == null) return null;
  try {
    final folder = Directory(dir);
    if (!await folder.exists()) await folder.create(recursive: true);

    final now = DateTime.now();
    final stamp = '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final file = File('$dir${Platform.pathSeparator}app-$stamp.log');

    // A session writes a few hundred lines; anything beyond the last five files
    // is noise and just eats the user's disk.
    try {
      final logs = await folder
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .toList();
      if (logs.length > 5) {
        logs.sort((a, b) => a.path.compareTo(b.path));
        for (final stale in logs.take(logs.length - 5)) {
          try {
            await stale.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}

    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    return _FileWriter(file.path, sink);
  } catch (_) {
    return null;
  }
}

/// Reveal the log folder in the platform's file manager. Best-effort.
Future<bool> revealLogDirectory() async {
  final dir = logDirectory();
  if (dir == null) return false;
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', <String>[dir]);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.run('open', <String>[dir]);
      return true;
    }
    await Process.run('xdg-open', <String>[dir]);
    return true;
  } catch (_) {
    return false;
  }
}
