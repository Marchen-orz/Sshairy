import '../features/terminal/api.dart';
import '../features/workspace/api.dart';
import '../foundation/ids.dart';

class WorkspaceTerminalHistoryReader implements TerminalHistoryReader {
  WorkspaceTerminalHistoryReader(this._workspace, this._sessions);

  final WorkspaceState Function() _workspace;
  final Map<SessionId, TerminalSession> Function() _sessions;

  @override
  List<TerminalHistorySession> get sessions {
    final current = _sessions();
    final seen = <SessionId>{};
    return List.unmodifiable([
      for (final (tabIndex, tab) in _workspace().tabs.indexed)
        for (final (paneIndex, leaf) in tab.layout.leaves.indexed)
          if (seen.add(leaf.session))
            if (current[leaf.session]?.historySession case final session?)
              TerminalHistorySession(
                sessionId: session.sessionId,
                target: session.target,
                label: '${tabIndex + 1}.${paneIndex + 1} · ${session.label}',
                generation: session.generation,
                historyRevision: session.historyRevision,
                binding: session.binding,
              ),
    ]);
  }

  @override
  SessionId? get focusedSession => _workspace().activeTab?.layout.focusedLeaf.session;

  TerminalSession? _resolve(TerminalHistorySession expected) {
    final open = _workspace().tabs.any((tab) => tab.layout.leaves.any((leaf) => leaf.session == expected.sessionId));
    if (!open) return null;
    final session = _sessions()[expected.sessionId];
    return session?.historySessionCurrent(expected) == true ? session : null;
  }

  @override
  bool isCurrent(TerminalHistorySession expected) => _resolve(expected) != null;

  @override
  TerminalHistorySnapshot? read(TerminalHistorySession expected) => _resolve(expected)?.readHistory(expected);
}
