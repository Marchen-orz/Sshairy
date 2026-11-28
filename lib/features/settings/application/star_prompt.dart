import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/open_external.dart';
import '../../../platform/device_form_factor.dart';
import '../../../platform/mobile_platform.dart';
import '../domain/star_prompt.dart';

const githubRepositoryUrl = 'https://github.com/Marchen-orz/Sshairy';

abstract class StarPromptStore {
  StarPromptState load();
  Future<void> save(StarPromptState state);
}

/// Stores reminder progress in its own lightweight JSON file so periodic usage flushes never touch
/// settings.json revisions or backup snapshots. Corrupt or unreadable files fall back to defaults.
class FileStarPromptStore implements StarPromptStore {
  FileStarPromptStore(this.path);

  final String path;
  static var _serial = 0;

  @override
  StarPromptState load() {
    try {
      final file = File(path);
      if (!file.existsSync()) return const StarPromptState();
      return StarPromptState.fromJson(jsonDecode(file.readAsStringSync()));
    } on Object {
      return const StarPromptState();
    }
  }

  @override
  Future<void> save(StarPromptState state) async {
    File? tmp;
    try {
      final target = File(path);
      await target.parent.create(recursive: true);
      tmp = File('$path.$pid.${DateTime.now().microsecondsSinceEpoch}-${_serial++}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(state.toJson()), flush: true);
      await tmp.rename(path);
      tmp = null;
    } on Object {
      // Non-critical reminder state must never surface an error to the user.
    } finally {
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } on Object {
        // Ignore cleanup failures.
      }
    }
  }
}

final starPromptStoreProvider = Provider<StarPromptStore>(
  (ref) => FileStarPromptStore('${ref.read(dataDirProvider)}/star_prompt.json'),
);

final starPromptClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

final starPromptScheduleProvider = Provider<StarPromptSchedule>((_) => const StarPromptSchedule());

final starPromptOpenUrlProvider = Provider<Future<bool> Function(String)>(
  (_) => (url) => isAndroidPlatform ? MobilePlatform.openUrl(url) : openExternal(url),
);

class StarPromptViewState {
  const StarPromptViewState({required this.visible, required this.record});

  final bool visible;
  final StarPromptState record;
}

class StarPromptNotifier extends Notifier<StarPromptViewState> {
  static const flushInterval = Duration(minutes: 5);

  late StarPromptStore _store;
  var _unsavedSeconds = 0;
  Future<void> _pending = Future.value();

  Future<void> get saved => _pending;

  @override
  StarPromptViewState build() {
    _store = ref.read(starPromptStoreProvider);
    _unsavedSeconds = 0;
    return StarPromptViewState(visible: false, record: _store.load());
  }

  void tick(Duration elapsed, {required bool canShow}) {
    final current = state;
    if (current.record.dismissed || current.visible || elapsed <= Duration.zero) return;
    final next = current.record.addUsage(elapsed);
    final added = next.activeSeconds - current.record.activeSeconds;
    if (added <= 0) return;
    _unsavedSeconds += added;
    final now = ref.read(starPromptClockProvider)();
    final schedule = ref.read(starPromptScheduleProvider);
    if (canShow && schedule.shouldPrompt(next, now)) {
      final shown = next.markShown(now);
      state = StarPromptViewState(visible: true, record: shown);
      _unsavedSeconds = 0;
      unawaited(_persist(shown));
      return;
    }
    state = StarPromptViewState(visible: false, record: next);
    if (_unsavedSeconds >= flushInterval.inSeconds) {
      _unsavedSeconds = 0;
      unawaited(_persist(next));
    }
  }

  Future<void> flush() {
    if (_unsavedSeconds <= 0) return _pending;
    final record = ref.mounted ? state.record : null;
    if (record == null) return _pending;
    _unsavedSeconds = 0;
    return _persist(record);
  }

  Future<void> star() async {
    final next = state.record.markDismissed();
    state = StarPromptViewState(visible: false, record: next);
    _unsavedSeconds = 0;
    await _persist(next);
    await ref.read(starPromptOpenUrlProvider)(githubRepositoryUrl);
  }

  void later() {
    if (!state.visible) return;
    state = StarPromptViewState(visible: false, record: state.record);
  }

  Future<void> neverRemind() {
    final next = state.record.markDismissed();
    state = StarPromptViewState(visible: false, record: next);
    _unsavedSeconds = 0;
    return _persist(next);
  }

  Future<void> _persist(StarPromptState record) {
    final next = _pending.then((_) => _store.save(record));
    _pending = next.catchError((Object _) {});
    return next;
  }
}

final starPromptProvider = NotifierProvider<StarPromptNotifier, StarPromptViewState>(StarPromptNotifier.new);
