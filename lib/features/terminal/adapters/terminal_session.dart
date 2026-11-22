import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../design/cursor_popup.dart';
import '../../../design/menu.dart';
import '../../../design/popup.dart';
import '../../../design/scrolling.dart';
import '../../../design/terminal_palette.dart';
import '../../../design/theme.dart';
import '../../../foundation/ids.dart';
import '../../../foundation/cancellation.dart';
import '../../../foundation/shortcuts.dart';
import '../../../foundation/open_external.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../application/completion_translations.dart';
import '../application/ai.dart';
import '../domain/ai_intent.dart';
import '../domain/ai_terminal.dart';
import '../domain/command_assistance.dart';
import '../domain/completion_command_metadata.dart';
import '../domain/directory.dart';
import '../domain/insertion.dart';
import '../domain/shell_integration.dart';
import '../domain/local_pty.dart';
import '../domain/terminal_target.dart';
import '../domain/terminal_paths.dart';
import '../domain/spec_completion.dart';
import 'terminal_paths.dart';
import 'completion_specs.dart';
import 'completion_translations.dart';
import '../presentation/confirm_insert.dart';
import '../presentation/mobile_key_bar.dart';
import 'ime_caret.dart';
import 'terminal_output.dart';

part 'terminal_pane.dart';
part 'terminal_search.dart';
part 'terminal_assistance.dart';
part 'terminal_assistance_ui.dart';
part 'terminal_input_overlays.dart';
part 'terminal_ai.dart';
part 'terminal_history.dart';
part 'terminal_ai_task.dart';

/// [idle] has never connected; a restored tab waits there until the user connects.
enum SessionStatus { idle, connecting, connected, failed, disconnected }

/// Owns the shell and terminal model; panes only display it, so hiding a tab never closes the shell.
class TerminalSession extends ChangeNotifier implements TerminalContextReader, TerminalDraftAcceptor {
  TerminalSession(
    this.id,
    Host host,
    ConnectionManager connections, {
    this.autoConnect = true,
    int scrollback = 2000,
    bool Function()? autoReconnect,
    this.completionProvider,
    CompletionSpecs? completionSpecs,
    CompletionTranslations? completionTranslations,
    this.remotePaths,
    List<CommandSnippet> Function()? snippets,
  }) : _sshHost = host,
       target = SshTerminalTarget(host.id),
       _connections = connections,
       _localPtyFactory = null,
       _remoteOpener = null,
       _terminal = _HistoryTerminal(maxLines: scrollback),
       _autoReconnect = autoReconnect ?? (() => false),
       _completionSpecs = completionSpecs ?? CompletionSpecs.shared,
       _translations = completionTranslations,
       _snippets = snippets ?? (() => const []) {
    _configureTerminal();
  }

  TerminalSession.local(
    this.id,
    LocalShell shell,
    LocalPtyFactory factory, {
    this.autoConnect = true,
    int scrollback = 2000,
    this.completionProvider,
    CompletionSpecs? completionSpecs,
    CompletionTranslations? completionTranslations,
    List<CommandSnippet> Function()? snippets,
  }) : _sshHost = null,
       target = LocalTerminalTarget(shell),
       _connections = null,
       _localPtyFactory = factory,
       _remoteOpener = null,
       _terminal = _HistoryTerminal(maxLines: scrollback),
       _autoReconnect = (() => false),
       _completionSpecs = completionSpecs ?? CompletionSpecs.shared,
       _translations = completionTranslations,
       _snippets = snippets ?? (() => const []),
       remotePaths = null {
    _configureTerminal();
  }

  /// A terminal backed by an external [ShellChannel] (e.g. Sshairy Link desktop mirror or desktop-proxied SSH).
  TerminalSession.remote(
    this.id,
    LinkTerminalTarget linkTarget,
    Future<ShellChannel> Function(int cols, int rows) openChannel, {
    this.autoConnect = true,
    int scrollback = 2000,
    this.completionProvider,
    CompletionSpecs? completionSpecs,
    CompletionTranslations? completionTranslations,
    List<CommandSnippet> Function()? snippets,
  }) : _sshHost = null,
       target = linkTarget,
       _connections = null,
       _localPtyFactory = null,
       _remoteOpener = openChannel,
       _terminal = _HistoryTerminal(maxLines: scrollback),
       _autoReconnect = (() => false),
       _completionSpecs = completionSpecs ?? CompletionSpecs.shared,
       _translations = completionTranslations,
       _snippets = snippets ?? (() => const []),
       remotePaths = null {
    _configureTerminal();
  }

  void _configureTerminal() {
    _terminal.onSemanticPrompt = _semanticPrompt;
    _terminal.onPrivateOSC = _historyOsc;
    // OSC 52 stays off (docs/MODULES.md §3): a remote program must not read or replace the local clipboard.
    _terminal.onClipboardStore = (_, _) {};
    _terminal.onClipboardQuery = (_) => null;
    _terminal.onCurrentDirectoryChange = (uri) {
      _reported = parseOsc7(uri);
      if (_reported != null) _directory.value = _reported;
      // The report comes with the prompt, so the command that changed directory has finished.
      if (_directory.followed) _lookSoon(const [Duration(milliseconds: 50)]);
    };
  }

