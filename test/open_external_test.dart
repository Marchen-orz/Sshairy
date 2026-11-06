import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/foundation/open_external.dart';

void main() {
  test('finds the link under a column and drops sentence punctuation', () {
    const line = 'see https://example.com/a?b=1. or (https://x.org/y) now';
    expect(linkAt(line, 4), 'https://example.com/a?b=1');
    expect(linkAt(line, 24), 'https://example.com/a?b=1');
    expect(linkAt(line, 29), isNull, reason: 'the full stop is not part of the link');
    expect(linkAt(line, 35), 'https://x.org/y');
    expect(linkAt(line, 0), isNull);
  });

  test('keeps a closing bracket that belongs to the link', () {
    const line = 'https://en.wikipedia.org/wiki/Tree_(graph_theory).';
    expect(linkAt(line, 10), 'https://en.wikipedia.org/wiki/Tree_(graph_theory)');
  });

  test('refuses anything but http(s) links and existing folders', () async {
    expect(await openExternal('file:///etc/passwd'), isFalse);
    expect(await openExternal('javascript:alert(1)'), isFalse);
    expect(await openExternal('calc.exe'), isFalse);
  });
}
