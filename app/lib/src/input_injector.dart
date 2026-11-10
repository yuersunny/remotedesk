import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException;

import 'input_event.dart';

/// What the target can do about incoming input events.
class InjectionSupport {
  const InjectionSupport({
    required this.available,
    this.reason,
    this.screenWidth = 0,
    this.screenHeight = 0,
  });

  /// True when this build can actually move the local cursor / press keys.
  final bool available;

  /// Why it is unavailable, shown in the UI instead of a silent no-op.
  final String? reason;

  /// Virtual desktop size in the unit the native injector uses — physical
  /// pixels on Windows, Quartz points on macOS.
  final int screenWidth;
  final int screenHeight;
}

/// Injects remote input into the local desktop (target side).
///
/// The controller's events arrive as normalised coordinates, so this class owns
/// the *only* place where they become screen pixels. That conversion lives in
/// native code because only the platform knows about multi-monitor layouts and
/// per-monitor DPI: a Windows virtual desktop can start at a negative offset and
/// span several screens of different scale factors, and macOS uses a
/// top-left-origin Quartz space that AppKit never shows you.
///
/// Platforms are handled explicitly rather than optimistically: a browser
/// target can capture a screen but can never inject input, and saying so is
/// better than letting the user wonder why clicking does nothing.
class InputInjector {
  InputInjector({this.onLog, this.onChanged});

  static const MethodChannel _channel = MethodChannel('remotedesk/input');

  final void Function(String message)? onLog;

  /// Called when [support] or [ready] changed on their own, so the UI can
  /// repaint without polling it from above.
  final void Function()? onChanged;

  InjectionSupport _support = const InjectionSupport(available: false);
  InjectionSupport get support => _support;

  /// True once the native channel answered at all.
  ///
  /// Deliberately *not* tied to [InjectionSupport.available]: on macOS the
  /// blocker is a user-granted permission that can appear mid-session, and
  /// freezing this flag would mean "granted it, still nothing moves, restart to
  /// find out". The native side is authoritative about each individual event,
  /// so the only thing worth gating here is whether a channel exists.
  bool _ready = false;

  /// Throttle for re-probing an unavailable platform (see [handle]).
  DateTime _probedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _probeInterval = Duration(seconds: 15);

  /// Idle re-probe loop, see [_startWatching].
  Timer? _watch;

  /// Last line pushed to [onLog] by [init], to keep the 15 s probe quiet.
  String _lastSummary = '';

  /// Last pointer position we sent, in normalised units.
  ///
  /// Button events carry a position too, but Windows needs the cursor to be at
  /// the click point *before* the down event. Comparing against this lets us
  /// skip a redundant absolute move on every click.
  Offset? _lastPointer;

