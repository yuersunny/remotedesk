import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show VoidCallback;

/// Where the remote picture sits on screen, and how far the user has zoomed in.
///
/// The stream is laid out `contain` inside [viewport]: [baseRect] is that
/// fitted rectangle, and [scale] / [pan] are the user's own magnification on
/// top of it. Every touch has to travel back through this transform before it
/// becomes a remote coordinate — a click that lands 200 px off because the
/// picture was zoomed is the single most confusing failure a remote-control
/// app can have, so the maths lives here, in one place, and is unit-tested.
class RemoteViewport {
  RemoteViewport();

  /// Size of the widget hosting the picture, in logical pixels.
  Size viewport = Size.zero;

  /// Natural size of the decoded frame (or the target's reported screen size
  /// before the first frame arrives).
  Size picture = const Size(16, 9);

  double scale = 1;
  Offset pan = Offset.zero;

  static const double minScale = 1;
  static const double maxScale = 6;

  Offset get _centre => Offset(viewport.width / 2, viewport.height / 2);

  /// The `contain` fit of [picture] inside [viewport], before user zoom.
  Rect get baseRect {
    if (viewport.isEmpty || picture.width <= 0 || picture.height <= 0) {
      return Rect.zero;
    }
    final factor = math.min(
      viewport.width / picture.width,
      viewport.height / picture.height,
    );
    final w = picture.width * factor;
    final h = picture.height * factor;
    return Rect.fromLTWH(
      (viewport.width - w) / 2,
      (viewport.height - h) / 2,
      w,
      h,
    );
  }

  bool get isZoomed => scale > 1.001;

  /// Where the picture rectangle actually is, after zoom and pan.
  Rect get displayRect {
    final b = baseRect;
    final c = _centre;
    return Rect.fromLTRB(
      c.dx + (b.left - c.dx) * scale + pan.dx,
      c.dy + (b.top - c.dy) * scale + pan.dy,
      c.dx + (b.right - c.dx) * scale + pan.dx,
      c.dy + (b.bottom - c.dy) * scale + pan.dy,
    );
  }

  /// Screen point -> point in the un-zoomed fitted picture.
  Offset _toBase(Offset local) => _centre + (local - pan - _centre) / scale;

  /// Normalised picture coordinate -> screen point (used to draw the cursor).
  Offset toLocal(Offset normalised) {
    final b = baseRect;
    final base = Offset(
      b.left + normalised.dx * b.width,
      b.top + normalised.dy * b.height,
    );
    return _centre + (base - _centre) * scale + pan;
  }

  /// Screen point -> `[0, 1]` pair the wire format carries.
  ///
  /// Always clamped: a drag that leaves the picture should pin the remote
  /// cursor to the edge instead of freezing. Callers that must *not* pin (a
  /// hover over a letterbox bar) ask [containsLocal] first.
  Offset? toNormalised(Offset local) {
    final b = baseRect;
    if (b.isEmpty) return null;
    final base = _toBase(local);
    return Offset(
      ((base.dx - b.left) / b.width).clamp(0.0, 1.0),
      ((base.dy - b.top) / b.height).clamp(0.0, 1.0),
    );
  }

  /// True when [local] lands on a real remote pixel.
  bool containsLocal(Offset local) {
    final b = baseRect;
    if (b.isEmpty) return false;
    return b.contains(_toBase(local));
  }

  /// Zoom by [factor] while keeping the picture point under [focal] still.
  void zoomAround(Offset focal, double factor) {
    final next = (scale * factor).clamp(minScale, maxScale);
    if ((next - scale).abs() < 0.001) return;
    final c = _centre;
    pan = focal - c - (focal - pan - c) * (next / scale);
    scale = next;
    if (scale <= minScale + 0.001) {
      // Snapping back to 1 avoids a permanently half-pixel-shifted picture
      // after a pinch that only just crossed the threshold.
      scale = minScale;
      pan = Offset.zero;
      return;
    }
    _clampPan();
  }

  void panBy(Offset delta) {
    pan += delta;
    _clampPan();
  }

  void reset() {
    scale = minScale;
    pan = Offset.zero;
  }

  /// Keeps the picture covering the viewport (or centred when it is smaller).
  void _clampPan() {
    final b = baseRect;
    final c = _centre;
    final left = c.dx + (b.left - c.dx) * scale;
    final right = c.dx + (b.right - c.dx) * scale;
    final top = c.dy + (b.top - c.dy) * scale;
    final bottom = c.dy + (b.bottom - c.dy) * scale;
    pan = Offset(
      _axis(left, right, viewport.width, pan.dx),
      _axis(top, bottom, viewport.height, pan.dy),
    );
  }

