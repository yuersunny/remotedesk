import '../input_event.dart' as proto;

/// One keypress on the remote keyboard: which key, and whether Shift is held.
class HidStroke {
  const HidStroke(this.key, {this.shift = false});

  final proto.InputKey key;
  final bool shift;

  @override
  String toString() => 'HidStroke(${key.code}${shift ? '+shift' : ''})';

  @override
  bool operator ==(Object other) =>
      other is HidStroke && other.key == key && other.shift == shift;

  @override
  int get hashCode => Object.hash(key, shift);
}

/// Unshifted and shifted spellings of the printable keys we can type.
///
/// The wire protocol carries HID *keys*, not text: there is no event that
/// injects an arbitrary unicode string, so Chinese/Japanese/emoji cannot be
/// typed through this channel at all. Mapping characters back to keys is the
/// honest approach — it types exactly what a real keyboard would type, on the
/// remote machine's own layout.
const Map<String, proto.InputKey> _plain = <String, proto.InputKey>{
  ' ': proto.InputKey.space,
  '-': proto.InputKey.minus,
  '=': proto.InputKey.equal,
  '[': proto.InputKey.bracketLeft,
  ']': proto.InputKey.bracketRight,
  '\\': proto.InputKey.backslash,
  ';': proto.InputKey.semicolon,
  "'": proto.InputKey.quote,
  '`': proto.InputKey.backquote,
  ',': proto.InputKey.comma,
  '.': proto.InputKey.period,
  '/': proto.InputKey.slash,
  '\n': proto.InputKey.enter,
  '\t': proto.InputKey.tab,
};

const Map<String, proto.InputKey> _shifted = <String, proto.InputKey>{
  '_': proto.InputKey.minus,
  '+': proto.InputKey.equal,
  '{': proto.InputKey.bracketLeft,
  '}': proto.InputKey.bracketRight,
  '|': proto.InputKey.backslash,
  ':': proto.InputKey.semicolon,
  '"': proto.InputKey.quote,
  '~': proto.InputKey.backquote,
  '<': proto.InputKey.comma,
  '>': proto.InputKey.period,
  '?': proto.InputKey.slash,
  '!': proto.InputKey.digit1,
  '@': proto.InputKey.digit2,
  '#': proto.InputKey.digit3,
  r'$': proto.InputKey.digit4,
  '%': proto.InputKey.digit5,
  '^': proto.InputKey.digit6,
  '&': proto.InputKey.digit7,
  '*': proto.InputKey.digit8,
  '(': proto.InputKey.digit9,
  ')': proto.InputKey.digit0,
};

/// The keypress that produces [ch], or null when the channel cannot type it.
HidStroke? strokeFor(String ch) {
  if (ch.isEmpty) return null;

  final plain = _plain[ch];
  if (plain != null) return HidStroke(plain);

  final shifted = _shifted[ch];
  if (shifted != null) return HidStroke(shifted, shift: true);

  if (ch.length == 1) {
    final unit = ch.toUpperCase().codeUnitAt(0);
    if (unit >= 0x41 && unit <= 0x5A) {
      return HidStroke(proto.InputKey.fromCode('Key${ch.toUpperCase()}')!,
          shift: ch != ch.toLowerCase());
    }
    if (unit >= 0x30 && unit <= 0x39) {
      return HidStroke(proto.InputKey.fromCode('Digit$ch')!);
    }
  }
  return null;
}

/// Type into a text field and get keystrokes out, without ever losing count.
///
/// A soft keyboard reports whole *strings* (autocorrect, IME composition,
/// pasting), while the remote machine needs individual key transitions. This
/// turns the difference between two snapshots of the field into the exact
/// keypresses that would have produced it: common prefix kept, the rest
/// backspaced away, then retyped.
///
/// [accept] returns the text that should be shown in the field — characters the
/// channel cannot type are dropped, so the field never displays something that
/// did not reach the other machine.
class HidTextBridge {
  HidTextBridge(this.onStroke);

  final void Function(HidStroke stroke) onStroke;

  String _sent = '';

  /// Characters that were dropped because they cannot be typed remotely.
  int dropped = 0;

  String accept(String raw) {
    final kept = StringBuffer();
    for (final rune in raw.runes) {
      final ch = String.fromCharCode(rune);
      if (strokeFor(ch) == null) {
        dropped++;
        continue;
      }
      kept.write(ch);
    }
    final clean = kept.toString();
    if (clean == _sent) return clean;

    final before = _sent.runes.toList(growable: false);
    final after = clean.runes.toList(growable: false);
    var prefix = 0;
    while (prefix < before.length &&
        prefix < after.length &&
        before[prefix] == after[prefix]) {
      prefix++;
    }
    for (var i = prefix; i < before.length; i++) {
      onStroke(const HidStroke(proto.InputKey.backspace));
    }
    for (var i = prefix; i < after.length; i++) {
      final stroke = strokeFor(String.fromCharCode(after[i]));
      if (stroke != null) onStroke(stroke);
    }
    _sent = clean;
    return clean;
  }

  void clear() {
    _sent = '';
    dropped = 0;
  }
}
