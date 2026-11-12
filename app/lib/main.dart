import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// Prefixed: `package:flutter/material.dart` also exports a `KeyEvent`
// (the hardware-keyboard one), and this file needs both.
import 'src/clipboard_sync.dart';
import 'src/input_event.dart' as proto;
import 'src/diag_log.dart';
// Finds the other machine instead of asking the user for an address: the
// tailnet's node list plus a UDP broadcast on the local network. A browser tab
// can do neither, hence the conditional import.
import 'src/discovery_stub.dart'
    if (dart.library.io) 'src/discovery_io.dart';
import 'src/input_injector.dart';
// The phone build is controller-only and needs a completely different layout:
// thumbs instead of a mouse, a soft keyboard instead of a physical one.
import 'src/mobile/mobile_home.dart';
import 'src/pairing_code.dart';
import 'src/platform_kind.dart';
import 'src/peer_info.dart';
import 'src/reach.dart';
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

/// Shown in the phone UI. Kept in step with `version:` in pubspec.yaml by hand:
/// reading it back at runtime would pull in a plugin and a native call just to
/// print a string.
const String kAppVersion = '1.0.8';

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
        // The phone build runs dark: the session screen is a black stage, and a
        // white home screen flashing between them is jarring at night, which is
        // exactly when someone reaches for a phone to fix a machine.
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: isHandheld ? Brightness.dark : Brightness.light,
        ),
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

class _HomePageState extends State<HomePage> implements MobileHost {
  static const _kRelayOverride = 'relay_url';
  static const _kDevice = 'device_id';
  static const _kUnattended = 'unattended';
  static const _kUnattendedPassword = 'unattended_password';
  static const _kRecentPeers = 'recent_peers';
  static const _kClipboard = 'clipboard_sync';
  static const _kCmdAsCtrl = 'cmd_as_ctrl';

  /// Signaling for the target side of a session: this app connected to its own
  /// relay, waiting to be called.
  final SignalingClient _client = SignalingClient();

  /// Signaling for the controller side: connected to *the other machine's*
  /// relay, only while a session is being set up.
  ///
  /// Two connections instead of one is what removes the last piece of setup the
  /// user had to reason about. A single shared relay meant "somebody has to run
  /// the server"; with this, each machine relays for itself and dialling a peer
  /// means joining *their* relay. Nobody has to be designated.
  final SignalingClient _dial = SignalingClient();

  final ScreenCaptureService _capture = ScreenCaptureService();

  final TextEditingController _serverCtrl = TextEditingController(text: 'ws://127.0.0.1:8787/ws');
  final TextEditingController _deviceCtrl = TextEditingController();
  final TextEditingController _targetCtrl = TextEditingController();
  final TextEditingController _pairCtrl = TextEditingController();

  /// Finds peers over the tailnet and the local network.
  late final PeerDiscovery _discovery =
      PeerDiscovery(onLog: (message) => _log('[发现] $message'));

  /// Machines found by the last scan.
  List<PeerInfo> _foundPeers = const <PeerInfo>[];
  bool _scanning = false;

  /// Machines connected to successfully before, most recent first, stored as
  /// pairing codes.
  ///
  /// Codes rather than plain hosts because a code also carries the password:
  /// remembering the *machine* but not its password would mean retyping six
  /// characters every time, which is the friction this change exists to remove.
  List<String> _recentCodes = const <String>[];

  /// Parsed view of [_recentCodes]. Cheap — at most a handful of entries.
  List<PeerInfo> get _recentPeers => <PeerInfo>[
        for (final raw in _recentCodes)
          if (PairingCode.parse(raw) case final code? when code.id.isNotEmpty)
            code.toPeer(),
      ];

  /// Address for the manual path, kept out of `_serverCtrl` so the override in
  /// 高级设置 and a one-off manual connect cannot overwrite each other.
  final TextEditingController _manualHostCtrl = TextEditingController();

  /// Where the currently selected target lives.
  ///
  /// Dialling joins the *peer's* relay, so host and port have to travel with
  /// the call. They come from the discovered list or a pairing code — never
  /// from a field the user had to type an IP into.
  String _targetHost = '';
  int _targetPort = 8787;

  /// The relay, hosted by this app when no other server is configured.
  ///
  /// See [LocalSignalingServer] for why this lives inside the app: it is the
  /// only way "the office machine is reachable from home" survives a reboot
  /// without a second process that someone has to keep alive.
  late final LocalSignalingServer _localServer =
      LocalSignalingServer(onLog: (message) => _log('[服务] $message'));

  /// What the *other* machine should type into 高级设置, e.g.
  /// `ws://100.101.102.103:8787/ws`. Empty while not hosting.
  String _peerServerUrl = '';

  /// How far this machine's relay is reachable from — the answer to "can I
  /// connect to this computer when I am not at home?". See `reach.dart`.
  ReachInfo _reach = ReachInfo.unknown;

  /// Whether the "connect from outside" explanation is unfolded.
  bool _reachOpen = false;

  StreamSubscription<Map<String, dynamic>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _dialSub;
  final List<String> _logs = <String>[];

  bool _connected = false;
  bool _busy = false;
  /// True once startup finished. The phone UI shows this instead of the relay
  /// state, because the phone never holds a relay connection of its own.
  bool _ready = false;
  String? _selfId;

  /// Which signaling connection the live session belongs to.
  ///
  /// The target side runs on [_client] (our own relay); the controller side
  /// runs on [_dial] (the peer's relay). Accept/reject/leave have to go back
  /// out the connection the call came in on — sending them the other way is
  /// silently ignored by the far server.
  late SignalingClient _activeSignaling = _client;

  /// Sessions this machine is *serving*, keyed by the caller's id.
  ///
  /// A desktop can legitimately be watched by more than one device at once —
  /// a phone next to a laptop, both looking at the same screen. Keeping a
  /// single session here used to mean the second caller silently evicted the
  /// first, which reads as "the phone cannot connect while the Mac is
  /// connected". Each entry owns its peer connection and input channel; only
  /// the captured stream is shared.
  final Map<String, RtcSession> _hosted = <String, RtcSession>{};

  /// The session currently shown in the stage.
  ///
  /// On the controller this is the only one. On the target it is the most
  /// recent entry of [_hosted] — the stage there only previews what is being
  /// sent, so one representative is enough.
  RtcSession? _session;
  SessionPhase _phase = SessionPhase.idle;
  SessionStats _stats = SessionStats.empty;
  Timer? _statsTimer;

  /// Fails a session that never reaches `live`.
  ///
  /// Without it a call the far side accepted but never negotiated left the
  /// phone on a spinner forever with no explanation — the state machine simply
  /// stayed in `connecting`. 25 s is past the point where a person has decided
  /// it is not going to work.
  Timer? _connectTimer;

  /// Target only: watches whether the display being captured still exists.
  /// Separate from [_statsTimer] because it is far more expensive (it asks the
  /// plugin to enumerate every screen) and must not run on the controller.
  Timer? _sourceWatchTimer;

  /// Guards against two recoveries overlapping when one capture attempt is slow.
  bool _recovering = false;

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
  /// One subscription per session. Input channels belong to a peer connection,
  /// so a single field would unsubscribe the first caller the moment a second
  /// one arrived — with no error, just a mouse that stopped moving.
  final Map<String, StreamSubscription<proto.InputEvent>> _inputSubs =
      <String, StreamSubscription<proto.InputEvent>>{};

  /// The one capture shared by every hosted session.
  ///
  /// Grabbing the screen once and attaching the same track to several peer
  /// connections keeps CPU and encoder load flat as viewers are added.
  /// Capturing per caller would run the OS screen grab N times for pixels that
  /// are identical anyway.
  MediaStream? _hostStream;

