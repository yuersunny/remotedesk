import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// Prefixed: `package:flutter/material.dart` also exports a `KeyEvent`
// (the hardware-keyboard one), and this file needs both.
import 'src/input_event.dart' as proto;
import 'src/diag_log.dart';
import 'src/input_injector.dart';
import 'src/rtc_session.dart';
import 'src/screen_capture.dart';
import 'src/session_view.dart';
import 'src/signaling_client.dart';
// Desktop builds can host the relay themselves; a browser tab cannot, hence the
// conditional import rather than a story about "run node somewhere".
import 'src/signaling_server_stub.dart'
    if (dart.library.io) 'src/signaling_server_io.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opened *before* the app runs, not in parallel with it.
  //
  // Starting the log concurrently looked harmless and was not: opening the file
  // takes tens of milliseconds, the startup sequence takes fewer, so every line
  // describing how startup went — including why the signaling connection
  // failed — landed while the writer was still null and was discarded. The log
  // then contained a "开始" line and nothing else, which reads exactly like a
  // crash. Disk I/O here is a few milliseconds and blocks nothing the user can
  // perceive.
  await DiagLog.start();

  // Everything else runs inside a guarded zone: an exception thrown from an
  // `await` in startup code is otherwise swallowed, and the app just sits there
  // looking normal with nothing connected.
  runZonedGuarded(() {
    // Uncaught framework errors go to the file as well: on a machine we cannot
    // reach, a red screen is indistinguishable from "it just does nothing".
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      DiagLog.write('[FLUTTER] ${details.exceptionAsString()}');
      final stack = details.stack;
      if (stack != null) DiagLog.write('[FLUTTER] $stack');
      unawaited(DiagLog.forceFlush());
    };

    runApp(const RemoteDeskApp());
  }, (error, stack) {
    DiagLog.write('[UNCAUGHT] $error');
    DiagLog.write('[UNCAUGHT] $stack');
    unawaited(DiagLog.forceFlush());
  });
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

  /// The relay, hosted by this app when no other server is configured.
  ///
  /// See [LocalSignalingServer] for why this lives inside the app: it is the
  /// only way "the office machine is reachable from home" survives a reboot
  /// without a second process that someone has to keep alive.
  late final LocalSignalingServer _localServer =
      LocalSignalingServer(onLog: (message) => _log('[服务] $message'));

  /// True once the port bound — i.e. other machines should be pointed here.
  bool _hosting = false;

  /// What the *other* machine should type into 高级设置, e.g.
  /// `ws://100.101.102.103:8787/ws`. Empty while not hosting.
  String _peerServerUrl = '';

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
    // Not `unawaited`: a startup failure has to be visible in the log with a
    // reason, not silently leave the app sitting there unconnected.
    _bootstrap().catchError((Object error, StackTrace stack) {
      _log('[启动失败] $error');
      _log('$stack');
      unawaited(DiagLog.forceFlush());
    });
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
    }
    // Become the relay when nobody else is one.
    //
    // The Node server needed a separate process plus something to keep it alive
    // across reboots, and on this machine the login-item route could not even be
    // verified — launchd refused to bootstrap it. The machine being controlled
    // has the app running anyway, so letting the app listen costs nothing and
    // removes the moving part that "connect from home tomorrow" depended on.
    //
    // Only when the saved address points at this machine or at nothing: if the
    // user deliberately configured another host, two islands both reporting
    // "online" on their own loopback would never see each other.
    final configured = _serverCtrl.text.trim();
    if (configured.isEmpty || _isLocalAddress(configured)) {
      await _startHosting(quietWhenTaken: configured.isNotEmpty);
    }

    // Connect at launch either way. "Fill in a server address, then press 连接"
    // was a step users should never have had to think about — the address is
    // remembered, so being online from the first second is the only sensible
    // default. Failure is logged and leaves the app usable.
    await _connect();
  }

  /// Bind the relay and remember what to tell the other machine.
  Future<void> _startHosting({bool quietWhenTaken = false}) async {
    final ok = await _localServer.start(port: 8787);
    if (!ok) {
      // Normal: the Node server, or a second copy of this app, already serves.
      if (!quietWhenTaken) _log('端口 8787 已被占用，直接连它');
      return;
    }
    final ips = await localIpv4Addresses();
    final picked = pickPeerAddress(ips);
    if (!mounted) return;
    setState(() {
      _hosting = true;
      _peerServerUrl = picked == null ? '' : 'ws://$picked:8787/ws';
    });
    _log(picked == null
        ? '本机已作为信令服务器（端口 8787）'
        : '本机已作为信令服务器（端口 8787），对方要填 $_peerServerUrl');
    final others = ips.where((ip) => ip != picked).toList();
    if (others.isNotEmpty) _log('本机其它可用地址: ${others.join(', ')}');
  }

  /// Is this URL aimed at the machine we are running on?
  static bool _isLocalAddress(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '0.0.0.0' ||
        host.isEmpty;
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _inputSub?.cancel();
    _sub?.cancel();
    _session?.close();
    _injector.dispose();
    _client.dispose();
    // Release the port: a relaunch should be able to take it back immediately
    // rather than trip over the socket the previous instance left behind.
    unawaited(_localServer.stop());
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _targetCtrl.dispose();
    super.dispose();
  }

  void _log(String message) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    // Written before the `mounted` check: the most interesting lines are often
    // the ones produced while shutting down.
    DiagLog.write('[$t] $message');
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
        // The server speaks in codes; a person needs a sentence and a next
        // step. `rate_limited` in particular looks like a bug otherwise.
        _log('⚠ ${_errorText(m['code'])}');
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
    // Guarded: the launch path connects automatically, and the reconnect button
    // in 高级设置 goes through the same function.
    if (_connected) return;
    final url = _serverCtrl.text.trim();
    final id = _deviceCtrl.text.trim();
    if (url.isEmpty || id.isEmpty) {
      _log('服务器地址或本机 ID 为空');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServer, url);
    _log('正在连接 $url ...');
    try {
      await _client.connect(url: url, id: id, name: 'flutter-client');
      return;
    } catch (e) {
      _log('连接失败: $e');
    }

    // Fall back to a signaling server on this very machine.
    //
    // The saved address is often one that used to be right — another machine's
    // tailnet IP, yesterday's LAN address — and a stale address is the single
    // most common reason for "it just doesn't connect". When this machine
    // happens to be running the server itself, that is a strictly better guess
    // than leaving the app offline, and the switch is written to the log.
    const local = 'ws://127.0.0.1:8787/ws';
    if (url == local) return;
    _log('改用本机服务器再试一次…');
    // Serve it here if nothing else does, so the app still comes up online
    // instead of sitting dead on a stale address.
    if (!_localServer.running) {
      await _startHosting(quietWhenTaken: true);
      if (!_localServer.running) return;
      _log('（注意：此时只有连到本机的设备互相可见；对方若连的是别的服务器，两边看不到彼此）');
    }
    try {
      await _client.connect(url: local, id: id, name: 'flutter-client');
      if (!mounted) return;
      setState(() => _serverCtrl.text = local);
      await prefs.setString(_kServer, local);
      _log('已改用本机服务器 $local（地址已记住）');
    } catch (e) {
      _log('本机也没有可用的服务器: $e');
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
          : await _capture.capture(await _resolveCaptureRequest());
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
  /// Switching on with no password used to fail with "口令需要至少 6 位" and
  /// leave the switch off — a dead end the user could only escape by typing
  /// something first. A machine that is about to sit there unattended needs a
  /// secret, not a prompt to invent one, so one is generated and shown. The
  /// password stays editable for anyone who wants to choose their own.
  Future<void> _toggleUnattended(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    if (on) {
      var password = _unattendedPassCtrl.text.trim();
      if (password.length < 6) {
        password = _generatePassword();
        _unattendedPassCtrl.text = password;
        _log('已自动生成访问口令：$password（可在「密码」框里改）');
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

  /// Six digits, `Random.secure` so the value is not predictable from the clock.
  ///
  /// Six digits is only defensible because the server rate-limits attempts to
  /// 10 per minute per caller (see server/src/server.js): 10^6 guesses at that
  /// rate is about three months, and the address is not discoverable anyway.
  static String _generatePassword() {
    final random = Random.secure();
    return List<int>.generate(6, (_) => random.nextInt(10)).join();
  }

  Future<void> _copyToClipboard(String label, String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    _log('已复制$label: $value');
  }

  /// Rename this machine. The ID is generated at first launch, which is fine
  /// for a stranger's machine but useless when the same person has to tell
  /// colleagues "connect to 85262df3" — a chosen name is easier to say.
  Future<void> _editDeviceId() async {
    final controller = TextEditingController(text: _deviceCtrl.text);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改本机 ID'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '本机 ID',
            helperText: '对方用这个 ID 连你。建议用字母数字，不要空格',
          ),
          onSubmitted: (text) => Navigator.pop(context, text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || value == _deviceCtrl.text) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDevice, value);
    // Must re-register: the server keys devices by this ID.
    await _disconnect();
    if (!mounted) return;
    setState(() => _deviceCtrl.text = value);
    await _connect();
    _log('本机 ID 已改为 $value');
  }

  /// Turn a signaling error code into something a person can act on.
  static String _errorText(Object? code) {
    return switch (code) {
      'target_offline' => '对方不在线 —— 确认那台机器开着程序，且 ID 没打错',
      'rate_limited' => '尝试太频繁了，等一分钟再连',
      'id_taken' => '这个 ID 已被别的设备占用，换一个（高级设置里可以改）',
      'no_target' => '请先填对方 ID',
      'bad_token' => '服务器要求鉴权码，当前版本没有对应输入框',
      _ => '出错了（${code ?? "未知"}）',
    };
  }

  /// Make sure a desktop capture request names a concrete source.
  ///
  /// Only the browser has a "let the user pick a screen" dialog. On macOS and
  /// Windows the media layer needs an explicit `deviceId`; asking for
  /// `getDisplayMedia` without one fails, and a failed capture makes this
  /// machine *reject the call* — which the controller can only read as "连不上".
  /// That is exactly how Windows behaved as a target while macOS worked.
  ///
  /// An explicit choice made in 高级设置 always wins, so this only fills a gap.
  Future<CaptureRequest> _resolveCaptureRequest() async {
    if (kIsWeb || _request.sourceId != null) return _request;
    try {
      final sources = await _capture.listSources();
      if (sources.isEmpty) {
        _log('⚠ 没有枚举到可采集的屏幕，可能缺少屏幕录制权限');
        return _request;
      }
      final screen = sources.firstWhere(
        (s) => s.isScreen,
        orElse: () => sources.first,
      );
      _request = _request.copyWith(sourceId: screen.id);
      if (mounted) setState(() => _sources = sources);
      _log('采集源: $screen');
    } catch (e) {
      _log('枚举采集源失败: $e');
    }
    return _request;
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
        if (!_connected) ...[
          _offlineBanner(theme),
          const SizedBox(height: 10),
        ],
        _thisDeviceCard(theme),
        const SizedBox(height: 10),
        _connectCard(theme),
        const SizedBox(height: 10),
        _advancedCard(theme),
        const SizedBox(height: 10),
        // Fixed, not Expanded: in a short window the flex used to collapse to
        // zero and push everything above it off the bottom edge.
        SizedBox(height: 170, child: _logPanel(theme)),
      ],
    );
  }

  /// Shown only while the signaling link is down.
  ///
  /// Without this, "auto-connect on launch" turns a wrong server address into a
  /// silently dead app: the window looks normal, nothing is online, and the fix
  /// is buried in a collapsed section. The banner names the actual address it
  /// tried, which is usually enough to spot a 127.0.0.1 on the wrong machine.
  Widget _offlineBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off, size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '还没连上信令服务器（${_serverCtrl.text}）。\n'
              '两台机器要填同一个地址 —— 填运行服务器那台的地址，末尾的 /ws 别漏。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "This computer": the two things another person needs, and the switch that
  /// decides whether it can be controlled at all.
  ///
  /// This is the whole model, borrowed from every consumer remote-desktop tool:
  /// you read an ID and a password off this card, you type them on the other
  /// machine, you are in. Nothing here asks the user to understand sessions,
  /// roles or signaling.
  Widget _thisDeviceCard(ThemeData theme) {
    final selfId = _selfId ?? _deviceCtrl.text;
    final open = _unattended;
    final idStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 2,
      color: theme.colorScheme.onSurface,
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('这台电脑', style: theme.textTheme.titleSmall),
                const Spacer(),
                _onlineChip(theme),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本机 ID',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(selfId.isEmpty ? '—' : selfId, style: idStyle),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _copyToClipboard('本机 ID', selfId),
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制 ID',
                ),
                IconButton(
                  onPressed: _editDeviceId,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: '改 ID',
                ),
              ],
            ),
            // Only when we are the server: this is the one string the other
            // machine needs beyond the ID and password. Buried in 高级设置 it is
            // the step people skip, and skipping it is what produces "连不上".
            if (_hosting && _peerServerUrl.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _copyToClipboard('服务器地址', _peerServerUrl),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(Icons.dns_outlined,
                          size: 14, color: theme.colorScheme.outline),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '对方服务器填 $_peerServerUrl',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                      Icon(Icons.copy,
                          size: 14, color: theme.colorScheme.outline),
                    ],
                  ),
                ),
              ),
            ],
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('允许远程控制'),
                      const SizedBox(height: 2),
                      Text(
                        open
                            ? '密码正确即自动接受，本机不用有人守着'
                            : '关闭：每次连接都要在本机点「接受」',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: open
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: open, onChanged: _toggleUnattended),
              ],
            ),
            if (open) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _unattendedPassCtrl,
                      '连接密码（对方要输入这串）',
                      onChanged: _onUnattendedPasswordChanged,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () =>
                        _copyToClipboard('密码', _unattendedPassCtrl.text.trim()),
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制密码',
                  ),
                  IconButton(
                    onPressed: () {
                      final fresh = _generatePassword();
                      _unattendedPassCtrl.text = fresh;
                      _onUnattendedPasswordChanged(fresh);
                      setState(() {});
                      _log('已换新密码：$fresh');
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: '换一个密码',
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 6),
              Text(
                '想让这台电脑无人值守，把上面的开关打开，'
                '再把「本机 ID」和「连接密码」发给对方。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline, height: 1.45),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// "Connect to another computer": two fields and one button.
  Widget _connectCard(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('连接另一台电脑', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(flex: 5, child: _field(_targetCtrl, '对方 ID')),
                const SizedBox(width: 8),
                Expanded(
                  flex: 5,
                  child: _field(_passCtrl, '对方密码', obscure: true),
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
                      onPressed: () =>
                          setState(() => _targetCtrl.text = peer['id']!),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: FilledButton.icon(
                onPressed: _connected && _session == null && !_busy ? _call : null,
                icon: const Icon(Icons.desktop_windows_outlined),
                label: const Text('连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Everything that used to be on the main path but is not part of the daily
  /// flow: server address, picture quality, capture source, injector health.
  Widget _advancedCard(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // Re-keyed on the link state so the section opens by itself while
          // offline (that is where the address lives) and folds away once the
          // connection is up.
          key: ValueKey<String>('advanced-$_connected'),
          initiallyExpanded: !_connected,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          title: Text('高级设置', style: theme.textTheme.titleSmall),
          subtitle: Text(
            '服务器地址 · 画质 · 注入诊断',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          children: [
            Row(
              children: [
                Expanded(child: _field(_serverCtrl, '信令服务器 (ws://host:port/ws)')),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _connected ? _disconnect : _connect,
                  icon: Icon(_connected ? Icons.link_off : Icons.link),
                  tooltip: _connected ? '断开' : '重新连接',
                ),
              ],
            ),
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
                      DropdownMenuItem(value: 30, child: Text('30 fps')),
                      DropdownMenuItem(value: 60, child: Text('60 fps')),
                    ],
                    onChanged: (v) => setState(() {
                      _frameRate = v ?? 60;
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
                                child: Text(source.toString(),
                                    overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: (v) => setState(
                              () => _request = _request.copyWith(sourceId: v)),
                        ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _refreshSources,
                  icon: const Icon(Icons.refresh),
                  tooltip: '枚举采集源',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _injectionStatus(theme),
            const Divider(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final ok = await DiagLog.reveal();
                  if (!ok) {
                    _log('打不开日志目录（当前平台无文件系统）');
                  }
                },
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('打开日志目录'),
              ),
            ),
            if (DiagLog.enabled)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: SelectableText(
                  '日志: ${DiagLog.path ?? ""}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Signaling link state as a single dot — the only "am I online" signal the
  /// user needs, and it never moves around the layout.
  Widget _onlineChip(ThemeData theme) {
    final color = _connected ? const Color(0xFF22C55E) : theme.colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 9, color: color),
        const SizedBox(width: 5),
        Text(
          _connected ? '在线' : '未连上服务器',
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
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
