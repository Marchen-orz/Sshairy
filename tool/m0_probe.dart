// M0 probes E-08 (host key) and E-03 (backpressure) against a real server.
// Usage: SSHAIRY_TEST_PASSWORD=... dart run tool/m0_probe.dart user@host[:port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

late String host, user;
var port = 22;
final password = Platform.environment['SSHAIRY_TEST_PASSWORD'];

Future<void> main(List<String> args) async {
  final target = args.single.split('@');
  user = target[0];
  final hp = target[1].split(':');
  host = hp[0];
  if (hp.length > 1) port = int.parse(hp[1]);
  if (password == null) throw 'SSHAIRY_TEST_PASSWORD not set';

  await rejectedKeySkipsAuth();
  final fingerprint = await asyncVerifyThenRekey();
  await backpressure();
  print('fingerprint $fingerprint');
}

Future<SSHClient> connect(FutureOr<bool> Function(String, String) verify) async =>
    SSHClient(
      await SSHSocket.connect(host, port, timeout: const Duration(seconds: 20)),
      username: user,
      onVerifyHostKey: (type, fp) => verify(type, utf8.decode(fp)),
      onPasswordRequest: () {
        authAttempts++;
        return password;
      },
    );

var authAttempts = 0;

Future<void> rejectedKeySkipsAuth() async {
  authAttempts = 0;
  final client = await connect((_, _) => false);
  Object? error;
  try {
    await client.authenticated;
  } catch (e) {
    error = e;
  }
  check('E-08 reject: no auth sent', authAttempts == 0 && error != null, '$error');
}

Future<String> asyncVerifyThenRekey() async {
  late String seen;
  final client = await connect((type, fp) async {
    seen = '$type $fp';
    await Future<void>.delayed(const Duration(seconds: 3)); // simulates the user deciding
    return true;
  });
  await client.authenticated;
  check('E-08 async confirm', true, seen);
  final s = await client.execute('head -c 5000000 /dev/zero | base64');
  final bytes = s.stdout.fold<int>(0, (n, b) => n + b.length);
  await client.rekey();
  check('E-08 rekey during output', await bytes > 5000000, '');
  client.close();
  return seen;
}

// The remote writer is named so a second channel can read how much it wrote:
// if pausing our stream stalls the writer, the pause reached the SSH window.
Future<void> backpressure() async {
  const total = 30000000;
  final client = await connect((_, _) => true);
  await client.authenticated;
  final s = await client.execute("bash -c 'exec -a sshairy-e03 head -c $total /dev/zero'");
  Future<int> written() async => int.parse(utf8
      .decode(await client.run("grep wchar /proc/\$(pgrep -f '^sshairy-e03' | head -1)/io | cut -d' ' -f2"))
      .trim());

  var received = 0;
  final paused = Completer<void>();
  final sub = s.stdout.listen((b) {
    received += b.length;
    if (received > 1 << 20 && !paused.isCompleted) paused.complete();
  });
  await paused.future;
  sub.pause();
  await Future<void>.delayed(const Duration(seconds: 2));
  final a = await written();
  await Future<void>.delayed(const Duration(seconds: 4));
  final b = await written();
  check('E-03 pause stalls remote writer', b == a && b < total, 'wrote ${a >> 10} KiB, then ${b >> 10} KiB');
  sub.resume();
  await sub.asFuture<void>();
  check('E-03 resume completes', received == total, '${received >> 20} MiB');
  client.close();
}

void check(String name, bool ok, String detail) {
  print('${ok ? 'PASS' : 'FAIL'}  $name  $detail');
  if (!ok) exitCode = 1;
}
