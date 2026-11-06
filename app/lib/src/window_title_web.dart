import 'package:web/web.dart' as web;

/// Expose the live session state in the browser tab title.
///
/// Used by the automated M1 smoke test: two headless Chrome instances report
/// their phase / resolution / fps though `document.title`, which is readable
/// over the DevTools protocol without touching the canvas UI.
void setWindowTitle(String title) => web.document.title = title;
