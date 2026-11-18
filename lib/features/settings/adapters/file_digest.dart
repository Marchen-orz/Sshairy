import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streams the file, so a package of any size is hashed without being held in memory.
Future<String> fileSha256(File file) async => (await sha256.bind(file.openRead()).first).toString();
