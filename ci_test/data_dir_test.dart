import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/foundation/data_dir.dart';

void main() {
  test('a --data-dir argument overrides the platform location', () {
    expect(dataDirOverride(['--data-dir=D:/state'], const {}), 'D:/state');
    expect(dataDirOverride(['--renderer=smooth', '--data-dir', 'D:/state'], const {}), 'D:/state');
  });

  test('SSHAIRY_DATA_DIR applies when no argument is given', () {
    expect(dataDirOverride(const [], const {'SSHAIRY_DATA_DIR': 'D:/state'}), 'D:/state');
  });

  test('the argument wins over the environment', () {
    expect(
      dataDirOverride(['--data-dir=D:/arg'], const {'SSHAIRY_DATA_DIR': 'D:/env'}),
      'D:/arg',
    );
  });

  test('empty or unrelated settings keep the platform default', () {
    expect(dataDirOverride(const [], const {}), isNull);
    expect(dataDirOverride(['--data-dir='], const {}), isNull);
    expect(dataDirOverride(['--data-dir'], const {}), isNull);
    expect(dataDirOverride(['--renderer=smooth'], const {'SSHAIRY_DATA_DIR': ''}), isNull);
  });
}
