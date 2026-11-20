import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../adapters/terminal_session.dart';
import '../domain/command_assistance.dart';
import '../domain/terminal_target.dart';
import 'local_terminal.dart';

final terminalSnippetsProvider = Provider<List<CommandSnippet>>((_) => const []);

final terminalSessionsProvider = NotifierProvider<TerminalSessions, Map<SessionId, TerminalSession>>(
  TerminalSessions.new,
);

/// Owns every shell and terminal model (docs/CONTRACTS.md §2); panes and tabs only refer to them by ID.
class TerminalSessions extends Notifier<Map<SessionId, TerminalSession>> {
  /// Mirrors [state]; disposal callbacks may not read state.
  final _owned = <SessionId, TerminalSession>{};
  final _closing = <Future<void>>{};

  void _stop(TerminalSession session) {
    session.close();
    final stopped = session.stopped;
    _closing.add(stopped);
    unawaited(stopped.whenComplete(() => _closing.remove(stopped)));
  }

  @override
  Map<SessionId, TerminalSession> build() {
    ref.onDispose(() {
      for (final s in _owned.values) {
        _stop(s);
      }
      _owned.clear();
    });
    return const {};
  }

  /// [id] lets a restored layout name its sessions before they exist.
  TerminalSession open(Host host, {SessionId? id, bool autoConnect = true}) {
    final session = TerminalSession(
      id ?? SessionId(newId()),
      host,
      ref.read(connectionManagerProvider),
      autoConnect: autoConnect,
      scrollback: ref.read(settingsProvider).get(SettingKeys.scrollback),
      autoReconnect: () => ref.read(settingsProvider).get(SettingKeys.autoReconnect),
      snippets: () => ref.read(terminalSnippetsProvider),
    );
    _owned[session.id] = session;
    state = {...state, session.id: session};
    return session;
  }

  TerminalSession openLocal(LocalShell shell, {SessionId? id, bool autoConnect = true}) {
    final session = TerminalSession.local(
      id ?? SessionId(newId()),
      shell,
      ref.read(localPtyProvider),
      autoConnect: autoConnect,
      scrollback: ref.read(settingsProvider).get(SettingKeys.scrollback),
      snippets: () => ref.read(terminalSnippetsProvider),
    );
    _owned[session.id] = session;
    state = {...state, session.id: session};
    return session;
  }

  TerminalSession openRemote(
    LinkTerminalTarget target,
    Future<ShellChannel> Function(int cols, int rows) openChannel, {
    SessionId? id,
    bool autoConnect = true,
  }) {
    final session = TerminalSession.remote(
      id ?? SessionId(newId()),
      target,
      openChannel,
      autoConnect: autoConnect,
      scrollback: ref.read(settingsProvider).get(SettingKeys.scrollback),
      snippets: () => ref.read(terminalSnippetsProvider),
    );
    _owned[session.id] = session;
    state = {...state, session.id: session};
    return session;
  }

  void closeAll() {
    final sessions = _owned.values.toList();
    _owned.clear();
    state = const {};
    for (final session in sessions) {
      _stop(session);
    }
  }

  Future<void> shutdown() async {
    closeAll();
    await Future.wait(_closing.toList());
  }

  void close(SessionId id) {
    final session = _owned.remove(id);
    if (session == null) return;
    state = {...state}..remove(id);
    _stop(session);
  }
}
