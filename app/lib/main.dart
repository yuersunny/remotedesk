import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// Prefixed: `package:flutter/material.dart` also exports a `KeyEvent`
// (the hardware-keyboard one), and this file needs both.
import 'src/input_event.dart' as proto;
import 'src/input_injector.dart';
import 'src/rtc_session.dart';
import 'src/screen_capture.dart';
import 'src/session_view.dart';
import 'src/signaling_client.dart';
import 'src/window_title.dart';

/// ICE servers used by every session.
///
/// Two devices on the same LAN connect through host candidates alone, so an
/// empty list works there. STUN is what allows two devices on *different*
/// networks to find a direct path; without it every cross-network session would
/// need a TURN relay. Override or disable it with `?ice=` (see [_HomePageState]).
const List<Map<String, dynamic>> kDefaultIceServers = <Map<String, dynamic>>[
  <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
  <String, dynamic>{'urls': 'stun:stun.cloudflare.com:3478'},
];

void main() {
  runApp(const RemoteDeskApp());
}

class RemoteDeskApp extends StatelessWidget {
  const RemoteDeskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteDesk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _kServer = 'server_url';
  static const _kDevice = 'device_id';
  static const _kUnattended = 'unattended';
  static const _kUnattendedPassword = 'unattended_password';

  final SignalingClient _client = SignalingClient();
  final ScreenCaptureService _capture = ScreenCaptureService();

  final TextEditingController _serverCtrl = TextEditingController(text: 'ws://127.0.0.1:8787/ws');
  final TextEditingController _deviceCtrl = TextEditingController();
  final TextEditingController _targetCtrl = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _sub;
  final List<String> _logs = <String>[];

  bool _connected = false;
  bool _busy = false;
  String? _selfId;
  List<Map<String, String>> _peers = const <Map<String, String>>[];

  RtcSession? _session;
  SessionPhase _phase = SessionPhase.idle;
  SessionStats _stats = SessionStats.empty;
  Timer? _statsTimer;

