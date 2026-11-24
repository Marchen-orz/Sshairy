import 'dart:convert';

import 'package:crypto/crypto.dart';

String skillTextSha256(String text) => sha256.convert(utf8.encode(text)).toString();
