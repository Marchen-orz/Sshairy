import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/design/format.dart';

void main() {
  test('file sizes use B, KB, MB and GB with one decimal above bytes', () {
    expect(formatFileSize(0), '0 B');
    expect(formatFileSize(999), '999 B');
    expect(formatFileSize(1024), '1.0 KB');
    expect(formatFileSize(1536), '1.5 KB');
    expect(formatFileSize(512 * 1024), '512.0 KB');
    expect(formatFileSize(1024 * 1024), '1.0 MB');
    expect(formatFileSize(1024 * 1024 * 1024), '1.0 GB');
  });
}
