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

  /// Second, disposable channel for pointer movement only.
  ///
  /// Movement is unique among input events: a stale sample is worthless, and
  /// there are dozens of them per second. Putting them on the reliable channel
  /// means one lost SCTP packet stalls every later move until it is retransmitted
  /// — over a lossy link (Wi-Fi, a TURN relay) that turns into a cursor which
  /// lags further behind the more you move. This one is unordered with a 30 ms
  /// retransmit window: a dropped move is simply dropped.
  ///
  /// Buttons, wheel and keys must never move here — a lost key-up leaves a
  /// modifier stuck down on the remote machine.
  RTCDataChannel? _moveDc;
  bool _moveOpen = false;
  Timer? _moveTicker;
  final MoveCoalescer _moves = MoveCoalescer();

  /// Movement is coalesced to one sample per tick: intermediate positions carry
  /// no information the target can use, they only queue up.
  static const Duration _moveTick = Duration(milliseconds: 16);

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

  /// Attach the movement channel (see [_moveDc]). Safe to call once.
  ///
  /// Until this channel opens, moves keep using the reliable channel, so an
  /// older peer that ignores the extra label still gets a working — merely
  /// laggier — pointer. No timeout or probing is needed for that fallback: the
  /// fast path is simply gated on [_moveOpen].
  void attachMove(RTCDataChannel channel) {
    if (_moveDc != null) return;
    _moveDc = channel;
    channel.onDataChannelState = (state) {
      final open = state == RTCDataChannelState.RTCDataChannelOpen;
      if (open == _moveOpen) return;
      _moveOpen = open;
      if (open) {
        onLog?.call('移动通道已就绪（无序传输）');
        _moveTicker ??= Timer.periodic(_moveTick, (_) => _flushMove());
      } else {
        _moveTicker?.cancel();
        _moveTicker = null;
        _moves.clear();
        onLog?.call('移动通道已关闭，回退到可靠通道');
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _moveOpen = true;
      _moveTicker ??= Timer.periodic(_moveTick, (_) => _flushMove());
    }
  }

  /// Send at most one coalesced move per tick, always the newest one.
  void _flushMove() {
    final move = _moves.take();
    if (move == null) return;
    final dc = _moveDc;
    if (dc == null || !_moveOpen) return;
    try {
      dc.send(RTCDataChannelMessage(move.encodeCompact()));
    } catch (_) {
      // Dropping a move is harmless; the next tick carries a fresher position.
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
    // Movement takes the fast path as soon as it is available: overwrite the
    // pending sample and let the ticker pick the newest one up. Nothing is
    // queued here, so a burst of 200 mouse events cannot build a backlog.
    if (event is PointerMove && _moveOpen) {
      _moves.submit(event);
      return;
    }
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

  Future<void> dispose() async {    _moveTicker?.cancel();
    _moveTicker = null;
    _moves.clear();
    _moveOpen = false;
    final moveDc = _moveDc;
    _moveDc = null;

    final dc = _dc;
    _dc = null;
    _open = false;
    _pending.clear();
    // Release anyone awaiting `opened`, so a handshake that never got a chance
    // to run does not leak a pending future.
    if (!_opened.isCompleted) _opened.complete();
    if (moveDc != null) {
      try {
        moveDc.onDataChannelState = null;
        await moveDc.close();
      } catch (_) {}
    }
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

/// Keeps only the newest pointer sample between ticks.
///
/// Plain "send every event" is what makes a remote cursor fall behind: 120
/// events per second enter SCTP faster than a congested link drains them, and
/// every sample queued in front of the newest one is already obsolete. Keeping
/// a single slot means the send rate is capped by the tick, not by how fast the
/// user moves the mouse.
///
/// Separated from [InputChannel] so the policy can be tested without a real
/// data channel.
class MoveCoalescer {
  PointerMove? _pending;

  /// Samples replaced before being sent — the number that proves the coalescing
  /// actually happened, exposed for diagnostics and tests.
  int dropped = 0;

  bool get hasPending => _pending != null;

  /// Store a sample, replacing any that has not been taken yet.
  /// Returns true when an earlier sample was discarded.
  bool submit(PointerMove move) {
    final replaced = _pending != null;
    _pending = move;
    if (replaced) dropped++;
    return replaced;
  }

  /// Take the newest sample and clear the slot.
  PointerMove? take() {
    final move = _pending;
    _pending = null;
    return move;
  }

  void clear() => _pending = null;
}
