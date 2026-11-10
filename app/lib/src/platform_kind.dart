import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// True on the phone/tablet build.
///
/// That build is deliberately **controller-only**: it drives a desktop and
/// never shares its own screen. Sharing an Android screen needs a
/// `MediaProjection` consent dialog plus a `mediaProjection` foreground
/// service, and being *controlled* would additionally need an
/// AccessibilityService — so this build does not pretend to host, and the UI
/// never offers a switch that cannot work.
bool get isHandheld =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// True where the app can relay for itself, share its screen and inject input.
bool get canHostScreen => !kIsWeb && !isHandheld;

/// This machine's platform as it travels in the `hello` handshake.
///
/// A plain lowercase tag rather than [TargetPlatform]'s enum name, because the
/// receiving side compares it against a fixed string and a renamed enum member
/// should not silently change the wire format.
String get platformTag {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}