  /// Clipboard mirroring for the duration of a session.
  ///
  /// Runs on both ends: whichever side copies, the other side gets the text.
  /// Kept outside the session object because it must keep its "what we last
  /// saw" baseline across a reconnect — otherwise reconnecting re-pushes
  /// whatever happens to be in the clipboard.
  late final ClipboardSync _clipboard = ClipboardSync(
    backend: const FlutterClipboardBackend(),
    onLog: _log,
    onLocalText: _sendClipboard,
  );

  bool _clipboardEnabled = true;

  /// Send ⌘ as Ctrl when the far end is not a Mac (see [_commandAsControl]).
  bool _cmdAsCtrl = true;

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

  /// True when the user picked a capture source in 高级设置 by hand.
  ///
  /// Only a manual pick survives the process. An auto-resolved source is
  /// re-enumerated on every session, because display topology is not stable:
  /// unplugging the monitor, powering it off, or moving the cable to another
  /// machine makes Windows tear down the output and re-create it under a new
  /// device name (`\\.\DISPLAY2` → `\\.\DISPLAY1`). The old id then points at
  /// an output that no longer exists and the session comes up **connected with
  /// no picture** — pointer works, screen stays black.
  bool _sourceChosenByUser = false;
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
    _sub = _client.events.listen((m) => _onEvent(m, from: _client));
    _dialSub = _dial.events.listen((m) => _onEvent(m, from: _dial));
    // Not `unawaited`: a startup failure has to be visible in the log with a
    // reason, not silently leave the app sitting there unconnected.
    _bootstrap().catchError((Object error, StackTrace stack) {
      _log('[启动失败] $error');
      _log('$stack');
      unawaited(DiagLog.forceFlush());
    });
    // Probe the injector once, up front: knowing early that this build cannot
    // inject input is far more useful than discovering it after a session.
    // The phone build never injects (it is not a target), so it does not ask.
    if (canHostScreen) {
      _injector.init().then((support) {
        if (!mounted) return;
        setState(() {});
        // Prove the pipe at every launch: `available` only says the platform
        // reports a permission, and `CGEventPost` still no-ops silently when it
        // does not really hold.
        if (support.available) _injector.selfTest();
      });
    }
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final query = Uri.base.queryParameters;
    final urlId = query['id'];
    final urlServer = query['server'];
    final urlPeer = query['peer'];

    // The device name is what the other person sees and types, so it comes from
    // the machine's own name rather than a random string. `mac-mini` is
    // recognisable; `85262df3` is not, and a random id is also what made two
    // machines collide after someone copied a config.
    var deviceId = urlId ?? prefs.getString(_kDevice) ?? '';
    if (deviceId.isEmpty) {
      // Comes from the tailnet name (`mac-mini`) or the hostname, so the other
      // person sees something they recognise instead of `85262df3`.
      deviceId = await suggestedDeviceName();
      if (deviceId.isEmpty) deviceId = const Uuid().v4().substring(0, 8);
      await prefs.setString(_kDevice, deviceId);
    }

    final recentCodes =
        prefs.getStringList(_kRecentPeers) ?? const <String>[];

    if (!mounted) return;
    setState(() {
      // Only an explicit override is restored. The old `server_url` preference
      // held "the one server everybody shares", which is exactly the concept
      // this change removes — carrying it forward would keep pointing at a
      // machine that may no longer relay for anyone.
      final saved = urlServer ?? prefs.getString(_kRelayOverride);
      // A loopback address is not an override — it is the default written out
      // longhand. Restoring it made the offline banner claim "这是你手工指定的
      // 地址" about a value nobody chose, and pointed at a port that may well be
      // served by some unrelated program.
      if (saved != null && saved.isNotEmpty && !_isLoopbackRelay(saved)) {
        _serverCtrl.text = saved;
      }
      _deviceCtrl.text = deviceId;
      if (urlPeer != null && urlPeer.isNotEmpty) _targetCtrl.text = urlPeer;
      _autoJoin = query['autojoin'] == '1';
      _autoRole = query['role'] ?? '';
      _useFakeCapture = query['capture'] == 'fake';
      _iceServers = _parseIceServers(query['ice']);
      _unattended = prefs.getBool(_kUnattended) ?? false;
      _unattendedPassword = prefs.getString(_kUnattendedPassword) ?? '';
      _unattendedPassCtrl.text = _unattendedPassword;
      _clipboardEnabled = prefs.getBool(_kClipboard) ?? true;
      _cmdAsCtrl = prefs.getBool(_kCmdAsCtrl) ?? true;
      _recentCodes = recentCodes;
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

    if (canHostScreen) {
      // Every machine relays for itself.
      //
      // This used to be conditional — "host only if no server was configured" —
      // because two machines each on their own loopback became two islands that
      // both reported "online" and could not see each other. The fix is not to
      // designate one of them; it is to stop needing a shared relay at all. Each
      // machine joins its own relay and waits to be called; dialling a peer means
      // joining *that peer's* relay for the length of the handshake. Being
      // reachable and reaching are then independent, and "who is the server" is
      // no longer a question the user is asked.
      await _startHosting(quietWhenTaken: true);

      // Announce on the LAN and re-announce periodically, so the other side's
      // scan finds us even if it starts later.
      await _discovery.startResponder(selfId: deviceId);
      _discovery.startAnnouncing();

      // Connect at launch either way. "Fill in a server address, then press 连接"
      // was a step users should never have had to think about — the address is
      // remembered, so being online from the first second is the only sensible
      // default. Failure is logged and leaves the app usable.
      await _connect();
    } else {
      // The phone never relays and never shares its own screen, so there is
      // nothing to host and no reason to sit on a loopback connection to
      // itself. It only ever dials out, which is what keeps the Android build
      // free of foreground services and screen-capture permissions.
      _log('手机端只当主控：不中转、不共享本机屏幕，只负责连到电脑');
    }

    // Look for the other machine without being asked. It is a background scan:
    // if it finds nothing the list simply says so.
    unawaited(_scanPeers());
    if (mounted) setState(() => _ready = true);
  }

  /// Scan both channels and rebuild the list.
  ///
  /// Recently-used machines stay in the list even when the scan misses them:
  /// "last connected yesterday" is a far better row than an empty screen that
  /// reads as "the app is broken".
  Future<void> _scanPeers() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final found = await _discovery.scan();
      if (!mounted) return;
      final selfId = _deviceCtrl.text.trim();
      final live = found.where((p) => p.id != selfId).toList();
      final liveIds = live.map((p) => p.id).toSet();
      final remembered = _recentPeers
          .where((p) => !liveIds.contains(p.id))
          .map((p) => p.copyWith(online: false, source: PeerSource.remembered));
      setState(() {
        _foundPeers = mergePeers(
          <PeerInfo>[...live, ...remembered],
          recentIds: _recentPeerIds,
        );
      });
      _log(live.isEmpty
          ? '自动查找：没找到在线的电脑（对方要先打开 RemoteDesk）'
          : '自动查找：找到 ${live.length} 台 — ${live.map((p) => p.displayName).join(', ')}');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Set<String> get _recentPeerIds =>
      _recentPeers.map((p) => p.id).where((id) => id.isNotEmpty).toSet();

  /// Remember a machine we successfully reached.
  ///
  /// Stores the password too, so the next connection is a single tap. If the far
  /// side rotates its password this entry simply fails once and the user is
  /// asked again — a stale password costs one prompt, not a wrong connection.
  Future<void> _rememberPeer(PeerInfo peer, {String password = ''}) async {
    if (peer.id.isEmpty) return;
    final code = PairingCode(
      host: peer.host,
      port: peer.port,
      id: peer.id,
      password: password,
    ).encode();
    final next = <String>[
      code,
      ..._recentCodes.where((raw) {
        final parsed = PairingCode.parse(raw);
        return parsed == null || parsed.id != peer.id;
      }),
    ].take(6).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecentPeers, next);
    if (!mounted) return;
    setState(() => _recentCodes = next);
  }

