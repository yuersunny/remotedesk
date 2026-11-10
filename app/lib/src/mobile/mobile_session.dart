import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../input_event.dart' as proto;
import '../rtc_session.dart';
import 'hid_text.dart';
import 'touch_input.dart';

/// The phone-side session screen: remote picture edge to edge, controls on top.
///
/// Deliberately a separate widget from the desktop [SessionView]: a phone has
/// no hover, no right button and no physical modifier keys, so all input has to
/// be re-thought rather than reused. Keeping them apart also means tuning one
/// cannot regress the other.
class MobileSessionView extends StatefulWidget {
  const MobileSessionView({
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
  });

  final RtcSession session;
  final SessionPhase phase;
  final SessionStats stats;
  final VoidCallback onHangUp;
  final proto.HelloEvent? remoteHello;
  final bool controlEnabled;
  final ValueChanged<bool>? onControlChanged;
  final bool clipboardEnabled;
  final ValueChanged<bool>? onClipboardChanged;
  final VoidCallback? onPushClipboard;

  @override
  State<MobileSessionView> createState() => _MobileSessionViewState();
}

class _MobileSessionViewState extends State<MobileSessionView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final RemoteViewport _viewport = RemoteViewport();
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'remote-soft-keyboard');
  final TextEditingController _textCtrl = TextEditingController();

  late final TouchInput _touch = TouchInput(
    viewport: _viewport,
    onMove: _sendMove,
    onButton: _sendButton,
    onWheel: _sendWheel,
    onViewChanged: _onViewChanged,
    onClickFeedback: _pulse,
  );

  late final HidTextBridge _bridge = HidTextBridge(_sendStroke);

  late final AnimationController _click = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  Offset? _clickAt;

  Timer? _longPress;
  Offset _downAt = Offset.zero;

  /// Modifiers the user latched with the accessory bar.
  final Set<proto.InputKey> _latched = <proto.InputKey>{};

  /// Keys reported down and not yet released, so a latch can be undone.
  final Set<proto.InputKey> _down = <proto.InputKey>{};

  bool _keyboardOpen = false;
  bool _suppressText = false;
  String _hint = '';

  bool get _isController => widget.session.role == SessionRole.controller;

  bool get _canControl =>
      _isController &&
      widget.controlEnabled &&
      widget.phase == SessionPhase.live;

  @override
  void initState() {
    super.initState();
    _touch.enabled = _canControl;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant MobileSessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _touch.enabled = _canControl;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding the app must not leave a modifier held down on the remote
    // machine; every later key would arrive as Ctrl+X.
    if (state != AppLifecycleState.resumed) _releaseAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPress?.cancel();
    _click.dispose();
    _textCtrl.dispose();
    _keyboardFocus.dispose();
    _releaseAll();
    super.dispose();
  }

  void _releaseAll() {
    for (final key in _down.toList(growable: false)) {
      widget.session.input.send(proto.KeyEvent(key: key, pressed: false));
    }
    _down.clear();
    _latched.clear();
    _touch.reset();
  }

  void _pulse(Offset local) {
    setState(() => _clickAt = local);
    _click.forward(from: 0);
  }

  void _onViewChanged() => setState(() {});

  void _sendMove(Offset normalised) =>
      widget.session.input.send(proto.PointerMove(normalised.dx, normalised.dy));

  void _sendButton(int button, bool pressed, Offset normalised) {
    widget.session.input.send(proto.PointerButtonEvent(
      button: button,
      pressed: pressed,
      x: normalised.dx,
      y: normalised.dy,
    ));
  }

  void _sendWheel(double dx, double dy) {
    widget.session.input.send(proto.PointerWheelEvent(dx: dx, dy: dy));
  }

  int get _modifierMask {
    var mask = 0;
    if (_latched.contains(proto.InputKey.shiftLeft)) mask |= proto.InputModifier.shift;
    if (_latched.contains(proto.InputKey.controlLeft)) {
      mask |= proto.InputModifier.control;
    }
    if (_latched.contains(proto.InputKey.altLeft)) mask |= proto.InputModifier.alt;
    if (_latched.contains(proto.InputKey.metaLeft)) mask |= proto.InputModifier.meta;
    return mask;
  }

  /// Press and release one key, honouring both latched and per-character Shift.
  void _sendKey(proto.InputKey key, {bool shift = false}) {
    final mask = _modifierMask;
    final extraShift = shift && (mask & proto.InputModifier.shift) == 0;
    if (extraShift) {
      widget.session.input.send(proto.KeyEvent(
          key: proto.InputKey.shiftLeft, pressed: true, modifiers: mask));
    }
    final effective = mask | (extraShift ? proto.InputModifier.shift : 0);
    widget.session.input
        .send(proto.KeyEvent(key: key, pressed: true, modifiers: effective));
    widget.session.input
        .send(proto.KeyEvent(key: key, pressed: false, modifiers: effective));
    if (extraShift) {
      widget.session.input.send(proto.KeyEvent(
          key: proto.InputKey.shiftLeft, pressed: false, modifiers: mask));
    }
  }

  void _sendStroke(HidStroke stroke) => _sendKey(stroke.key, shift: stroke.shift);

  void _toggleLatch(proto.InputKey key) {
    setState(() {
      if (_latched.remove(key)) {
        _down.remove(key);
        widget.session.input
            .send(proto.KeyEvent(key: key, pressed: false, modifiers: _modifierMask));
      } else {
        _latched.add(key);
        _down.add(key);
        widget.session.input
            .send(proto.KeyEvent(key: key, pressed: true, modifiers: _modifierMask));
      }
    });
    HapticFeedback.selectionClick();
  }

  void _onTextChanged(String value) {
    if (_suppressText) return;
    final clean = _bridge.accept(value);
    if (clean != value) {
      _suppressText = true;
      _textCtrl.value = TextEditingValue(
        text: clean,
        selection: TextSelection.collapsed(offset: clean.length),
      );
      _suppressText = false;
    }
    if (_bridge.dropped > 0) {
      _bridge.dropped = 0;
      setState(() => _hint = '中文和表情发不过去，只能发英文、数字和符号');
      Future<void>.delayed(const Duration(seconds: 4), () {
        if (mounted && _hint.isNotEmpty) setState(() => _hint = '');
      });
    }
  }

  void _startLongPress(Offset at) {
    _longPress?.cancel();
    _downAt = at;
    _longPress = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || !_touch.awaitingLongPress) return;
      HapticFeedback.mediumImpact();
      _touch.fireLongPress();
    });
  }

  void _cancelLongPress() {
    _longPress?.cancel();
    _longPress = null;
  }

  Size? _pictureSize() {
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

  @override
  Widget build(BuildContext context) {
    final picture = _pictureSize();
    if (picture != null) _viewport.picture = picture;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmHangUp();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070A0F),
        body: SafeArea(
          child: Column(
            children: [
              _topBar(),
              Expanded(child: _stage()),
              if (_keyboardOpen) _keyboardBar(),
              if (_hint.isNotEmpty) _hintBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final phase = widget.phase;
    final color = switch (phase) {
      SessionPhase.live => const Color(0xFF4ADE80),
      SessionPhase.failed => const Color(0xFFFF6B6B),
      SessionPhase.closed => Colors.white38,
      _ => const Color(0xFFFBBF24),
    };
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      color: const Color(0xFF11161F),
      child: Row(
        children: [
          IconButton(
            onPressed: _confirmHangUp,
            icon: const Icon(Icons.arrow_back, size: 22),
            color: Colors.white70,
            tooltip: '断开',
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.session.peerId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Icon(Icons.circle, size: 7, color: color),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '${phase.label} · ${widget.stats.rttText} · ${widget.stats.fpsText}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_viewport.isZoomed)
            IconButton(
              onPressed: () => setState(_viewport.reset),
              icon: const Icon(Icons.zoom_out_map, size: 19),
              color: const Color(0xFF60A5FA),
              tooltip: '还原大小',
            ),
          IconButton(
            onPressed: _showHelp,
            icon: const Icon(Icons.touch_app_outlined, size: 19),
            color: Colors.white70,
            tooltip: '手势说明',
          ),
          IconButton(
            onPressed: () => setState(() => _keyboardOpen = !_keyboardOpen),
            icon: Icon(
              _keyboardOpen ? Icons.keyboard_hide : Icons.keyboard_alt_outlined,
              size: 21,
            ),
            color: _keyboardOpen ? const Color(0xFF60A5FA) : Colors.white70,
            tooltip: '键盘',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 19, color: Colors.white70),
            tooltip: '更多',
            onSelected: (value) {
              switch (value) {
                case 'control':
                  widget.onControlChanged?.call(!widget.controlEnabled);
                case 'reset':
                  setState(_viewport.reset);
                case 'push':
                  widget.onPushClipboard?.call();
                case 'clipboard':
                  widget.onClipboardChanged?.call(!widget.clipboardEnabled);
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem(
                value: 'control',
                child: Text(widget.controlEnabled ? '改成「只看不控」' : '恢复控制'),
              ),
              const PopupMenuItem(value: 'reset', child: Text('还原画面大小')),
              const PopupMenuDivider(),
              // Copying on the phone and pasting on the computer is the one
              // cross-device move a phone makes constantly — a code, a link,
              // an address — so it earns a menu entry rather than staying
              // desktop-only.
              const PopupMenuItem(
                value: 'push',
                child: Text('把手机剪贴板发到电脑'),
              ),
              PopupMenuItem(
                value: 'clipboard',
                child: Text(
                  widget.clipboardEnabled ? '关闭剪贴板同步' : '开启剪贴板同步',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stage() {
    if (!_isController) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '手机端只能当主控，不能把本机屏幕共享出去。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport.viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final ready = widget.session.remoteStream != null;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _touch.pointerDown(event.pointer, event.localPosition);
            if (event.kind != PointerDeviceKind.mouse) {
              _startLongPress(event.localPosition);
            }
          },
          onPointerMove: (event) {
            if ((event.localPosition - _downAt).distance > 10) _cancelLongPress();
            _touch.pointerMove(event.pointer, event.localPosition);
          },
          onPointerUp: (event) {
            _cancelLongPress();
            _touch.pointerUp(event.pointer, event.localPosition);
          },
          onPointerCancel: (event) {
            _cancelLongPress();
            _touch.pointerCancel(event.pointer);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translateByDouble(_viewport.pan.dx, _viewport.pan.dy, 0, 1)
                  ..scaleByDouble(_viewport.scale, _viewport.scale, 1, 1),
                child: ready
                    ? RTCVideoView(
                        widget.session.remoteRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      )
                    : const SizedBox.shrink(),
              ),
              if (!ready) _waiting(),
              IgnorePointer(child: _ripple()),
            ],
          ),
        );
      },
    );
  }

  Widget _waiting() {
    final failed = widget.phase == SessionPhase.failed;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failed)
            const Icon(Icons.error_outline, color: Color(0xFFFF6B6B), size: 34)
          else
            const CircularProgressIndicator(color: Colors.white24),
          const SizedBox(height: 14),
          Text(
            failed ? '连接失败，回去再试一次' : '等待电脑画面…',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          const Text(
            '电脑端需要点「接受并共享屏幕」',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _ripple() {
    return AnimatedBuilder(
      animation: _click,
      builder: (context, _) {
        final at = _clickAt;
        if (at == null || _click.value == 0) return const SizedBox.shrink();
        final t = _click.value;
        return Stack(
          children: [
            Positioned(
              left: at.dx - 22,
              top: at.dy - 22,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF60A5FA).withValues(alpha: 1 - t),
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _keyboardBar() {
    return Container(
      color: const Color(0xFF11161F),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  focusNode: _keyboardFocus,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  cursorColor: const Color(0xFF60A5FA),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '在这里打字，直接发到电脑上',
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.newline,
                  onChanged: _onTextChanged,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: () {
                  _textCtrl.clear();
                  _bridge.clear();
                },
                icon: const Icon(Icons.backspace_outlined, size: 20),
                color: Colors.white70,
                tooltip: '清空输入框（电脑上已打的字还在）',
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _latchChip('Ctrl', proto.InputKey.controlLeft),
                _latchChip('Alt', proto.InputKey.altLeft),
                _latchChip('Shift', proto.InputKey.shiftLeft),
                _latchChip('Win', proto.InputKey.metaLeft),
                const SizedBox(width: 8),
                _keyButton('Esc', proto.InputKey.escape),
                _keyButton('Tab', proto.InputKey.tab),
                _keyButton('Enter', proto.InputKey.enter),
                _keyButton('⌫', proto.InputKey.backspace),
                _keyButton('↑', proto.InputKey.arrowUp),
                _keyButton('↓', proto.InputKey.arrowDown),
                _keyButton('←', proto.InputKey.arrowLeft),
                _keyButton('→', proto.InputKey.arrowRight),
                _keyButton('Del', proto.InputKey.delete),
                _keyButton('Home', proto.InputKey.home),
                _keyButton('End', proto.InputKey.end),
                _keyButton('PgUp', proto.InputKey.pageUp),
                _keyButton('PgDn', proto.InputKey.pageDown),
                _keyButton('F5', proto.InputKey.f5),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _latchChip(String label, proto.InputKey key) {
    final on = _latched.contains(key);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _toggleLatch(key),
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minWidth: 46),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color:
                on ? const Color(0xFF2563EB) : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: on ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _keyButton(String label, proto.InputKey key) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          _sendKey(key);
          HapticFeedback.selectionClick();
        },
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(6),
          ),
          child:
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
      ),
    );
  }

  Widget _hintBar() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3F2D0B),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        _hint,
        style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 12),
      ),
    );
  }

  Future<void> _confirmHangUp() async {
    final leaves = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接？'),
        content: const Text('断开后电脑上的画面就不再传过来了。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续看'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (leaves == true && mounted) {
      _releaseAll();
      widget.onHangUp();
    }
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF151B24),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '手机怎么操作电脑',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                const _HelpRow(
                    icon: Icons.touch_app, title: '单指点一下', body: '左键单击'),
                const _HelpRow(
                    icon: Icons.pan_tool_alt,
                    title: '单指按住拖',
                    body: '按住左键拖动：选文字、拖窗口'),
                const _HelpRow(
                    icon: Icons.timer_outlined, title: '单指长按', body: '右键，弹出菜单'),
                const _HelpRow(
                    icon: Icons.swap_vert, title: '双指上下滑', body: '滚轮上下滚'),
                const _HelpRow(
                    icon: Icons.pinch,
                    title: '双指捏合',
                    body: '放大缩小画面（只放大手机这边，不改电脑分辨率）'),
                const _HelpRow(
                    icon: Icons.zoom_in_map,
                    title: '放大之后',
                    body: '双指拖动平移画面，点右上角方框图标还原'),
                const _HelpRow(
                    icon: Icons.keyboard,
                    title: '键盘按钮',
                    body: '打字和 Ctrl/Alt/Win 组合键都在这个面板里'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpRow extends StatelessWidget {
  const _HelpRow({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF60A5FA)),
          const SizedBox(width: 12),
          SizedBox(
            width: 86,
            child: Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              body,
              style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
