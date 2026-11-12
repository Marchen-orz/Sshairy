import 'package:crypto/crypto.dart';

String fileTextSha256(List<int> bytes) => sha256.convert(bytes).toString();
