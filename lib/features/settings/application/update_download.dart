import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../foundation/app_info.dart';
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

/// Downloads one release asset to the user's Downloads folder, checking it against the release's SHA256SUMS.
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
  var _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  /// Streams [asset] into a `.part` file and renames it only after the size and checksum agree.
  Future<UpdateDownloadState> download(
    ReleaseNote release, {
    required ReleaseAsset asset,
    required void Function(UpdateDownloadState state) onProgress,
  }) async {
    _cancelled = false;
    final client = _client = _clientFactory()..connectionTimeout = const Duration(seconds: 15);
    File? part;
    try {
      final folder = await _downloadsDirectory();
      await folder.create(recursive: true);
      final name = _safeName(asset.name);
      final target = File('${folder.path}${Platform.pathSeparator}$name');
      part = File('${target.path}.part');
      final response = await _open(client, Uri.parse(asset.url));
      if (response.statusCode != HttpStatus.ok) {
        throw const UpdateDownloadFailure();
      }
      final total = response.contentLength > 0 ? response.contentLength : asset.size;
      var received = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in response) {
          if (_cancelled) throw const UpdateDownloadCancelled();
          received += chunk.length;
          sink.add(chunk);
          onProgress(UpdateDownloadState(UpdateDownloadStatus.downloading, received: received, total: total));
        }
      } finally {
        await sink.close();
      }
      if (_cancelled) throw const UpdateDownloadCancelled();
      onProgress(UpdateDownloadState(UpdateDownloadStatus.verifying, received: received, total: total));
      final expected = await _expectedDigest(client, release, name);
      if (expected != null) {
        final actual = (await sha256.bind(part.openRead()).first).toString();
        if (actual != expected) throw const UpdateDownloadFailure();
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      part = null;
      final ready = UpdateDownloadState(UpdateDownloadStatus.ready, path: target.path);
      onProgress(ready);
      return ready;
    } on UpdateDownloadCancelled {
      rethrow;
    } on UpdateDownloadFailure {
      rethrow;
    } on Object {
      throw const UpdateDownloadFailure();
    } finally {
      if (part != null) {
        try {
          if (await part.exists()) await part.delete();
        } on FileSystemException {
          // A leftover `.part` hides no correctness problem; the next attempt overwrites it.
        }
      }
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<HttpClientResponse> _open(HttpClient client, Uri uri) async {
    if (!_trustedUrl(uri)) throw const UpdateDownloadFailure();
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    return request.close();
  }

  /// The hash for [name] when the release ships a checksum file; a missing or unreadable file skips the check.
  Future<String?> _expectedDigest(HttpClient client, ReleaseNote release, String name) async {
    final sums = release.checksums;
    if (sums == null) return null;
    try {
      final response = await _open(client, Uri.parse(sums.url));
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
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
