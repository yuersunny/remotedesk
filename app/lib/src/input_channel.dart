import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'input_event.dart';

/// Wraps the `input` DataChannel that carries M2 control events.
///
/// Both ends own one of these; who created the channel is the only asymmetry —
/// the controller calls [RTCSession.ensureInputChannel] before its offer, the
/// target receives the channel through `onDataChannel` and hands it here.
///
/// Three behaviours are load-bearing:
///
/// * **Messages are queued until the channel opens.** The controller can start
///   capturing input the moment the video appears, which is usually *before*
///   SCTP finishes connecting. Dropping those frames would make the first
///   click after connect a no-op.
/// * **The queue is bounded.** A dead channel must not grow the heap; once
///   [maxPending] is reached the oldest frames are discarded, because a stale
///   mouse position is worthless anyway.
/// * **Decode failures are silent.** A future peer may send event types this
///   build does not know; that is normal, not an error worth logging 60×/s.
class InputChannel {
  InputChannel({
    this.onLog,
    this.onOpen,
    this.onStateChanged,
    this.maxPending = 120,
  });

  /// Diagnostics sink, wired to the session log panel.
  final void Function(String message)? onLog;

  /// Fired once when the channel becomes usable. The target uses this to send
  /// its [HelloEvent].
  final void Function()? onOpen;

  final void Function(bool open)? onStateChanged;

  /// Hard cap on queued frames while the channel is still connecting.
  final int maxPending;

  RTCDataChannel? _dc;
  final List<String> _pending = <String>[];
  final StreamController<InputEvent> _events =
      StreamController<InputEvent>.broadcast();
  final Completer<void> _opened = Completer<void>();
  bool _open = false;

  /// Decoded inbound events. Broadcast: the owner may listen late.
  Stream<InputEvent> get events => _events.stream;

  /// Completes the first time the channel opens.
  ///
  /// The target awaits this to send its `hello`; using a future instead of the
  /// [onOpen] callback means a late subscriber still wakes up, so a handshake
  /// sent before the channel connects cannot be missed.
  Future<void> get opened => _opened.future;

  bool get isOpen => _open;

  /// True once a channel object exists (open or not).
  bool get hasChannel => _dc != null;

  /// Number of frames waiting for the channel to open. Exposed for tests.
  int get pendingCount => _pending.length;

  /// Attach to a freshly created or received channel. Safe to call once.
  void attach(RTCDataChannel channel) {
    if (_dc != null) return;
    _dc = channel;
    channel.onMessage = _handleMessage;
    channel.onDataChannelState = (state) {
      final open = state == RTCDataChannelState.RTCDataChannelOpen;
      _setOpen(open);
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        onLog?.call('输入通道已关闭');
      }
    };
    // The channel may already be open by the time we attach.
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _setOpen(true);
    }
  }

  void _setOpen(bool open) {
    if (_open == open) return;
    _open = open;
    onStateChanged?.call(open);
    if (!open) return;

    onLog?.call('输入通道已就绪');
    final queued = List<String>.from(_pending);
    _pending.clear();
    for (final frame in queued) {
      _rawSend(frame);
    }
    if (queued.isNotEmpty) {
      onLog?.call('补发了 ${queued.length} 条排队事件');
    }
    onOpen?.call();
    if (!_opened.isCompleted) _opened.complete();
  }

  /// Send one event, or queue it if the channel is not ready yet.
  void send(InputEvent event) {
    // Pointer moves dominate the traffic; the compact encoder avoids building
    // an intermediate map 60 times a second.
    final frame = event is PointerMove ? event.encodeCompact() : event.encode();
    if (!_open) {
      if (_pending.length >= maxPending) _pending.removeAt(0);
      _pending.add(frame);
      return;
    }
    _rawSend(frame);
  }

  void _rawSend(String frame) {
    final dc = _dc;
    if (dc == null) return;
    try {
      dc.send(RTCDataChannelMessage(frame));
    } catch (e) {
      // A closing channel throws; nothing to do but note it once.
      onLog?.call('发送输入事件失败: $e');
    }
  }

  void _handleMessage(RTCDataChannelMessage message) {
    if (message.isBinary || _events.isClosed) return;
    final event = InputEvent.decode(message.text);
    if (event != null) _events.add(event);
  }

  Future<void> dispose() async {
    final dc = _dc;
    _dc = null;
    _open = false;
    _pending.clear();
    // Release anyone awaiting `opened`, so a handshake that never got a chance
    // to run does not leak a pending future.
    if (!_opened.isCompleted) _opened.complete();
    if (dc != null) {
      try {
        dc.onMessage = null;
        dc.onDataChannelState = null;
        await dc.close();
      } catch (_) {
        // already torn down with the peer connection
      }
    }
    await _events.close();
  }
}
