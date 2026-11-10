import 'package:flutter/widgets.dart';

/// A form retains its own draft and save rules; a containing surface only coordinates the actions.
class FormSaveEntry {
  const FormSaveEntry({
    required this.dirty,
    required this.canSave,
    required this.save,
    required this.reset,
    required this.context,
  });

  final bool Function() dirty, canSave;
  final Future<bool> Function() save;
  final VoidCallback reset;
  final BuildContext? Function() context;
}

class FormSaveController extends ChangeNotifier {
  final _entries = <FormSaveEntry>[];
  var _busy = false, _scheduled = false, _disposed = false;
  List<(FormSaveEntry, bool, bool)> _reported = [];

  bool get busy => _busy;
  bool get dirty => _entries.any((entry) => entry.dirty());
  bool get canSave => !_busy && dirty && _entries.where((entry) => entry.dirty()).every((entry) => entry.canSave());

  void register(FormSaveEntry entry) {
    _entries.add(entry);
    changed();
  }

  void unregister(FormSaveEntry entry) {
    _entries.remove(entry);
    changed();
  }

  /// Forms may report while building; listeners are notified only after layout and only for real changes.
  void changed() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      final next = [for (final entry in _entries) (entry, entry.dirty(), entry.canSave())];
      if (next.length == _reported.length &&
          Iterable<int>.generate(next.length).every((index) => next[index] == _reported[index])) {
        return;
      }
      _reported = next;
      notifyListeners();
    });
  }

  Future<BuildContext?> save() async {
    if (!canSave) return null;
    _busy = true;
    notifyListeners();
    try {
      for (final entry in _entries.toList()) {
        if (_disposed || !_entries.contains(entry)) return null;
        if (!entry.dirty()) continue;
        if (!entry.canSave() || !await entry.save()) return entry.context();
      }
      return null;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void reset() {
    if (_busy) return;
    for (final entry in _entries.toList()) {
      if (entry.dirty()) entry.reset();
    }
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _entries.clear();
    super.dispose();
  }
}

class FormSaveScope extends InheritedWidget {
  const FormSaveScope({super.key, required this.controller, required super.child});

  final FormSaveController controller;

  static FormSaveController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FormSaveScope>()?.controller;

  @override
  bool updateShouldNotify(FormSaveScope oldWidget) => controller != oldWidget.controller;
}
