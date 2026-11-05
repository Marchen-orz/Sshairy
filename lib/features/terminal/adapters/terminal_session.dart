import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../../design/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';

enum SessionStatus { connecting, connected, failed, disconnected }

/// Owns the shell and terminal model; panes only display it, so hiding a tab never closes the shell.
class TerminalSession extends ChangeNotifier {
  TerminalSession(this.host, this._connector);

  final Host host;
  final Connector _connector;
  final _terminal = Terminal(maxLines: 2000);
  SessionStatus status = SessionStatus.connecting;
  ConnectError? error;
  SshShell? _shell;
  var _closed = false;

  Future<void> connect(ConnectPrompts prompts) async {
    status = SessionStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final shell = await _connector.open(host, prompts, cols: _terminal.viewWidth, rows: _terminal.viewHeight);
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
      await shell.done.catchError((_) {});
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
      _shell = null;
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
    dispose();
  }
}

class TerminalPane extends StatefulWidget {
  const TerminalPane(this.session, {super.key, required this.fontSize, required this.active, this.onKeyEvent});

  final TerminalSession session;
  final double fontSize;
  final bool active;

  /// Sees keys before the terminal does, so application shortcuts are not sent to the shell.
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final _focus = FocusNode();
  final _controller = TerminalController();

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_focusWhenConnected);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _connect();
    });
  }

  @override
  void didUpdateWidget(TerminalPane old) {
    super.didUpdateWidget(old);
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

  @override
  void dispose() {
    widget.session.removeListener(_focusWhenConnected);
    _controller.dispose();
    _focus.dispose();
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
            focusNode: _focus,
            controller: _controller,
            onKeyEvent: _onKey,
            padding: const EdgeInsets.all(Space.sm),
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
                        Text(_message(l, session)),
                        const SizedBox(height: Space.md),
                        FilledButton(autofocus: true, onPressed: _connect, child: Text(l.retry)),
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
