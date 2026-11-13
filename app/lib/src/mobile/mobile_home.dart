import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input_event.dart' as proto;
import '../pairing_code.dart';
import '../peer_info.dart';
import '../reach.dart';
import '../rtc_session.dart';
import 'mobile_session.dart';

/// Everything the phone UI needs from the app state, so the screen can be built
/// (and tested) without touching signaling, discovery or WebRTC.
abstract interface class MobileHost {
  List<PeerInfo> get peers;
  bool get scanning;
  RtcSession? get session;
  SessionPhase get phase;
  SessionStats get stats;
  proto.HelloEvent? get remoteHello;
  bool get signalingUp;
  bool get busy;
  String get selfId;
  List<String> get logLines;
  bool get controlEnabled;
  bool get clipboardEnabled;
  String get version;

  Future<void> rescan();
  Future<void> connectPeer(PeerInfo peer);
  Future<void> connectByCode(String raw);
  Future<void> connectManual(String target);
  Future<void> hangUp();
  Future<void> pushClipboard();
  void setControlEnabled(bool on);
  void setClipboardEnabled(bool on);
}

/// Home screen of the phone build: pick a computer, or paste a pairing code.
///
/// The layout is the phone version of the desktop control panel, reduced to
/// what a thumb can reach: one list that connects on tap, one field for the
/// case discovery cannot cover, and everything diagnostic folded away.
class MobileHomePage extends StatefulWidget {
  const MobileHomePage({super.key, required this.host});

  final MobileHost host;

  @override
  State<MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends State<MobileHomePage> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _manual = TextEditingController();
  bool _manualOpen = false;
  bool _logsOpen = false;

