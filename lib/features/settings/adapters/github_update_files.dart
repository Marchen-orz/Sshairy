import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../foundation/app_info.dart';
import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';
import '../application/updates.dart';

/// A read-only Link mount for public releases. Each request selects a fixed GitHub resource.
class GithubUpdateFiles implements FileSystem {
  GithubUpdateFiles(CancellationToken lifetime, {HttpClient Function()? clientFactory})
    : _client = (clientFactory ?? HttpClient.new)()..connectionTimeout = _timeout {
    unawaited(lifetime.whenCancelled.then((_) => close()));
  }

  static const _timeout = Duration(seconds: 15);
  static final _path = RegExp(r'^/(\d{1,6}\.\d{1,6}\.\d{1,6})/([A-Za-z0-9_.-]+)$');

  final HttpClient _client;

  static ({Uri url, int limit})? _resource(String path) {
    if (path == releaseFeedPath) {
      return (url: Uri.parse(releaseFeedUrl), limit: GithubReleaseSource.maxResponseBytes);
    }
    final match = _path.firstMatch(path);
    if (match == null || match.end != path.length) return null;
    final version = match[1]!, name = match[2]!;
    final checksums = name == 'SHA256SUMS';
    if (!checksums && !androidReleaseAbis.any((abi) => name == 'sshairy-$version-android-$abi.apk')) return null;
    return (
      url: Uri.https('github.com', '/Marchen-orz/Sshairy/releases/download/v$version/$name'),
      limit: checksums ? 64 * 1024 : maxUpdateApkBytes,
    );
  }

  @override
  PathStyle get style => PathStyle.posix;
  @override
  bool get canReplace => false;
  @override
  bool get canChmod => false;

  @override
  Future<String> home() async => '/';

  @override
  Future<String> resolve(String path) async {
    if (path != '/' && _resource(path) == null) throw const FsError(FsFailure.notFound);
    return path;
  }

  @override
  Future<FileEntry?> stat(String path) async => path == '/'
      ? const FileEntry('/', FileKind.directory)
      : _resource(path) == null
      ? null
      : FileEntry(style.name(path), FileKind.file);

  @override
  Stream<Uint8List> read(String path, {int offset = 0}) async* {
    final resource = _resource(path);
    if (resource == null || offset != 0) throw const FsError(FsFailure.permission);
    final request = await _client.getUrl(resource.url).timeout(_timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'Sshairy/$appVersion');
    if (path == releaseFeedPath) request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok || response.contentLength > resource.limit) {
      throw const FsError(FsFailure.failed);
    }
    var size = 0;
    await for (final chunk in response.timeout(_timeout)) {
      size += chunk.length;
      if (size > resource.limit) throw const FsError(FsFailure.failed);
      yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    }
  }

  @override
  Future<void> close() async => _client.close(force: true);

  Never _unsupported() => throw const FsError(FsFailure.unsupported);

  @override
  Future<List<FileEntry>> list(String dir) async => _unsupported();
  @override
  Future<void> mkdir(String path) async => _unsupported();
  @override
  Future<void> rename(String from, String to, {void Function()? checkCurrent}) async => _unsupported();
  @override
  Future<void> replace(String from, String to, {void Function()? checkCurrent}) async => _unsupported();
  @override
  Future<void> delete(String path) async => _unsupported();
  @override
  Future<void> rmdir(String path) async => _unsupported();
  @override
  Future<void> chmod(String path, int mode) async => _unsupported();
  @override
  Future<int> create(
    String path,
    Stream<Uint8List> data, {
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) async => _unsupported();
  @override
  Future<int> append(
    String path,
    Stream<Uint8List> data, {
    required int offset,
    void Function(int written)? onProgress,
    CancellationToken? cancel,
    void Function()? checkCurrent,
  }) async => _unsupported();
}
