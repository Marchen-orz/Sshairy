import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../../design/terminal_palette.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import 'ime_caret.dart';

/// [idle] has never connected; a restored tab waits there until the user connects.
enum SessionStatus { idle, connecting, connected, failed, disconnected }

/// Owns the shell and terminal model; panes only display it, so hiding a tab never closes the shell.
class TerminalSession extends ChangeNotifier {
  TerminalSession(this.id, this.host, this._connections, {this.autoConnect = true});

  final SessionId id;
  final Host host;

  /// False for restored tabs: the first view shows a connect button instead of dialling (docs/MODULES.md §3).
  final bool autoConnect;
  final ConnectionManager _connections;
  final _terminal = Terminal(maxLines: 2000);
  SessionStatus status = SessionStatus.idle;
  ConnectError? error;
  ShellChannel? _shell;
  TransportLease? _lease;
  var _closed = false;

  Future<void> connect(ConnectPrompts prompts) async {
    if (_closed || status == SessionStatus.connecting || status == SessionStatus.connected) return;
    status = SessionStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final (lease, shell) = await _connections.open(
        host,
        prompts,
        (lease) => lease.openShell(cols: _terminal.viewWidth, rows: _terminal.viewHeight),
      );
      _lease = lease;
      if (_closed) return shell.close();
      _shell = shell;
      _terminal.onOutput = (data) => shell.write(utf8.encode(data));
      _terminal.onResize = (cols, rows, _, _) => shell.resize(cols, rows);
      shell.resize(_terminal.viewWidth, _terminal.viewHeight);
      // shortcut: output is parsed synchronously as it arrives; add a time-sliced queue if E-02 shows UI stalls.
      for (final stream in [shell.stdout, shell.stderr]) {
        stream.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(_terminal.write);
      }
      _set(SessionStatus.connected);
      await Future.any([shell.done, lease.done]).catchError((_) {});
      _set(SessionStatus.disconnected);
    } on ConnectError catch (e) {
      error = e;
      _set(SessionStatus.failed);
    } on Object catch (e) {
      error = ConnectError(ConnectFailure.network, '$e');
      _set(SessionStatus.failed);
    } finally {
      _terminal.onOutput = null;
      _terminal.onResize = null;
      _shell?.close();
      _shell = null;
      _lease?.release();
      _lease = null;
    }
  }

  void _set(SessionStatus s) {
    if (_closed) return;
    status = s;
    notifyListeners();
  }

  void close() {
    _closed = true;
    _shell?.close();
    _lease?.release();
    dispose();
  }
}

class TerminalPane extends StatefulWidget {
  const TerminalPane(this.session, {super.key, required this.fontSize, required this.active, this.onKeyEvent, this.focusNode});

  final TerminalSession session;
  final double fontSize;
  final bool active;

