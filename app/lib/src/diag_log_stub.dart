import 'diag_log_types.dart';

/// Web build: no filesystem, so nothing is written.
///
/// Returns null instead of throwing so the shared code needs no special case —
/// it already treats a null writer as "logging disabled".
Future<DiagWriter?> openLogWriter() async => null;

String? logDirectory() => null;

Future<bool> revealLogDirectory() async => false;
