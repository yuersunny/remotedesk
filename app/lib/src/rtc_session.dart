import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'input_channel.dart';
import 'input_event.dart';
import 'signaling_client.dart';

/// Who we are in a session.
enum SessionRole {
  /// Shows the remote screen and (in M2) sends input events.
  controller,

  /// Captures the local screen and streams it out.
  target,
}

extension SessionRoleLabel on SessionRole {
  String get label => this == SessionRole.controller ? '主控' : '被控';
}

enum SessionPhase { idle, preparing, negotiating, connecting, live, closed, failed }

/// Label of the DataChannel that carries input events (M2).
const String kInputChannelLabel = 'input';

/// Label of the movement-only channel (unordered, disposable frames).
///
/// Kept separate from [kInputChannelLabel] on purpose; see `InputChannel._moveDc`
/// for why. A peer that does not recognise the label simply ignores it and moves
/// keep flowing over the reliable channel.
const String kMoveChannelLabel = 'move';

extension SessionPhaseLabel on SessionPhase {
  String get label => switch (this) {
        SessionPhase.idle => '未开始',
        SessionPhase.preparing => '准备中',
        SessionPhase.negotiating => '协商中',
        SessionPhase.connecting => '连接中',
        SessionPhase.live => '已连通',
        SessionPhase.closed => '已结束',
        SessionPhase.failed => '连接失败',
      };
}

/// A single snapshot of the media pipeline, used only for the on-screen HUD.
class SessionStats {
  const SessionStats({
    this.width,
    this.height,
    this.fps,
    this.kbps,
    this.rttMs,
    this.codec,
  });

  static const SessionStats empty = SessionStats();

  final int? width;
  final int? height;
  final int? fps;
  final double? kbps;
  final double? rttMs;
  final String? codec;

  String get resolution => (width != null && height != null) ? '${width!}×${height!}' : '—';
  String get fpsText => fps != null ? '$fps fps' : '—';
  String get kbpsText => kbps != null ? '${kbps!.toStringAsFixed(0)} kbps' : '—';
  String get rttText => rttMs != null ? '${rttMs!.toStringAsFixed(0)} ms' : '—';
  String get codecText {
    final c = codec;
    if (c == null || c.isEmpty) return '—';
    final part = c.split('/').last;
    return part.toUpperCase();
  }
}

/// One WebRTC session between two devices.
///
/// M1 scope: **video only, one direction** (target -> controller). No input
/// injection yet (that is M2), no audio.
///
/// The session never talks to the socket itself: the owner routes inbound
/// signaling frames into [handleSignal], which keeps one subscription in one
/// place.
class RtcSession {
  RtcSession({
    required this.role,
    required this.signaling,
    required this.peerId,
    this.iceServers = const <Map<String, dynamic>>[],
    this.targetScreen,
    this.onLog,
    this.onPhase,
  });

  final SessionRole role;
  final SignalingClient signaling;
  final String peerId;
  final List<Map<String, dynamic>> iceServers;

  /// Target side only: physical size of the screen being shared. Reported to
  /// the controller in the input `hello` so its HUD can show the real desktop
  /// resolution instead of the (possibly downscaled) video size.
  final Size? targetScreen;

  final void Function(String message)? onLog;
  final void Function(SessionPhase phase)? onPhase;

  /// Control channel for M2. Created lazily; see [ensureInputChannel].
  late final InputChannel input = InputChannel(onLog: _log);

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  SessionPhase _phase = SessionPhase.idle;
  SessionPhase get phase => _phase;

  bool _remoteDescriptionSet = false;
  bool _disposed = false;
  Map<String, dynamic>? _pendingOffer;
  final List<RTCIceCandidate> _pendingRemoteCandidates = <RTCIceCandidate>[];

  int _lastBytes = 0;
  DateTime _lastStatsAt = DateTime.now();
  SessionStats _stats = SessionStats.empty;

  SessionStats get stats => _stats;
  MediaStream? get remoteStream => _remoteStream;

  void _log(String message) => onLog?.call(message);
  void _setPhase(SessionPhase next) {
    if (_phase == next) return;
    _phase = next;
    onPhase?.call(next);
  }