  /// Keeps the picture inside the viewport on one axis.
  ///
  /// Both cases fall out of the same clamp: when the picture is larger than the
  /// viewport both edges cannot be inside at once, so the nearer constraint
  /// wins and the picture ends up covering the viewport; when it is smaller,
  /// both constraints can hold and the user may place it anywhere inside —
  /// which is what keeps a pinch anchored under the fingers instead of snapping
  /// to the centre.
  static double _axis(double start, double end, double view, double current) {
    final near = -start;
    final far = view - end;
    return current.clamp(math.min(near, far), math.max(near, far));
  }
}

/// Turns raw touch pointers into remote mouse input — and pinch into local zoom.
///
/// The gesture model is the one people already know from AnyDesk/TeamViewer:
///
/// * one finger **taps** = left click at that point;
/// * one finger **drags** = press, move, release (a real drag on the desktop);
/// * one finger held still = right click (the widget owns the 600 ms timer and
///   calls [fireLongPress]);
/// * two fingers **drag** = scroll wheel (or pan the picture when zoomed);
/// * two fingers **pinch** = zoom the picture, never the remote;
/// * two fingers **tap** = right click.
///
/// The press is deliberately delayed until the finger moves past [slop]: firing
/// a click on touch-down would leave a stray click behind every scroll, because
/// the second finger always arrives milliseconds after the first.
class TouchInput {
  TouchInput({
    required this.viewport,
    required this.onMove,
    required this.onButton,
    required this.onWheel,
    required this.onViewChanged,
    this.onClickFeedback,
  });

  final RemoteViewport viewport;

  /// Hover move, normalised to the picture.
  final void Function(Offset normalised) onMove;

  /// Button transition at a normalised position.
  final void Function(int button, bool pressed, Offset normalised) onButton;

  /// Scroll deltas in the wire's `WHEEL_DELTA` unit (120 per notch).
  final void Function(double dx, double dy) onWheel;

  /// The local zoom/pan changed; repaint.
  final VoidCallback onViewChanged;

  /// A click landed at [local] — the UI draws its ripple here so the user sees
  /// something before the network can answer.
  final void Function(Offset local)? onClickFeedback;

  /// When false, touches still zoom and pan but send nothing to the peer.
  bool enabled = true;

  /// Movement that separates a tap from a drag.
  static const double _slop = 8;

  /// A two-finger drag of 60 logical pixels is one wheel notch.
  static const double _wheelPerPixel = 2;

  /// How far the two fingers must spread before this counts as a pinch.
  ///
  /// Above the jitter of two fingers scrolling together (which is a handful of
  /// pixels per event), below a deliberate pinch.
  static const double _spanSlop = 26;

  final Map<int, Offset> _points = <int, Offset>{};
  Offset? _downLocal;
  bool _pressed = false;
  bool _consumed = false;
  bool _multi = false;
  _MultiMode _mode = _MultiMode.none;
  Offset _lastMid = Offset.zero;
  Offset _startMid = Offset.zero;
  double _lastSpan = 0;
  double _startSpan = 0;

  /// True while a single finger is down, has not moved and has not fired yet:
  /// i.e. a long press is still possible.
  bool get awaitingLongPress =>
      _points.length == 1 && !_pressed && !_consumed && !_multi;

  /// Where a pending long press would click.
  Offset? get pendingLocal => _downLocal;

  bool get isPressed => _pressed;

  void pointerDown(int pointer, Offset local) {
    _points[pointer] = local;
    if (_points.length == 1) {
      _downLocal = local;
      _pressed = false;
      _consumed = false;
      _multi = false;
      _mode = _MultiMode.none;
      _hover(local);
      return;
    }
    // A second finger only starts a multi-touch gesture when the first one has
    // not begun dragging yet. Once a drag is in progress the extra finger is
    // ignored: silently converting a drag into a scroll loses the button press
    // the remote machine is still holding.
    if (_points.length == 2 && !_pressed) {
      _multi = true;
      _mode = _MultiMode.none;
      _lastMid = _midpoint();
      _startMid = _lastMid;
      _lastSpan = _span();
      _startSpan = _lastSpan;
    }
  }

  void pointerMove(int pointer, Offset local) {
    if (!_points.containsKey(pointer)) return;
    _points[pointer] = local;
    if (_multi) {
      _handleMulti();
      return;
    }
    if (_points.length != 1) return;
    if (_pressed) {
      _dragTo(local);
      return;
    }
    final down = _downLocal;
    if (down != null && (local - down).distance > _slop) {
      _pressAt(local);
    }
  }

  void pointerUp(int pointer, Offset local) {
    if (!_points.containsKey(pointer)) return;
    _points.remove(pointer);
    if (_multi) {
      if (_points.isEmpty) _finishMulti();
      return;
    }
    if (_pressed) {
      _dragTo(local);
      final n = viewport.toNormalised(local);
      if (n != null) onButton(0, false, n);
      _pressed = false;
      _downLocal = null;
      return;
    }
    if (_consumed) {
      _consumed = false;
      _downLocal = null;
      return;
    }
    // A tap: hover first so the remote cursor is where the click happens.
    _tapAt(local);
    _downLocal = null;
  }

