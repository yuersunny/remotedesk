/// Platform-neutral surface for the diagnostic log.
///
/// Kept in its own file, importing nothing platform-specific, so both the
/// `dart:io` implementation and the web stub can implement it without the
/// shared code ever naming `IOSink`.
abstract class DiagWriter {
  /// Absolute path of the file being written.
  String get path;

  /// Append one line (newline added by the implementation).
  void writeLine(String line);

  /// Push buffered bytes to disk without closing.
  Future<void> flush();

  /// Flush and close.
  Future<void> close();
}
