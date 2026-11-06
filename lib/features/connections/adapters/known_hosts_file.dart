import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as selector;

import '../../../foundation/result.dart';
import '../domain/known_hosts.dart';

/// Lets the user pick a known_hosts file and returns its text; null when cancelled. Errors are `knownHostsTooLarge`
/// and `knownHostsUnreadable`.
Future<Result<String>?> pickKnownHosts() async {
  final ssh = Directory('${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? ''}/.ssh');
  final picked = await selector.openFile(initialDirectory: ssh.existsSync() ? ssh.path : null);
  if (picked == null) return null;
  return readKnownHosts(picked.path);
}

Future<Result<String>> readKnownHosts(String path) async {
  try {
    final file = File(path);
    if (await file.length() > knownHostsMaxBytes) return const Err(AppError('knownHostsTooLarge'));
    final bytes = await file.readAsBytes();
    // The file may have grown since it was measured.
    if (bytes.length > knownHostsMaxBytes) return const Err(AppError('knownHostsTooLarge'));
    return Ok(utf8.decode(bytes, allowMalformed: true));
  } on FileSystemException {
    return const Err(AppError('knownHostsUnreadable'));
  }
}
