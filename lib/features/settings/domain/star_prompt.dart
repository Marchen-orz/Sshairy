/// Pure timing rules and persisted state for the non-blocking GitHub Star reminder (docs/UI.md §5).
class StarPromptSchedule {
  const StarPromptSchedule({
    this.firstPromptUsage = const Duration(minutes: 30),
    this.repeatCooldown = const Duration(days: 7),
    this.repeatUsage = const Duration(minutes: 30),
  });

  /// Accumulated foreground usage required before the first reminder.
  final Duration firstPromptUsage;

  /// Minimum wall-clock time after a shown reminder before another can appear.
  final Duration repeatCooldown;

  /// Additional foreground usage required after a shown reminder before another can appear.
  final Duration repeatUsage;

  bool shouldPrompt(StarPromptState state, DateTime now) {
    if (state.dismissed) return false;
    final last = state.lastPromptedAt;
    if (last == null) return state.activeSeconds >= firstPromptUsage.inSeconds;
    return now.toUtc().difference(last.toUtc()) >= repeatCooldown && state.activeSeconds >= repeatUsage.inSeconds;
  }
}

class StarPromptState {
  const StarPromptState({this.dismissed = false, this.activeSeconds = 0, this.lastPromptedAt});

  /// Caps a single tick so waking from sleep cannot suddenly count as continuous foreground use.
  static const maxTickSeconds = 300;

  final bool dismissed;

  /// Foreground usage seconds accumulated since install or since [lastPromptedAt].
  final int activeSeconds;

  final DateTime? lastPromptedAt;

  StarPromptState addUsage(Duration elapsed) {
    final seconds = elapsed.inSeconds;
    if (dismissed || seconds <= 0) return this;
    final delta = seconds > maxTickSeconds ? maxTickSeconds : seconds;
    return StarPromptState(dismissed: dismissed, activeSeconds: activeSeconds + delta, lastPromptedAt: lastPromptedAt);
  }

  StarPromptState markShown(DateTime now) =>
      StarPromptState(dismissed: dismissed, activeSeconds: 0, lastPromptedAt: now.toUtc());

  StarPromptState markDismissed() =>
      StarPromptState(dismissed: true, activeSeconds: activeSeconds, lastPromptedAt: lastPromptedAt);

  factory StarPromptState.fromJson(Object? raw) {
    if (raw is! Map) return const StarPromptState();
    final dismissed = raw['dismissed'] == true;
    final secondsRaw = raw['activeSeconds'];
    final activeSeconds = secondsRaw is int && secondsRaw >= 0 ? secondsRaw : 0;
    final promptedRaw = raw['lastPromptedAt'];
    final lastPromptedAt = promptedRaw is String ? DateTime.tryParse(promptedRaw)?.toUtc() : null;
    return StarPromptState(dismissed: dismissed, activeSeconds: activeSeconds, lastPromptedAt: lastPromptedAt);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'dismissed': dismissed,
    'activeSeconds': activeSeconds,
    if (lastPromptedAt != null) 'lastPromptedAt': lastPromptedAt!.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is StarPromptState &&
      other.dismissed == dismissed &&
      other.activeSeconds == activeSeconds &&
      other.lastPromptedAt == lastPromptedAt;

  @override
  int get hashCode => Object.hash(dismissed, activeSeconds, lastPromptedAt);
}
