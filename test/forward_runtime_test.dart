import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/forwarding/adapters/runtime.dart';
import 'package:sshairy/features/forwarding/domain/forward.dart';

void main() {
  const runtime = IoForwardRuntime();

  test('a port this process already listens on is reported as in use', () async {
    final taken = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(taken.close);
    await expectLater(
      runtime.listen('127.0.0.1', taken.port),
      throwsA(isA<ForwardError>().having((e) => e.code, 'code', ForwardErrors.addressInUse)),
    );
  });

  test('a listener gives its port back when closed', () async {
    final first = await runtime.listen('127.0.0.1', 0);
    final port = first.port;
    await first.close();
    final again = await runtime.listen('127.0.0.1', port);
    expect(again.port, port);
    await again.close();
  });
}
