import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/json_file.dart';
import '../domain/local_profile.dart';

final localProfilesProvider = NotifierProvider<LocalProfiles, List<LocalProfile>>(LocalProfiles.new);

/// Owns local_terminals.json; writes land before the list changes.
class LocalProfiles extends Notifier<List<LocalProfile>> {
  late final _file = JsonFile(
    '${ref.read(dataDirProvider)}/local_terminals.json',
    backups: true,
    validate: (json) {
      if (json['terminals'] is! List) throw const FormatException('invalid local terminals');
      final ids = <String>{};
      for (final entry in json['terminals'] as List) {
        final profile = LocalProfile.fromJson((entry as Map).cast());
        profile.validate();
        if (!ids.add(profile.id)) throw const FormatException('duplicate local terminal');
      }
    },
  );
  Future<void> _pending = Future.value();

  /// The file behind this state, for restoring a snapshot from settings.
  JsonFile get storage => _file;

  @override
  List<LocalProfile> build() => List.unmodifiable([
    for (final entry in _file.read()?['terminals'] as List<dynamic>? ?? const [])
      LocalProfile.fromJson((entry as Map).cast()),
  ]);

  Future<void> get saved => _pending.then((_) => _file.idle);

  Future<void> _change(List<LocalProfile> Function() change) {
    final next = _pending.then((_) async {
      final items = change();
      await _file.write({
        'schemaVersion': 1,
        'terminals': [for (final p in items) p.toJson()],
      });
      state = List.unmodifiable(items);
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> save(LocalProfile profile) => _change(() {
    profile.validate();
    final index = state.indexWhere((p) => p.id == profile.id);
    return index < 0 ? [...state, profile] : ([...state]..[index] = profile);
  });

  Future<void> delete(String id) => _change(() => state.where((p) => p.id != id).toList());
}
