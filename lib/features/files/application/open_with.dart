import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/data_dir.dart';
import '../../../foundation/json_file.dart';
import '../../../foundation/result.dart';
import '../adapters/open_with.dart';
import '../domain/open_with.dart';

/// Separate so the edit flow can run without starting a program.
final editorLauncherProvider = Provider<EditorLauncher>((_) => PlatformEditorLauncher());

final editorAppsProvider = NotifierProvider<EditorAppsNotifier, EditorApps>(EditorAppsNotifier.new);

/// The program each file type opens with. It stays in its own file and is not a setting: a setting can be written
/// through the command palette and the agent, and this one names a program to start (docs/EXTERNAL_EDITS.md).
class EditorAppsNotifier extends Notifier<EditorApps> {
  late final JsonFile _file = JsonFile('${ref.read(dataDirProvider)}/editor_apps.json', validate: EditorApps.validate);

  @override
  EditorApps build() {
    try {
      final json = _file.read();
      return json == null ? const EditorApps() : EditorApps.fromJson(json);
    } on Object {
      // A preference is not worth stopping the start for; the damaged file stays where it is (JsonFile blocks
      // writes over it), so choices last until the app closes.
      return const EditorApps();
    }
  }

  Future<void> get saved => _file.idle.then((_) {}, onError: (Object _) {});

  /// Makes [app] the program for the type of [fileName]; null or the system association goes back to the system.
  /// The choice applies at once; the error is only about keeping it for the next start.
  Future<Result<void>> setDefault(String fileName, OpenWithApp? app) async {
    state = state.withDefault(fileName, app);
    try {
      await _file.write(state.toJson());
      return const Ok(null);
    } on JsonFileError catch (error) {
      return Err(AppError('saveFailed', detail: error.kind.name));
    }
  }
}