  @override
  void dispose() {
    _code.dispose();
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final session = host.session;
    if (session != null) {
      return MobileSessionView(
        session: session,
        phase: host.phase,
        stats: host.stats,
        remoteHello: host.remoteHello,
        controlEnabled: host.controlEnabled,
        onControlChanged: host.setControlEnabled,
        clipboardEnabled: host.clipboardEnabled,
        onClipboardChanged: host.setClipboardEnabled,
        onPushClipboard: host.pushClipboard,
        onHangUp: host.hangUp,
      );
    }

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteDesk'),
        actions: [
          _StatusPill(online: host.signalingUp),
          IconButton(
            onPressed: host.scanning || host.busy ? null : host.rescan,
            icon: host.scanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
            tooltip: '重新查找',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: host.rescan,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
          children: [
            Text(
              '连到哪台电脑？',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              host.scanning && host.peers.isEmpty
                  ? '正在找…'
                  // The phone has no tailnet CLI, so it genuinely cannot list
                  // machines on a tailnet — promising "同一个 Tailscale 网络里
                  // 会自动出现" was simply wrong and made people wait for a row
                  // that could never appear.
                  : '同一 Wi-Fi 下的电脑会自动出现在下面。'
                      '人在外面：手机先开 Tailscale（和电脑同一账号），再用配对码。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline, height: 1.4),
            ),
            const SizedBox(height: 12),
            if (host.peers.isEmpty)
              _emptyCard(theme)
            else
              for (final peer in host.peers) ...[
                _PeerTile(
                  peer: peer,
                  busy: host.busy,
                  onTap: () => host.connectPeer(peer),
                ),
                const SizedBox(height: 8),
              ],
            const SizedBox(height: 6),
            _codeCard(theme),
            const SizedBox(height: 10),
            _selfCard(theme),
            const SizedBox(height: 10),
            _logCard(theme),
            const SizedBox(height: 16),
            Center(
              child: Text(
                '手机端 v${host.version} · 只能当主控，不共享本机屏幕',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(Icons.computer_outlined, size: 38, color: theme.colorScheme.outline),
          const SizedBox(height: 10),
          Text('还没找到电脑', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '先在电脑上打开 RemoteDesk（Mac / Windows 版），\n'
            '让它停在主界面，手机这边就会自动出现。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline, height: 1.5),
          ),
          const SizedBox(height: 14),
          // The phone cannot discover machines on a tailnet by itself, so the
          // "I am not at home" case needs its own explanation — otherwise the
          // empty list reads as "the app is broken" rather than "you are on the
          // wrong network".
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.22),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.public,
                        size: 15, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      '人在外面（用手机流量）',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  '1. 手机装 Tailscale，登录和电脑同一个账号\n'
                  '2. 让电脑上那行「配对码」发到你手机上（微信也行）\n'
                  '3. 粘到下面「用配对码连」的框里，点连接',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The three-step "outside the house" guide lives in the empty-state card.
  /// That is exactly where it stops being visible once the phone has ever seen
  /// a computer before: the remembered rows make `peers` non-empty, so someone
  /// standing on 5G with a pasted code sees no explanation at all. This notice
  /// sits with the code field instead and is driven by the address they pasted.
  Widget? _addressNotice(ThemeData theme) {
    final parsed = PairingCode.parse(_code.text);
    if (parsed == null || parsed.host.isEmpty) return null;

    final host = parsed.host;
    final kind = classifyAddress(host);
    late final String title;
    late final String body;
    late final bool alert;

    if (kind == AddressKind.tailnet) {
      title = '这行是 Tailscale 地址（100.x）';
      body = '手机也要装 Tailscale、登录和电脑同一个账号，并把开关打开。'
          '人在外面只粘配对码不够：手机没进这个网络，100.x 是拨不通的。'
          '连不上先用手机浏览器打开 http://$host:${parsed.port}/health 试一下。';
      alert = false;
    } else if (kind == AddressKind.lan) {
      title = '这行是内网地址，外面用不了';
      body = '192.168 / 10 / 172 开头的地址只在同一个 Wi-Fi 里有效。'
          '让那台电脑装 Tailscale 并登录，再重新复制配对码，地址会变成 100.x。';
      alert = true;
    } else if (kind == AddressKind.publicIp) {
      title = '这行是公网地址';
      body = '要那台电脑的路由器把 8787 转发进来、防火墙也放行，手机才连得上。'
          '没做端口映射就改走 Tailscale。';
      alert = true;
    } else {
      title = '这行是电脑名，不是 IP';
      body = '手机在外面通常解析不到电脑名。让对方重新复制一次带 IP 的配对码。';
      alert = true;
    }

    final color = alert
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, bottom: 2),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeCard(ThemeData theme) {
    final notice = _addressNotice(theme);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('用配对码连', style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            '电脑「这台电脑」卡片上那行字，粘过来就能连。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          ?notice,
          const SizedBox(height: 10),
          TextField(
            controller: _code,
            // The address notice is derived from what was pasted, so typing or
            // editing the field has to rebuild it too — not just the paste icon.
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'RDSK1 100.86.1.5:8787 mac-mini 密码',
              hintStyle: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
                fontFamily: 'monospace',
              ),
              suffixIcon: IconButton(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final text = data?.text;
                  if (text == null || text.isEmpty) return;
                  setState(() => _code.text = text);
                },
                icon: const Icon(Icons.content_paste, size: 18),
                tooltip: '粘贴',
              ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onSubmitted: (value) {
              if (!widget.host.busy) widget.host.connectByCode(value);
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.host.busy
                      ? null
                      : () => widget.host.connectByCode(_code.text),
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(widget.host.busy ? '正在连接…' : '连接'),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => setState(() => _manualOpen = !_manualOpen),
                child: Text(_manualOpen ? '收起' : '手动填地址'),
              ),
            ],
          ),
          // A dial that has not been accepted yet has no session, so the
          // session screen (and its "stop waiting" button) never opens. Without
          // this, a busy flag left on an unreachable 100.x address strands the
          // person on the home screen with a grey button and no way out except
          // killing the app.
          if (widget.host.busy)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.host.hangUp,
                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                label: const Text('停止这次连接，去连另一台'),
              ),
            ),
          if (_manualOpen) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _manual,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                isDense: true,
                hintText: '比如 192.168.1.20 或 name:8787',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                  fontFamily: 'monospace',
                ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onSubmitted: (value) => widget.host.connectManual(value),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: widget.host.busy
                    ? null
                    : () => widget.host.connectManual(_manual.text),
                child: const Text('连这台'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _selfCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.smartphone, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('这台手机的名字', style: theme.textTheme.labelSmall),
                const SizedBox(height: 2),
                SelectableText(
                  widget.host.selfId.isEmpty ? '—' : widget.host.selfId,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.host.selfId));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制名字')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制名字',
          ),
        ],
      ),
    );
  }

  Widget _logCard(ThemeData theme) {
    final lines = widget.host.logLines;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _logsOpen = !_logsOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 18, color: theme.colorScheme.outline),
                  const SizedBox(width: 10),
                  Text('运行日志', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Icon(_logsOpen ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: theme.colorScheme.outline),
                ],
              ),
            ),
          ),
          if (_logsOpen)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  lines.isEmpty ? '（还没有日志）' : lines.join('\n'),
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    fontFamily: 'monospace',
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online ? const Color(0xFF4ADE80) : const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              online ? '已就绪' : '未连上',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.busy, required this.onTap});

  final PeerInfo peer;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offline = !peer.online;
    final meta = <String>[peer.sourceLabel, peer.host].join(' · ');
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (offline ? theme.colorScheme.outline : theme.colorScheme.primary)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  peer.platform.contains('win')
                      ? Icons.desktop_windows_outlined
                      : Icons.desktop_mac_outlined,
                  size: 21,
                  color: offline
                      ? theme.colorScheme.outline
                      : theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: offline
                            ? theme.colorScheme.outline
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
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
              const SizedBox(width: 8),
              busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.chevron_right,
                      size: 20, color: theme.colorScheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
