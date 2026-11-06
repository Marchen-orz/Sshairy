import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/ids.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../adapters/terminal_session.dart';

final terminalSessionsProvider =
    NotifierProvider<TerminalSessions, Map<SessionId, TerminalSession>>(TerminalSessions.new);

/// Owns every shell and terminal model (docs/CONTRACTS.md §2); panes and tabs only refer to them by ID.
class TerminalSessions extends Notifier<Map<SessionId, TerminalSession>> {
  /// Mirrors [state]; disposal callbacks may not read state.
  final _owned = <SessionId, TerminalSession>{};

  @override
  Map<SessionId, TerminalSession> build() {
    ref.onDispose(() {
      for (final s in _owned.values) {
        s.close();
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
    );
    _owned[session.id] = session;
    state = {...state, session.id: session};
    return session;
  }

  void close(SessionId id) {
    final session = _owned.remove(id);
    if (session == null) return;
    state = {...state}..remove(id);
    session.close();
  }
}
