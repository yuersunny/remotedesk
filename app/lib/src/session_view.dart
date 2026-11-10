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
    this.clipboardEnabled = true,
    this.onClipboardChanged,
    this.onPushClipboard,
    this.commandAsControl = false,
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

  /// Whether clipboard text is being mirrored in both directions.
  final bool clipboardEnabled;

  final ValueChanged<bool>? onClipboardChanged;

  /// Push the local clipboard to the peer now, without waiting for a change.
  final VoidCallback? onPushClipboard;

  /// Send ⌘ as Ctrl instead of as the Windows/Super key.
  ///
  /// Meaningful when this machine is a Mac and the far end is not: ⌘ sits
  /// exactly where every other platform keeps Ctrl, so a Mac user pressing
  /// ⌘C means "copy" — but the key itself travels as Super/Cmd, and on Windows
  /// Win+C opens a system panel instead of copying anything. The caller decides
  /// this (it knows the peer's platform from `hello`); this view only applies it.
  final bool commandAsControl;

  @override
  State<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<SessionView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
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

  /// Click feedback, drawn locally the moment the button goes down.
  ///
  /// The remote picture cannot confirm a click any faster than the network, so
  /// without this the first visible reaction to a click is a whole round trip
  /// later — long enough to click twice "because nothing happened". A 260 ms
  /// ring at the press point costs nothing and closes that gap.
  late final AnimationController _click = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// Where the last press happened, in this widget's coordinates.
  Offset? _clickAt;

  void _pulseClick(Offset local) {
    _clickAt = local;
    _click.forward(from: 0);
  }

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
    _cursor.dispose();
    _click.dispose();
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

  /// Where to paint the local cursor, in this widget's coordinates.
  ///
  /// A [ValueNotifier] rather than `setState`: the pointer moves dozens of times
  /// a second, and rebuilding the subtree that hosts `RTCVideoView` at that rate
  /// is pure waste. Only the small cursor layer listens.
  final ValueNotifier<Offset?> _cursor = ValueNotifier<Offset?>(null);

  void _trackCursor(Offset local) {
    if (_cursor.value != local) _cursor.value = local;
  }

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
          const SizedBox(width: 8),
          _clipboardChip(),
          if (widget.clipboardEnabled && widget.onPushClipboard != null)
            IconButton(
              tooltip: '把本机剪贴板发到对面',
              visualDensity: VisualDensity.compact,
              onPressed: widget.phase == SessionPhase.live
                  ? widget.onPushClipboard
                  : null,
              icon: Icon(
                Icons.content_paste_go,
                size: 17,
                color: widget.phase == SessionPhase.live
                    ? Colors.white70
                    : Colors.white24,
              ),
            ),
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

  /// Clipboard mirroring on/off.
  ///
  /// Shown on both ends, because both ends push: a target user copying
  /// something on their own machine also wants it over here.
  Widget _clipboardChip() {
    final on = widget.clipboardEnabled;
    final live = widget.phase == SessionPhase.live;
    final color = !live
        ? Colors.white38
        : (on ? const Color(0xFF4ADE80) : const Color(0xFF94A3B8));
    return InkWell(
      onTap: widget.onClipboardChanged == null
          ? null
          : () => widget.onClipboardChanged!(!on),
      borderRadius: BorderRadius.circular(20),
      child: _chip(
        icon: on ? Icons.content_paste : Icons.content_paste_off,
        label: on ? '剪贴板' : '剪贴板关',
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
            onPointerHover: (event) {
              _trackCursor(event.localPosition);
              _sendMove(fit, event.localPosition);
            },
            onPointerMove: (event) {
              _trackCursor(event.localPosition);
              _sendMove(
                fit,
                event.localPosition,
                dragging: _pressedButtons.isNotEmpty,
              );
            },
            onPointerDown: (event) {
              _trackCursor(event.localPosition);
              if (_canControl) _pulseClick(event.localPosition);
              _sendButton(fit, event, pressed: true);
            },
            onPointerUp: (event) => _sendButton(fit, event, pressed: false),
            onPointerCancel: (event) => _releaseAll(),
            onPointerSignal: _onPointerSignal,
            child: MouseRegion(
              cursor: _canControl ? SystemMouseCursors.none : MouseCursor.defer,
              // Leaving the picture must take the drawn arrow with it: a stale
              // arrow parked at the last position reads as a second, frozen
              // cursor sitting over the toolbar.
              onExit: (_) => _cursor.value = null,
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
                    // The cursor is drawn here, not captured into the stream —
                    // so it tracks the physical mouse with no network in
                    // between. See CaptureRequest.showCursor: the sharer's own
                    // cursor is explicitly excluded on every platform, which is
                    // what keeps this the *only* arrow on screen.
                    if (_canControl)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: Listenable.merge(<Listenable>[_cursor, _click]),
                            builder: (context, _) {
                              final position = _cursor.value;
                              if (position == null || !fit.contains(position)) {
                                return const SizedBox.expand();
                              }
                              // One box holding both the arrow and the click
                              // ring, so the repainted area stays ~56 px square
                              // instead of covering the whole picture at pointer
                              // rate.
                              const half = _CursorPainter.half;
                              final origin =
                                  Offset(position.dx - half, position.dy - half);
                              final clickLocal = _clickAt;
                              return Stack(
                                children: [
                                  Positioned(
                                    left: origin.dx,
                                    top: origin.dy,
                                    child: SizedBox(
                                      width: half * 2,
                                      height: half * 2,
                                      child: CustomPaint(
                                        painter: _CursorPainter(
                                          clickLocal: clickLocal == null
                                              ? null
                                              : clickLocal - origin,
                                          clickProgress: _click.value,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
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
    final physical = proto.InputKey.fromHidUsage(event.physicalKey.usbHidUsage);
    if (physical == null) return false;
    // Map once, and remember it: the release has to send the same id the press
    // did, or the remote machine keeps the unmapped key held down forever.
    final key = _mapKey(physical);

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

  /// ⌘ → Ctrl when the far end has no ⌘ key (see [SessionView.commandAsControl]).
  proto.InputKey _mapKey(proto.InputKey key) =>
      widget.commandAsControl ? proto.metaAsControl(key) : key;

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
    return widget.commandAsControl
        ? proto.modifiersMetaAsControl(mask)
        : mask;
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

/// A plain arrow pointer: white fill with a dark outline, so it stays visible
/// on both a white document and a dark terminal.
///
/// Hand-drawn rather than an icon font glyph because the glyph's own padding
/// would offset the hotspot: the tip has to sit exactly at the pointer position,
/// otherwise clicks land a few pixels away from where the user aimed.
///
/// The same canvas also draws the click ring, so one 56 px layer carries both
/// and the pointer never forces a repaint of the whole picture.
class _CursorPainter extends CustomPainter {
  const _CursorPainter({this.clickLocal, this.clickProgress = 1});

  /// Half the side of the painted box; the tip sits at its centre.
  static const double half = 28;

  /// Press point in box coordinates, or null when no ring is in flight.
  final Offset? clickLocal;

  /// 0→1 over the ring's life; 1 means "finished, draw nothing".
  final double clickProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final anchor = Offset(size.width / 2, size.height / 2);

    final ripple = clickLocal;
    if (ripple != null && clickProgress < 1) {
      final eased = Curves.easeOut.transform(clickProgress);
      canvas.drawCircle(
        ripple,
        7 + 17 * eased,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55 * (1 - eased))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    // 22 logical px tall, measured from the tip down — the same size as before;
    // only the canvas around it grew to make room for the ring.
    final path = Path()
      ..moveTo(anchor.dx, anchor.dy)
      ..lineTo(anchor.dx, anchor.dy + 16)
      ..lineTo(anchor.dx + 3.6, anchor.dy + 12.4)
      ..lineTo(anchor.dx + 6.2, anchor.dy + 18.6)
      ..lineTo(anchor.dx + 8.6, anchor.dy + 17.6)
      ..lineTo(anchor.dx + 6.1, anchor.dy + 11.4)
      ..lineTo(anchor.dx + 10.6, anchor.dy + 11.4)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xCC000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _CursorPainter oldDelegate) =>
      oldDelegate.clickLocal != clickLocal ||
      oldDelegate.clickProgress != clickProgress;
}
