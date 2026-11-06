import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../design/terminal_palette.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import 'ime_caret.dart';

part 'terminal_pane.dart';
part 'terminal_search.dart';

/// [idle] has never connected; a restored tab waits there until the user connects.
enum SessionStatus { idle, connecting, connected, failed, disconnected }

/// Owns the shell and terminal model; panes only display it, so hiding a tab never closes the shell.
class TerminalSession extends ChangeNotifier {
  TerminalSession(
    this.id,
    this.host,
    this._connections, {
    this.autoConnect = true,
    int scrollback = 2000,
    bool Function()? autoReconnect,
  })  : _terminal = Terminal(maxLines: scrollback),
        _autoReconnect = autoReconnect ?? (() => false) {
    // OSC 52 stays off (docs/MODULES.md §3): a remote program must not read or replace the local clipboard.
    _terminal.onClipboardStore = (_, _) {};
    _terminal.onClipboardQuery = (_) => null;
  }

  final SessionId id;
  final Host host;

  /// False for restored tabs: the first view shows a connect button instead of dialling (docs/MODULES.md §3).
  final bool autoConnect;
  final ConnectionManager _connections;
  final bool Function() _autoReconnect;
  final Terminal _terminal;
  SessionStatus status = SessionStatus.idle;
  ConnectError? error;
  ShellChannel? _shell;
  TransportLease? _lease;
  var _closed = false;

  /// Output arrived while no pane showed this session.
  var unread = false;
  var _viewed = false;

  /// The prompts of the pane that last connected, so a timer or the palette can reconnect too.
  ConnectPrompts? _prompts;

  /// Seconds until the next automatic attempt; null when none is planned.
  int? reconnectIn;
  Timer? _reconnectTimer;
  var _attempts = 0;
  static const _backoff = [1, 2, 4, 8, 16];

  set viewed(bool value) {
    if (_viewed == value) return;
    _viewed = value;
    if (value && unread) {
      unread = false;
      notifyListeners();
    }
  }

  bool get canReconnect => _prompts != null && status != SessionStatus.connecting && status != SessionStatus.connected;

  /// A user's attempt: starts over the automatic retry budget.
  Future<void> connect([ConnectPrompts? prompts]) {
    _stopTimer();
    _attempts = 0;
    return _connect(prompts);
  }

  /// Cancels a planned automatic attempt.
  void stopReconnect() {
    _stopTimer();
    _attempts = 0;
    notifyListeners();
  }

  Future<void> _connect(ConnectPrompts? prompts) async {
    prompts ??= _prompts;
    if (prompts == null || _closed || status == SessionStatus.connecting || status == SessionStatus.connected) return;
    _prompts = prompts;
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
        stream.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(_output);
      }
      _attempts = 0;
      _set(SessionStatus.connected);
      await Future.any([shell.done, lease.done]).catchError((_) {});
      // A shell that ended on its own (`exit`) leaves the transport up; only a lost transport is retried.
      await Future<void>.delayed(Duration.zero);
      final lost = lease.lost;
      _set(SessionStatus.disconnected);
      if (lost) _scheduleReconnect();
    } on ConnectError catch (e) {
      error = e;
      _set(SessionStatus.failed);
      if (e.kind == ConnectFailure.network && _attempts > 0) _scheduleReconnect();
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

  void _output(String data) {
    _terminal.write(data);
    if (!_viewed && !unread) {
      unread = true;
      notifyListeners();
    }
  }

  /// docs/MODULES.md §2: 1/2/4/8/16 s with jitter, at most five times, network errors only.
  void _scheduleReconnect() {
    if (_closed || !_autoReconnect() || _attempts >= _backoff.length) return;
    final due = DateTime.now().add(Duration(milliseconds: _backoff[_attempts++] * 1000 + Random().nextInt(500)));
    void tick() {
      final left = due.difference(DateTime.now());
      if (left <= Duration.zero) {
        _stopTimer();
        _connect(null);
      } else {
        reconnectIn = (left.inMilliseconds / 1000).ceil();
        notifyListeners();
      }
    }

    _reconnectTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => tick());
    tick();
  }

  void _stopTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    reconnectIn = null;
  }

  void _set(SessionStatus s) {
    if (_closed) return;
    status = s;
    notifyListeners();
  }

  void close() {
    _closed = true;
    _stopTimer();
    _shell?.close();
    _lease?.release();
    dispose();
  }
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
