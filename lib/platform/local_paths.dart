import 'dart:io';

final _quotedPath = RegExp(r'^"([^"]*)"$');

/// Windows Explorer's Copy as path wraps the path in double quotes.
String unquoteWindowsPath(String path) {
  if (!Platform.isWindows) return path;
  return _quotedPath.firstMatch(path.trim())?.group(1) ?? path;
}