  /// Bind the relay and remember what to tell the other machine.
  ///
  /// Also decides — from the addresses the OS reports — whether anyone outside
  /// this network can reach it. That answer is the one piece of information the
  /// old screen never showed, and it is the difference between "this app only
  /// works on my home Wi-Fi" and "this app works from anywhere".
  Future<void> _startHosting({bool quietWhenTaken = false}) async {
    final ok = await _localServer.start(port: 8787);
    if (!ok) {
      // Normal: the Node server, or a second copy of this app, already serves.
      if (!quietWhenTaken) _log('端口 8787 已被占用，直接连它');
    }
    final ips = await localIpv4Addresses();
    final picked = pickPeerAddress(ips);
    final reach = classifyReach(ips);
    if (!mounted) return;
    setState(() {
      _reach = reach;
      _peerServerUrl = picked == null ? '' : 'ws://$picked:8787/ws';
    });
    if (ok) {
      _log(picked == null
          ? '本机可被连接（端口 8787）'
          : '本机可被连接：$_peerServerUrl');
      final others = ips.where((ip) => ip != picked).toList();
      if (others.isNotEmpty) _log('本机其它可用地址: ${others.join(', ')}');
    }
    _log('外网可达性：${reach.headline}'
        '${reach.chosen == null ? '' : '（${reach.chosen}）'}');
    // Advertised by `/info` so a scanning peer sees a name instead of an IP.
    // Set even when the port was taken: in that case the relay is someone
    // else's, but this machine's identity is still this machine's.
    _localServer.setIdentity(
      id: _deviceCtrl.text.trim(),
      name: _deviceCtrl.text.trim(),
    );
  }

  /// Re-read the network addresses after the user installs or signs in to
  /// Tailscale. Nothing else can notice that: the app has no event for "a new
  /// network interface appeared", and asking the user to restart the program
  /// for that is a bad trade.
  Future<void> _refreshReach() async {
    final ips = await localIpv4Addresses();
    if (!mounted) return;
    final reach = classifyReach(ips);
    final picked = pickPeerAddress(ips);
    setState(() {
      _reach = reach;
      _peerServerUrl = picked == null ? '' : 'ws://$picked:8787/ws';
    });
    _log('重新检测网络：${reach.headline}'
        '${reach.chosen == null ? '' : '（${reach.chosen}）'}');
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _sourceWatchTimer?.cancel();
    _connectTimer?.cancel();
    for (final sub in _inputSubs.values) {
      sub.cancel();
    }
    _inputSubs.clear();
    _sub?.cancel();
    _dialSub?.cancel();
    for (final session in _hosted.values) {
      session.close();
    }
    _session?.close();
    _hosted.clear();
    _session = null;
    _injector.dispose();
    _client.dispose();
    _dial.dispose();
    // Release the port: a relaunch should be able to take it back immediately
    // rather than trip over the socket the previous instance left behind.
    unawaited(_localServer.stop());
    unawaited(_discovery.stop());
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    _targetCtrl.dispose();
    _pairCtrl.dispose();
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

  /// [from] is the connection the frame arrived on. Two exist now — ours
  /// (waiting to be called) and the peer's (while we dial out) — and replies
  /// have to go back out the same one.
  Future<void> _onEvent(
    Map<String, dynamic> m, {
    required SignalingClient from,
  }) async {
    switch (m['type']) {
      case 'transport_open':
        _log(from == _dial ? '已连上对方的服务' : '信令通道已打开');
        break;
      case 'registered':
        if (from == _dial) {
          // Registering on a peer's relay is a step in dialling, not "we are
          // online" — the online chip belongs to our own relay.
          _log('已在对方的服务上登记（临时）');
          break;
        }
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
        final ids = <String>[
          for (final e in (m['devices'] as List)) '${e['id']}',
        ];
        // Informational only now: the visible list comes from discovery, not
        // from whoever happens to share this machine's relay.
        _log('本机中转上的设备: ${ids.isEmpty ? '(无)' : ids.join(', ')}');
        break;
      case 'incoming':
        // Always arrives on our own relay: the caller joined it to reach us.
        _activeSignaling = from;
        _log('收到呼叫 from=${_prettyPeerId('${m['from']}')}');
        if (_autoJoin && _autoRole == 'target') {
          _acceptAndShare('${m['from']}');
        } else {
          _handleIncoming(m);
        }
        break;
      case 'accepted':
        // Always arrives on the peer's relay: we joined it to reach them.
        _activeSignaling = from;
        _log('对方已接受 from=${_prettyPeerId('${m['from']}')}');
        await _startController('${m['from']}', from);
        break;
      case 'rejected':
        _log('对方拒绝 from=${_prettyPeerId('${m['from']}')}');
        if (mounted) setState(() => _busy = false);
        break;
      case 'offer':
      case 'answer':
      case 'ice':
      case 'candidate':
        // Route by sender, never by "the current session". With several callers
        // connected, each negotiation belongs to exactly one of them; handing a
        // frame to the wrong one leaves both half-negotiated with no error on
        // either side.
        final peer = '${m['from'] ?? ''}';
        final target =
            _hosted[peer] ?? (_session?.peerId == peer ? _session : null);
        final handled = await target?.handleSignal(m) ?? false;
        if (!handled) {
          _log('收到未处理的 ${m['type']}（对端 ${_prettyPeerId(peer)} 没有会话）');
        }
        break;
      case 'peer_left':
        final gone = '${m['from'] ?? ''}';
        _log('对端已离开 from=${_prettyPeerId(gone)}');
        await _closeSession(gone);
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
        if (from == _client) setState(() => _connected = false);
        _log(from == _dial ? '对方的服务已断开' : '信令通道已关闭');
        break;
      case 'transport_error':
        if (from == _client) setState(() => _connected = false);
        _log('通道错误: ${m['error']}');
        break;
      default:
        _log('<< $m');
    }
  }

  /// True when a relay address points at this machine.
  ///
  /// Typing `127.0.0.1` into 更多设置 is indistinguishable from leaving it
  /// blank, so it must not be treated as a deliberate override — otherwise the
  /// UI claims the user chose an address and offers to "clear" something they
  /// never set.
  static bool _isLoopbackRelay(String url) {
    final value = url.trim().toLowerCase();
    return value.contains('127.0.0.1') ||
        value.contains('localhost') ||
        value.contains('[::1]');
  }

  Future<void> _connect() async {
    // Guarded: the launch path connects automatically, and the reconnect button
    // in 高级设置 goes through the same function.
    if (_connected) return;
    final id = _deviceCtrl.text.trim();
    if (id.isEmpty) {
      _log('本机设备 ID 为空');
      return;
    }
    // No address configured means "join my own relay" — that is now the normal
    // case, not a fallback. An address is only ever an override.
    final override = _serverCtrl.text.trim();
    final url = override.isEmpty || _isLoopbackRelay(override)
        ? 'ws://127.0.0.1:8787/ws'
        : override;
    _log('正在连接 $url ...');
    try {
      await _client.connect(url: url, id: id, name: 'flutter-client');
      return;
    } catch (e) {
      _log('连接失败: $e');
    }

    // An override pointing at a machine that no longer relays for us is the
    // single most common way this used to end up "offline forever". Falling
    // back to the local relay keeps the app reachable instead of dead.
    const local = 'ws://127.0.0.1:8787/ws';
    if (url == local) return;
    _log('改用本机端口再试一次…');
    if (!_localServer.running) {
      await _startHosting(quietWhenTaken: true);
      if (!_localServer.running) return;
    }
    try {
      await _client.connect(url: local, id: id, name: 'flutter-client');
      if (!mounted) return;
      setState(() => _serverCtrl.text = '');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kRelayOverride);
      _log('已改回本机（那个地址上的服务没有响应）');
    } catch (e) {
      _log('本机也没有可用的服务: $e');
    }
  }

  Future<void> _disconnect() async {
    await _teardownSession();
    await _client.disconnect();
    if (mounted) setState(() => _connected = false);
    _log('已断开');
  }

