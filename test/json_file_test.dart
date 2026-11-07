import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/foundation/json_file.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-json-'));
  tearDown(() => dir.deleteSync(recursive: true));

  void validate(Map<String, dynamic> data) {
    if (data['n'] is! int) throw const FormatException('n must be an integer');
  }

  JsonFile open({bool backups = true, bool validated = true, Duration interval = Duration.zero}) =>
      JsonFile('${dir.path}/hosts.json', backups: backups, interval: interval, validate: validated ? validate : null);

  Matcher failure(JsonFileFailure kind) => isA<JsonFileError>().having((error) => error.kind, 'kind', kind);
  Map<String, dynamic> disk() => jsonDecode(File('${dir.path}/hosts.json').readAsStringSync()) as Map<String, dynamic>;

  test('only a missing file reads as null; writes add a revision and leave no temporary file', () async {
    final file = open();
    expect(file.read(), isNull);
    expect(file.status, JsonReadStatus.missing);
    await file.write({'n': 1});
    expect(open().read(), {'n': 1, 'revision': 1});
    expect(file.revision, 1);
    expect(dir.listSync().where((entry) => entry.path.endsWith('.tmp')), isEmpty);
  });

  test('legacy documents without a revision start at zero', () async {
    File('${dir.path}/hosts.json').writeAsStringSync('{"schemaVersion":1,"n":4}');
    final file = open();
    expect(file.read()?['n'], 4);
    expect(file.revision, 0);
    await file.write({'schemaVersion': 1, 'n': 5}, expectedRevision: 0);
    expect(disk(), {'schemaVersion': 1, 'n': 5, 'revision': 1});
  });

  test('the replaced content is retained, newest first', () async {
    final file = open();
    await file.write({'n': 1});
    expect(file.snapshots(), isEmpty);
    await file.write({'n': 2});
    await file.write({'n': 3});
    expect([for (final copy in file.snapshots()) jsonDecode(copy.readAsStringSync())['n']], [2, 1]);
    expect(file.read(), {'n': 3, 'revision': 3});
  });

  test('writes in one interval refresh the snapshot with the actual preceding valid state', () async {
    final file = open(interval: const Duration(hours: 1));
    for (var i = 1; i <= 4; i++) {
      await file.write({'n': i});
    }
    expect([for (final copy in file.snapshots()) jsonDecode(copy.readAsStringSync())['n']], [3]);
  });

  test('only the newest ${JsonFile.keepSnapshots} snapshot slots are kept', () async {
    final file = open();
    for (var i = 1; i <= JsonFile.keepSnapshots + 5; i++) {
      await file.write({'n': i});
    }
    final copies = [for (final copy in file.snapshots()) jsonDecode(copy.readAsStringSync())['n'] as int];
    expect(copies.length, JsonFile.keepSnapshots);
    expect(copies.first, JsonFile.keepSnapshots + 4);
  });

  test('files without backups leave no snapshots', () async {
    final file = open(backups: false);
    await file.write({'n': 1});
    await file.write({'n': 2});
    expect(Directory('${dir.path}/backups').existsSync(), isFalse);
  });

  test('snapshots of one file are not mixed with another', () async {
    final hosts = open();
    final keys = JsonFile('${dir.path}/keys.json', backups: true, interval: Duration.zero);
    await hosts.write({'n': 1});
    await hosts.write({'n': 2});
    await keys.write({'k': 1});
    await keys.write({'k': 2});
    expect(hosts.snapshots().length, 1);
    expect(keys.snapshots().length, 1);
    expect(jsonDecode(keys.snapshots().single.readAsStringSync()), {'k': 1, 'revision': 1});
  });

  test('damaged data is protected before a domain-validated snapshot replaces it', () async {
    final file = open();
    await file.write({'n': 1});
    await file.write({'n': 2});
    File('${dir.path}/hosts.json').writeAsStringSync('{"n": 3');
    final again = open();
    expect(again.read(), {'n': 1, 'revision': 1});
    expect(again.status, JsonReadStatus.recovered);
    expect(disk(), {'n': 1, 'revision': 1});
    final protection = dir.listSync().where((entry) => entry.path.contains('.corrupt-')).toList();
    expect(protection.length, 1);
    expect((protection.single as File).readAsStringSync(), '{"n": 3');
  });

  test('parseable but domain-invalid snapshots are skipped', () async {
    final file = open();
    for (var i = 1; i <= 3; i++) {
      await file.write({'n': i});
    }
    file.snapshots().first.writeAsStringSync('{"n":"wrong","revision":20}');
    File('${dir.path}/hosts.json').writeAsStringSync('[]');
    final again = open();
    expect(again.read(), {'n': 1, 'revision': 1});
    expect(again.status, JsonReadStatus.recovered);
  });

  test('a validator is required for automatic recovery', () async {
    final file = open();
    await file.write({'n': 1});
    await file.write({'n': 2});
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('broken');
    final again = open(validated: false);
    expect(again.read, throwsA(failure(JsonFileFailure.corrupt)));
    await expectLater(again.write({'n': 3}), throwsA(failure(JsonFileFailure.corrupt)));
    expect(source.readAsStringSync(), 'broken');
  });

  test('without a valid snapshot a damaged file stays in place and locks saves', () async {
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('oops');
    final file = open();
    expect(file.read, throwsA(failure(JsonFileFailure.corrupt)));
    expect(file.status, JsonReadStatus.corrupt);
    await expectLater(file.write({'n': 1}), throwsA(failure(JsonFileFailure.corrupt)));
    expect(source.readAsStringSync(), 'oops');
    expect(dir.listSync().where((entry) => entry.path.contains('.corrupt-')), isEmpty);
  });

  test('invalid UTF-8 is corruption, never an empty configuration', () async {
    final source = File('${dir.path}/hosts.json')..writeAsBytesSync([0xff, 0xfe]);
    final file = open();
    expect(file.read, throwsA(failure(JsonFileFailure.corrupt)));
    await expectLater(file.write({'n': 1}), throwsA(failure(JsonFileFailure.corrupt)));
    expect(source.readAsBytesSync(), [0xff, 0xfe]);
  });

  test('domain-invalid current data cannot be replaced by a normal save', () async {
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('{"n": "wrong"}');
    final file = open();
    expect(file.read, throwsA(failure(JsonFileFailure.corrupt)));
    await expectLater(file.write({'n': 1}), throwsA(failure(JsonFileFailure.corrupt)));
    expect(source.readAsStringSync(), '{"n": "wrong"}');
  });

  test('a future schema remains unchanged even when an older valid backup exists', () async {
    final first = open();
    await first.write({'n': 1});
    await first.write({'n': 2});
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('{"schemaVersion":2,"n":3}');
    final file = open();
    expect(file.read, throwsA(failure(JsonFileFailure.unsupportedVersion)));
    expect(file.status, JsonReadStatus.unsupportedVersion);
    await expectLater(file.write({'n': 4}), throwsA(failure(JsonFileFailure.unsupportedVersion)));
    expect(source.readAsStringSync(), '{"schemaVersion":2,"n":3}');
    expect(dir.listSync().where((entry) => entry.path.contains('.corrupt-')), isEmpty);
  });

  test('wrong schema types and invalid revisions are not accepted', () {
    final source = File('${dir.path}/hosts.json');
    for (final version in ['"1"', 'null', 'true', '0']) {
      source.writeAsStringSync('{"schemaVersion":$version,"n":1}');
      expect(open().read, throwsA(failure(JsonFileFailure.unsupportedVersion)));
    }
    for (final revision in ['"1"', 'null', '-1', '1.5']) {
      source.writeAsStringSync('{"revision":$revision,"n":1}');
      expect(open().read, throwsA(failure(JsonFileFailure.corrupt)));
    }
  });

  test('a repaired valid file can be reread to release its write lock', () async {
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('oops');
    final file = open();
    expect(file.read, throwsA(failure(JsonFileFailure.corrupt)));
    source.writeAsStringSync('{"n":4,"revision":5}');
    expect(file.read()?['n'], 4);
    await file.write({'n': 6}, expectedRevision: 5);
    expect(disk(), {'n': 6, 'revision': 6});
  });

  test('removing a damaged file does not silently clear the existing write lock', () async {
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('oops');
    final file = open();
    expect(file.read, throwsA(failure(JsonFileFailure.corrupt)));
    source.deleteSync();
    expect(file.read, throwsA(failure(JsonFileFailure.corrupt)));
    await expectLater(file.write({'n': 1}), throwsA(failure(JsonFileFailure.corrupt)));
    expect(source.existsSync(), isFalse);
  });

  test('a failed protection copy aborts recovery and retains the damaged original', () async {
    // Both source and snapshot names fit the filesystem component limit; the required protection suffix does not.
    final name = '${List.filled(230, 'x').join()}.json';
    final path = '${dir.path}/$name';
    final source = File(path)..writeAsStringSync('damaged');
    Directory('${dir.path}/backups').createSync();
    File('${dir.path}/backups/$name.1.bak').writeAsStringSync('{"n":1}');
    final file = JsonFile(path, backups: true, validate: validate);
    expect(file.read, throwsA(failure(JsonFileFailure.backupFailed)));
    expect(source.readAsStringSync(), 'damaged');
    await expectLater(file.write({'n': 2}), throwsA(failure(JsonFileFailure.backupFailed)));
    expect(source.readAsStringSync(), 'damaged');
  });

  test('IO failures are not missing files and cannot be overwritten', () async {
    Directory('${dir.path}/hosts.json').createSync();
    final file = open();
    expect(
      file.read,
      throwsA(
        isA<JsonFileError>().having(
          (error) => error.kind,
          'kind',
          isIn([JsonFileFailure.io, JsonFileFailure.permissionDenied]),
        ),
      ),
    );
    await expectLater(file.write({'n': 1}), throwsA(isA<JsonFileError>()));
    expect(Directory('${dir.path}/hosts.json').existsSync(), isTrue);
  });

  test('the oldest snapshots go first when the archive is over its byte cap', () async {
    final file = JsonFile('${dir.path}/hosts.json', backups: true, interval: Duration.zero, bytesCap: 80);
    for (var i = 1; i <= 6; i++) {
      await file.write({'n': i});
    }
    final copies = [for (final copy in file.snapshots()) jsonDecode(copy.readAsStringSync())['n'] as int];
    expect(copies, isNotEmpty);
    expect(copies.length, lessThan(5));
    expect(copies.first, 5);
    expect(copies, [for (var n = 5; n > 5 - copies.length; n--) n]);
  });

  test('the archive cap does not remove another configuration\'s only known-good predecessor', () async {
    final hosts = JsonFile('${dir.path}/hosts.json', backups: true, interval: Duration.zero, bytesCap: 1);
    final keys = JsonFile('${dir.path}/keys.json', backups: true, interval: Duration.zero, bytesCap: 1);
    await keys.write({'k': 1});
    await keys.write({'k': 2});
    for (var i = 1; i <= 4; i++) {
      await hosts.write({'n': i});
    }
    expect(hosts.snapshots().length, 1);
    expect(keys.snapshots().length, 1);
    expect(jsonDecode(keys.snapshots().single.readAsStringSync())['k'], 1);
  });

  test('a failed backup aborts replacement; idle retains the failure until a successful retry', () async {
    final file = open();
    await file.write({'n': 1});
    final blocker = File('${dir.path}/backups')..writeAsStringSync('in the way');
    await expectLater(file.write({'n': 2}), throwsA(failure(JsonFileFailure.backupFailed)));
    expect(disk(), {'n': 1, 'revision': 1});
    expect(file.revision, 1);
    await expectLater(file.idle, throwsA(failure(JsonFileFailure.backupFailed)));
    blocker.deleteSync();
    await file.write({'n': 3});
    await file.idle;
    expect(disk(), {'n': 3, 'revision': 2});
  });

  test('concurrent writes on one instance land in order with increasing revisions', () async {
    final file = open();
    await Future.wait([
      for (var i = 1; i <= 20; i++) file.write({'n': i}),
    ]);
    expect(file.read(), {'n': 20, 'revision': 20});
  });

  test('two instances that read the same revision cannot overwrite each other', () async {
    final first = open(), second = open();
    first.read();
    second.read();
    final won = first.write({'n': 1});
    final stale = second.write({'n': 2});
    await expectLater(stale, throwsA(failure(JsonFileFailure.conflict)));
    await won;
    expect(disk(), {'n': 1, 'revision': 1});
    second.read();
    await second.write({'n': 3});
    expect(disk(), {'n': 3, 'revision': 2});
  });

  test('stale expectedRevision is rejected and cannot be supplied in the document to reset the revision', () async {
    final file = open();
    await file.write({'n': 1, 'revision': 90});
    expect(file.revision, 1);
    await expectLater(file.write({'n': 2}, expectedRevision: 0), throwsA(failure(JsonFileFailure.conflict)));
    expect(disk(), {'n': 1, 'revision': 1});
    await file.write({'n': 3}, expectedRevision: 1);
    expect(disk(), {'n': 3, 'revision': 2});
  });

  test('external edits are detected even when the revision was not changed', () async {
    final file = open();
    await file.write({'n': 1});
    File('${dir.path}/hosts.json').writeAsStringSync('{"n":4,"revision":1}');
    await expectLater(file.write({'n': 2}), throwsA(failure(JsonFileFailure.conflict)));
    expect(disk(), {'n': 4, 'revision': 1});
  });

  test('an external deletion after reading does not reinitialize the file on save', () async {
    final file = open();
    await file.write({'n': 1});
    File('${dir.path}/hosts.json').deleteSync();
    await expectLater(file.write({'n': 2}), throwsA(failure(JsonFileFailure.conflict)));
    expect(File('${dir.path}/hosts.json').existsSync(), isFalse);
  });

  test('corruption discovered at save time also locks the instance', () async {
    final file = open();
    await file.write({'n': 1});
    File('${dir.path}/hosts.json').writeAsStringSync('broken');
    await expectLater(file.write({'n': 2}), throwsA(failure(JsonFileFailure.corrupt)));
    await expectLater(file.write({'n': 3}), throwsA(failure(JsonFileFailure.corrupt)));
    expect(File('${dir.path}/hosts.json').readAsStringSync(), 'broken');
  });

  test('schema migrations convert in memory and preserve the old document until a protected save', () async {
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('{"schemaVersion":1,"revision":7,"old":4}');
    final original = source.readAsStringSync();
    final file = JsonFile(
      source.path,
      schemaVersion: 3,
      backups: true,
      validate: validate,
      migrations: {
        1: (data) => {'n': data['old']},
        2: (data) => {...data, 'n': (data['n'] as int) + 1},
      },
    );
    final converted = file.read()!;
    expect(converted, {'schemaVersion': 3, 'revision': 7, 'n': 5});
    expect(source.readAsStringSync(), original);
    await file.write(converted, expectedRevision: 7);
    expect(jsonDecode(source.readAsStringSync()), {'schemaVersion': 3, 'revision': 8, 'n': 5});
    expect(file.snapshots().single.readAsStringSync(), original);
  });

  test('failed or missing migrations never recover over or change a readable old document', () async {
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('{"schemaVersion":1,"revision":7,"old":4}');
    final original = source.readAsStringSync();
    final failed = JsonFile(
      source.path,
      schemaVersion: 2,
      backups: true,
      validate: validate,
      migrations: {1: (_) => throw const FormatException('cannot convert')},
    );
    expect(failed.read, throwsA(failure(JsonFileFailure.migrationFailed)));
    await expectLater(failed.write({'n': 2}), throwsA(failure(JsonFileFailure.migrationFailed)));
    expect(source.readAsStringSync(), original);
    final missing = JsonFile(source.path, schemaVersion: 2, validate: validate);
    expect(missing.read, throwsA(failure(JsonFileFailure.unsupportedVersion)));
    final invalid = JsonFile(
      source.path,
      schemaVersion: 2,
      validate: validate,
      migrations: {
        1: (_) => {'n': 'bad'},
      },
    );
    expect(invalid.read, throwsA(failure(JsonFileFailure.migrationFailed)));
    expect(source.readAsStringSync(), original);
    expect(JsonFile(source.path).read()?['old'], 4);
  });

  test('explicit snapshot restore protects the current revision and invalidates stale readers', () async {
    final file = open();
    await file.write({'n': 1});
    await file.write({'n': 2});
    final selected = file.availableSnapshots().single;
    expect(selected.revision, 1);
    final stale = open()..read();
    await file.restore(selected);
    expect(disk(), {'schemaVersion': 1, 'n': 1, 'revision': 3});
    final protected = dir.listSync().where((entry) => entry.path.contains('.before-restore-')).single as File;
    expect(jsonDecode(protected.readAsStringSync()), {'n': 2, 'revision': 2});
    await expectLater(stale.write({'n': 9}), throwsA(failure(JsonFileFailure.conflict)));
  });

  test('explicit recovery releases a corruption block without inventing an empty library', () async {
    final first = open();
    await first.write({'n': 1});
    await first.write({'n': 2});
    final source = File('${dir.path}/hosts.json')..writeAsStringSync('damaged');
    final file = JsonFile(source.path, validate: validate);
    JsonFileError? error;
    try {
      file.read();
    } on JsonFileError catch (caught) {
      error = caught;
    }
    expect(error?.kind, JsonFileFailure.corrupt);
    expect(error?.recovery, same(file));
    await file.restore(file.availableSnapshots().single);
    expect(file.read()?['n'], 1);
    expect(file.revision, 2);
    final protected = dir.listSync().where((entry) => entry.path.contains('.before-restore-')).single as File;
    expect(protected.readAsStringSync(), 'damaged');
    await file.write({'n': 3});
    expect(file.revision, 3);
  });

  test('changed or invalid snapshots and files changed after a restore request are preserved', () async {
    final file = open();
    await file.write({'n': 1});
    await file.write({'n': 2});
    final selected = file.availableSnapshots().single;
    File(selected.path).writeAsStringSync('{"n":"bad","revision":1}');
    expect(file.availableSnapshots(), isEmpty);
    await expectLater(file.restore(selected), throwsA(failure(JsonFileFailure.corrupt)));
    expect(disk()['n'], 2);
    File(selected.path).writeAsStringSync('{"n":1,"revision":1}');
    final restoring = file.restore(file.availableSnapshots().single);
    File('${dir.path}/hosts.json').writeAsStringSync('{"n":9,"revision":2}');
    await expectLater(restoring, throwsA(failure(JsonFileFailure.conflict)));
    expect(disk()['n'], 9);
  });

  test('a failed protection copy aborts explicit restore before replacing current bytes', () async {
    final name = '${List.filled(230, 'y').join()}.json';
    final path = '${dir.path}/$name';
    final source = File(path)..writeAsStringSync('{"n":2,"revision":2}');
    Directory('${dir.path}/backups').createSync();
    File('${dir.path}/backups/$name.1.bak').writeAsStringSync('{"n":1,"revision":1}');
    final file = JsonFile(path, validate: validate);
    file.read();
    await expectLater(file.restore(file.availableSnapshots().single), throwsA(failure(JsonFileFailure.backupFailed)));
    expect(source.readAsStringSync(), '{"n":2,"revision":2}');
    expect(file.revision, 2);
  });

  Future<Process> lockInAnotherProcess() async {
    final process = await Process.start('dart', [
      'test/support/json_lock_probe.dart',
      '${dir.path}/hosts.json',
    ], runInShell: Platform.isWindows);
    final errors = process.stderr.transform(utf8.decoder).join();
    final ready = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    expect(ready, 'locked');
    addTearDown(() async {
      process.stdin.writeln('release');
      await process.stdin.flush();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isEmpty);
      await process.stdin.close();
    });
    return process;
  }

  test('a separate process holding the OS lock prevents a commit without changing current bytes', () async {
    final file = open();
    await file.write({'n': 1});
    await lockInAnotherProcess();
    await expectLater(file.write({'n': 2}), throwsA(failure(JsonFileFailure.conflict)));
    expect(disk(), {'n': 1, 'revision': 1});
  });

  test('automatic and selected recovery also respect the separate process lock', () async {
    final first = open();
    await first.write({'n': 1});
    await first.write({'n': 2});
    File('${dir.path}/hosts.json').writeAsStringSync('damaged');
    final file = open();
    final snapshot = file.availableSnapshots().single;
    await lockInAnotherProcess();
    expect(file.read, throwsA(failure(JsonFileFailure.conflict)));
    await expectLater(file.restore(snapshot), throwsA(failure(JsonFileFailure.conflict)));
    expect(File('${dir.path}/hosts.json').readAsStringSync(), 'damaged');
  });

  test('queued writes capture input when issued rather than reading a later mutation', () async {
    final file = open();
    final value = {'n': 1};
    final saved = file.write(value);
    value['n'] = 5;
    await saved;
    expect(disk(), {'n': 1, 'revision': 1});
  });
}