  /// Create the peer connection.
  ///
  /// For the target side pass the captured [localStream] here (or call
  /// [useLocalStream] first) so tracks are attached before the answer is made.
  Future<void> start({MediaStream? localStream}) async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    if (localStream != null) _localStream = localStream;

    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    _pc = pc;

    // Target side: the controller creates the input channel, we just adopt it.
    // Non-matching labels are ignored so a future extra channel cannot break
    // control on an older build.
    pc.onDataChannel = (channel) {
      _log('收到数据通道: ${channel.label}');
      if (channel.label == kInputChannelLabel) {
        input.attach(channel);
      } else if (channel.label == kMoveChannelLabel) {
        input.attachMove(channel);
      }
    };

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      signaling.sendIce(peerId, <String, dynamic>{
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onTrack = (event) async {
      _log('收到远端轨道: ${event.track.kind}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
      } else {
        // Some senders deliver a bare track without a stream wrapper.
        final stream = await createLocalMediaStream('remote');
        await stream.addTrack(event.track);
        _remoteStream = stream;
      }
      remoteRenderer.srcObject = _remoteStream;
    };

    pc.onConnectionState = (state) {
      _log('连接状态: ${state.name}');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setPhase(SessionPhase.live);
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          _setPhase(SessionPhase.connecting);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _setPhase(SessionPhase.connecting);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setPhase(SessionPhase.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setPhase(SessionPhase.closed);
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          break;
      }
    };

    if (_localStream != null) {
      // 预览可以立刻挂上，但 **addTrack 不能在这里**：此刻还没有
      // setRemoteDescription，新建的 transceiver 与 offer 里那条 m-line 对不上，
      // 只能靠再协商一轮去合并，而这条链路没有重协商 —— 结果就是数据通道通、
      // 画面永远不来。推流交给 handleOffer，那时 offer 的 m-line 已经就位。
      localRenderer.srcObject = _localStream;
    }

    _setPhase(SessionPhase.negotiating);
    // An offer may have arrived while we were still creating the pipeline.
    final pending = _pendingOffer;
    if (pending != null) {
      _pendingOffer = null;
      await handleOffer(pending);
    }

    // Target side: greet the controller as soon as the input channel is up.
    // `opened` is a future rather than a callback so a handshake cannot be
    // lost if the channel came up before this line ran.
    if (role == SessionRole.target) {
      unawaited(input.opened.then((_) async {
        if (!input.isOpen) return;
        await sendHello();
      }));
    }
  }

  /// Controller side: create the input channel *before* sending the offer.
  ///
  /// Doing it here means the target receives the channel through
  /// `onDataChannel` during the same single negotiation round; creating it
  /// afterwards would force a renegotiation on a session that is already live.
  Future<void> ensureInputChannel() async {
    final pc = _pc;
    if (pc == null || input.hasChannel) return;
    try {
      final channel = await pc.createDataChannel(
        kInputChannelLabel,
        RTCDataChannelInit()..ordered = true,
      );
      input.attach(channel);
      _log('已创建输入通道');
    } catch (e) {
      _log('创建输入通道失败: $e');
    }

    // Movement channel: unordered, and frames that are not through within 30 ms
    // are abandoned rather than retransmitted. The library only forwards
    // `maxRetransmits`/`maxRetransmitTime` when positive (see
    // RTCDataChannelInit.toMap), so "no retransmit at all" is not expressible —
    // 30 ms is the closest behaviour and far below a perceptible stall.
    //
    // Failure here is not fatal: moves then ride the reliable channel above.
    try {
      final move = await pc.createDataChannel(
        kMoveChannelLabel,
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmitTime = 30,
      );
      input.attachMove(move);
      _log('已创建移动通道（无序，超时丢弃）');
    } catch (e) {
      _log('创建移动通道失败，鼠标移动将走可靠通道: $e');
    }
  }

  /// Target side: report desktop geometry to the controller.
  ///
  /// Public so a future geometry change (resolution switch, DPI change) can
  /// re-announce itself; nothing calls it a second time today. Frame size comes
  /// from the live track when available, because the encoder may hand back a
  /// smaller picture than requested.
  Future<void> sendHello() async {
    final screen = targetScreen;
    var videoWidth = 0;
    var videoHeight = 0;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getVideoTracks()) {
        try {
          final settings = track.getSettings();
          videoWidth = (settings['width'] as num?)?.toInt() ?? videoWidth;
          videoHeight = (settings['height'] as num?)?.toInt() ?? videoHeight;
        } catch (_) {
          // Settings are best-effort on every backend.
        }
      }
    }
    // Track settings are best-effort: a backend that cannot report them must
    // not cost the controller its handshake, because without `hello` the HUD
    // shows nothing and — worse — a controller cannot tell whether the target
    // is control-capable at all. Fall back to the screen size we do know.
    if (screen == null && (videoWidth <= 0 || videoHeight <= 0)) return;