  // ------------------------------------------------------------------ session

  Future<void> _startController(
    String peer,
    SignalingClient signaling,
  ) async {
    // Only clear *our* controller session. A blanket teardown here also killed
    // the sessions other devices were watching on this machine, so answering a
    // call while someone else was connected dropped their picture.
    final previous = _session;
    if (previous != null && previous.role == SessionRole.controller) {
      await _inputSubs.remove(previous.peerId)?.cancel();
      _session = null;
      await previous.close();
    }
    _activeSignaling = signaling;
    final session = RtcSession(
      role: SessionRole.controller,
      signaling: signaling,
      peerId: peer,
      iceServers: _iceServers,
      onLog: _log,
      onPhase: _onPhase,
    );
    setState(() {
      _session = session;
      _phase = SessionPhase.negotiating;
      _busy = false;
    });
    _bindSessionInput(session);
    await _startClipboard();
    try {
      await session.start();
      await session.createOffer();
      _startStatsTimer();
      _armConnectTimeout(peer);
    } catch (e) {
      _log('建立主控会话失败: $e');
      setState(() => _phase = SessionPhase.failed);
    }
  }

  Future<void> _acceptAndShare(String peer) async {
    if (_busy) return;
    // Read the view geometry before any await: after the capture prompt the
    // context may be gone, and this is only a fallback anyway.
    final fallbackScreen = View.of(context).physicalSize;

    // A repeat call from the same caller (double tap, retry after a timeout)
    // must replace its own session, not pile a second peer connection onto the
    // same device id — the relay only has one slot per id.
    await _closeSession(peer);
    if (!mounted) return;
    setState(() => _busy = true);
    _log('正在请求屏幕采集…');

    // Share one capture across every caller. Asking for the screen again for a
    // second viewer would pop a second permission prompt on macOS and run a
    // second screen grab for identical pixels.
    MediaStream? stream = _hostStream;
    if (stream == null) {
      // Capture first: browsers only allow getDisplayMedia inside a user gesture.
      try {
        stream = _useFakeCapture
            // Self-test path: same RtcSession pipeline, no permission prompt.
            ? await navigator.mediaDevices.getUserMedia(<String, dynamic>{
                'video': <String, dynamic>{
                  'width': 1280,
                  'height': 720,
                  'frameRate': 30,
                },
                'audio': false,
              })
            : await _capture.capture(await _resolveCaptureRequest());
      } catch (e) {
        _log('屏幕采集被取消或失败: $e');
        _activeSignaling.reject(peer);
        if (mounted) {
          setState(() => _busy = false);
        }
        return;
      }
      _hostStream = stream;
    } else {
      _log('复用已有画面（不再单独采集）——${_hosted.length} 人正在看这台电脑');
    }

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
      signaling: _activeSignaling,
      peerId: peer,
      iceServers: _iceServers,
      targetScreen: injectorScreen,
      onLog: _log,
      onPhase: (phase) => _onHostedPhase(peer, phase),
    );
    _hosted[peer] = session;
    setState(() {
      _session = session;
      _phase = SessionPhase.preparing;
      _busy = false;
    });
    _bindSessionInput(session);
    await _startClipboard();

    // Accept only once we really have frames to send.
    _activeSignaling.accept(peer);
    _log('已接受 ${_prettyPeerId(peer)}，开始共享屏幕'
        '${_hosted.length > 1 ? '（共 ${_hosted.length} 人）' : ''}');

