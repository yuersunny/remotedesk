import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// Prefixed: Flutter's services library also exports a `KeyEvent` (the
// hardware-keyboard event), and this file needs both. Qualifying the wire types
// keeps the two unambiguous at every call site.
import 'input_event.dart' as proto;
import 'rtc_session.dart';


/// The "in a session" screen: remote screen for the controller, a local
/// preview for the target, plus a live HUD that proves the media is flowing.
///
/// On the controller the remote picture doubles as the input surface (M2):
/// pointer and keyboard events are captured here and pushed into
/// [RtcSession.input].
class SessionView extends StatefulWidget {
  const SessionView({
    super.key,
    required this.session,
    required this.phase,
    required this.stats,
    required this.onHangUp,
    this.remoteHello,
    this.controlEnabled = true,
    this.onControlChanged,
  });

  final RtcSession session;
  final SessionPhase phase;
  final SessionStats stats;
  final VoidCallback onHangUp;

  /// Geometry reported by the target's `hello`, used for the HUD and as an
  /// aspect-ratio fallback before the first frame decodes.
  final proto.HelloEvent? remoteHello;

  /// Whether the user has armed input forwarding.
  final bool controlEnabled;

  final ValueChanged<bool>? onControlChanged;

  @override
  State<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<SessionView> with WidgetsBindingObserver {
  /// Keys we have told the target are down. Released on focus loss so the
  /// remote desktop cannot be left with a stuck modifier — a confusing failure
  /// mode where every later key arrives as Ctrl+X.
  final Set<proto.InputKey> _pressedKeys = <proto.InputKey>{};

  /// Buttons currently held, in press order.
  ///
  /// Needed because the pointer-up event's bitmask has *already cleared* the
  /// button, so the mask alone cannot tell a right-click release from a left
  /// one. Without this, releasing the right button would be sent as a left
  /// release and leave the remote context menu dragging.
  final List<int> _pressedButtons = <int>[];

  final FocusNode _focusNode = FocusNode(debugLabel: 'remote-input');

  bool get _isController => widget.session.role == SessionRole.controller;

  bool get _canControl =>
      _isController &&
      widget.controlEnabled &&
      widget.phase == SessionPhase.live;

  @override
  void initState() {
    super.initState();
    // Keyboard goes through a process-wide handler rather than
    // `Focus.onKeyEvent`: the Focus-based path only fires while that exact node
    // holds focus, and any click on another control (the address field, a
    // dialog) silently takes it away for good — the pointer keeps working
    // because it travels through `Listener`, which needs no focus, so the
    // failure looks like "mouse works, keyboard dead". A global handler sees
    // every key the window receives, wherever focus sits.
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Release everything the remote machine thinks is held when this window
  /// stops being the active one. Without it a window switch mid-keystroke
  /// leaves a modifier stuck down remotely, and every later key arrives as
  /// Ctrl+X.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _releaseAll();
    _focusNode.dispose();
    super.dispose();
  }

  void _releaseAll() {
    final channel = widget.session.input;
    for (final key in _pressedKeys) {
      channel.send(proto.KeyEvent(key: key, pressed: false));
    }
    _pressedKeys.clear();

    for (final button in _pressedButtons) {
      final position = _lastNormalised ?? const Offset(0.5, 0.5);
      channel.send(proto.PointerButtonEvent(
        button: button,
        pressed: false,
        x: position.dx,
        y: position.dy,
      ));
    }
    _pressedButtons.clear();
  }

  /// Last pointer position in picture coordinates, for synthetic releases.
  Offset? _lastNormalised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF11151C),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _topBar(theme),
          Expanded(child: _isController ? _remoteArea(theme) : _localArea(theme)),
          _hud(theme),
        ],
      ),
    );
  }

  Widget _topBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.white.withValues(alpha: 0.04),
      child: Row(
        children: [
          _chip(
            icon: _isController ? Icons.desktop_windows_outlined : Icons.screen_share_outlined,
            label: '${widget.session.role.label} · ${widget.session.peerId}',
            color: Colors.white70,
          ),
          const SizedBox(width: 8),
          _phaseChip(widget.phase),
          if (_isController) ...[
            const SizedBox(width: 8),
            _controlChip(),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: widget.onHangUp,
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF6B6B)),
            icon: const Icon(Icons.call_end, size: 18),
            label: const Text('挂断'),
          ),
        ],
      ),
    );
  }

  Widget _controlChip() {
    final armed = widget.controlEnabled;
    final live = widget.phase == SessionPhase.live;
    final color = !live
        ? Colors.white38
        : (armed ? const Color(0xFF4ADE80) : const Color(0xFF94A3B8));
    return InkWell(
      onTap: widget.onControlChanged == null
          ? null
          : () => widget.onControlChanged!(!armed),
      borderRadius: BorderRadius.circular(20),
      child: _chip(
        icon: armed ? Icons.mouse : Icons.mouse_outlined,
        label: armed ? '控制中' : '只看不控',
        color: color,
      ),
    );
  }

  Widget _phaseChip(SessionPhase phase) {
    final color = switch (phase) {
      SessionPhase.live => const Color(0xFF4ADE80),
      SessionPhase.failed => const Color(0xFFFF6B6B),
      SessionPhase.closed => Colors.white38,
      _ => const Color(0xFFFBBF24),
    };
    return _chip(icon: Icons.circle, label: phase.label, color: color, iconSize: 8);
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required Color color,
    double iconSize = 14,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  /// Picture aspect ratio, preferring the decoded frame over what the target
  /// reported. Null while both are still unknown.
  Size? _remotePictureSize() {
    final value = widget.session.remoteRenderer.value;
    if (value.width > 0 && value.height > 0) {
      return Size(value.width, value.height);
    }
    final hello = widget.remoteHello;
    if (hello != null && hello.videoWidth > 0 && hello.videoHeight > 0) {
      return Size(hello.videoWidth.toDouble(), hello.videoHeight.toDouble());
    }
    return null;
  }

  Widget _remoteArea(ThemeData theme) {
    final ready = widget.session.remoteStream != null;
    final picture = _remotePictureSize();
    return LayoutBuilder(
      builder: (context, constraints) {
        final container = Size(constraints.maxWidth, constraints.maxHeight);
        // Unknown aspect ratio yet: assume 16:9 so the first clicks before a
        // frame decodes are not wildly off.
        final fit = proto.RemoteViewFit.compute(container, picture ?? const Size(16, 9));
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          // No `onKeyEvent` here: keys are handled process-wide in
          // [_onGlobalKey]. Releasing on focus loss moved to the lifecycle
          // observer, because losing widget focus no longer means the user
          // stopped typing at the remote machine.
          child: Listener(
            onPointerHover: (event) => _sendMove(fit, event.localPosition),
            onPointerMove: (event) => _sendMove(
              fit,
              event.localPosition,
              dragging: _pressedButtons.isNotEmpty,
            ),
            onPointerDown: (event) => _sendButton(fit, event, pressed: true),
            onPointerUp: (event) => _sendButton(fit, event, pressed: false),
            onPointerCancel: (event) => _releaseAll(),
            onPointerSignal: _onPointerSignal,
            child: MouseRegion(
              cursor: _canControl ? SystemMouseCursors.none : MouseCursor.defer,
              child: GestureDetector(
                // Take focus back when the user clicks the picture.
                onTapDown: (_) => _focusNode.requestFocus(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (ready)
                      RTCVideoView(
                        widget.session.remoteRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      )
                    else
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(color: Colors.white24),
                            const SizedBox(height: 16),
                            Text(
                              widget.phase == SessionPhase.failed ? '连接失败，请重试' : '等待远端画面…',
                              style: const TextStyle(color: Colors.white54),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '对端需要点击“接受并共享屏幕”',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    if (ready && widget.phase != SessionPhase.live)
                      Positioned(
                        left: 12,
                        bottom: 12,
                        child: _chip(
                          icon: Icons.hourglass_bottom,
                          label: widget.phase.label,
                          color: const Color(0xFFFBBF24),
                        ),
                      ),
                    if (ready && _canControl)
                      Positioned(
                        left: 12,
                        bottom: 12,
                        child: _chip(
                          icon: Icons.mouse,
                          label: '点击画面后可直接操作远端',
                          color: const Color(0xFF4ADE80),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _sendMove(proto.RemoteViewFit fit, Offset local, {bool dragging = false}) {
    if (!_canControl || !fit.visible) return;
    // Over a letterbox bar there is no remote pixel to point at. Clamping there
    // would shove the remote cursor to the edge just because the local window is
    // wider than the stream. While a button is held we keep sending anyway: a
    // drag that leaves the picture should pin to the edge, not freeze.
    if (!fit.contains(local) && !dragging) return;
    final normalised = fit.normalise(local);
    _lastNormalised = normalised;
    widget.session.input.send(proto.PointerMove(normalised.dx, normalised.dy));
  }

  void _sendButton(
    proto.RemoteViewFit fit,
    PointerEvent event, {
    required bool pressed,
  }) {
    if (!_canControl || !fit.visible) return;
    final normalised = fit.normalise(event.localPosition);
    _lastNormalised = normalised;

    final int button;
    if (pressed) {
      button = _buttonFromMask(event.buttons);
      if (!_pressedButtons.contains(button)) _pressedButtons.add(button);
    } else {
      button = _pressedButtons.isNotEmpty
          ? _pressedButtons.last
          : proto.InputButton.left;
      _pressedButtons.remove(button);
    }

    widget.session.input.send(proto.PointerButtonEvent(
      button: button,
      pressed: pressed,
      x: normalised.dx,
      y: normalised.dy,
    ));
  }

  /// Flutter reports buttons as a bitmask; the wire uses the Web numbering
  /// (0 left, 1 middle, 2 right).
  int _buttonFromMask(int buttons) {
    if (buttons & kSecondaryButton != 0) return proto.InputButton.right;
    if (buttons & kTertiaryButton != 0) return proto.InputButton.middle;
    return proto.InputButton.left;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_canControl || event is! PointerScrollEvent) return;
    // Flutter's deltaY is positive downward; WHEEL_DELTA (and the wire) is
    // positive upward. 1.2 turns Flutter's typical 100-per-notch into 120.
    const scale = 1.2;
    widget.session.input.send(proto.PointerWheelEvent(
      dx: -event.scrollDelta.dx * scale,
      dy: -event.scrollDelta.dy * scale,
    ));
  }

  /// Process-wide key handler. Returns true when the event was consumed, which
  /// stops it from also being delivered to local widgets — desirable here, as
  /// the key is meant for the remote machine.
  bool _onGlobalKey(KeyEvent event) {
    if (!_canControl) return false;

    // Physical keys, not logical ones: the target must receive the key that was
    // pressed, regardless of the controller's layout or IME state.
    final key = proto.InputKey.fromHidUsage(event.physicalKey.usbHidUsage);
    if (key == null) return false;

    if (event is KeyDownEvent) {
      _pressedKeys.add(key);
      widget.session.input.send(
        proto.KeyEvent(key: key, pressed: true, modifiers: _modifiers()),
      );
      return true;
    }
    if (event is KeyUpEvent) {
      _pressedKeys.remove(key);
      widget.session.input.send(
        proto.KeyEvent(key: key, pressed: false, modifiers: _modifiers()),
      );
      return true;
    }
    // KeyRepeatEvent: the target's own OS generates repeats for a held key, so
    // forwarding these would roughly double the repeat rate.
    return false;
  }

  /// Current modifier state, sampled per event rather than tracked: the OS is
  /// the authority on what is physically held.
  int _modifiers() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    var mask = 0;
    if (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight)) {
      mask |= proto.InputModifier.shift;
    }
    if (pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight)) {
      mask |= proto.InputModifier.control;
    }
    if (pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight)) {
      mask |= proto.InputModifier.alt;
    }
    if (pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight)) {
      mask |= proto.InputModifier.meta;
    }
    return mask;
  }

  /// Target side: deliberately **no** local preview.
  ///
  /// Mirroring the captured desktop back onto the machine being captured makes
  /// a picture-in-picture loop: the window shows the screen, that screen
  /// contains the window, and a click on the inner copy sends the remote cursor
  /// chasing smaller copies of itself. Nothing about being controlled requires
  /// the picture. What the person sitting at this machine actually needs is who
  /// is connected, whether the stream is healthy, and how to stop it.
  Widget _localArea(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B6B).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.screen_share_outlined,
                    color: Color(0xFFFF6B6B),
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Center(
                child: Text(
                  '正在共享本机屏幕',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '主控设备 · ${widget.session.peerId}',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  _stat('分辨率', widget.stats.resolution),
                  _stat('帧率', widget.stats.fpsText),
                  _stat('码率', widget.stats.kbpsText),
                ],
              ),
              const SizedBox(height: 26),
              _hintRow(
                Icons.visibility_off_outlined,
                '这里不显示画面',
                '把自己映给自己是无限套娃，被控端不需要看画面。',
              ),
              const SizedBox(height: 10),
              _hintRow(
                Icons.push_pin_outlined,
                '可以最小化，别关闭',
                '关掉这个窗口等于结束共享，对面会立刻失去画面。',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hintRow(IconData icon, String title, String body) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Colors.white38),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(color: Colors.white38, fontSize: 11.5, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hud(ThemeData theme) {
    final hello = widget.remoteHello;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: Colors.white.withValues(alpha: 0.04),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white70, fontSize: 12),
        child: Row(
          children: [
            _stat('分辨率', widget.stats.resolution),
            _stat('帧率', widget.stats.fpsText),
            _stat('码率', widget.stats.kbpsText),
            _stat('延迟', widget.stats.rttText),
            if (hello != null)
              _stat('远端桌面', '${hello.screenWidth}×${hello.screenHeight}'),
            _stat('编码', widget.stats.codecText),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
