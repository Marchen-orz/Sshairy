import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/configuration.dart';
import 'package:sshairy/features/files/application/edits.dart';
import 'package:sshairy/foundation/data_dir.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-edits-'));
  tearDown(() => dir.deleteSync(recursive: true));

  String at(String relative) => '${dir.path}${Platform.pathSeparator}$relative';

  /// An edit copy at the location ExternalEdits owns, recorded in edits.json.
  String craft({String id = 'edit-1', bool unsaved = false, String? localPath}) {
    final copy = File(at('edits${Platform.pathSeparator}$id${Platform.pathSeparator}notes.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('draft');
    File(at('edits.json')).writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'edits': [
          {
            'id': id,
            'host': 'h1',
            'hostLabel': 'box',
            'remotePath': '/home/u/notes.txt',
            'localPath': localPath ?? copy.path,
            'size': 5,
            'unsaved': unsaved,
            'autoUpload': true,
          },
        ],
      }),
    );
    return copy.path;
  }

  ProviderContainer open({Future<void> Function(String)? cleanup}) {
    final container = ProviderContainer(
      overrides: [
        dataDirProvider.overrideWithValue(dir.path),
        if (cleanup != null) editCleanupProvider.overrideWithValue(cleanup),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Map<String, dynamic> saved() => (jsonDecode(File(at('edits.json')).readAsStringSync()) as Map).cast();

  test('finishing removes the copy directory and the record', () async {
    final copy = craft();
    final container = open();
    final edits = container.read(editsProvider.notifier);
    expect(container.read(editsProvider), hasLength(1));

    await edits.finish('edit-1');

    expect(container.read(editsProvider), isEmpty);
    expect(File(copy).parent.existsSync(), isFalse);
    expect(saved()['edits'], isEmpty);
  });

  test('a copy that cannot be deleted keeps its record, stops auto upload and can be finished again', () async {
    final copy = craft(unsaved: true);
    var locked = true;
    final attempts = <String>[];
    final container = open(
      cleanup: (path) async {
        attempts.add(path);
        if (locked) throw const FileSystemException('locked by editor');
        await Directory(path).delete(recursive: true);
      },
    );
    final edits = container.read(editsProvider.notifier);

    await edits.finish('edit-1');

    expect(attempts, hasLength(3));
    final stuck = container.read(editsProvider).single;
    expect(stuck.state, EditState.failed);
    expect(stuck.error, 'cleanupFailed');
    expect(stuck.autoUpload, isFalse);
    expect(File(copy).existsSync(), isTrue);
    expect((saved()['edits'] as List).single['unsaved'], isTrue);
    expect((saved()['edits'] as List).single.containsKey('autoUpload'), isFalse);

    locked = false;
    await edits.finish('edit-1');

    expect(container.read(editsProvider), isEmpty);
    expect(File(copy).parent.existsSync(), isFalse);
    expect(saved()['edits'], isEmpty);
  });

  test('a transient deletion failure is retried before the record is touched', () async {
    final copy = craft();
    var calls = 0;
    final container = open(
      cleanup: (path) async {
        if (++calls < 3) throw const FileSystemException('busy');
        await Directory(path).delete(recursive: true);
      },
    );

    await container.read(editsProvider.notifier).finish('edit-1');

    expect(calls, 3);
    expect(container.read(editsProvider), isEmpty);
    expect(File(copy).parent.existsSync(), isFalse);
  });

  test('concurrent finish calls share one cleanup', () async {
    craft();
    var calls = 0;
    final container = open(
      cleanup: (path) async {
        calls++;
        await Directory(path).delete(recursive: true);
      },
    );
    final edits = container.read(editsProvider.notifier);

    await Future.wait([edits.finish('edit-1'), edits.finish('edit-1')]);

    expect(calls, 1);
    expect(container.read(editsProvider), isEmpty);
  });

  test('history outside the owned layout enters the configuration gate and deletes nothing', () {
    final outside = File(at('outside${Platform.pathSeparator}keep.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep');
    for (final (id, local) in [
      ('edit-1', outside.path),
      ('..${Platform.pathSeparator}outside', outside.path),
      ('x/y', at('edits${Platform.pathSeparator}x${Platform.pathSeparator}y${Platform.pathSeparator}notes.txt')),
    ]) {
      craft(id: 'edit-1', localPath: local);
      final json = saved();
      (json['edits'] as List).single['id'] = id;
      final original = jsonEncode(json);
      File(at('edits.json')).writeAsStringSync(original);

      final container = open(cleanup: (_) async => fail('nothing may be deleted for invalid history'));
      expect(container.read(configurationCheckProvider)?.file, 'edits.json');
      expect(File(at('edits.json')).readAsStringSync(), original);
      expect(outside.readAsStringSync(), 'keep');
    }
  });

  test('a copy directory replaced by a link is refused instead of deleted through', () async {
    final copy = craft();
    final target = Directory(at('elsewhere'))..createSync();
    File('${target.path}${Platform.pathSeparator}notes.txt').writeAsStringSync('outside');
    final container = open(cleanup: (_) async => fail('must not delete through a link'));
    final edits = container.read(editsProvider.notifier);
    final directory = File(copy).parent;
    directory.deleteSync(recursive: true);
    try {
      Link(directory.path).createSync(target.path);
    } on FileSystemException {
      markTestSkipped('this account cannot create links');
      return;
    }

    await edits.finish('edit-1');

    expect(container.read(editsProvider).single.state, EditState.failed);
    expect(File('${target.path}${Platform.pathSeparator}notes.txt').readAsStringSync(), 'outside');
  });
}
