import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../foundation/file_system.dart';
import '../../../platform/mobile_platform.dart';
import 'local_fs.dart';

var _askedForStorage = false;

/// The phone's shared storage, or the app's own folder without access. [ask] opens Android's access screen once
/// per run when access is missing.
Future<FileSystem> openMobileStorage({bool sharedOnly = false, bool ask = false}) async {
  var root = Platform.isAndroid ? await MobilePlatform.sharedStoragePath() : null;
  if (root == null && ask && Platform.isAndroid && !_askedForStorage) {
    _askedForStorage = true;
    if (await MobilePlatform.requestAllFilesAccess()) root = await MobilePlatform.sharedStoragePath();
  }
  if (root != null) return LocalFileSystem(root: root);
  if (sharedOnly) throw const FsError(FsFailure.permission);
  try {
    return LocalFileSystem(root: (await getApplicationDocumentsDirectory()).path);
  } on Object catch (e) {
    throw FsError(FsFailure.unsupported, '$e');
  }
}