  /// Sees keys before the terminal does, so application shortcuts are not sent to the shell.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// Lets the owner move focus between panes; the pane makes its own when none is given.
  final FocusNode? focusNode;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  final _controller = TerminalController();
  final _view = GlobalKey<TerminalViewState>();
  Rect? _imeRect;
  var _imeRectScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_focusWhenConnected);
    widget.session._terminal.addListener(_scheduleImeRect);
    _focus.addListener(_scheduleImeRect);
    // A pane can be rebuilt (moved into a split, a tab restored): only a session that never ran dials by itself.
    if (widget.session.status == SessionStatus.idle && widget.session.autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connect();
      });
    }
  }

  @override
  void didUpdateWidget(TerminalPane old) {
    super.didUpdateWidget(old);
    _scheduleImeRect();
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focus.requestFocus();
      });
    }
  }

  Future<void> _connect() => widget.session.connect(DialogPrompts(context));

  void _focusWhenConnected() {
    if (widget.active && widget.session.status == SessionStatus.connected) _focus.requestFocus();
  }

  /// xterm2 never sends the composing rect, so Windows puts the IME candidate window at the window corner.
  /// Its editable transform is the identity, so the cursor's global rect is what the engine expects.
  void _scheduleImeRect() {
    if (_imeRectScheduled) return;
    _imeRectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _imeRectScheduled = false;
      final view = _view.currentState;
      if (!mounted || view == null || !_focus.hasFocus) return;
      final rect = view.globalCursorRect;
      if (rect == _imeRect) return;
      _imeRect = rect;
      SystemChannels.textInput.invokeMethod<void>('TextInput.setMarkedTextRect', {
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
      });
      final scale = View.of(context).devicePixelRatio;
      ImeCaret.moveTo(Rect.fromLTRB(rect.left * scale, rect.top * scale, rect.right * scale, rect.bottom * scale));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.session._terminal.removeListener(_scheduleImeRect);
    widget.session.removeListener(_focusWhenConnected);
    _controller.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    // xterm2 copies on Ctrl+C while text is selected; docs/UI.md §6 always passes it to the shell.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyC &&
        keys.isControlPressed &&
        !keys.isShiftPressed &&
        !keys.isAltPressed) {
      _controller.clearSelection();
    }
    return widget.onKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    if (text.contains('\n') && !await _confirmPaste(text)) return;
    widget.session._terminal.paste(text);
  }

  Future<bool> _confirmPaste(String text) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: SizedBox(
          width: 520,
          height: 240,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontFamily: 'Consolas'))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: Text(l.paste)),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final session = widget.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Stack(children: [
        Positioned.fill(
          child: TerminalView(
            session._terminal,
            key: _view,
            focusNode: _focus,
            controller: _controller,
            onKeyEvent: _onKey,
            padding: const EdgeInsets.all(Space.sm),
            theme: _terminalTheme(TerminalPalette.of(Theme.of(context))),
            onPaste: _paste,
            textStyle: TerminalStyle(
              fontSize: widget.fontSize,
              fontFamily: 'Cascadia Mono',
              fontFamilyFallback: const [
                'Consolas', 'Menlo', 'DejaVu Sans Mono', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC',
              ],
            ),
          ),
        ),
        if (session.status != SessionStatus.connected)
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: session.status == SessionStatus.connecting
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: Space.md),
                        Text(l.connecting),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(session.status == SessionStatus.idle ? session.host.target : _message(l, session)),
                        const SizedBox(height: Space.md),
                        FilledButton(
                          autofocus: true,
                          onPressed: _connect,
                          child: Text(session.status == SessionStatus.idle ? l.connect : l.retry),
                        ),
                      ]),
              ),
            ),
          ),
      ]),
    );
  }

  String _message(AppLocalizations l, TerminalSession s) => switch (s.error?.kind) {
        null => l.disconnected,
        ConnectFailure.network => l.errConnect(s.error!.detail),
        ConnectFailure.auth => l.errAuth,
        ConnectFailure.hostKeyRejected => l.errHostKeyRejected,
        ConnectFailure.keyFile => l.errKeyFile(s.error!.detail),
        ConnectFailure.cancelled => l.errCancelled,
      };
}

TerminalTheme _terminalTheme(TerminalPalette p) {
  final a = p.ansi;
  return TerminalTheme(
    cursor: p.cursor,
    selection: p.selection,
    foreground: p.foreground,
    background: p.background,
    black: a[0],
    red: a[1],
    green: a[2],
    yellow: a[3],
    blue: a[4],
    magenta: a[5],
    cyan: a[6],
    white: a[7],
    brightBlack: a[8],
    brightRed: a[9],
    brightGreen: a[10],
    brightYellow: a[11],
    brightBlue: a[12],
    brightMagenta: a[13],
    brightCyan: a[14],
    brightWhite: a[15],
    searchHitBackground: p.searchHit,
    searchHitBackgroundCurrent: p.searchHitCurrent,
    searchHitForeground: const Color(0xFF10151C),
  );
}
