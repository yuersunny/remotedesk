import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// One selectable capture target: a whole display or a single window.
class CaptureSource {
  const CaptureSource({
    required this.id,
    required this.name,
    required this.isScreen,
  });

  final String id;
  final String name;
  final bool isScreen;

  @override
  String toString() => '${isScreen ? '屏幕' : '窗口'} · $name';
}

/// What we ask the platform capturer for.
class CaptureRequest {
  const CaptureRequest({
    this.sourceId,
    this.width = 1920,
    this.height = 1080,
    this.frameRate = 60,
    this.showCursor = false,
  });

  /// Desktop only: which screen/window to capture. `null` = let the user pick
  /// (browser picker on web; first screen on desktop when omitted).
  final String? sourceId;
  final int width;
  final int height;

  /// 60 rather than 30: a remote pointer that updates 60×/s reads as "直接跟手",
  /// while 30 reads as laggy even on a perfect network. Screen content is mostly
  /// static, so the extra frames cost little (the encoder emits delta frames).
  final int frameRate;

  /// Default **false**, and this is the single biggest latency decision here.
  ///
  /// A cursor composited into the captured picture inherits the whole media
  /// pipeline: capture → encode → network → decode → render. On a LAN that is
  /// 80–150 ms, over a relay it can pass half a second — and the user reads all
  /// of it as "the mouse is laggy", even though the injected event itself
  /// arrived in microseconds. The controller draws its own cursor at the local
  /// pointer position instead, so movement is immediate and only the *content*
  /// behind it lags.
  ///
  /// The flip side, and the reason this must be **explicit** on every platform
  /// rather than left to a default: if the sharer's cursor stays in the frames,
  /// the viewer sees that one *and* the one we paint, offset by the network
  /// delay. On Windows that reads as "点鼠标时出现两个鼠标" — the frame only
  /// refreshes when something changes, so the baked-in arrow reappears at the
  /// new position a beat after each click.
  final bool showCursor;

  CaptureRequest copyWith({String? sourceId, int? width, int? height, int? frameRate, bool? showCursor}) {
    return CaptureRequest(
      sourceId: sourceId ?? this.sourceId,
      width: width ?? this.width,
      height: height ?? this.height,
      frameRate: frameRate ?? this.frameRate,
      showCursor: showCursor ?? this.showCursor,
    );
  }
}

/// Thin wrapper over `flutter_webrtc` screen capture.
///
/// Desktop (macOS/Windows/Linux) can enumerate screens and windows and capture
/// a chosen one. Web has no enumeration API - the browser shows its own picker -
/// so [listSources] returns an empty list there and [capture] ignores sourceId.
class ScreenCaptureService {
  /// Available screens/windows. Empty on web (browser handles the picker).
  Future<List<CaptureSource>> listSources() async {
    if (kIsWeb) return const <CaptureSource>[];
    try {
      final sources = await desktopCapturer.getSources(
        types: <SourceType>[SourceType.Screen, SourceType.Window],
        thumbnailSize: ThumbnailSize(240, 150),
      );
      return sources
          .map((s) => CaptureSource(
                id: s.id,
                name: s.name,
                isScreen: s.type == SourceType.Screen,
              ))
          .toList(growable: false);
    } catch (_) {
      // Desktop enumeration is best-effort: a missing permission or an
      // unsupported platform must not break the call flow.
      return const <CaptureSource>[];
    }
  }

  /// Start capturing. Must be called from a user gesture on web.
  Future<MediaStream> capture(CaptureRequest request) {
    return navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
      'video': buildVideoConstraints(request, isWeb: kIsWeb),
      'audio': false,
    });
  }

  /// Release every track of a capture.
  Future<void> stop(MediaStream? stream) async {
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {
        // already stopped
      }
    }
    try {
      await stream.dispose();
    } catch (_) {
      // already disposed
    }
  }
}

/// The `video` half of the `getDisplayMedia` constraints.
///
/// Top-level and pure so its shape can be asserted in a test — two of the three
/// things that matter here fail **silently** instead of throwing:
///
///  * **`cursor` has to be passed on desktop too.** Only the web branch used to
///    set it, so on Windows/macOS the sharer's own cursor stayed composited into
///    every frame while the controller painted another one on top — the "two
///    cursors" the Windows target showed. The plugin's desktop handler reads
///    `video.cursor` and defaults to `always`.
///  * **`frameRate` must sit under `mandatory`, and must be a `double`.** The
///    desktop handler reads `video.mandatory.frameRate`, and its `findDouble()`
///    accepts only a real double: an `int` arrives as int32, is treated as
///    absent, and the capturer quietly stays on its 30 fps default. Writing
///    `60` instead of `60.0` looks identical at the call site and does nothing.
///  * **`width`/`height` are web-only.** Desktop ignores them and captures at
///    native resolution; leaving them out of the desktop map keeps us from
///    implying we asked for a size we never got.
Map<String, dynamic> buildVideoConstraints(
  CaptureRequest request, {
  required bool isWeb,
}) {
  final String cursor = request.showCursor ? 'always' : 'never';
  if (isWeb) {
    return <String, dynamic>{
      'cursor': cursor,
      'frameRate': request.frameRate,
      'width': <String, dynamic>{'max': request.width, 'ideal': request.width},
      'height': <String, dynamic>{'max': request.height, 'ideal': request.height},
    };
  }
  return <String, dynamic>{
    'cursor': cursor,
    'mandatory': <String, dynamic>{
      'frameRate': request.frameRate.toDouble(),
    },
    if (request.sourceId != null)
      'deviceId': <String, dynamic>{'exact': request.sourceId},
  };
}