  final SessionId id;
  final TerminalTarget target;
  final Host? _sshHost;
  Host? get sshHost => _sshHost;
  Host get host => _sshHost ?? (throw StateError('Local terminal has no SSH host'));
  LocalShell? get localShell => switch (target) {
    LocalTerminalTarget(:final shell) => shell,
    _ => null,
  };
  LinkTerminalTarget? get linkTarget => switch (target) {
    final LinkTerminalTarget t => t,
    _ => null,
  };
  bool get isLocal => target is LocalTerminalTarget;
  bool get isRemote => target is LinkTerminalTarget;
  String get title => _sshHost?.title ?? localShell?.name ?? linkTarget!.title;
  String get targetLabel => _sshHost?.target ?? localShell?.name ?? linkTarget!.targetLabel;
  int get cols => _terminal.viewWidth;
  int get rows => _terminal.viewHeight;

  final _mirrorOut = StreamController<Uint8List>.broadcast();

  /// Broadcast stream of terminal output chunks for paired mobile mirroring; zero work when no mirror is attached.
  Stream<Uint8List> get mirrorOutput => _mirrorOut.stream;

  /// Captures a bounded UTF-8 text snapshot of the recent buffer for newly attached mobile mirrors.
  Uint8List captureMirrorSnapshot({int maxBytes = 65536}) {
    final buffer = _terminal.buffer;
    final total = buffer.lines.length;
    if (total == 0) return Uint8List(0);
    final end = total - 1;
    final start = max(0, end - 160);
    final lines = <String>[];
    for (var i = start; i <= end; i++) {
      lines.add(buffer.lines[i].getText().replaceAll(RegExp(r'\s+$'), ''));
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    final joined = lines.isEmpty ? '' : '${lines.join('\r\n')}\r\n';
    final bytes = utf8.encode(joined);
    if (bytes.length <= maxBytes) return Uint8List.fromList(bytes);
    // Keep the tail within budget without splitting a UTF-8 sequence.
    var offset = bytes.length - maxBytes;
    while (offset < bytes.length && (bytes[offset] & 0xc0) == 0x80) {
      offset++;
    }
    return Uint8List.fromList(bytes.sublist(offset));
  }

  /// Injects raw input bytes from a paired mobile mirror into this active desktop session.
  void sendRemoteInput(Uint8List bytes) {
    if (_closed || _shellEnded || bytes.isEmpty) return;
    if (_shell != null) {
      _shell!.write(bytes);
    } else if (_localPty != null) {
      _localPty!.write(bytes);
    }
  }

  /// Forwards an optional resize request from a paired mobile mirror.
  void resizeFromRemote(int cols, int rows) {
    if (_closed || _shellEnded || cols < 10 || rows < 4) return;
    if (_shell != null) {
      _shell!.resize(cols, rows);
    } else if (_localPty != null) {
      _localPty!.resize(cols, rows);
    }
  }

  /// UI draft only; it never enters the layout, history or application notifications.
  String multilineDraft = '';

  /// False for restored tabs: the first view shows a connect button instead of dialling (docs/MODULES.md §3).
  final bool autoConnect;
  final ConnectionManager? _connections;
  final LocalPtyFactory? _localPtyFactory;
  final Future<ShellChannel> Function(int cols, int rows)? _remoteOpener;
  LocalPty? _localPty;
  Future<void> _localStopped = Future.value();
  Future<void> get stopped => _localStopped;
  final bool Function() _autoReconnect;
  final _HistoryTerminal _terminal;
  SessionStatus status = SessionStatus.idle;
  ConnectError? error;
  ShellChannel? _shell;
  TransportLease? _lease;
  TerminalOutput? _outputQueue;
  CancellationToken? _connecting;
  var _closed = false;
  var _shellEnded = true;
  final _insertions = <CancellationToken>{};
  final CommandCompletionProvider? completionProvider;
  final CompletionSpecs _completionSpecs;
  final CompletionTranslations? _translations;
  // Source flags are caller-settable; only internally built specification objects may leave the app.
  final _translationSources = Expando<String>();
  final List<CommandSnippet> Function() _snippets;
  final RemotePathSource? remotePaths;
  RemotePathSource? _ownedPaths;
  final _browseStack = <_BrowseFrame>[];
  final _commands = CommandHistory();
  final _aiHistory = <TerminalAiHistoryEntry>[];
  final _historyBinding = Object();
  _PendingCommandResult? _pendingCommandResult;
  var _historyRevision = 0;
  _AiTask? _aiTask;

  // Part extensions may not call the protected notifyListeners.
  void _aiTaskChanged() => notifyListeners();
  final _history = ValueNotifier<List<String>>(const []);
  final _assistance = ValueNotifier<CommandAssistanceState>(const CommandAssistanceState());
  Timer? _completionTimer;
  CancellationToken? _completionCancel;
  var _shellGeneration = 0, _draftRevision = 0, _inputSequence = 0;
  var _semanticSeen = false, _semanticInput = false;
  int? _promptRow, _promptColumn;
  BufferLine? _submittedLine, _pastedPromptLine;
  String? _submittedText;
  var _inputPending = false, _historyBrowsing = false;

  ValueListenable<CommandAssistanceState> get commandAssistance => _assistance;
  ValueListenable<List<String>> get commandHistory => _history;
  int get shellGeneration => _shellGeneration;

  /// The view calls this before forwarding a user Enter; terminal responses are never recorded.
  void commandSubmitted() => _submitCommand();
  void clearCommandHistory() {
    if (_closed) return;
    _commands.clear();
    _clearAiHistory();
    _history.value = const [];
    _invalidateCommandDraft();
    _syncCommandDraft();
  }

  Future<InsertResult> acceptCommand(CommandCompletionRequest request, String text) => _acceptCommand(request, text);

  @override
  TerminalAiContext readAiContext() {
    final echoed = pendingOutputBytes == 0 ? _echoedCommand(allowMultiline: true) : null;
    final draft = echoed != null && (echoed.isEmpty || validTerminalAiDraft(echoed)) ? echoed : null;
    return TerminalAiContext(
      sessionId: id,
      target: switch (target) {
        SshTerminalTarget(:final hostId) => SshTerminalAiTarget(hostId),
        LocalTerminalTarget(:final shell) => LocalTerminalAiTarget(shell.kind),
        LinkTerminalTarget() => const LocalTerminalAiTarget(LocalShellKind.unix),
      },
      generation: _shellGeneration,
      revision: _draftRevision,
      historyRevision: _historyRevision,
      prompt: !canInsert
          ? TerminalAiPrompt.unavailable
          : draft == null
          ? TerminalAiPrompt.unknown
          : _semanticSeen
          ? TerminalAiPrompt.semantic
          : TerminalAiPrompt.recognized,
      draft: draft,
      directory: _directory.value,
      server: isRemote ? linkTarget?.targetLabel : _lease?.serverVersion,
    );
  }

  bool _aiContextCurrent(TerminalAiContext expected) {
    final current = readAiContext();
    return current.ready && expected.ready && sameTerminalAiContext(current, expected);
  }

  List<TerminalAiHistoryEntry> readAiHistory(TerminalAiContext expected) {
    if (!_aiContextCurrent(expected)) return const [];
    return boundedTerminalAiHistory(_aiHistory.where((entry) => entry.generation == expected.generation));
  }

  TerminalHistorySession? get historySession {
    if (!canInsert || isRemote || (!isLocal && _lease?.isCurrent != true)) return null;
    return TerminalHistorySession(
      sessionId: id,
      target: switch (target) {
        SshTerminalTarget(:final hostId) => SshTerminalAiTarget(hostId),
        LocalTerminalTarget(:final shell) => LocalTerminalAiTarget(shell.kind),
        LinkTerminalTarget() => throw StateError('unreachable'),
      },
      label: _historyMetadata(_sshHost?.label ?? localShell!.name, 256) ?? '',
      generation: _shellGeneration,
      historyRevision: _historyRevision,
      binding: _historyBinding,
    );
  }

  // New commands update history without revoking the Agent's access to the same connection.
  bool historySessionCurrent(TerminalHistorySession expected) =>
      canInsert &&
      (isLocal || _lease?.isCurrent == true) &&
      expected.sessionId == id &&
      expected.generation == _shellGeneration &&
      identical(expected.binding, _historyBinding) &&
      switch ((expected.target, target)) {
        (SshTerminalAiTarget(hostId: final expected), SshTerminalTarget(:final hostId)) => expected == hostId,
        (LocalTerminalAiTarget(kind: final expected), LocalTerminalTarget(:final shell)) => expected == shell.kind,
        _ => false,
      };

  TerminalHistorySnapshot? readHistory(TerminalHistorySession expected) {
    if (!historySessionCurrent(expected)) return null;
    return TerminalHistorySnapshot(
      session: expected,
      directory: _historyMetadata(_directory.value, 1024),
      prompt: readAiContext().prompt,
      history: boundedTerminalAiHistory(_aiHistory.where((entry) => entry.generation == expected.generation)),
    );
  }

  String? _historyMetadata(String? text, int maxBytes) =>
      text != null &&
          validTerminalAiCommand(text) &&
          utf8.encode(text).length <= maxBytes &&
          !terminalAiSensitiveText(text)
      ? text
      : null;

  @override
  Future<InsertResult> acceptAiDraft(
    TerminalAiContext expected,
    String text, {
    bool suffix = false,
    CancellationToken? cancel,
    bool Function()? isCurrent,
  }) async {
    if ((cancel?.isCancelled ?? false) || isCurrent?.call() == false) return InsertResult.cancelled;
    if (!canInsert) return InsertResult.unavailable;
    if (!validTerminalAiCommand(text) || (suffix && utf8.encode(text).length > 2048)) {
      return InsertResult.rejected;
    }
    if (!_aiContextCurrent(expected)) return InsertResult.stale;
    final command = suffix ? '${expected.draft}$text' : text;
    if (!validTerminalAiCommand(command)) return InsertResult.rejected;
    if (!command.startsWith(expected.draft!)) {
      final erased = await _eraseAiDraft(expected, cancel, isCurrent);
      if (erased != InsertResult.sent) return erased;
      if ((cancel?.isCancelled ?? false) || isCurrent?.call() == false) return InsertResult.cancelled;
      final current = readAiContext();
      if (!current.ready ||
          current.draft!.isNotEmpty ||
          expected.historyRevision != current.historyRevision ||
          !sameTerminalAiEnvironment(expected, current)) {
        return InsertResult.stale;
      }
      expected = current;
    }
    return _acceptCommand(
      CommandCompletionRequest(
        text: expected.draft!,
        generation: expected.generation,
        revision: expected.revision,
        directory: expected.directory,
      ),
      command,
    );
  }

  Future<InsertResult> _eraseAiDraft(
    TerminalAiContext expected,
    CancellationToken? cancel,
    bool Function()? isCurrent,
  ) async {
    final stopped = CancellationToken();
    final result = Completer<InsertResult>();
    final buffer = _terminal.buffer;
    final startRow = _promptStartRow() ?? _logicalStartRow(buffer.absoluteCursorY);
    final startLine = buffer.lines[startRow];
    _insertions.add(stopped);
    void finish(InsertResult value) {
      if (!result.isCompleted) result.complete(value);
    }

    int? sequence;
    void check() {
      if (sequence == null) return;
      final current = readAiContext();
      final lines = _terminal.buffer.lines;
      final row = _terminal.buffer.absoluteCursorY;
      final currentLine = row >= 0 && row < lines.length ? lines[row] : null;
      final activeStart = _promptStartRow();
      final samePrompt =
          currentLine != null &&
          (activeStart != null
              ? identical(lines[activeStart], startLine)
              : () {
                  final floor = max(0, row - 32);
                  for (var r = row; r >= floor; r--) {
                    if (identical(lines[r], startLine)) return true;
                  }
                  return false;
                }());
      if (isCurrent?.call() == false) {
        finish(InsertResult.cancelled);
      } else if (!canInsert ||
          sequence != _inputSequence ||
          !samePrompt ||
          expected.historyRevision != current.historyRevision ||
          !sameTerminalAiEnvironment(expected, current)) {
        finish(InsertResult.stale);
      } else if (current.ready && current.draft!.isEmpty && identical(currentLine, startLine)) {
        _pastedPromptLine = null;
        finish(InsertResult.sent);
      }
    }

    _assistance.addListener(check);
    _directory.changes.addListener(check);
    addListener(check);
    unawaited(Future.any([stopped.whenCancelled, ?cancel?.whenCancelled]).then((_) => finish(InsertResult.cancelled)));
    try {
      // Use the same erase key as terminal input; only a confirmed empty echo permits the following paste.
      final runes = expected.draft!.runes.length;
      for (var i = 0; i < runes; i++) {
        if (!_terminal.keyInput(TerminalKey.backspace)) return InsertResult.rejected;
      }
      sequence = _inputSequence;
      check();
      final wait = Duration(milliseconds: 2000 + min(3000, runes * 10));
      return await result.future.timeout(wait, onTimeout: () => InsertResult.rejected);
    } finally {
      _assistance.removeListener(check);
      _directory.changes.removeListener(check);
      removeListener(check);
      _insertions.remove(stopped);
      stopped.cancel();
    }
  }

  @override
  TerminalAiSnapshot? readAiSnapshot(TerminalAiContext expected, {int maxLines = 200, int maxBytes = 32768}) {
    if (!_aiContextCurrent(expected)) return null;
    final screen = _screenProjection(maxLines, maxBytes);
    if (screen == null) return null;
    return TerminalAiSnapshot(
      context: expected,
      text: screen.text,
      firstLine: screen.firstLine,
      lastLine: screen.lastLine,
      truncated: screen.truncated,
    );
  }

  TerminalScreenSnapshot? readScreen(TerminalHistorySession expected, {int maxLines = 200, int maxBytes = 32768}) {
    if (!historySessionCurrent(expected)) return null;
    final screen = _screenProjection(maxLines, maxBytes);
    if (screen == null) return null;
    return TerminalScreenSnapshot(
      session: expected,
      text: screen.text,
      firstLine: screen.firstLine,
      lastLine: screen.lastLine,
      truncated: screen.truncated,
    );
  }

  ({String text, int firstLine, int lastLine, bool truncated})? _screenProjection(int maxLines, int maxBytes) {
    if (maxLines < 1 || maxLines > 200 || maxBytes < 1 || maxBytes > 32768) {
      throw ArgumentError('Invalid terminal snapshot limits');
    }
    final buffer = _terminal.buffer;
    final first = max(0, buffer.scrollBack);
    final last = min(buffer.height - 1, first + maxLines - 1);
    if (last < first) return null;
    final text = StringBuffer();
    var bytes = 0, includedLast = first;
    var truncated = last < buffer.height - 1;
    bool append(String value) {
      final size = utf8.encode(value).length;
      if (bytes + size > maxBytes) {
        truncated = true;
        return false;
      }
      text.write(value);
      bytes += size;
      return true;
    }

    rows:
    for (var row = first; row <= last; row++) {
      if (row > first && !append('\n')) break;
      final line = buffer.lines[row];
      var end = line.length;
      while (end > 0 && (line.getCodePoint(end - 1) == 0 || line.getCodePoint(end - 1) == 32)) {
        end--;
      }
      includedLast = row;
      for (var column = 0; column < end; column++) {
        if (line.getWidth(column) == 0) continue;
        final code = line.getCodePoint(column);
        if (!append('${String.fromCharCode(code == 0 ? 32 : code)}${line.getCombiningCharacters(column) ?? ''}')) {
          break rows;
        }
      }
    }
    return (text: text.toString(), firstLine: first, lastLine: includedLast, truncated: truncated);
  }

  bool browseCommand(CommandCompletionRequest request, CommandCandidate candidate) =>
      _browseCommand(request, candidate);
  bool returnCommandBrowse() => _returnCommandBrowse();

  /// Shell history echo must not start a new completion request.
  void browseShellHistory() {
    _historyBrowsing = true;
    _invalidateCommandDraft();
  }

  void reopenCommandCompletion() {
    if (!_historyBrowsing) return;
    _historyBrowsing = false;
    final request = _assistance.value.request;
    if (request != null) unawaited(_complete(request));
  }

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

  /// The marker in this session's shell environment (docs/MODULES.md §3).
  final _marker = [for (var i = 0; i < 8; i++) Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  late final _directory = _DirectoryNotifier(_following);
  String? _reported;
  final _lookups = <Timer>[];
  Future<String?>? _directoryLookup;
  CancellationToken? _directoryCancel;
  var _directoryRevision = 0;

  /// The shell's working directory, looked up only while something listens; null until known.
  ValueListenable<String?> get directory => _directory;

  final _listingTicks = ValueNotifier<int>(0);

  /// Bumped when a command may have changed the files a panel lists for this shell.
  ValueListenable<int> get listingTicks => _listingTicks;

  Timer? _localListing;

  set viewed(bool value) {
    if (_viewed == value) return;
    _viewed = value;
    if (value && unread) {
      unread = false;
      notifyListeners();
    }
  }

  /// Received from the shell but not yet parsed into the model.
  int get pendingOutputBytes => _outputQueue?.pendingBytes ?? 0;

  bool get canReconnect =>
      (isLocal || _prompts != null) && status != SessionStatus.connecting && status != SessionStatus.connected;

  bool get canInsert =>
      !_closed &&
      status == SessionStatus.connected &&
      !_shellEnded &&
      (isLocal
          ? _localPty != null
          : isRemote
          ? _shell != null
          : _shell != null && !(_lease?.lost ?? true));

  Future<InsertResult> insert(
    String text, {
    bool run = false,
    bool confirmMultiline = true,
    ConfirmInsert? confirm,
    CancellationToken? cancel,
  }) {
    final shell = _shell, lease = _lease, local = _localPty;
    // Closes the confirmation dialog when the caller cancels or this shell ends; the result stays decided by `current`.
    final dismiss = CancellationToken();
    _insertions.add(dismiss);
    unawaited(cancel?.whenCancelled.then((_) => dismiss.cancel()));
    return approveInsertion(
      preview: InsertPreview(targetLabel, text, run: run, cancellation: dismiss),
      confirmMultiline: confirmMultiline,
      confirm: confirm,
      cancel: cancel,
      current: () => canInsert && identical(_shell, shell) && identical(_lease, lease) && identical(_localPty, local),
      send: () {
        if (!run && _terminal.bracketedPasteMode && (text.contains('\n') || text.contains('\r'))) {
          final start = _echoedCommand(allowMultiline: true) != null ? _promptStartRow() : null;
          _pastedPromptLine = start != null ? _terminal.buffer.lines[start] : null;
        } else if (run) {
          _pastedPromptLine = null;
        }
        _terminal.paste(text);
        if (run) {
          _discardPendingCommandResult();
          _rememberCommand(text);
          _markCommandSubmitted();
          (local != null ? local.write : shell!.write)(utf8.encode('\r'));
          _entered();
        }
      },
    ).whenComplete(() => _insertions.remove(dismiss));
  }

  void _dismissInsertions() {
    for (final token in [..._insertions]) {
      token.cancel();
    }
  }

  /// A user's attempt: starts over the automatic retry budget.
  Future<void> connect([ConnectPrompts? prompts]) {
    _stopTimer();
    _attempts = 0;
    if (isLocal) {
      if (_closed || status == SessionStatus.connecting || status == SessionStatus.connected) return _localStopped;
      final previous = _localStopped;
      final pending = _connectLocal();
      _localStopped = Future.wait([previous, pending]).then((_) {});
      return pending;
    }
    if (isRemote) {
      return _connectRemote();
    }
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
    if (prompts == null || _closed || status == SessionStatus.connecting || status == SessionStatus.connected) {
      return;
    }
    _prompts = prompts;
    final cancel = CancellationToken();
    _connecting = cancel;
    ShellChannel? ownedShell;
    TransportLease? ownedLease;
    TerminalOutput? output;
    status = SessionStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final (lease, shell) = await _connections!.open(
        host,
        prompts,
        (lease) => lease.openShell(
          cols: _terminal.viewWidth,
          rows: _terminal.viewHeight,
          environment: {directoryVariable: _marker},
        ),
        cancel: cancel,
      );
      ownedShell = shell;
      ownedLease = lease;
      if (_closed) return;
      _lease = lease;
      _shell = shell;
      _shellEnded = false;
      _cancelDirectoryLookup();
      _resetCommandDraft();
      _ownedPaths = remotePaths == null ? LeaseRemotePathSource(lease, generation: _shellGeneration) : null;
      void ended() {
        if (!identical(_shell, shell)) return;
        _shellEnded = true;
        _cancelDirectoryLookup();
        if (!_closed) _resetCommandDraft();
        _dismissInsertions();
      }

      shell.done.then((_) => ended(), onError: (Object _) => ended());
      _terminal.onOutput = (data) {
        if (data.isEmpty) return;
        // A soft-keyboard Enter skips the view's submit hook; an inline task still needs its command recorded.
        if (data == '\r' && _aiTask?.awaiting == true) _submitCommand();
        final bracketedPaste = data.startsWith('\x1b[200~');
        if (data == '\x1b[A' || data == '\x1b[B' || data == '\x1bOA' || data == '\x1bOB') {
          _historyBrowsing = true;
        } else if (bracketedPaste ||
            (!data.startsWith('\x1b') &&
                (data.runes.any((rune) => rune >= 32 && rune != 127) || data == '\x7f' || data == '\b'))) {
          _historyBrowsing = false;
        }
        _inputSequence++;
        _inputPending = true;
        _invalidateCommandDraft();
        shell.write(utf8.encode(data));
        if (data.contains('\r') && !bracketedPaste) _entered();
        if (data.contains('\x03') || data.contains('\x04')) _pastedPromptLine = null;
      };
      _terminal.onResize = (cols, rows, _, _) => shell.resize(cols, rows);
      shell.resize(_terminal.viewWidth, _terminal.viewHeight);
      final consumer = TerminalOutput([shell.stdout, shell.stderr], (data) {
        if (!_closed && identical(_shell, shell)) _output(data);
      });
      output = consumer;
      _outputQueue = consumer;
      final transportEnded = lease.done.then(
        (_) {
          output?.finishInput();
        },
        onError: (Object _) {
          output?.finishInput();
        },
      );
      _attempts = 0;
      _set(SessionStatus.connected);
      if (_directory.followed) _lookSoon(const [Duration(milliseconds: 400)]);
      await Future.any([shell.done, transportEnded, consumer.failed]).catchError((_) {});
      ended();
      // SSH's done can precede EOF delivery: parse the queued tail before ending this shell's generation.
      await consumer.done;
      if (consumer.error case final e?) throw ConnectError(ConnectFailure.network, '$e');
      // A shell that ended on its own (`exit`) leaves the transport up; only a lost transport is retried.
      final lost = lease.lost;
      _set(SessionStatus.disconnected);
      if (lost && status == SessionStatus.disconnected) _scheduleReconnect();
    } on ConnectError catch (e) {
      error = e;
      _set(SessionStatus.failed);
      if (e.kind == ConnectFailure.network && _attempts > 0 && status == SessionStatus.failed) {
        _scheduleReconnect();
      }
    } on Object catch (e) {
      error = ConnectError(ConnectFailure.network, '$e');
      _set(SessionStatus.failed);
    } finally {
      output?.cancel();
      if (identical(_outputQueue, output)) _outputQueue = null;
      output = null;
      if (identical(_connecting, cancel)) _connecting = null;
      if (identical(_shell, ownedShell)) {
        _cancelDirectoryLookup();
        _terminal.onOutput = null;
        _terminal.onResize = null;
        _dismissInsertions();
        _shell = null;
        _shellEnded = true;
      }
      ownedShell?.close();
      ownedLease?.release();
      if (identical(_lease, ownedLease)) _lease = null;
    }
  }

  Future<void> _connectLocal() async {
    if (_closed || status == SessionStatus.connecting || status == SessionStatus.connected) return;
    final cancel = CancellationToken();
    _connecting = cancel;
    LocalPty? owned;
    TerminalOutput? output;
    status = SessionStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final pty = await _localPtyFactory!.start(
        localShell!,
        cols: max(1, _terminal.viewWidth),
        rows: max(1, _terminal.viewHeight),
        cancel: cancel,
      );
      owned = pty;
      if (_closed || cancel.isCancelled) return;
      _localPty = pty;
      _shellEnded = false;
      _cancelDirectoryLookup();
      _resetCommandDraft();
      void ended() {
        if (!identical(_localPty, pty)) return;
        _shellEnded = true;
        if (!_closed) _resetCommandDraft();
        _dismissInsertions();
      }

      _terminal.onOutput = (data) {
        if (data.isEmpty || _shellEnded) return;
        if (data == '\r' && _aiTask?.awaiting == true) _submitCommand();
        final bracketedPaste = data.startsWith('\x1b[200~');
        if (data == '\x1b[A' || data == '\x1b[B' || data == '\x1bOA' || data == '\x1bOB') {
          _historyBrowsing = true;
        } else if (bracketedPaste ||
            (!data.startsWith('\x1b') &&
                (data.runes.any((rune) => rune >= 32 && rune != 127) || data == '\x7f' || data == '\b'))) {
          _historyBrowsing = false;
        }
        _inputSequence++;
        _inputPending = true;
        _invalidateCommandDraft();
        pty.write(utf8.encode(data));
        if (data.contains('\r') && !bracketedPaste) _entered();
        if (data.contains('\x03') || data.contains('\x04')) _pastedPromptLine = null;
      };
      _terminal.onResize = (cols, rows, _, _) => pty.resize(cols, rows);
      pty.resize(_terminal.viewWidth, _terminal.viewHeight);
      final consumer = TerminalOutput([pty.output], (data) {
        if (!_closed && identical(_localPty, pty)) _output(data);
      });
      output = consumer;
      _outputQueue = consumer;
      _set(SessionStatus.connected);
      final exit = pty.exitCode.then<void>((_) => ended(), onError: (Object _) => ended());
      await Future.any([exit, consumer.failed]);
      if (consumer.error != null) pty.close();
      await exit;
      await consumer.done;
      if (consumer.error != null) throw StateError('Local terminal output failed');
      _set(SessionStatus.disconnected);
    } on Object {
      if (!_closed) {
        error = const ConnectError(ConnectFailure.network);
        _set(SessionStatus.failed);
      }
    } finally {
      output?.cancel();
      if (identical(_outputQueue, output)) _outputQueue = null;
      if (identical(_connecting, cancel)) _connecting = null;
      if (identical(_localPty, owned)) {
        _terminal.onOutput = null;
        _terminal.onResize = null;
        _dismissInsertions();
        _localPty = null;
        _shellEnded = true;
      }
      owned?.close();
      if (owned != null) await owned.exitCode.catchError((Object _) => -1);
    }
  }

