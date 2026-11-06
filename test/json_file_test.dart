import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/foundation/json_file.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sshairy-json-'));
  tearDown(() => dir.deleteSync(recursive: true));

  JsonFile open({bool backups = true, Duration interval = Duration.zero}) =>
      JsonFile('${dir.path}/hosts.json', backups: backups, interval: interval);

  test('a missing file reads as null and a written one reads back', () async {
    final file = open();
    expect(file.read(), isNull);
    expect(file.status, JsonReadStatus.missing);
    await file.write({'n': 1});
    expect(open().read(), {'n': 1});
    expect(File('${dir.path}/hosts.json.tmp').existsSync(), isFalse);
  });

  test('each write replaces the file, and the replaced content is kept as a snapshot', () async {
    final file = open();
    await file.write({'n': 1});
    expect(file.snapshots(), isEmpty, reason: 'nothing was replaced yet');
    await file.write({'n': 2});
    await file.write({'n': 3});
    final copies = [for (final s in file.snapshots()) jsonDecode(s.readAsStringSync())['n']];
    expect(copies, [2, 1]);
    expect(file.read(), {'n': 3});
  });

  test('snapshots are at most one per interval', () async {
    final file = open(interval: const Duration(hours: 1));
    for (var i = 1; i <= 4; i++) {
      await file.write({'n': i});
    }
    expect([for (final s in file.snapshots()) jsonDecode(s.readAsStringSync())['n']], [1]);
  });

  test('only the newest ${JsonFile.keepSnapshots} snapshots are kept', () async {
    final file = open();
    for (var i = 1; i <= JsonFile.keepSnapshots + 5; i++) {
      await file.write({'n': i});
    }
    final copies = [for (final s in file.snapshots()) jsonDecode(s.readAsStringSync())['n'] as int];
    expect(copies.length, JsonFile.keepSnapshots);
    expect(copies.first, JsonFile.keepSnapshots + 4, reason: 'newest first, the latest write is the file itself');
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
    await hosts.write({'h': 1});
    await hosts.write({'h': 2});
    await keys.write({'k': 1});
    await keys.write({'k': 2});
    expect(hosts.snapshots().length, 1);
    expect(keys.snapshots().length, 1);
    expect(jsonDecode(keys.snapshots().single.readAsStringSync()), {'k': 1});
  });

  test('an unreadable file is kept aside and the newest readable snapshot takes its place', () async {
    final file = open();
    await file.write({'n': 1});
    await file.write({'n': 2});
    File('${dir.path}/hosts.json').writeAsStringSync('{"n": 3');

    final again = open();
    expect(again.read(), {'n': 1});
    expect(again.status, JsonReadStatus.recovered);
    expect(jsonDecode(File('${dir.path}/hosts.json').readAsStringSync()), {'n': 1}, reason: 'restored on disk');
    final aside = dir.listSync().where((e) => e.path.contains('.corrupt-')).toList();
    expect(aside.length, 1);
    expect((aside.single as File).readAsStringSync(), '{"n": 3');
  });

  test('a corrupt snapshot is skipped for an older one', () async {
    final file = open();
    for (var i = 1; i <= 3; i++) {
      await file.write({'n': i});
    }
    file.snapshots().first.writeAsStringSync('not json');
    File('${dir.path}/hosts.json').writeAsStringSync('[]');

    final again = open();
    expect(again.read(), {'n': 1});
    expect(again.status, JsonReadStatus.recovered);
  });

  test('without any snapshot an unreadable file reads as lost, and is still kept aside', () {
    File('${dir.path}/hosts.json').writeAsStringSync('oops');
    final file = open();
    expect(file.read(), isNull);
    expect(file.status, JsonReadStatus.lost);
    expect(dir.listSync().any((e) => e.path.contains('.corrupt-')), isTrue);
    expect(File('${dir.path}/hosts.json').existsSync(), isFalse);
  });

  test('the oldest snapshots go first when the folder is over its byte cap', () async {
    final file = JsonFile('${dir.path}/hosts.json', backups: true, interval: Duration.zero, bytesCap: 30);
    for (var i = 1; i <= 6; i++) {
      await file.write({'n': i});
    }
    final copies = [for (final s in file.snapshots()) jsonDecode(s.readAsStringSync())['n'] as int];
    expect(copies, isNotEmpty);
    expect(copies.length, lessThan(5));
    expect(copies.first, 5, reason: 'the newest copy is never the one dropped');
    expect(copies, [for (var n = 5; n > 5 - copies.length; n--) n]);
  });

  test('a failing backup does not stop the write', () async {
    final file = open();
    await file.write({'n': 1});
    // A file where the backups folder should be.
    File('${dir.path}/backups').writeAsStringSync('in the way');
    await file.write({'n': 2});
    expect(file.read(), {'n': 2});
  });

  test('concurrent writes land in the order issued', () async {
    final file = open();
    await Future.wait([
      for (var i = 1; i <= 20; i++) file.write({'n': i}),
    ]);
    expect(file.read(), {'n': 20});
  });
}
