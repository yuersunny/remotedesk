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
  /// A cursor painted into the captured picture inherits the whole media
  /// pipeline: capture → encode → network → decode → render. On a LAN that is
  /// 80–150 ms, over a relay it can pass half a second — and the user reads all
  /// of it as "the mouse is laggy", even though the injected event itself
  /// arrived in microseconds. The controller draws its own cursor at the local
  /// pointer position instead, so movement is immediate and only the *content*
  /// behind it lags.
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
    final video = <String, dynamic>{
      'frameRate': request.frameRate,
      'width': {'max': request.width, 'ideal': request.width},
      'height': {'max': request.height, 'ideal': request.height},
    };

    if (kIsWeb) {
      // Chrome-specific hint; ignored elsewhere.
      video['cursor'] = request.showCursor ? 'always' : 'never';
    } else if (request.sourceId != null) {
      // Desktop: pick the exact screen/window the user selected.
      video['deviceId'] = {'exact': request.sourceId};
    }

    return navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
      'video': video,
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
