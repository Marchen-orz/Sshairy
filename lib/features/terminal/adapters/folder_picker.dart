import 'package:file_selector/file_selector.dart' as selector;

/// A folder from the system dialog, or null when cancelled.
Future<String?> pickFolder({String? initial}) => selector.getDirectoryPath(initialDirectory: initial);
