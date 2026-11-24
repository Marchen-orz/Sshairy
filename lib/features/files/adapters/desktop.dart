import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as selector;

/// Files the user picks in the system dialog; empty when cancelled.
Future<List<String>> pickFiles() async => [for (final f in await selector.openFiles()) f.path];

/// Files picked via system SAF / file dialog with bytes loaded directly (safe for Android scoped storage).
Future<List<({String name, Uint8List bytes})>> pickUploadFiles() async {
  final picked = await selector.openFiles();
  return [for (final f in picked) (name: f.name, bytes: await f.readAsBytes())];
}

/// Streamed file handle returned by the system SAF / file picker without loading whole files into memory.
typedef PickedUploadStream = ({String name, int? size, Stream<Uint8List> Function() openRead});

/// Picks files from the system dialog / Android SAF and exposes chunked [openRead] streams.
Future<List<PickedUploadStream>> pickUploadFileStreams() async {
  final picked = await selector.openFiles();
  final out = <PickedUploadStream>[];
  for (final f in picked) {
    int? size;
    try {
      size = await f.length();
    } on Object {
      size = null;
    }
    out.add((name: f.name, size: size, openRead: () => f.openRead()));
  }
  return out;
}

/// A folder the user picks in the system dialog; null when cancelled.
Future<String?> pickDirectory() => selector.getDirectoryPath();

/// A program the user picks in the system dialog; null when cancelled.
Future<String?> pickProgram() async {
  final file = await selector.openFile(
    acceptedTypeGroups: [
      if (Platform.isWindows) const selector.XTypeGroup(label: 'exe', extensions: ['exe']),
      if (Platform.isMacOS)
        const selector.XTypeGroup(
          label: 'app',
          extensions: ['app'],
          uniformTypeIdentifiers: ['com.apple.application-bundle'],
        ),
    ],
  );
  return file?.path;
}