  Future<void> _connectRemote() async {
    if (_closed || status == SessionStatus.connecting || status == SessionStatus.connected) return;
    final opener = _remoteOpener;
    if (opener == null) return;
    ShellChannel? ownedShell;
    TerminalOutput? output;
    status = SessionStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final shell = await opener(max(1, _terminal.viewWidth), max(1, _terminal.viewHeight));
      ownedShell = shell;
      if (_closed) return;
      _shell = shell;
      _shellEnded = false;
      _resetCommandDraft();
      void ended() {
        if (!identical(_shell, shell)) return;
        _shellEnded = true;
        if (!_closed) _resetCommandDraft();
        _dismissInsertions();
      }

      shell.done.then((_) => ended(), onError: (Object _) => ended());
      _terminal.onOutput = (data) {
        if (data.isEmpty || _shellEnded) return;
        if (data == '\r' && _aiTask?.awaiting == true) _submitCommand();
        _inputSequence++;
        _inputPending = true;
        shell.write(utf8.encode(data));
      };
      _terminal.onResize = (cols, rows, _, _) => shell.resize(cols, rows);
      final consumer = TerminalOutput([shell.stdout, shell.stderr], (data) {
        if (!_closed && identical(_shell, shell)) _output(data);
      });
      output = consumer;
      _outputQueue = consumer;
      _set(SessionStatus.connected);
      await Future.any([shell.done, consumer.failed]).catchError((_) {});
      ended();
      await consumer.done;
      if (consumer.error != null) throw ConnectError(ConnectFailure.network, '${consumer.error}');
      _set(SessionStatus.disconnected);
    } on ConnectError catch (e) {
      error = e;
      _set(SessionStatus.failed);
    } on Object catch (e) {
      error = ConnectError(ConnectFailure.network, '$e');
      _set(SessionStatus.failed);
    } finally {
      output?.cancel();
      if (identical(_outputQueue, output)) _outputQueue = null;
      if (identical(_shell, ownedShell)) {
        _terminal.onOutput = null;
        _terminal.onResize = null;
        _dismissInsertions();
        _shell = null;
        _shellEnded = true;
      }
      ownedShell?.close();
    }
  }

  void _output(String data) {
    if (_mirrorOut.hasListener && data.isNotEmpty) {
      _mirrorOut.add(Uint8List.fromList(utf8.encode(data)));
    }
    _scanCommandResult(data);
    _terminal.write(data);
    _inputPending = false;
    final buffer = _terminal.buffer;
    final row = buffer.absoluteCursorY;
    if (_submittedLine != null && row >= 0 && row < buffer.lines.length) {
      final text = _rowText(row, 0, buffer.cursorX);
      if (data.contains('\n') ||
          !identical(buffer.lines[row], _submittedLine) ||
          (text != _submittedText && visibleShellCommand(text, '') != null)) {
        _submittedLine = null;
        _submittedText = null;
      }
    }
    _finishRecognizedCommandResult();
    _syncCommandDraft();
    if (!_viewed && !unread) {
      unread = true;
      notifyListeners();
    }
  }

  /// Enter may have run a `cd`: look once the shell has had time, and again for a slow one.
  void _entered() {
    _directoryRevision++;
    _cancelDirectoryLookup();
    _reported = null;
    _directory.value = null;
    (remotePaths ?? _ownedPaths)?.invalidate();
    if (_directory.followed) _lookSoon(const [Duration(milliseconds: 400), Duration(milliseconds: 1500)]);
    // A local shell has no marker to query, so a listing refresh follows the command once its output has settled.
    _localListing?.cancel();
    if (isLocal) {
      _localListing = Timer(const Duration(milliseconds: 1200), () {
        if (!_closed && !_shellEnded) _listingTicks.value++;
      });
    }
  }

  void _following(bool on) {
    if (on) {
      _lookSoon(const [Duration.zero]);
    } else {
      _cancelLookups();
    }
  }

  void _lookSoon(List<Duration> delays) {
    _cancelLookups();
    for (final d in delays) {
      _lookups.add(Timer(d, _look));
    }
  }

  void _cancelLookups() {
    for (final t in _lookups) {
      t.cancel();
    }
    _lookups.clear();
  }

  void _cancelDirectoryLookup() {
    _directoryCancel?.cancel();
    _directoryCancel = null;
    _directoryLookup = null;
  }

  /// The current shell reported semantic prompts, from Sshairy's integration or the user's own.
  bool get shellIntegrated => _semanticSeen;

  /// Installs or removes shell integration for this connection's login user; takes effect in new shells.
  Future<bool> setShellIntegration(bool install) async {
    final lease = _lease;
    if (_closed || lease == null || lease.lost) return false;
    try {
      final result = await lease.exec(
        install ? shellIntegrationInstall : shellIntegrationRemove,
        limit: 4096,
        timeout: const Duration(seconds: 10),
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Future<String?> _look({bool force = false}) async {
    final lease = _lease, generation = _shellGeneration, revision = _directoryRevision;
    if (_closed || _shellEnded || lease == null || lease.lost || (!force && !_directory.followed)) {
      return _directory.value;
    }
    final pending = _directoryLookup;
    if (pending != null) return pending;
    final cancel = _directoryCancel = CancellationToken();
    Future<String?> query() async {
      String? found;
      try {
        final result = await lease.exec(
          directoryQuery(_marker),
          limit: 4096,
          timeout: const Duration(seconds: 5),
          cancel: cancel,
        );
        found = parseDirectoryQuery(utf8.decode(result.stdout, allowMalformed: true));
      } on Object {
        found = null;
      }
      if (_closed ||
          cancel.isCancelled ||
          generation != _shellGeneration ||
          revision != _directoryRevision ||
          !identical(_lease, lease)) {
        return null;
      }
      // A server that refused the marker or has no /proc may still report through OSC 7.
      found ??= _reported;
      if (found != null) {
        _directory.value = found;
        // The lookup follows a finished command, so what the panel lists for this shell is stale.
        _listingTicks.value++;
      }
      return found;
    }

    final lookup = query();
    _directoryLookup = lookup;
    try {
      return await lookup;
    } finally {
      if (identical(_directoryLookup, lookup)) _directoryLookup = null;
      if (identical(_directoryCancel, cancel)) _directoryCancel = null;
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
    if (_closed) return;
    _closed = true;
    _shellEnded = true;
    _cancelCompletion();
    _ownedPaths?.dispose();
    _ownedPaths = null;
    _commands.clear();
    _clearAiHistory();
    _stopAiTask();
    multilineDraft = '';
    _history.value = const [];
    _assistance.value = const CommandAssistanceState();
    _submittedLine = null;
    _submittedText = null;
    _pastedPromptLine = null;
    _history.dispose();
    _assistance.dispose();
    _dismissInsertions();
    _stopTimer();
    _cancelLookups();
    _cancelDirectoryLookup();
    _localListing?.cancel();
    _directory.dispose();
    _listingTicks.dispose();
    _connecting?.cancel();
    _outputQueue?.cancel();
    _terminal.onOutput = null;
    _terminal.onResize = null;
    _shell?.close();
    _localPty?.close();
    _localPty = null;
    _shell = null;
    _lease?.release();
    _lease = null;
    if (!_mirrorOut.isClosed) unawaited(_mirrorOut.close());
    dispose();
  }
}

/// Tells the session when the first listener arrives and the last one leaves, so lookups run only while followed.
class _DirectoryNotifier extends ValueNotifier<String?> {
  _DirectoryNotifier(this._following) : super(null);

  final void Function(bool on) _following;
  final changes = ChangeNotifier();

  bool get followed => hasListeners;

  @override
  void notifyListeners() {
    super.notifyListeners();
    changes.notifyListeners();
  }

  @override
  void dispose() {
    changes.dispose();
    super.dispose();
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) _following(true);
  }

  @override
  void removeListener(VoidCallback listener) {
    final had = hasListeners;
    super.removeListener(listener);
    if (had && !hasListeners) _following(false);
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
    searchHitForeground: p.searchHitForeground,
  );
}