  void pointerCancel(int pointer) {
    _points.remove(pointer);
    if (_pressed) {
      final n = _downLocal == null ? null : viewport.toNormalised(_downLocal!);
      if (n != null) onButton(0, false, n);
      _pressed = false;
    }
    if (_points.isEmpty) {
      _multi = false;
      _downLocal = null;
      _consumed = false;
    }
  }

  /// The widget's long-press timer fired: right click where the finger is.
  void fireLongPress() {
    final local = _downLocal;
    if (local == null || !awaitingLongPress) return;
    final n = viewport.toNormalised(local);
    if (n == null) return;
    _consumed = true;
    onClickFeedback?.call(local);
    onButton(2, true, n);
    onButton(2, false, n);
  }

  void reset() {
    if (_pressed && _downLocal != null) {
      final n = viewport.toNormalised(_downLocal!);
      if (n != null) onButton(0, false, n);
    }
    _points.clear();
    _pressed = false;
    _consumed = false;
    _multi = false;
    _mode = _MultiMode.none;
    _downLocal = null;
  }

  void _hover(Offset local) {
    if (!enabled) return;
    final n = viewport.toNormalised(local);
    if (n == null || !viewport.containsLocal(local)) return;
    onMove(n);
  }

  void _pressAt(Offset local) {
    if (!viewport.containsLocal(local)) return;
    final n = viewport.toNormalised(local);
    if (n == null) return;
    _pressed = true;
    if (!enabled) return;
    onClickFeedback?.call(local);
    onMove(n);
    onButton(0, true, n);
  }

  void _dragTo(Offset local) {
    if (!enabled) return;
    final n = viewport.toNormalised(local);
    if (n == null) return;
    onMove(n);
  }

  void _tapAt(Offset local) {
    if (!viewport.containsLocal(local)) return;
    final n = viewport.toNormalised(local);
    if (n == null) return;
    if (!enabled) return;
    _hover(local);
    onClickFeedback?.call(local);
    onButton(0, true, n);
    onButton(0, false, n);
  }

  void _finishMulti() {
    final isTap = _mode == _MultiMode.none;
    final at = _downLocal;
    _multi = false;
    _downLocal = null;
    if (!isTap || at == null) return;
    final n = viewport.toNormalised(at);
    if (n == null || !enabled) return;
    onClickFeedback?.call(at);
    onButton(2, true, n);
    onButton(2, false, n);
  }

  void _handleMulti() {
    final mid = _midpoint();
    final span = _span();
    if (span <= 0 || _lastSpan <= 0) {
      _lastMid = mid;
      _lastSpan = span;
      return;
    }
    // Decide once per gesture what this is: a pinch changes the distance
    // between the fingers, a scroll keeps it. Deciding frame by frame would
    // turn every slightly unparallel two-finger scroll into an accidental zoom —
    // two fingers never travel perfectly in lockstep.
    if (_mode == _MultiMode.none) {
      // Two fingers never travel in perfect lockstep: during a plain scroll the
      // distance between them wobbles by whatever one finger moved before the
      // other reported. The threshold has to sit above that wobble, or every
      // scroll degrades into an accidental zoom.
      if ((span - _startSpan).abs() > _spanSlop) {
        _mode = _MultiMode.zoom;
      } else if ((mid - _startMid).distance > 8) {
        _mode = _MultiMode.scroll;
      }
    }

    switch (_mode) {
      case _MultiMode.zoom:
        final ratio = span / _lastSpan;
        if ((ratio - 1).abs() > 0.002) {
          viewport.zoomAround(mid, ratio);
          onViewChanged();
        }
        break;
      case _MultiMode.scroll:
        final drift = mid - _lastMid;
        if (drift.distance > 0.5) {
          if (viewport.isZoomed) {
            // Zoomed in: two fingers move the picture itself, because a scroll
            // wheel is unreachable through a magnified view anyway.
            viewport.panBy(drift);
            onViewChanged();
          } else if (enabled) {
            // Positive wire dy scrolls up; dragging content down reveals what
            // is above it, which is exactly that.
            onWheel(-drift.dx * _wheelPerPixel, drift.dy * _wheelPerPixel);
          }
        }
        break;
      case _MultiMode.none:
        break;
    }
    _lastMid = mid;
    _lastSpan = span;
  }

  Offset _midpoint() {
    if (_points.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final p in _points.values) {
      sum += p;
    }
    return sum / _points.length.toDouble();
  }

  double _span() {
    if (_points.length < 2) return 0;
    final values = _points.values.toList(growable: false);
    return (values[0] - values[1]).distance;
  }
}

/// What a two-finger gesture turned out to be. Decided once, on the first
/// movement past a threshold, and then held for the rest of the gesture.
enum _MultiMode { none, scroll, zoom }
