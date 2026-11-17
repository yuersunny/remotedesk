import 'dart:ui' show Size;

import 'input_event.dart' show HelloEvent;

/// Pure decisions about a session *after* it has gone live.
///
/// Two things drift while a remote desktop is left idle, and both used to be
/// frozen at handshake time:
///
/// * the picture's real size — a monitor wakes up at a different resolution,
///   an encoder renegotiates down, or the capture source is rebuilt;
/// * the peer connection — NAT mappings expire and ICE goes `disconnected`
///   without ever reaching `failed`.
///
/// The first makes clicks land in the wrong place, the second leaves a frozen
/// last frame that silently swallows every click. Both decisions live here so
/// they can be unit-tested without a WebRTC peer connection.

/// Which numbers describe the picture the controller is actually looking at.
///
/// Priority matters. `getStats()` reports the decoded frame size every second,
/// so it is the only source that reliably follows a resolution change. The
/// renderer's `value` is a snapshot that some backends do not refresh after a
/// `replaceTrack`, and the `hello` handshake is older still. Falling back in
/// that order keeps the contain-rectangle (and therefore every normalised
/// click) aligned with what is on screen.
///
/// Returns null while no source has a usable size; the caller then assumes
/// 16:9 until the first frame decodes.
Size? remotePictureSize({
  required num rendererWidth,
  required num rendererHeight,
  required num? statsWidth,
  required num? statsHeight,
  required num? helloWidth,
  required num? helloHeight,
}) {
  return _pair(statsWidth, statsHeight) ??
      _pair(rendererWidth, rendererHeight) ??
      _pair(helloWidth, helloHeight);
}

Size? _pair(num? width, num? height) {
  if (width == null || height == null) return null;
  final w = width.toDouble();
  final h = height.toDouble();
  if (w <= 0 || h <= 0 || !w.isFinite || !h.isFinite) return null;
  return Size(w, h);
}

/// Whether the target's geometry differs from the last `hello` it sent.
///
/// The target polls every few seconds; comparing first keeps a stable session
/// quiet (no log spam, no frames on the control channel) while still
/// re-announcing the moment anything changes.
bool geometryChanged(
  HelloEvent? last, {
  required int screenWidth,
  required int screenHeight,
  required int videoWidth,
  required int videoHeight,
}) {
  if (last == null) return true;
  return last.screenWidth != screenWidth ||
      last.screenHeight != screenHeight ||
      last.videoWidth != videoWidth ||
      last.videoHeight != videoHeight;
}

/// Tracks how long the peer connection has been `disconnected`.
///
/// WebRTC marks a stalled link `disconnected` and may leave it there forever —
/// it is a *transient* state that often recovers on its own, but when it does
/// not there is no further `failed` callback. Without a deadline the controller
/// keeps showing the last decoded frame and discards every input event because
/// input is gated on the live phase. That is exactly "went away, came back,
/// nothing responds".
class DisconnectWatch {
  DisconnectWatch({this.grace = const Duration(seconds: 12)});

  /// How long a stalled link is allowed to try to recover before we call it
  /// dead. Long enough for ICE to restart on a flaky Wi-Fi, short enough that
  /// the user is not left tapping a frozen picture.
  final Duration grace;

  DateTime? _since;
  bool _stalled = false;

  bool get isStalled => _stalled;

  void connected() {
    _stalled = false;
    _since = null;
  }

  void disconnected(DateTime now) {
    if (_stalled) return;
    _stalled = true;
    _since = now;
  }

  /// True once a stalled link has outlived [grace].
  bool expired(DateTime now) =>
      _stalled && _since != null && now.difference(_since!) >= grace;

  void reset() => connected();
}