  /// Probe the platform and cache the screen geometry.
  Future<InjectionSupport> init() async {
    _probedAt = DateTime.now();
    if (kIsWeb) {
      _support = const InjectionSupport(
        available: false,
        reason: '浏览器无法注入输入，请用原生版作为被控端',
      );
      _ready = false;
      return _support;
    }
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('screenInfo');
      if (info == null) {
        _support = const InjectionSupport(available: false, reason: '原生注入器未响应');
        return _support;
      }
      final available = info['available'] == true;
      // The platform knows *why* better than we do — macOS says which settings
      // pane to open, and repeating that here would let the two drift.
      final platformReason = (info['reason'] as String?)?.trim() ?? '';
      _support = InjectionSupport(
        available: available,
        reason: available
            ? null
            : (platformReason.isEmpty ? '当前平台不支持输入注入' : platformReason),
        screenWidth: (info['width'] as num?)?.toInt() ?? 0,
        screenHeight: (info['height'] as num?)?.toInt() ?? 0,
      );
      _ready = true;
      // Log on change only: [_startWatching] re-probes every 15 s and would
      // otherwise repeat the same "unavailable" line forever.
      final summary = available
          ? '输入注入就绪：虚拟桌面 ${_support.screenWidth}×${_support.screenHeight}'
          : '输入注入不可用：${_support.reason}';
      if (summary != _lastSummary) {
        _lastSummary = summary;
        onLog?.call(summary);
      }
      _startWatching();
    } on MissingPluginException {
      _support = const InjectionSupport(
        available: false,
        reason: '未找到原生注入器（需要重新编译本机版本）',
      );
      _ready = false;
      onLog?.call('输入注入不可用：原生侧未注册 method channel');
    } catch (e) {
      _support = InjectionSupport(available: false, reason: '$e');
      _ready = false;
      onLog?.call('输入注入初始化失败: $e');
    }
    return _support;
  }

  /// Ask for whatever permission the platform requires to post events, then
  /// re-probe.
  ///
  /// Called only when this device is about to act as a target. A controller has
  /// no business pulling up an Accessibility prompt — and on macOS the prompt is
  /// a one-shot system dialog, so asking at the wrong moment trains the user to
  /// dismiss it.
  Future<InjectionSupport> requestPermission() async {
    if (kIsWeb || _support.available) return _support;
    // Only macOS gates injection behind a permission today; skip the round trip
    // where the method does not exist.
    if (defaultTargetPlatform != TargetPlatform.macOS) return _support;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccessibility');
      onLog?.call(granted == true
          ? '辅助功能权限已具备'
          : '辅助功能权限未授予，授予后无需重启，最快 15 秒内自动生效');
    } on MissingPluginException {
      return _support;
    } catch (e) {
      onLog?.call('申请辅助功能权限失败: $e');
    }
    return init();
  }

  /// Temporarily stop injecting (the controller paused control).
  bool disabled = false;

  /// Move the local cursor a few points and read it back.
  ///
  /// The only check that actually proves this machine can be controlled: it goes
  /// through the same permission and the same native post path a remote pointer
  /// move takes, so it cannot pass by accident the way a log line can.
  /// Returns null when the platform has no self-test.
  Future<bool?> selfTest() async {
    if (kIsWeb) return false;
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('pointerSelfTest');
      if (info == null) return null;
      final moved = info['moved'] == true;
      // macOS returns a ready-made sentence; Windows returns only the facts
      // (its C++ strings are ASCII to survive MSVC's code page). The wording
      // lives here so both targets read the same.
      final message = (info['message'] as String?)?.trim() ?? '';
      onLog?.call(message.isEmpty
          ? (moved
              ? '注入自检通过：光标动了（本机已可被远程控制）'
              : '注入自检失败：光标没有移动（管理员窗口 / UAC 安全桌面会丢弃普通权限的注入）')
          : message);
      return moved;
    } on MissingPluginException {
      // Re-probe: a build without the method is a different problem from a
      // build without permission.
      await init();
      return null;
    } catch (e) {
      onLog?.call('注入自检出错: $e');
      return null;
    }
  }

  /// Feed one event from the wire into the local desktop.
  ///
  /// Never throws: a focus-stealing or dying target must not tear down the
  /// session because one synthetic key press failed.
  Future<void> handle(InputEvent event) async {
    if (!_ready || disabled) return;
    // Permission can be granted while the session is live, so an unavailable
    // platform gets re-probed on a slow timer rather than only at startup.
    if (!_support.available &&
        DateTime.now().difference(_probedAt) > _probeInterval) {
      await init();
      if (disabled) return;
    }
    try {
      switch (event) {
        case PointerMove(:final x, :final y):
          _lastPointer = Offset(x, y);
          await _channel.invokeMethod<void>('pointer', <String, Object?>{
            'action': 0,
            'x': x,
            'y': y,
          });
        case PointerButtonEvent(:final button, :final pressed, :final x, :final y):
          final target = Offset(x, y);
          final moved = _lastPointer != target;
          _lastPointer = target;
          await _channel.invokeMethod<void>('pointer', <String, Object?>{
            'action': pressed ? 1 : 2,
            'button': button,
            'x': x,
            'y': y,
            'moved': moved,
          });
        case PointerWheelEvent(:final dx, :final dy):
          await _channel.invokeMethod<void>('wheel', <String, Object?>{
            'dx': dx,
            'dy': dy,
          });
        case KeyEvent(:final key, :final pressed):
          await _channel.invokeMethod<void>('key', <String, Object?>{
            'id': key.id,
            'down': pressed,
          });
        case HelloEvent():
          // Target → controller only; nothing to inject.
          break;
        case ClipboardEvent():
          // Applied to the local pasteboard by the session owner. Reaching here
          // would mean the routing skipped that, and typing the text through
          // synthetic keys instead would be both slow and wrong for anything
          // outside ASCII.
          break;
      }
    } catch (_) {
      // Swallow: see the method comment.
    }
  }

  /// Poll for a permission that appears while the app sits idle.
  ///
  /// Without this the status is a snapshot from launch: ticking Accessibility
  /// in System Settings leaves the stale "unavailable" line on screen until
  /// some remote event happens to arrive, which reads exactly like "the grant
  /// did not take" and sends people back to the settings pane for nothing —
  /// this cost one full round trip already.
  void _startWatching() {
    if (_watch != null || _support.available || kIsWeb) return;
    // No channel at all means the wrong build; polling cannot fix that.
    if (!_ready) return;
    _watch = Timer.periodic(_probeInterval, (_) async {
      if (_support.available) {
        _watch?.cancel();
        _watch = null;
        return;
      }
      final fresh = await init();
      onChanged?.call();
      if (fresh.available) {
        _watch?.cancel();
        _watch = null;
        // Permission just landed: run the only check that proves it, and say so
        // without waiting for a button press.
        onLog?.call('检测到权限已授予，自动执行注入自检');
        await selfTest();
        onChanged?.call();
      }
    });
  }

  Future<void> dispose() async {
    _watch?.cancel();
    _watch = null;
    _ready = false;
    _lastPointer = null;
    _lastSummary = '';
  }
}
