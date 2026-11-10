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
import '../domain/local_pty.dart';
import '../domain/terminal_target.dart';
import '../domain/terminal_paths.dart';
import '../domain/spec_completion.dart';
import 'terminal_paths.dart';
import 'completion_specs.dart';
import 'completion_translations.dart';
import '../presentation/confirm_insert.dart';
import 'ime_caret.dart';
import 'command_descriptions.dart';
import 'terminal_output.dart';

part 'terminal_pane.dart';
part 'terminal_search.dart';
part 'terminal_assistance.dart';
part 'terminal_assistance_ui.dart';
part 'terminal_input_overlays.dart';
part 'terminal_ai.dart';

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
       _terminal = Terminal(maxLines: scrollback),
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
       _terminal = Terminal(maxLines: scrollback),
       _autoReconnect = (() => false),
       _completionSpecs = completionSpecs ?? CompletionSpecs.shared,
       _translations = completionTranslations,
       _snippets = snippets ?? (() => const []),
       remotePaths = null {
    _configureTerminal();
  }

  void _configureTerminal() {
    _terminal.onSemanticPrompt = _semanticPrompt;
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
  bool get isLocal => target is LocalTerminalTarget;
  String get title => _sshHost?.title ?? localShell!.name;
  String get targetLabel => _sshHost?.target ?? localShell!.name;

  /// UI draft only; it never enters the layout, history or application notifications.
  String multilineDraft = '';

  /// False for restored tabs: the first view shows a connect button instead of dialling (docs/MODULES.md §3).
  final bool autoConnect;
  final ConnectionManager? _connections;
  final LocalPtyFactory? _localPtyFactory;
  LocalPty? _localPty;
  Future<void> _localStopped = Future.value();
  Future<void> get stopped => _localStopped;
  final bool Function() _autoReconnect;
  final Terminal _terminal;
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
  String inlineAiDraft = '', inlineAiCommand = '';
  TerminalAiContext? inlineAiContext;
  TerminalAiGeneration? inlineAiResult;
  final _history = ValueNotifier<List<String>>(const []);
  final _assistance = ValueNotifier<CommandAssistanceState>(const CommandAssistanceState());
  Timer? _completionTimer;
  CancellationToken? _completionCancel;
  var _shellGeneration = 0, _draftRevision = 0;
  var _semanticSeen = false, _semanticInput = false;
  int? _promptRow, _promptColumn;
  BufferLine? _submittedLine;
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
    _aiHistory.clear();
    _history.value = const [];
    _invalidateCommandDraft();
    _syncCommandDraft();
  }

  Future<InsertResult> acceptCommand(CommandCompletionRequest request, String text) => _acceptCommand(request, text);

  @override
  TerminalAiContext readAiContext() {
    final echoed = pendingOutputBytes == 0 ? _echoedCommand() : null;
    final draft = echoed != null && (echoed.isEmpty || validTerminalAiCommand(echoed)) ? echoed : null;
    return TerminalAiContext(
      sessionId: id,
      target: switch (target) {
        SshTerminalTarget(:final hostId) => SshTerminalAiTarget(hostId),
        LocalTerminalTarget(:final shell) => LocalTerminalAiTarget(shell.kind),
      },
      generation: _shellGeneration,
      revision: _draftRevision,
      prompt: !canInsert
          ? TerminalAiPrompt.unavailable
          : draft == null
          ? TerminalAiPrompt.unknown
          : _semanticSeen
          ? TerminalAiPrompt.semantic
          : TerminalAiPrompt.recognized,
      draft: draft,
      directory: _directory.value,
    );
  }

  bool _aiContextCurrent(TerminalAiContext expected) {
    final current = readAiContext();
    return current.ready && expected.ready && sameTerminalAiContext(current, expected);
  }

  List<TerminalAiHistoryEntry> readAiHistory(TerminalAiContext expected) {
    if (!_aiContextCurrent(expected)) return const [];
    final entries = <TerminalAiHistoryEntry>[];
    var bytes = 0;
    for (final entry in _aiHistory.reversed) {
      if (entry.generation != expected.generation) continue;
      final size = utf8.encode(entry.text).length;
      if (entries.length >= 8 || bytes + size > 4096) break;
      entries.add(entry);
      bytes += size;
    }
    return List.unmodifiable(entries.reversed);
  }

  @override
  Future<InsertResult> acceptAiDraft(TerminalAiContext expected, String text, {bool suffix = false}) {
    if (!canInsert) return Future.value(InsertResult.unavailable);
    if (!validTerminalAiCommand(text) || (suffix && utf8.encode(text).length > 2048)) {
      return Future.value(InsertResult.rejected);
    }
    if (!_aiContextCurrent(expected)) return Future.value(InsertResult.stale);
    if (!suffix && expected.draft!.isNotEmpty) return Future.value(InsertResult.rejected);
    final command = suffix ? '${expected.draft}$text' : text;
    if (!validTerminalAiCommand(command)) return Future.value(InsertResult.rejected);
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

  @override
  TerminalAiSnapshot? readAiSnapshot(TerminalAiContext expected, {int maxLines = 200, int maxBytes = 32768}) {
    if (maxLines < 1 || maxLines > 200 || maxBytes < 1 || maxBytes > 32768) {
      throw ArgumentError('Invalid terminal snapshot limits');
    }
    if (!_aiContextCurrent(expected)) return null;
    final buffer = _terminal.buffer;
    final last = buffer.absoluteCursorY;
    if (last < 0 || last >= buffer.lines.length) return null;
    final first = max(0, last - maxLines + 1);
    final text = StringBuffer();
    var bytes = 0, includedLast = first;
    var truncated = first > 0;
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
    return TerminalAiSnapshot(
      context: expected,
      text: text.toString(),
      firstLine: first,
      lastLine: includedLast,
      truncated: truncated,
    );
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
      (isLocal ? _localPty != null : _shell != null && !(_lease?.lost ?? true));

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
        _terminal.paste(text);
        if (run) {
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
        if (data == '\x1b[A' || data == '\x1b[B' || data == '\x1bOA' || data == '\x1bOB') {
          _historyBrowsing = true;
        } else if (!data.startsWith('\x1b') &&
            (data.runes.any((rune) => rune >= 32 && rune != 127) || data == '\x7f' || data == '\b')) {
          _historyBrowsing = false;
        }
        _inputPending = true;
        _invalidateCommandDraft();
        shell.write(utf8.encode(data));
        if (data.contains('\r')) _entered();
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
        if (data == '\x1b[A' || data == '\x1b[B' || data == '\x1bOA' || data == '\x1bOB') {
          _historyBrowsing = true;
        } else if (!data.startsWith('\x1b') &&
            (data.runes.any((rune) => rune >= 32 && rune != 127) || data == '\x7f' || data == '\b')) {
          _historyBrowsing = false;
        }
        _inputPending = true;
        _invalidateCommandDraft();
        pty.write(utf8.encode(data));
        if (data.contains('\r')) _entered();
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

  void _output(String data) {
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
      if (found != null) _directory.value = found;
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
    _aiHistory.clear();
    inlineAiDraft = inlineAiCommand = '';
    inlineAiContext = null;
    inlineAiResult = null;
    multilineDraft = '';
    _history.value = const [];
    _assistance.value = const CommandAssistanceState();
    _submittedLine = null;
    _submittedText = null;
    _history.dispose();
    _assistance.dispose();
    _dismissInsertions();
    _stopTimer();
    _cancelLookups();
    _cancelDirectoryLookup();
    _directory.dispose();
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
