import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../foundation/app_info.dart';
import '../../../foundation/file_system.dart';
import '../adapters/file_digest.dart';
import 'updates.dart';

enum UpdateDownloadStatus { idle, downloading, verifying, ready, failed }

class UpdateDownloadState {
  const UpdateDownloadState(this.status, {this.received = 0, this.total = 0, this.path});

  const UpdateDownloadState.idle() : this(UpdateDownloadStatus.idle);

  final UpdateDownloadStatus status;
  final int received;
  final int total;
  final String? path;

  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
}

class UpdateDownloadFailure implements Exception {
  const UpdateDownloadFailure();
}

typedef _OpenAsset = Future<({Stream<List<int>> chunks, int size})> Function(ReleaseAsset asset);

/// Saves one release asset, checking it against the release's SHA256SUMS.
class UpdateDownloader {
  UpdateDownloader({
    HttpClient Function()? clientFactory,
    Future<Directory> Function()? downloadsDirectory,
    bool Function(Uri url)? trustedUrl,
    this.userAgent = 'Sshairy/$appVersion',
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _downloadsDirectory = downloadsDirectory ?? _defaultDownloadsDirectory,
       _trustedUrl = trustedUrl ?? _githubUrl;

  final HttpClient Function() _clientFactory;
  final Future<Directory> Function() _downloadsDirectory;
  final bool Function(Uri url) _trustedUrl;
  final String userAgent;

  HttpClient? _client;
  FileSystem? _relay;
  var _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    unawaited(_relay?.close());
  }

  /// Streams [asset] into a private staging file, then moves the verified download into place.
  Future<UpdateDownloadState> download(
    ReleaseNote release, {
    required ReleaseAsset asset,
    required void Function(UpdateDownloadState state) onProgress,
    OpenUpdateRelay? openRelay,
  }) async {
    _cancelled = false;
    Directory? staging;
    try {
      final open = await _assetSource(release.version, openRelay);
      final folder = await _downloadsDirectory();
      if (_cancelled) throw const UpdateDownloadCancelled();
      await folder.create(recursive: true);
      final name = _safeName(asset.name);
      final apk = name.toLowerCase().endsWith('.apk');
      final download = await open(asset);
      if (_cancelled) throw const UpdateDownloadCancelled();
      if (apk && download.size > maxUpdateApkBytes) throw const UpdateDownloadFailure();
      final target = File('${folder.path}${Platform.pathSeparator}$name');
      staging = await folder.createTemp('.sshairy-update-');
      final part = File('${staging.path}${Platform.pathSeparator}$name.part');
      final total = download.size;
      var received = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in download.chunks) {
          if (_cancelled) throw const UpdateDownloadCancelled();
          received += chunk.length;
          if (apk && received > maxUpdateApkBytes) throw const UpdateDownloadFailure();
          sink.add(chunk);
          onProgress(UpdateDownloadState(UpdateDownloadStatus.downloading, received: received, total: total));
        }
      } finally {
        await sink.close();
      }
      if (_cancelled) throw const UpdateDownloadCancelled();
      onProgress(UpdateDownloadState(UpdateDownloadStatus.verifying, received: received, total: total));
      final expected = await _expectedDigest(open, release, name);
      if (_cancelled) throw const UpdateDownloadCancelled();
      if (apk && expected == null) throw const UpdateDownloadFailure();
      if (expected != null) {
        final actual = await fileSha256(part);
        if (_cancelled) throw const UpdateDownloadCancelled();
        if (actual != expected) throw const UpdateDownloadFailure();
      }
      await part.rename(target.path);
      if (_cancelled) throw const UpdateDownloadCancelled();
      final ready = UpdateDownloadState(UpdateDownloadStatus.ready, path: target.path);
      onProgress(ready);
      return ready;
    } on UpdateDownloadCancelled {
      rethrow;
    } on UpdateDownloadFailure {
      rethrow;
    } on Object {
      if (_cancelled) throw const UpdateDownloadCancelled();
      throw const UpdateDownloadFailure();
    } finally {
      if (staging != null) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // Each attempt owns its staging directory, so a leftover file cannot block a retry.
        }
      }
      _client?.close(force: true);
      _client = null;
      await _relay?.close();
      _relay = null;
    }
  }

  Future<_OpenAsset> _assetSource(String version, OpenUpdateRelay? openRelay) async {
    if (openRelay != null) {
      final relay = _relay = await openRelay();
      return (ReleaseAsset asset) async => (chunks: relay.read('/$version/${asset.name}'), size: asset.size);
    }
    const timeout = Duration(seconds: 15);
    final client = _client = _clientFactory()..connectionTimeout = timeout;
    return (ReleaseAsset asset) async {
      final response = await _open(client, Uri.parse(asset.url)).timeout(timeout);
      if (response.statusCode != HttpStatus.ok) throw const UpdateDownloadFailure();
      return (
        chunks: response.timeout(timeout),
        size: response.contentLength > 0 ? response.contentLength : asset.size,
      );
    };
  }

  Future<HttpClientResponse> _open(HttpClient client, Uri uri) async {
    if (!_trustedUrl(uri)) throw const UpdateDownloadFailure();
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    return request.close();
  }

  /// The hash for [name] when the release ships a checksum file; a missing or unreadable file skips the check.
  Future<String?> _expectedDigest(_OpenAsset open, ReleaseNote release, String name) async {
    final sums = release.checksums;
    if (sums == null) return null;
    try {
      final response = await open(sums);
      final bytes = <int>[];
      await for (final chunk in response.chunks) {
        if (bytes.length + chunk.length > 64 * 1024) return null;
        bytes.addAll(chunk);
      }
      return expectedSha256(utf8.decode(bytes, allowMalformed: true), name);
    } on Object {
      return null;
    }
  }
}

String? expectedSha256(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts.last == name) {
      return parts.first.toLowerCase();
    }
  }
  return null;
}

String _safeName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty || base == '.' || base == '..') {
    throw const UpdateDownloadFailure();
  }
  return base;
}

bool _githubUrl(Uri uri) =>
    uri.scheme == 'https' && (uri.host == 'github.com' || uri.host.endsWith('.githubusercontent.com'));

Future<Directory> _defaultDownloadsDirectory() async {
  if (Platform.isAndroid) {
    final cache = await getTemporaryDirectory();
    return Directory('${cache.path}/updates');
  }
  try {
    final directory = await getDownloadsDirectory();
    if (directory != null) return directory;
  } on Object {
    // Fall through to the home directory when the platform has no Downloads folder.
  }
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  return Directory(
    home == null || home.isEmpty
        ? Platform.environment['TEMP'] ?? Directory.systemTemp.path
        : '$home${Platform.pathSeparator}Downloads',
  );
}

/// Widget tests replace this to serve packages from a local server.
final updateDownloaderProvider = Provider<UpdateDownloader Function()>((_) => UpdateDownloader.new);