    try {
      await session.start(localStream: stream);
      _startStatsTimer();
      _startSourceWatch();
      _armConnectTimeout(peer);
    } catch (e) {
      _log('建立被控会话失败: $e');
      setState(() => _phase = SessionPhase.failed);
    }
  }

  /// Phase changes are reported per session; only the one on stage drives the
  /// header, so a second caller failing must not blank out a working picture.
  void _onHostedPhase(String peer, SessionPhase phase) {
    if (!mounted) return;
    if (_session?.peerId != peer) return;
    setState(() => _phase = phase);
  }

  void _onPhase(SessionPhase phase) {
    if (!mounted) return;
    if (phase == SessionPhase.live) {
      _connectTimer?.cancel();
      _connectTimer = null;
    }
    setState(() => _phase = phase);
    _reportTitle();
  }

  void _armConnectTimeout(String peer) {
    _connectTimer?.cancel();
    _connectTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted) return;
      if (_phase == SessionPhase.live) return;
      if (_session?.peerId != peer) return;
      _log('${_prettyPeerId(peer)} 25 秒还没出画面 —— 通道没有建立');
      setState(() => _phase = SessionPhase.failed);
    });
  }

  /// True when ⌘ should travel as Ctrl.
  ///
  /// Only macOS has ⌘, and it sits exactly where every other platform keeps
  /// Ctrl — so a Mac user pressing ⌘C means "copy". Sending it as the Win/Super
  /// key makes Windows open a system panel instead, which reads as "copying to
  /// the other machine does not work".
  ///
  /// Deliberately conservative about the unknown case: an older peer does not
  /// report its platform, and rewriting ⌘ to Ctrl for a Mac-to-Mac session
  /// would silently break every shortcut the user knows.
  bool get _commandAsControl {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return false;
    if (!_cmdAsCtrl) return false;
    final remote = _remoteHello?.platform ?? '';
    return remote.isNotEmpty && remote != 'macos';
  }

  void _sendClipboard(String text) {
    // Every live session shares this machine's clipboard: with several viewers
    // connected, copying once here has to reach all of them, not just the one
    // currently drawn in the stage.
    if (_hosted.isEmpty && _session == null) return;
    final targets = <RtcSession>{..._hosted.values};
    final current = _session;
    if (current != null) targets.add(current);
    var sent = 0;
    for (final session in targets) {
      // Not queued on purpose: by the time the channel opens, the text can be
      // minutes old, and pushing stale clipboard content into someone's machine
      // is worse than not pushing it. The toolbar's push button is the retry.
      if (!session.input.isOpen) continue;
      session.input.send(proto.ClipboardEvent(text));
      sent++;
    }
    if (sent == 0) _log('输入通道未就绪，本次剪贴板未发送');
  }

  Future<void> _startClipboard() async {
    if (!_clipboardEnabled) return;
    // baseline: what is on the clipboard at connect time is *not* news. Pushing
    // it would overwrite whatever the other side had prepared.
    await _clipboard.start();
    _log('剪贴板同步已开启（两个方向）');
  }

  Future<void> _setClipboardEnabled(bool on) async {
    setState(() => _clipboardEnabled = on);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kClipboard, on);
    if (on && (_session != null || _hosted.isNotEmpty)) {
      await _clipboard.start();
    } else {
      await _clipboard.stop();
    }
    _log(on ? '剪贴板同步已开启（两个方向）' : '剪贴板同步已关闭');
  }

  /// Ship the clipboard as it is right now.
  ///
  /// Covers the case "nothing is pushed on connect": text copied *before*
  /// dialling would otherwise never reach the other side, since no change
  /// happens after the baseline is taken.
  Future<void> _pushClipboard() async {
    if (!_clipboard.isRunning) await _clipboard.start(baseline: false);
    await _clipboard.pushNow();
  }

  /// Route inbound input frames.
  ///
  /// On the target every non-handshake event goes straight into the local
  /// desktop. On the controller the only inbound frame is the target's
  /// `hello`, which just updates the HUD.
  void _bindSessionInput(RtcSession session) {
    final peer = session.peerId;
    _inputSubs.remove(peer)?.cancel();
    if (session.role == SessionRole.controller) {
      _remoteHello = null;
      _inputRx = 0;
      _moveRx = 0;
      _keyRx = 0;
    }
    _inputSubs[peer] = session.input.events.listen((event) async {
      if (event is proto.HelloEvent) {
        if (!mounted) return;
        // Only the controller renders `hello` (the HUD shows the far desktop's
        // real size). On the target it means the far end is configured as a
        // controller too — nothing to draw, and overwriting our own stage's
        // geometry from it would be wrong.
        if (session.role != SessionRole.controller) return;
        setState(() => _remoteHello = event);
        _log('远端桌面 ${event.screenWidth}×${event.screenHeight}'
            '（画面 ${event.videoWidth}×${event.videoHeight}）'
            '${event.platform.isEmpty ? ' · 平台未知（老版本）' : ' · ${event.platform}'}');
        // Say it once, in the log, because "my ⌘C does not copy over there" is
        // otherwise indistinguishable from a broken keyboard.
        if (_commandAsControl) _log('⌘ 键将作为 Ctrl 发送');
        _reportTitle();
        return;
      }
      // Count before injecting: the count proves the frame crossed the wire,
      // which is the part that can be verified without a native target.
      if (event is proto.ClipboardEvent) {
        // State transfer, not input: it changes the local clipboard and never
        // touches the injector.
        await _clipboard.applyRemote(event.text);
        return;
      }
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

  /// 被控端：盯着"正在采集的那块屏还在不在"。
  ///
  /// 显示器断电或换线时，Windows 会销毁当前输出、在新编号上重建一个，DXGI
  /// 那条采集流从此不出帧。症状是画面黑着、但会话完全正常——鼠标还能动、
  /// 剪贴板还同步，所以看起来像"画面断了"，其实是"源没了"。
  ///
  /// 发现源消失就把采集换到新输出上（`replaceTrack`，不重新协商），画面几秒
  /// 内自己回来，不用断开重连。检查间隔 5 秒：枚举一次要过插件拿缩略图，
  /// 太频繁会让被控端白白耗电，而换显示器这种事本来也不差这几秒。
  void _startSourceWatch() {
    _sourceWatchTimer?.cancel();
    _sourceWatchTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
      // Watch while *any* caller is being served; the capture is shared, so one
      // broken display breaks every viewer at once.
      if (_hosted.isEmpty || !mounted) return;
      if (_recovering) return;
      final current = _request.sourceId;
      if (current == null) return;
      final sources = await _capture.listSources();
      if (!captureSourceGone(sources, current)) return;
      final next = pickCaptureSource(sources, null);
      if (next == null) return;
      _recovering = true;
      try {
        await _recoverCapture(next);
      } finally {
        _recovering = false;
      }
    });
  }

  /// 把采集切到 [next]，全程不动会话。
  ///
  /// 多个被控会话共享同一条采集流，所以这里必须先把新轨道换到**每一个**会话
  /// 上，最后才能停旧流。先停旧流会让还没换的那几路当场黑屏。
  Future<void> _recoverCapture(CaptureSource next) async {
    final request = _request.copyWith(sourceId: next.id);
    _log('⚠ 原采集源已从系统消失（显示器断电或换线？），'
        '改用 ${next.name} [${next.id}] 并重采');
    final MediaStream stream;
    try {
      stream = await _capture.capture(request);
    } catch (e) {
      // 到这一步就不是代码能救的了：连新输出都采不到，只能如实说明，
      // 别让用户对着黑屏猜。
      _log('重新采集失败: $e —— 画面会保持黑屏，可断开重连再试');
      return;
    }
    _request = request;
    final previous = _hostStream;
    _hostStream = stream;

    var swapped = 0;
    for (final session in _hosted.values.toList(growable: false)) {
      if (await session.replaceLocalStream(stream, stopPrevious: false)) {
        swapped++;
      } else {
        // 还没走到 addTrack（offer 未到），把新流直接交给会话，下次挂轨就用它。
        await session.useLocalStream(stream);
      }
    }

    // 所有会话都换到新轨道之后才能停旧流。
    if (previous != null && !identical(previous, stream)) {
      for (final track in previous.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
    }
    _log(swapped > 0
        ? '画面已恢复（采集源 ${next.name}）· $swapped 路会话已切换'
        : '采集已重建，等会话挂轨后生效');
  }

  /// 关掉**某一路**会话（被控端按对端 id；主控端就是唯一那一路）。
  ///
  /// 清理无条件执行，包括 `_busy`、拨号连接和 `setState`。原来的写法在
  /// `_session == null`（还在拨号、等对方接受）时直接 return，于是"连不上想
  /// 取消"留下的是一个永远转圈的按钮、一条仍然挂着的拨号连接，而且界面不刷新
  /// ——用户只能杀掉进程重来。
  Future<void> _closeSession(String peerId, {bool notifyPeer = true}) async {
    _connectTimer?.cancel();
    _connectTimer = null;
    final hosted = _hosted.remove(peerId);
    final current = _session;

    if (hosted != null) {
      if (notifyPeer) hosted.signaling.leave(peerId);
      await _inputSubs.remove(peerId)?.cancel();
      await hosted.close(stopLocalStream: false);
    }
    if (current != null && current.peerId == peerId && !identical(current, hosted)) {
      if (notifyPeer) current.signaling.leave(peerId);
      await _inputSubs.remove(peerId)?.cancel();
      await current.close(stopLocalStream: _hosted.isEmpty);
      _session = null;
    } else if (identical(current, hosted)) {
      _session = null;
    }

    // 还有别的被控会话：舞台切到剩下那一路，别让界面突然空白。
    if (_session == null && _hosted.isNotEmpty) {
      _session = _hosted.values.last;
      _phase = _session!.phase;
    }
    if (_session == null) {
      _phase = SessionPhase.idle;
      _stats = SessionStats.empty;
      _remoteHello = null;
      _statsTimer?.cancel();
      _statsTimer = null;
    }

    // 一个会话都不剩才停采集：共享流一停，系统那个"正在共享屏幕"的提示才消失。
    if (_hosted.isEmpty && _session == null) {
      _sourceWatchTimer?.cancel();
      _sourceWatchTimer = null;
      await _clipboard.stop();
      await _stopHostStream();
    } else if (_hosted.isNotEmpty) {
      // 还有人在看，采集看门狗必须继续跑。
      _startSourceWatch();
    }

    // 拨号连接只属于这一次呼叫；留着会在对端留下一条过期登记。
    if (_activeSignaling == _dial && _hosted.isEmpty && _session == null) {
      await _dial.disconnect();
      _activeSignaling = _client;
    }
    _busy = false;
    if (mounted) setState(() {});
  }

  Future<void> _stopHostStream() async {
    final stream = _hostStream;
    _hostStream = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
  }

  /// 清空全部会话与计时器（退出程序、断开信令时用）。
  Future<void> _teardownSession({bool notifyPeer = true}) async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _sourceWatchTimer?.cancel();
    _sourceWatchTimer = null;
    _recovering = false;
    for (final sub in _inputSubs.values.toList(growable: false)) {
      await sub.cancel();
    }
    _inputSubs.clear();
    await _clipboard.stop();
    _remoteHello = null;

    final peers = <String>{
      ..._hosted.keys,
      if (_session != null) _session!.peerId,
    };
    for (final peer in peers) {
      final hosted = _hosted.remove(peer);
      if (hosted != null) {
        if (notifyPeer) hosted.signaling.leave(peer);
        await hosted.close(stopLocalStream: false);
      }
      final current = _session;
      if (current != null && current.peerId == peer && !identical(current, hosted)) {
        if (notifyPeer) current.signaling.leave(peer);
        await current.close(stopLocalStream: false);
      }
    }
    _session = null;
    await _stopHostStream();
    _stats = SessionStats.empty;
    _phase = SessionPhase.idle;
    _busy = false;
    // The dial connection exists only for this session; keeping it open would
    // leave a stale registration on a machine that may reboot or move.
    if (_activeSignaling == _dial) {
      await _dial.disconnect();
      _activeSignaling = _client;
    }
    if (mounted) setState(() {});
  }

  /// 「断开」按钮：结束当前会话，或取消一次还没被接受的呼叫。
  Future<void> _hangUp() async {
    final peer = _session?.peerId ?? _targetCtrl.text.trim();
    if (peer.isEmpty || _session == null) {
      // 拨号已经发出、对方还没接受：没有会话可关，但按钮必须立刻活过来。
      _busy = false;
      if (_activeSignaling == _dial) {
        await _dial.disconnect();
        _activeSignaling = _client;
      }
      if (mounted) setState(() {});
      _log('已取消这次连接');
      return;
    }
    await _closeSession(peer);
    _log('已结束会话');
  }

  Future<void> _call() async {
    final to = _targetCtrl.text.trim();
    if (to.isEmpty) {
      _log('请选择一个要连接的设备');
      return;
    }
    final password = _passCtrl.text;
    // Dialling means joining the peer's relay, so the target's address has to
    // travel with the call. It comes from the list (or the pairing code), never
    // from a field the user had to fill with an IP.
    final host = _targetHost.trim();
    if (host.isEmpty) {
      _log('不知道该连哪台机器的地址 — 请从列表里选，或用配对码');
      return;
    }
    setState(() => _busy = true);
    final callerId = _callerId();
    try {
      await _dial.connect(
        url: 'ws://$host:$_targetPort/ws',
        id: callerId,
        name: _deviceCtrl.text.trim(),
      );
    } catch (e) {
      _log('连不上 $host —— $e');
      if (mounted) setState(() => _busy = false);
      return;
    }
    _activeSignaling = _dial;
    _dial.connectTo(to, password: password.isEmpty ? null : password);
    _log('已请求连接 ${_prettyPeerId(to)}${password.isEmpty ? '' : '（带访问口令）'}');

    // A call that is accepted by the relay but never answered — the far side is
    // up, its window is behind something, nobody is at the keyboard — would
    // otherwise leave the button disabled forever with no explanation. Fifteen
    // seconds is past the point where a person has decided it is stuck.
    Timer(const Duration(seconds: 15), () {
      if (!mounted || !_busy || _session?.role == SessionRole.controller) return;
      setState(() => _busy = false);
      _log('${_prettyPeerId(to)} 15 秒没有回应 —— 可能窗口弹在对方看不到的地方；'
          '对端开着「允许远程控制」时会自动接受，没开就需要有人在那边点一下');
    });
  }

  /// The id we register under on someone else's relay.
  ///
  /// It must differ from the id we use on our own relay, or the far server sees
  /// two devices with the same id and rejects the second — which shows up as
  /// "the other machine refuses me" with no useful message. The suffix is
  /// stripped again when displaying it.
  String _callerId() {
    final base = _deviceCtrl.text.trim();
    return base.isEmpty ? 'caller' : '$base-ctl';
  }

  /// Turn `mac-mini-ctl` back into `mac-mini` for anything a person reads.
  static String _prettyPeerId(String id) =>
      id.endsWith('-ctl') ? id.substring(0, id.length - 4) : id;

  /// Dial a peer picked from the list (or a remembered one).
  Future<void> _dialTo(PeerInfo peer, {String? password}) async {
    if (_busy || _session?.role == SessionRole.controller) return;
    setState(() {
      _targetCtrl.text = peer.id;
      _targetHost = peer.host;
      _targetPort = peer.port;
      if (password != null) _passCtrl.text = password;
    });
    await _rememberPeer(peer, password: password ?? '');
    await _call();
  }

  /// Dial from a pasted pairing code.
  ///
  /// One field instead of three: the code carries address, id and password, so
  /// the person who pastes it never has to know which machine is relaying.
  Future<void> _connectByCode([String? raw]) async {
    final source = (raw ?? _pairCtrl.text).trim();
    final code = PairingCode.parse(source);
    if (code == null) {
      _log('这行字里没有可用的地址 — 让对方重新复制一次配对码');
      return;
    }
    if (code.id.isEmpty) {
      _log('这行字里只有地址，还缺设备 ID');
      return;
    }
    _log('配对码：连 ${code.id} @ ${code.host}:${code.port}');
    if (_pairCtrl.text.trim() == source) {
      setState(_pairCtrl.clear);
    } else if (raw == null) {
      setState(_pairCtrl.clear);
    }
    setState(() {
      _targetCtrl.text = code.id;
      _targetHost = code.host;
      _targetPort = code.port;
      if (code.password.isNotEmpty) _passCtrl.text = code.password;
    });
    await _dialTo(
      PeerInfo(
        id: code.id,
        host: code.host,
        port: code.port,
        name: code.id,
        source: PeerSource.manual,
      ),
      password: code.password,
    );
  }

  /// This machine's own code, for the other person to paste. Empty until the
  /// relay address is known — a code without an address is worse than none.
  String get _myPairingCode {
    final host = Uri.tryParse(_peerServerUrl)?.host ?? '';
    final id = _deviceCtrl.text.trim();
    if (host.isEmpty || id.isEmpty) return '';
    return PairingCode(
      host: host,
      id: id,
      password: _unattendedPassword,
    ).encode();
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
      _activeSignaling.reject(from);
      return;
    }

    final offered = (m['password'] as String?) ?? '';
    if (offered.isEmpty) {
      _log('⚠ 无人值守：$from 未提供口令，已拒绝');
      _activeSignaling.reject(from);
      return;
    }
    if (!_constantTimeEquals(offered, _unattendedPassword)) {
      _log('⚠ 无人值守：$from 口令错误，已拒绝');
      _activeSignaling.reject(from);
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
              _activeSignaling.reject(from);
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
        title: const Text('给这台电脑改个名字'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名字',
            helperText: '对方在列表里看到的就是它。用字母数字，别和另一台重名',
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
    // Must re-register: the relay keys devices by this id, and discovery
    // advertises it. A stale id here makes the machine appear twice — once
    // under the old name in the other side's recent list, once under the new.
    await _disconnect();
    if (!mounted) return;
    setState(() => _deviceCtrl.text = value);
    _localServer.setIdentity(id: value, name: value);
    await _discovery.stop();
    await _discovery.startResponder(selfId: value);
    _discovery.startAnnouncing();
    await _connect();
    _log('本机名字已改为 $value');
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
  ///
  /// The auto-resolved source is **not** cached across sessions: see
  /// [_sourceChosenByUser]. Caching it means a display change (unplug, power
  /// off, cable moved to another machine) leaves us asking for an output id
  /// the system has already destroyed — the session connects and never gets a
  /// frame.
  Future<CaptureRequest> _resolveCaptureRequest() async {
    if (kIsWeb) return _request;
    if (_request.sourceId != null && _sourceChosenByUser) return _request;
    try {
      final sources = await _capture.listSources();
      final previous = _request.sourceId;
      final screen = pickCaptureSource(sources, previous);
      if (screen == null) {
        _log('⚠ 没有枚举到可采集的屏幕，可能缺少屏幕录制权限');
        return _request;
      }
      _request = _request.copyWith(sourceId: screen.id);
      if (mounted) setState(() => _sources = sources);
      final dropped = previous != null && previous != screen.id;
      // 名字（"Screen 1"）在换接口后会被系统重新分配，只有 id 才是稳定的
      // 身份。两边都写进日志，才分得清"抓错源"和"系统根本没画面"。
      _log(dropped
          ? '⚠ 采集源已失效（显示器编号变了？），改用: $previous → '
              '${screen.name} [${screen.id}]'
          : '采集源: ${screen.name} [${screen.id}]');
    } catch (e) {
      _log('枚举采集源失败: $e');
    }
    return _request;
  }

  Future<void> _refreshSources() async {
    final sources = await _capture.listSources();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      // 下拉框的 value 必须落在 items 里，否则 DropdownButtonFormField 直接
      // 断言失败、整块界面崩掉。显示器换过之后旧 id 会从列表里消失，这里
      // 跟着清掉，交给下一次会话重新解析。
      final current = _request.sourceId;
      if (current != null && !sources.any((s) => s.id == current)) {
        _request = CaptureRequest(
          width: _request.width,
          height: _request.height,
          frameRate: _request.frameRate,
          showCursor: _request.showCursor,
        );
        _sourceChosenByUser = false;
      }
    });
    _log(sources.isEmpty
        ? '当前平台由系统/浏览器弹窗选择采集源'
        : '发现 ${sources.length} 个可采集源');
  }

  // ----------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    // One state object, two entirely different shells. Everything above this
    // line — signaling, discovery, sessions — is shared, so the phone cannot
    // drift away from the desktop behaviour.
    if (isHandheld) return MobileHomePage(host: this);

    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteDesk'),
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
              const Text('还没连上任何电脑'),
              const SizedBox(height: 6),
              Text(
                '左边点一台连过去；或者等别人连你',
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
      clipboardEnabled: _clipboardEnabled,
      onClipboardChanged: _setClipboardEnabled,
      onPushClipboard: _pushClipboard,
      commandAsControl: _commandAsControl,
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
              _serverCtrl.text.trim().isEmpty ||
                      _isLoopbackRelay(_serverCtrl.text)
                  ? '本机的服务端口 8787 没起来，可能被别的程序占着。\n'
                      '别人仍然可以连你（局域网/配对码），但你现在连不出别人。'
                  : '连不上 ${_serverCtrl.text.trim()}。\n'
                      '这是「更多设置」里手工填的地址 —— 清空它就会改回本机。',
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

  /// Who is watching this machine right now, and how to drop one of them.
  ///
  /// A desktop can serve several viewers at once, so "somebody is connected"
  /// is no longer a yes/no fact: the user needs to see how many, and to be able
  /// to kick one without closing the others.
  Widget _viewersRow(ThemeData theme) {
    if (_hosted.isEmpty) return const SizedBox.shrink();
    final ids = _hosted.keys.toList(growable: false);
    const green = Color(0xFF16A34A);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: green.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.visibility_outlined, size: 15, color: green),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${ids.length} 台设备正在看这台电脑',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          for (final id in ids)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  const SizedBox(width: 21),
                  Expanded(
                    child: Text(
                      _prettyPeerId(id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _closeSession(id),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('断开', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (ids.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Text(
                '多人同时操作时鼠标会互相抢。要稳定操作，只留一个人就好。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One line that answers "can my phone reach this computer from outside?",
  /// with the explanation folded underneath.
  ///
  /// Before this existed the answer was only inferable from an IP address in an
  /// advanced field, so "connect over the internet" read as a feature that did
  /// not exist. The status is stated first, the steps only appear when asked.
  Widget _reachRow(ThemeData theme) {
    final reach = _reach;
    final ok = reach.worksFromOutside;
    final color = switch (reach.kind) {
      ReachKind.tailscale => const Color(0xFF16A34A),
      ReachKind.lanOnly => const Color(0xFFD97706),
      ReachKind.publicIp => const Color(0xFF2563EB),
      ReachKind.none => theme.colorScheme.outline,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _reachOpen = !_reachOpen),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.28)),
            ),
            child: Row(
              children: [
                Icon(ok ? Icons.public : Icons.wifi, size: 16, color: color),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    reach.headline,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _reachOpen ? '收起' : '怎么连',
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
                Icon(
                  _reachOpen ? Icons.expand_less : Icons.expand_more,
                  size: 17,
                  color: color,
                ),
              ],
            ),
          ),
        ),
        if (_reachOpen) ...[
          const SizedBox(height: 8),
          _reachPanel(theme, reach),
        ],
      ],
    );
  }

  Widget _reachPanel(ThemeData theme, ReachInfo reach) {
    final body = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.55,
        );
    final strong = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(reach.detail, style: body),
          const SizedBox(height: 10),
          if (reach.kind == ReachKind.lanOnly ||
              reach.kind == ReachKind.publicIp) ...[
            Text('要让外面也能连，按这三步：', style: strong),
            const SizedBox(height: 6),
            _step(theme, '1', '这台电脑装 Tailscale 并登录（tailscale.com，免费）'),
            _step(theme, '2', '手机装 Tailscale，登录同一个账号'),
            _step(theme, '3', '回来点下面的「重新检测」，状态会变成「出门也能连」'),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _refreshReach,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新检测'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ] else if (reach.kind == ReachKind.tailscale) ...[
            Text('手机在外面这样连：', style: strong),
            const SizedBox(height: 6),
            _step(theme, '1', '手机装 Tailscale，登录同一个账号'),
            _step(theme, '2', '在电脑上复制上面的配对码，发到手机'),
            _step(theme, '3', '手机 RemoteDesk 里粘贴，点「连接」'),
            const SizedBox(height: 8),
            Text(
              '不用配路由器、不用固定 IP、不用买服务器。',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ] else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _refreshReach,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新检测'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _step(ThemeData theme, String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.only(top: 1, right: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
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
      color: theme.colorScheme.onSurface,
    );
    final code = _myPairingCode;

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
            _viewersRow(theme),
            if (_hosted.isNotEmpty) const SizedBox(height: 8),
            // First thing under the title: whether this machine is reachable
            // from outside. It decides what the user should do next, so it
            // cannot live at the bottom of an advanced panel.
            _reachRow(theme),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '这台电脑的名字（对方选它就能连）',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(selfId.isEmpty ? '—' : selfId, style: idStyle),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _copyToClipboard('本机名称', selfId),
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制名字',
                ),
                IconButton(
                  onPressed: _editDeviceId,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: '改名',
                ),
              ],
            ),
            // The escape hatch, in one line.
            //
            // Auto-discovery covers the normal case; this is for the case it
            // cannot — a network that blocks broadcasts and has no tailnet, or
            // handing access to someone outside both. It replaces the old
            // "对方服务器填 ws://…" line: that one leaked the relay concept and
            // still left the password to be typed separately.
            if (code.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _copyToClipboard('配对码', code),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.qr_code_2,
                          size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          code,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Icon(Icons.copy,
                          size: 14, color: theme.colorScheme.primary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '点一下复制，发给对方就能连。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline, height: 1.4),
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
                '打开后不用有人守着，凭密码自动接受。',
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
  /// "Connect to another computer": a list you tap, or one line you paste.
  ///
  /// There is deliberately no address field on this path. Which machine relays
  /// the handshake is an implementation detail; asking the user to decide it
  /// was the reason this screen used to need a paragraph of explanation.
  Widget _connectCard(ThemeData theme) {
    // Only a *controller* session blocks dialling out. A session we are serving
    // must not: one machine can be watched by a phone while its owner remote
    // controls another computer, and greying out the whole list made that
    // impossible to even attempt.
    final busy = _busy || _session?.role == SessionRole.controller;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('连接另一台电脑', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_scanning)
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  )
                else
                  IconButton(
                    onPressed: busy ? null : _scanPeers,
                    icon: const Icon(Icons.refresh, size: 17),
                    tooltip: '重新查找',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (_foundPeers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  _scanning
                      ? '正在查找…'
                      : '还没找到。让另一台电脑先打开 RemoteDesk，'
                          '两台在同一个 Wi-Fi 或同一个 Tailscale 网络里就会自动出现。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    height: 1.45,
                  ),
                ),
              )
            else
              for (final peer in _foundPeers.take(6))
                _peerRow(theme, peer, busy: busy),
            const SizedBox(height: 10),
            // Pasting a line covers what discovery cannot: no shared network,
            // no tailnet, or handing access to someone outside both.
            Row(
              children: [
                Expanded(
                  child: _field(
                    _pairCtrl,
                    '或者粘贴对方给你的配对码',
                    onSubmitted: (_) => _connectByCode(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 40,
                  child: FilledButton.tonal(
                    onPressed: busy ? null : _connectByCode,
                    child: const Text('连'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _manualConnectToggle(theme, busy: busy),
          ],
        ),
      ),
    );
  }

  /// One row: name, where it was found, and a tap target that dials it.
  Widget _peerRow(ThemeData theme, PeerInfo peer, {required bool busy}) {
    final offline = !peer.online;
    final isRecent = _recentPeerIds.contains(peer.id) && peer.id.isNotEmpty;
    final meta = <String>[
      if (isRecent) '上次连过',
      peer.sourceLabel,
      peer.host,
    ].join(' · ');

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: busy ? null : () => _connectToPeer(peer),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Row(
          children: [
            Icon(
              peer.platform.contains('win')
                  ? Icons.desktop_windows_outlined
                  : Icons.desktop_mac_outlined,
              size: 18,
              color: offline
                  ? theme.colorScheme.outline
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: offline
                          ? theme.colorScheme.outline
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    offline ? '$meta · 现在没连上' : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }

  /// Tap a peer: connect, asking for a password only when we do not have one.
  ///
  /// The password is remembered after the first success, so the second time is
  /// one tap and nothing else. Without that, unattended mode would mean typing
  /// six characters on every single connection — which is precisely the kind of
  /// friction this whole change is about.
  Future<void> _connectToPeer(PeerInfo peer) async {
    if (_busy || _session != null) return;
    var password = _passwordFor(peer);
    if (password == null) {
      final typed = await _askPassword(peer);
      if (typed == null) return;
      password = typed;
    }
    await _dialTo(peer, password: password);
  }

  /// Cached password for a peer, or null when we have never connected to it.
  ///
  /// An empty string is a real answer: it means the far machine does not require
  /// one, and the caller must not prompt.
  String? _passwordFor(PeerInfo peer) {
    for (final raw in _recentCodes) {
      final code = PairingCode.parse(raw);
      if (code != null && code.id == peer.id) return code.password;
    }
    return null;
  }

  Future<String?> _askPassword(PeerInfo peer) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('连接 ${peer.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '如果对方开着「允许远程控制」，输入它显示的连接密码。'
              '如果没开，直接点连接 —— 对方屏幕上会弹出确认。',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '连接密码（可留空）',
                isDense: true,
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    return result;
  }

  /// The escape hatch, collapsed. Only reachable by people who know they need
  /// it — an address box on the main path is what this change removes.
  Widget _manualConnectToggle(ThemeData theme, {required bool busy}) {
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        title: Text(
          '手动连（配对码不好用时）',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        children: [
          Text(
            '对方把名字、密码、地址分开告诉你时才用这里；'
            '有一行配对码就直接粘到上面的框。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _field(_targetCtrl, '对方的名字')),
              const SizedBox(width: 8),
              Expanded(child: _field(_passCtrl, '对方的密码', obscure: true)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _field(_manualHostCtrl, '对方的地址（IP 或 ws://IP:8787/ws）'),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: FilledButton(
                  onPressed: busy ? null : _connectManual,
                  child: const Text('连接'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _connectManual() async {
    final host = _manualHostCtrl.text.trim();
    final id = _targetCtrl.text.trim();
    if (id.isEmpty) {
      _log('还差对方的名字（在对方那台的「这台电脑」卡片上）');
      return;
    }
    if (host.isEmpty) {
      final peer = _foundPeers.where((p) => p.id == id).firstOrNull;
      if (peer == null) {
        _log('还差对方地址 — 可以问对方要一行配对码，粘到上面的框里');
        return;
      }
      await _dialTo(peer, password: _passCtrl.text);
      return;
    }
    // Accept a bare IP, an IP with port, or a full ws:// URL — people paste all
    // three, and rejecting two of them teaches nothing.
    final parsed = PairingCode.parse('RDSK1 $host $id ${_passCtrl.text}') ??
        PairingCode.parse(host);
    if (parsed == null) {
      _log('这个地址看不懂：$host');
      return;
    }
    await _dialTo(
      PeerInfo(id: id, host: parsed.host, port: parsed.port, name: id),
      password: _passCtrl.text,
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
          // Always folded. Frame rate, capture source, relay override and the
          // log path are tuning knobs, not decisions anyone makes on first run;
          // auto-opening them while offline is what made this panel read as a
          // control room rather than a remote-desktop app.
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          title: Text('更多设置', style: theme.textTheme.titleSmall),
          subtitle: Text(
            '画面清晰度、中转地址、日志 · 一般不用动',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: _field(
                    _serverCtrl,
                    '改用自己的中转服务（留空=本机，一般不用填）',
                    onSubmitted: (_) => _connect(),
                  ),
                ),
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
                          onChanged: (v) => setState(() {
                            _request = _request.copyWith(sourceId: v);
                            // 手动选过就固定用它，不再自动重新解析。
                            _sourceChosenByUser = v != null;
                          }),
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

  // ---------------------------------------------------------------------------
  // MobileHost — the phone shell's only view of this state.
  //
  // Deliberately thin: every member either forwards to something that already
  // existed or exposes one field. Nothing here re-implements behaviour, which
  // is what keeps the phone and the desktop honest about doing the same thing.
  // ---------------------------------------------------------------------------

  @override
  List<PeerInfo> get peers => _foundPeers;

  @override
  bool get scanning => _scanning;

  @override
  RtcSession? get session => _session;

  @override
  SessionPhase get phase => _phase;

  @override
  SessionStats get stats => _stats;

  @override
  proto.HelloEvent? get remoteHello => _remoteHello;

  @override
  bool get signalingUp => canHostScreen ? _connected : _ready;

  @override
  bool get busy => _busy;

  @override
  String get selfId => (_selfId ?? _deviceCtrl.text).trim();

  @override
  List<String> get logLines => List<String>.unmodifiable(_logs);

  @override
  bool get controlEnabled => _controlEnabled;

  @override
  bool get clipboardEnabled => _clipboardEnabled;

  @override
  Future<void> pushClipboard() => _pushClipboard();

  @override
  void setClipboardEnabled(bool on) {
    unawaited(_setClipboardEnabled(on));
  }

  @override
  String get version => kAppVersion;

  @override
  Future<void> rescan() => _scanPeers();

  @override
  Future<void> connectPeer(PeerInfo peer) => _connectToPeer(peer);

  @override
  Future<void> connectByCode(String raw) => _connectByCode(raw);

  @override
  void setControlEnabled(bool on) {
    if (mounted) setState(() => _controlEnabled = on);
  }

  @override
  Future<void> hangUp() => _hangUp();

  /// Connect from a bare address, by asking that machine who it is.
  ///
  /// Typing an IP used to be impossible without also knowing the peer's id,
  /// because the handshake addresses people by name. `/info` is the answer: one
  /// GET tells us the id, so "address only" is a complete instruction again.
  @override
  Future<void> connectManual(String target) async {
    var text = target.trim();
    if (text.isEmpty) {
      _log('先填电脑地址，比如 192.168.1.20 或 192.168.1.20:8787');
      return;
    }
    text = text.replaceFirst(RegExp(r'^wss?://'), '').split('/').first;
    var host = text;
    var port = 8787;
    final colon = text.lastIndexOf(':');
    if (colon > 0) {
      host = text.substring(0, colon);
      port = int.tryParse(text.substring(colon + 1)) ?? port;
    }
    if (host.isEmpty) {
      _log('这个地址看不懂：$target');
      return;
    }
    _log('正在问 $host:$port 是谁…');
    final info = await probeInfo(
      host,
      port: port,
      timeout: const Duration(milliseconds: 1500),
    );
    if (info == null) {
      _log('$host:$port 上没有响应 — 确认电脑端开着 RemoteDesk，且手机和它在同一个网络');
      return;
    }
    final id = '${info['id'] ?? ''}'.trim();
    if (id.isEmpty) {
      _log('那台电脑没有报出名字 — 改用配对码更稳');
      return;
    }
    final name = '${info['name'] ?? id}'.trim();
    await _dialTo(
      PeerInfo(
        id: id,
        host: host,
        port: port,
        name: name.isEmpty ? id : name,
        source: PeerSource.manual,
      ),
      password: _passCtrl.text.trim(),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