    final screenWidth = screen?.width.round() ?? videoWidth;
    final screenHeight = screen?.height.round() ?? videoHeight;

    input.send(HelloEvent(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
    ));
    _log('已上报桌面尺寸 $screenWidth×$screenHeight'
        '（画面 $videoWidth×$videoHeight）');
  }

  /// Controller side only: reserve the receive-side video m-line.
  ///
  /// In unified-plan, `offerToReceiveVideo` is a Plan-B option and does **not**
  /// create an m-line. The controller captures nothing, so without this an
  /// offer carries the data channel and nothing else. The target's `addTrack`
  /// would then have to create its own transceiver, which needs a second
  /// negotiation round this pipeline never performs — the observable symptom
  /// is exactly "pointer works, no picture".
  Future<void> _ensureVideoReceiver(RTCPeerConnection pc) async {
    if (_videoReceiverAdded) return;
    _videoReceiverAdded = true;
    try {
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      _log('已预置接收侧视频 transceiver');
    } catch (e) {
      // Older platform implementations may lack transceiver support. Failing
      // here must not cost us the session: fall back to the old behaviour and
      // let the negotiation succeed or fail on its own merits.
      _videoReceiverAdded = false;
      _log('预置视频 transceiver 失败（将回退）: $e');
    }
  }

  bool _videoReceiverAdded = false;
  bool _tracksAttached = false;

  Future<void> _attachTracks(RTCPeerConnection pc, MediaStream stream) async {
    if (_tracksAttached) return;
    _tracksAttached = true;
    for (final track in stream.getVideoTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  /// Target side: hand over a stream captured *after* the pipeline started.
  Future<void> useLocalStream(MediaStream stream) async {
    _localStream = stream;
    localRenderer.srcObject = stream;
    final pc = _pc;
    if (pc == null) return;
    if (_remoteDescriptionSet) {
      // Same rule as [start]: only attach once the remote description is in, so
      // the track lands on the offer's m-line instead of a fresh transceiver.
      await _attachTracks(pc, stream);
      return;
    }
    // An offer arrived while we were still capturing — it was parked because
    // there was nothing to send. Answer it now.
    final pending = _pendingOffer;
    if (pending != null) {
      _pendingOffer = null;
      await handleOffer(pending);
    }
  }

  /// Controller side: make the offer and send it.
  Future<void> createOffer() async {
    final pc = _pc;
    if (pc == null || _disposed) return;
    await ensureInputChannel();
    await _ensureVideoReceiver(pc);
    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveVideo': true,
      'offerToReceiveAudio': false,
    });
    await pc.setLocalDescription(offer);
    signaling.sendOffer(peerId, <String, dynamic>{'type': offer.type, 'sdp': offer.sdp});
    _log('已发送 offer');
    _setPhase(SessionPhase.connecting);
  }

  /// Route one signaling frame here. Returns true when the frame was consumed.
  Future<bool> handleSignal(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'offer':
        final sdp = message['sdp'];
        if (sdp is Map) await handleOffer(Map<String, dynamic>.from(sdp));
        return true;
      case 'answer':
        final sdp = message['sdp'];
        if (sdp is Map) await handleAnswer(Map<String, dynamic>.from(sdp));
        return true;
      case 'ice':
      case 'candidate':
        final candidate = message['candidate'];
        if (candidate is Map) {
          await handleRemoteIce(Map<String, dynamic>.from(candidate));
        }
        return true;
      case 'peer_left':
        await close();
        return true;
      default:
        return false;
    }
  }

  /// Target side: apply the remote offer and answer it.
  Future<void> handleOffer(Map<String, dynamic> sdp) async {
    final pc = _pc;
    if (pc == null) {
      _pendingOffer = sdp;
      return;
    }
    if (_localStream == null) {
      // No screen stream yet - remember it and answer once capture is ready.
      _pendingOffer = sdp;
      _log('收到 offer，等待屏幕采集就绪…');
      return;
    }
    if (_remoteDescriptionSet) return;

    await pc.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );
    _remoteDescriptionSet = true;
    await _flushCandidates();

    // Now — and only now — attach the captured track. The offer's recvonly
    // m-line exists at this point, so addTrack reuses it and the answer turns
    // it into sendonly in the same round.
    final stream = _localStream;
    if (stream != null) await _attachTracks(pc, stream);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    signaling.sendAnswer(peerId, <String, dynamic>{'type': answer.type, 'sdp': answer.sdp});
    _log('已发送 answer');
    _setPhase(SessionPhase.connecting);
  }

  Future<void> handleAnswer(Map<String, dynamic> sdp) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );
    _remoteDescriptionSet = true;
    await _flushCandidates();
    _log('已应用 answer');
  }

  Future<void> handleRemoteIce(Map<String, dynamic> candidate) async {
    final pc = _pc;
    if (pc == null) return;
    final parsed = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (!_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(parsed);
      return;
    }
    try {
      await pc.addCandidate(parsed);
    } catch (e) {
      _log('添加 ICE 失败: $e');
    }
  }

  Future<void> _flushCandidates() async {
    final pc = _pc;
    if (pc == null) return;
    final queued = List<RTCIceCandidate>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in queued) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        _log('添加 ICE 失败: $e');
      }
    }
  }

  /// Refresh the HUD numbers. Safe to call on a timer.
  Future<SessionStats> pollStats() async {
    final pc = _pc;
    if (pc == null || _disposed) return _stats;

    List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } catch (_) {
      return _stats;
    }

    final byId = <String, StatsReport>{for (final r in reports) r.id: r};

    int? width;
    int? height;
    int? fps;
    int? bytes;
    double? rttMs;
    String? codecId;

    for (final report in reports) {
      final v = report.values;
      final kind = v['kind'] ?? v['mediaType'];
      final isInbound = report.type == 'inbound-rtp';
      final isOutbound = report.type == 'outbound-rtp';

      if ((isInbound || isOutbound) && kind == 'video') {
        width = _asInt(v['frameWidth']) ?? width;
        height = _asInt(v['frameHeight']) ?? height;
        final framesPerSecond = _asDouble(v['framesPerSecond']);
        if (framesPerSecond != null) fps = framesPerSecond.round();
        bytes = _asInt(isInbound ? v['bytesReceived'] : v['bytesSent']) ?? bytes;
        codecId = (v['codecId'] as String?) ?? codecId;
      }

      if (report.type == 'remote-inbound-rtp' && kind == 'video') {
        final rtt = _asDouble(v['roundTripTime']);
        if (rtt != null) rttMs = rtt * 1000;
      }

      if (report.type == 'candidate-pair') {
        final selected = v['selected'] == true || v['state'] == 'succeeded';
        if (selected) {
          final rtt = _asDouble(v['currentRoundTripTime']);
          if (rtt != null) rttMs ??= rtt * 1000;
        }
      }
    }

    String? codec;
    if (codecId != null) {
      final report = byId[codecId];
      codec = report?.values['mimeType'] as String?;
    }

    double? kbps;
    final now = DateTime.now();
    if (bytes != null && _lastBytes > 0 && bytes >= _lastBytes) {
      final seconds = now.difference(_lastStatsAt).inMilliseconds / 1000.0;
      if (seconds > 0.2) kbps = (bytes - _lastBytes) * 8 / 1000.0 / seconds;
    }
    if (bytes != null) {
      _lastBytes = bytes;
      _lastStatsAt = now;
    }

    _stats = SessionStats(
      width: width,
      height: height,
      fps: fps,
      kbps: kbps,
      rttMs: rttMs,
      codec: codec,
    );
    return _stats;
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _setPhase(SessionPhase.closed);
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    await input.dispose();

    // Stop the capture so the OS/browser screen-sharing indicator goes away.
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
    }

    try {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      await localRenderer.dispose();
      await remoteRenderer.dispose();
    } catch (_) {}
    _log('会话已关闭');
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) return int.tryParse(v);
    if (v is num) return v.round();
    return null;
  }

  static double? _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