  /// Local input injector. Only the target ever uses it; probing it at startup
  /// puts any "cannot inject here" reason in the log before the first session
  /// rather than after a mysteriously dead mouse.
  late final InputInjector _injector = InputInjector(
    onLog: _log,
    // The injector re-probes itself while the app idles; repaint so the
    // status line stops showing a stale "unavailable" after a permission
    // grant.
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  StreamSubscription<proto.InputEvent>? _inputSub;

  /// Geometry the target reported, shown in the controller HUD.
  proto.HelloEvent? _remoteHello;

  /// Controller-side switch: forward local input to the target or not.
  bool _controlEnabled = true;

  /// Target-side unattended mode: accept calls without asking anyone.
  ///
  /// Off by default and password-gated, because "no one clicks accept" is
  /// indistinguishable from "anyone who can reach the signaling server gets
  /// in" unless something else proves the caller is allowed.
  bool _unattended = false;

  /// The password this machine requires. Empty means unattended mode refuses
  /// every caller. Stored in the platform preferences, which are readable by
  /// the logged-in user — that is acceptable here: anyone who can read them
  /// already controls this machine. The real exposure is the wire, so the
  /// password only means something over wss:// or a private overlay network.
  String _unattendedPassword = '';

  final TextEditingController _passCtrl = TextEditingController();

  /// The password this machine *requires* (target side). Kept apart from
  /// [_passCtrl] so a machine that both hosts and dials can hold two different
  /// passwords without one silently overwriting the other.
  final TextEditingController _unattendedPassCtrl = TextEditingController();

  /// How many control frames this target has decoded. Counted before injection
  /// so the number is honest even where injection is unavailable (web, or a
  /// platform without an injector) — that is what makes it usable as a
  /// self-test signal instead of only as a diagnostic.
  int _inputRx = 0;
  int _moveRx = 0;
  int _keyRx = 0;

  List<CaptureSource> _sources = const <CaptureSource>[];
  CaptureRequest _request = const CaptureRequest();
  int _frameRate = 30;
  int _maxHeight = 1080;

  // Self-test wiring (see docs/m1-smoke-test.md). Enabled only by URL params,
  // so the normal app never auto-connects or reports its state.
  bool _autoJoin = false;
  String _autoRole = '';
  bool _useFakeCapture = false;

  /// ICE servers for this session. Defaults to public STUN, overridable by URL.
  List<Map<String, dynamic>> _iceServers = kDefaultIceServers;

  @override
  void initState() {
    super.initState();
    _sub = _client.events.listen(_onEvent);
    _bootstrap();
    // Probe the injector once, up front: knowing early that this build cannot
    // inject input is far more useful than discovering it after a session.
    _injector.init().then((support) {
      if (!mounted) return;
      setState(() {});
      // Prove the pipe at every launch: `available` only says the platform
      // reports a permission, and `CGEventPost` still no-ops silently when it
      // does not really hold.
      if (support.available) _injector.selfTest();
    });
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final query = Uri.base.queryParameters;
    final urlId = query['id'];
    final urlServer = query['server'];
    final urlPeer = query['peer'];

    var deviceId = urlId ?? prefs.getString(_kDevice) ?? const Uuid().v4().substring(0, 8);
    if (urlId == null) {
      await prefs.setString(_kDevice, deviceId);
    } else {
      deviceId = urlId;
    }

    if (!mounted) return;
    setState(() {
      final savedServer = urlServer ?? prefs.getString(_kServer);
      if (savedServer != null && savedServer.isNotEmpty) _serverCtrl.text = savedServer;
      _deviceCtrl.text = deviceId;
      if (urlPeer != null && urlPeer.isNotEmpty) _targetCtrl.text = urlPeer;
      _autoJoin = query['autojoin'] == '1';
      _autoRole = query['role'] ?? '';
      _useFakeCapture = query['capture'] == 'fake';
      _iceServers = _parseIceServers(query['ice']);
      _unattended = prefs.getBool(_kUnattended) ?? false;
      _unattendedPassword = prefs.getString(_kUnattendedPassword) ?? '';
      _unattendedPassCtrl.text = _unattendedPassword;
    });
    _log('本机设备ID: $deviceId');
    _log(_iceServers.isEmpty
        ? 'ICE: 未配置 STUN（仅同局域网可直连）'
        : 'ICE: ${_iceServers.map((s) => s['urls']).join(', ')}');
    if (urlId != null) _log('（设备ID 由 URL 参数指定，多标签页测试用）');
    if (_autoJoin) {
      _log('自检模式：自动连接（role=$_autoRole, fakeCapture=$_useFakeCapture）');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _connect();
    }
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _inputSub?.cancel();
    _sub?.cancel();
    _session?.close();
    _injector.dispose();
    _client.dispose();
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _targetCtrl.dispose();
    super.dispose();
  }

  void _log(String message) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[$t] $message');
      if (_logs.length > 400) _logs.removeLast();
    });
  }

  /// `?ice=none` disables STUN (LAN-only, avoids waiting on a blocked network);
  /// `?ice=stun:host:port` pins one server; omitting the param keeps the default.
  static List<Map<String, dynamic>> _parseIceServers(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return kDefaultIceServers;
    if (value == 'none' || value == 'off' || value == '0') {
      return const <Map<String, dynamic>>[];
    }
    return <Map<String, dynamic>>[
      for (final url in value.split(','))
        if (url.trim().isNotEmpty) <String, dynamic>{'urls': url.trim()},
    ];
  }

  // ---------------------------------------------------------------- signaling

  Future<void> _onEvent(Map<String, dynamic> m) async {
    switch (m['type']) {
      case 'transport_open':
        _log('信令通道已打开');
        break;
      case 'registered':
        setState(() {
          _selfId = m['id'] as String?;
          _connected = true;
        });
        _log('注册成功，设备ID: ${m['id']}');
        if (_autoJoin && _autoRole == 'controller') {
          final peer = _targetCtrl.text.trim();
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (peer.isNotEmpty && mounted) _call();
          });
        }
        break;
      case 'devices':
        final list = (m['devices'] as List)
            .map((e) => <String, String>{
                  'id': '${e['id']}',
                  'name': '${e['name'] ?? ''}',
                })
            .toList();
        setState(() => _peers = list);
        _log('在线设备: ${list.isEmpty ? '(无)' : list.map((e) => e['id']).join(', ')}');
        break;
      case 'incoming':
        _log('收到呼叫 from=${m['from']}');
        if (_autoJoin && _autoRole == 'target') {
          _acceptAndShare('${m['from']}');
        } else {
          _handleIncoming(m);
        }
        break;
      case 'accepted':
        _log('对方已接受 from=${m['from']}');
        await _startController('${m['from']}');
        break;
      case 'rejected':
        _log('对方拒绝 from=${m['from']}');
        break;
      case 'offer':
      case 'answer':
      case 'ice':
      case 'candidate':
        final handled = await _session?.handleSignal(m) ?? false;
        if (!handled) _log('收到未处理的 ${m['type']} (无会话)');
        break;
      case 'peer_left':
        _log('对端已离开 from=${m['from']}');
        await _teardownSession();
        break;
      case 'peer_offline':
        _log('设备离线: ${m['id']}');
        break;
      case 'error':
        _log('⚠ 错误: ${m['code']} ${m['message'] ?? ''}');
        setState(() => _busy = false);
        break;
      case 'transport_closed':
        setState(() => _connected = false);
        _log('信令通道已关闭');
        break;
      case 'transport_error':
        setState(() => _connected = false);
        _log('通道错误: ${m['error']}');
        break;
      default:
        _log('<< $m');
    }
  }

  Future<void> _connect() async {
    final url = _serverCtrl.text.trim();
    final id = _deviceCtrl.text.trim();
    if (url.isEmpty || id.isEmpty) {
      _log('请填写服务器地址和设备ID');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServer, url);
    _log('正在连接 $url ...');
    try {
      await _client.connect(url: url, id: id, name: 'flutter-client');
    } catch (e) {
      _log('连接失败: $e');
    }
  }

  Future<void> _disconnect() async {
    await _teardownSession();
    await _client.disconnect();
    if (mounted) setState(() => _connected = false);
    _log('已断开');
  }

  // ------------------------------------------------------------------ session

  Future<void> _startController(String peer) async {
    await _teardownSession(notifyPeer: false);
    final session = RtcSession(
      role: SessionRole.controller,
      signaling: _client,
      peerId: peer,
      iceServers: _iceServers,
      onLog: _log,
      onPhase: _onPhase,
    );
    setState(() {
      _session = session;
      _phase = SessionPhase.negotiating;
    });
    _bindSessionInput(session);
    try {
      await session.start();
      await session.createOffer();
      _startStatsTimer();
    } catch (e) {
      _log('建立主控会话失败: $e');
      setState(() => _phase = SessionPhase.failed);
    }
  }

  Future<void> _acceptAndShare(String peer) async {
    if (_busy) return;
    setState(() => _busy = true);
    _log('正在请求屏幕采集…');

    // Read the view geometry before any await: after the capture prompt the
    // context may be gone, and this is only a fallback anyway.
    final fallbackScreen = View.of(context).physicalSize;

    // Capture first: browsers only allow getDisplayMedia inside a user gesture.
    final MediaStream stream;
    try {
      stream = _useFakeCapture
          // Self-test path: same RtcSession pipeline, no permission prompt.
          ? await navigator.mediaDevices.getUserMedia(<String, dynamic>{
              'video': <String, dynamic>{'width': 1280, 'height': 720, 'frameRate': 30},
              'audio': false,
            })
          : await _capture.capture(_request);
    } catch (e) {
      _log('屏幕采集被取消或失败: $e');
      _client.reject(peer);
      if (mounted) {
        setState(() => _busy = false);
      }
      return;
    }

    await _teardownSession(notifyPeer: false);

    // Accepting control is the moment to ask for whatever the injector still
    // needs — on macOS that is the Accessibility grant. Keeping the prompt here
    // means a controller-only session never sees it.
    await _injector.requestPermission();

    // Prefer the native virtual-desktop size: it is the geometry the injector
    // will actually use, and unlike View.physicalSize it covers multi-monitor
    // layouts. Fall back to the Flutter view when native injection is absent.
    final injectorScreen = _injector.support.screenWidth > 0
        ? Size(
            _injector.support.screenWidth.toDouble(),
            _injector.support.screenHeight.toDouble(),
          )
        : fallbackScreen;

    final session = RtcSession(
      role: SessionRole.target,
      signaling: _client,
      peerId: peer,
      iceServers: _iceServers,
      targetScreen: injectorScreen,
      onLog: _log,
      onPhase: _onPhase,
    );
    setState(() {
      _session = session;
      _phase = SessionPhase.preparing;
      _busy = false;
    });
    _bindSessionInput(session);

    // Accept only once we really have frames to send.
    _client.accept(peer);
    _log('已接受 $peer，开始共享屏幕');

    try {
      await session.start(localStream: stream);
      _startStatsTimer();
    } catch (e) {
      _log('建立被控会话失败: $e');
      setState(() => _phase = SessionPhase.failed);
    }
  }

  void _onPhase(SessionPhase phase) {
    if (!mounted) return;
    setState(() => _phase = phase);
    _reportTitle();
  }

  /// Route inbound input frames.
  ///
  /// On the target every non-handshake event goes straight into the local
  /// desktop. On the controller the only inbound frame is the target's
  /// `hello`, which just updates the HUD.
  void _bindSessionInput(RtcSession session) {
    _inputSub?.cancel();
    _remoteHello = null;
    _inputRx = 0;
    _moveRx = 0;
    _keyRx = 0;
    _inputSub = session.input.events.listen((event) async {
      if (event is proto.HelloEvent) {
        if (!mounted) return;
        setState(() => _remoteHello = event);
        _log('远端桌面 ${event.screenWidth}×${event.screenHeight}'
            '（画面 ${event.videoWidth}×${event.videoHeight}）');
        _reportTitle();
        return;
      }
      // Count before injecting: the count proves the frame crossed the wire,
      // which is the part that can be verified without a native target.
      _inputRx++;
      if (event is proto.PointerMove) {
        _moveRx++;
      } else if (event is proto.KeyEvent) {
        _keyRx++;
      }
      await _injector.handle(event);
    });
  }

  /// In self-test mode the tab title carries the live state so an external
  /// driver (DevTools protocol) can assert on it without reading the canvas.
  ///
  /// The trailing `rx/mv/ky/h` fields are M2-only: control frames received,
  /// pointer moves received, key events received, and whether the target's
  /// `hello` arrived. They exist so the smoke test can prove the input channel
  /// carries traffic, which is otherwise invisible from outside the app.
  void _reportTitle() {
    if (!_autoJoin) return;
    final role = _session?.role.label ?? '-';
    setWindowTitle('RemoteDesk|$role|${_phase.name}|${_stats.resolution}|'
        '${_stats.fpsText}|${_stats.kbpsText}|${_stats.rttText}'
        '|rx$_inputRx|mv$_moveRx|ky$_keyRx|h${_remoteHello == null ? 0 : 1}');
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final session = _session;
      if (session == null || !mounted) return;
      final stats = await session.pollStats();
      if (!mounted) return;
      setState(() => _stats = stats);
      _reportTitle();
    });
  }

  Future<void> _teardownSession({bool notifyPeer = true}) async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _inputSub?.cancel();
    _inputSub = null;
    _remoteHello = null;
    final session = _session;
    if (session == null) return;
    if (notifyPeer) _client.leave(session.peerId);
    _session = null;
    _stats = SessionStats.empty;
    _phase = SessionPhase.idle;
    await session.close();
    if (mounted) setState(() {});
  }

  Future<void> _hangUp() async {
    final peer = _session?.peerId ?? _targetCtrl.text.trim();
    if (peer.isNotEmpty) _client.leave(peer);
    await _teardownSession(notifyPeer: false);
    _log('已结束会话');
  }

  Future<void> _call() async {
    final to = _targetCtrl.text.trim();
    if (to.isEmpty) {
      _log('请填写目标设备ID');
      return;
    }
    final password = _passCtrl.text;
    _client.connectTo(to, password: password.isEmpty ? null : password);
    _log('已请求连接 $to${password.isEmpty ? '' : '（带访问口令）'}');
  }

  /// Decide what to do with an inbound call.
  ///
  /// A machine that must be reachable while nobody is sitting at it cannot ask
  /// permission — there is no one to click. That is a real security trade-off,
  /// so it is opt-in and password-gated: with unattended mode off this is the
  /// familiar dialog; with it on, only a caller presenting the right password
  /// is accepted, and every rejected attempt is logged with the caller's id.
  void _handleIncoming(Map<String, dynamic> m) {
    final from = m['from'] as String? ?? '';
    if (!_unattended) {
      _showIncoming(m);
      return;
    }

    if (_unattendedPassword.isEmpty) {
      // Switched on without a password: refuse rather than hand the machine to
      // anyone who can reach the signaling server.
      _log('⚠ 无人值守已开启但没有设置口令，拒绝 $from');
      _client.reject(from);
      return;
    }

    final offered = (m['password'] as String?) ?? '';
    if (offered.isEmpty) {
      _log('⚠ 无人值守：$from 未提供口令，已拒绝');
      _client.reject(from);
      return;
    }
    if (!_constantTimeEquals(offered, _unattendedPassword)) {
      _log('⚠ 无人值守：$from 口令错误，已拒绝');
      _client.reject(from);
      return;
    }

    _log('无人值守：已自动接受 $from');
    _acceptAndShare(from);
  }

  /// Compare without an early return. The window here is microseconds against a
  /// network round trip, so this is hygiene rather than a real defence — the
  /// actual protection is the password plus the server-side attempt limit.
  static bool _constantTimeEquals(String a, String b) {
    final x = a.codeUnits;
    final y = b.codeUnits;
    var diff = x.length ^ y.length;
    final n = x.length < y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  void _showIncoming(Map<String, dynamic> m) {
    final from = m['from'] as String? ?? '';
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('收到远程协助请求'),
        content: Text('来自设备 $from\n\n接受后会开始共享你的屏幕，浏览器会立刻弹出选择框。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _client.reject(from);
              _log('已拒绝 $from');
            },
            child: const Text('拒绝'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _acceptAndShare(from);
            },
            icon: const Icon(Icons.screen_share),
            label: const Text('接受并共享屏幕'),
          ),
        ],
      ),
    );
  }

  /// Turn unattended mode on or off, persisting both the flag and the password.
  ///
  /// A password is mandatory to switch on: unattended mode without one would
  /// mean "the first caller wins", and the signaling server is reachable from
  /// anywhere on the network it runs on.
  Future<void> _toggleUnattended(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    if (on) {
      final password = _unattendedPassCtrl.text.trim();
      if (password.length < 6) {
        _log('⚠ 无人值守需要至少 6 位访问口令，未开启');
        if (mounted) setState(() {});
        return;
      }
      _unattendedPassword = password;
      await prefs.setString(_kUnattendedPassword, password);
    }

    await prefs.setBool(_kUnattended, on);
    if (!mounted) return;
    setState(() => _unattended = on);
    _log(on
        ? '无人值守已开启：口令正确即自动接受，本机不再弹确认框'
        : '无人值守已关闭：每次连接都需要本机点确认');

    // An unattended machine has nobody in front of it to press "连接", so
    // bringing the flag up must also bring the signaling link up.
    if (on && !_connected) {
      final url = _serverCtrl.text.trim();
      final id = _deviceCtrl.text.trim();
      if (url.isNotEmpty && id.isNotEmpty) {
        _log('无人值守：自动连接信令服务器');
        unawaited(_connect());
      } else {
        _log('⚠ 无人值守：服务器地址或设备ID为空，无法自动连接');
      }
    }
  }

  /// Keep the required password in step with the field while the mode is on.
  Future<void> _onUnattendedPasswordChanged(String value) async {
    if (!_unattended) return;
    final password = value.trim();
    _unattendedPassword = password;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUnattendedPassword, password);
  }

  Future<void> _refreshSources() async {
    final sources = await _capture.listSources();
    if (!mounted) return;
    setState(() => _sources = sources);
    _log(sources.isEmpty
        ? '当前平台由系统/浏览器弹窗选择采集源'
        : '发现 ${sources.length} 个可采集源');
  }

  // ----------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteDesk · M2 远程控制'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          // Busy spinner doubles as feedback while capture permission is pending.
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Row(
                children: [
                  Icon(Icons.circle, size: 10, color: _connected ? Colors.green : Colors.red),
                  const SizedBox(width: 6),
                  Text(_connected ? '已连接' : '未连接'),
                ],
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final panel = _controlPanel(context);
          final stage = _stage(context);
          if (!wide) {
            // Scrolls instead of overflowing: the default 810x667 window used
            // to clip the injection status and the log off the bottom edge.
            return SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 260, child: stage),
                  const SizedBox(height: 12),
                  panel,
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 380,
                  child: SingleChildScrollView(child: panel),
                ),
                const SizedBox(width: 12),
                Expanded(child: stage),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _stage(BuildContext context) {
    final session = _session;
    if (session == null) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.screen_share_outlined,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text('还没有进行中的会话'),
              const SizedBox(height: 6),
              Text(
                '呼叫对端，或等待别人呼叫你',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }
    return SessionView(
      session: session,
      phase: _phase,
      stats: _stats,
      onHangUp: _hangUp,
      remoteHello: _remoteHello,
      controlEnabled: _controlEnabled,
      onControlChanged: session.role == SessionRole.controller
          ? (value) => setState(() => _controlEnabled = value)
          : null,
    );
  }

  Widget _controlPanel(BuildContext context) {
    final theme = Theme.of(context);
    // Shrink-wrapped so the panel can live inside a scroll view; a filling
    // Column would need a bounded height the scroll view cannot provide.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('1. 连接信令', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _field(_serverCtrl, '信令服务器 (ws://host:port/ws)'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _field(_deviceCtrl, '本机设备ID')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _connected ? null : _connect,
                      child: const Text('连接'),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      onPressed: _connected ? _disconnect : null,
                      child: const Text('断开'),
                    ),
                  ],
                ),
                if (_selfId != null) ...[
                  const SizedBox(height: 6),
                  Text('我的ID: $_selfId',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('2. 发起远程协助', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _field(_targetCtrl, '目标设备ID')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _connected ? _client.listDevices : null,
                      child: const Text('刷新'),
                    ),
                  ],
                ),
                if (_peers.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final peer in _peers)
                        ActionChip(
                          label: Text(peer['id']!),
                          onPressed: () => setState(() => _targetCtrl.text = peer['id']!),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                _field(_passCtrl, '访问口令（对方开启无人值守时必填）', obscure: true),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _connected && _session == null ? _call : null,
                    icon: const Icon(Icons.call),
                    label: const Text('呼叫'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('3. 采集设置（被控端生效）', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _frameRate,
                        decoration: const InputDecoration(
                          labelText: '帧率',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 15, child: Text('15 fps')),
                          DropdownMenuItem(value: 30, child: Text('30 fps')),
                          DropdownMenuItem(value: 60, child: Text('60 fps')),
                        ],
                        onChanged: (v) => setState(() {
                          _frameRate = v ?? 30;
                          _request = _request.copyWith(frameRate: _frameRate);
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _maxHeight,
                        decoration: const InputDecoration(
                          labelText: '上限分辨率',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 720, child: Text('720p')),
                          DropdownMenuItem(value: 1080, child: Text('1080p')),
                          DropdownMenuItem(value: 1440, child: Text('1440p')),
                          DropdownMenuItem(value: 2160, child: Text('4K')),
                        ],
                        onChanged: (v) => setState(() {
                          _maxHeight = v ?? 1080;
                          _request = _request.copyWith(
                            height: _maxHeight,
                            width: (_maxHeight * 16 / 9).round(),
                          );
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _sources.isEmpty
                          ? Text('采集源: 由系统弹窗选择',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.outline))
                          : DropdownButtonFormField<String>(
                              initialValue: _request.sourceId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '采集源',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                for (final source in _sources)
                                  DropdownMenuItem(
                                    value: source.id,
                                    child: Text(source.toString(), overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _request = _request.copyWith(sourceId: v)),
                            ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _refreshSources,
                      child: const Text('枚举采集源'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _injectionStatus(theme),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('4. 无人值守（被控端生效）', style: theme.textTheme.titleSmall)),
                    Switch(
                      value: _unattended,
                      onChanged: (value) => _toggleUnattended(value),
                    ),
                  ],
                ),
                Text(
                  _unattended
                      ? '口令正确即自动接受，这台机器不需要有人守着。'
                      : '关闭中：每次有人呼叫，都要在本机点「接受并共享屏幕」。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _unattended
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                _field(
                  _unattendedPassCtrl,
                  '本机访问口令（至少 6 位）',
                  obscure: true,
                  onChanged: _onUnattendedPasswordChanged,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '开启后，知道这串口令、又能连到信令服务器的人都可以控制这台机器。\n'
                    '信令走明文 ws:// 时口令也明文传输 —— 跨公网请改用 wss:// 或 Tailscale 这类私有网络，'
                    '并给服务器设 AUTH_TOKEN 环境变量。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Fixed, not Expanded: in a short window the flex used to collapse to
        // zero and push everything above it off the bottom edge.
        SizedBox(height: 200, child: _logPanel(theme)),
      ],
    );
  }

  /// One line telling the user whether this build can inject input at all.
  ///
  /// The target side of M2 is easy to get subtly wrong — the events arrive, the
  /// log looks fine, and nothing moves because the platform has no injector.
  /// Stating it outright turns that into a visible fact instead of a riddle.
  Widget _injectionStatus(ThemeData theme) {
    final support = _injector.support;
    final ok = support.available;
    // Both halves of "can this machine be controlled" need a button: one to get
    // the permission, one to prove the permission actually works. Without the
    // second, a silent no-op looks exactly like a broken session.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.info_outline,
          size: 15,
          color: ok ? const Color(0xFF16A34A) : theme.colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ok
                ? '输入注入就绪 · 虚拟桌面 ${support.screenWidth}×${support.screenHeight}'
                : '输入注入不可用 · ${support.reason ?? '未知原因'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: ok ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 26),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: ok ? _selfTestInjection : _askForInjectionPermission,
          child: Text(ok ? '测试注入' : '去授权'),
        ),
      ],
    );
  }

  Future<void> _askForInjectionPermission() async {
    await _injector.requestPermission();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _selfTestInjection() async {
    // The injector logs the verdict itself (it has the coordinates and the
    // platform wording); logging again here produced two lines that could
    // disagree — one platform-specific, one generic.
    await _injector.selfTest();
    if (!mounted) return;
    setState(() {});
  }

  Widget _logPanel(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('会话日志', style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '清空',
                onPressed: () => setState(_logs.clear),
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _logs.length,
              itemBuilder: (ctx, i) => Text(
                _logs[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
