import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/app_info.dart';

/// One file attached to a published release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.size});

  final String name;
  final String url;
  final int size;

  bool get isChecksums => name.toLowerCase() == 'sha256sums';
}

/// One published release, newest first.
class ReleaseNote {
  const ReleaseNote({
    required this.version,
    required this.title,
    required this.notes,
    required this.url,
    this.assets = const [],
  });

  final String version;
  final String title;
  final String notes;
  final String url;
  final List<ReleaseAsset> assets;

  ReleaseAsset? get checksums {
    for (final asset in assets) {
      if (asset.isChecksums) return asset;
    }
    return null;
  }
}

const _releasesUrl = 'https://api.github.com/repos/Marchen-orz/Sshairy/releases?per_page=20';

/// Published, non-prerelease entries in the order the API returned them; anything malformed is skipped.
List<ReleaseNote> parseReleases(Object? json) {
  if (json is! List) return const [];
  final out = <ReleaseNote>[];
  for (final entry in json) {
    if (entry is! Map<String, dynamic> || entry['draft'] == true || entry['prerelease'] == true) {
      continue;
    }
    if (_note(entry) case final note?) out.add(note);
  }
  return out;
}

ReleaseNote? _note(Map<String, dynamic> entry) {
  final tag = entry['tag_name'];
  final url = entry['html_url'];
  if (tag is! String || url is! String) return null;
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  if (version.isEmpty) return null;
  final title = switch (entry['name']) {
    final String name when name.trim().isNotEmpty => name,
    _ => tag,
  };
  final notes = switch (entry['body']) {
    final String body => body.trim(),
    _ => '',
  };
  return ReleaseNote(version: version, title: title, notes: notes, url: url, assets: _assets(entry['assets']));
}

List<ReleaseAsset> _assets(Object? json) {
  if (json is! List) return const [];
  final out = <ReleaseAsset>[];
  for (final entry in json) {
    if (entry is! Map) continue;
    final name = entry['name'], url = entry['browser_download_url'], size = entry['size'];
    if (name is! String || name.isEmpty || url is! String) continue;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
    out.add(ReleaseAsset(name: name, url: url, size: size is int && size > 0 ? size : 0));
  }
  return out;
}

/// How this copy of the app reached the machine; the download follows the same habit.
class UpdateDelivery {
  const UpdateDelivery({required this.operatingSystem, this.installed = false, this.portableAppImage = false});

  factory UpdateDelivery.current() {
    final operatingSystem = Platform.operatingSystem;
    return UpdateDelivery(
      operatingSystem: operatingSystem,
      installed: operatingSystem == 'windows' && _hasUninstaller(),
      portableAppImage:
          operatingSystem == 'linux' &&
          ((Platform.environment['APPIMAGE']?.isNotEmpty ?? false) ||
              Platform.resolvedExecutable.toLowerCase().endsWith('.appimage')),
    );
  }

  final String operatingSystem;
  final bool installed;
  final bool portableAppImage;

  ReleaseAsset? assetFor(List<ReleaseAsset> assets) => selectUpdateAsset(
    assets,
    operatingSystem: operatingSystem,
    installed: installed,
    portableAppImage: portableAppImage,
  );
}

/// A packaged install for the running platform, preferring the kind of build the app was started from.
ReleaseAsset? selectUpdateAsset(
  List<ReleaseAsset> assets, {
  required String operatingSystem,
  bool installed = false,
  bool portableAppImage = false,
}) {
  ReleaseAsset? ending(String suffix) {
    for (final asset in assets) {
      if (asset.name.toLowerCase().endsWith(suffix)) return asset;
    }
    return null;
  }

  return switch (operatingSystem) {
    'windows' =>
      installed ? ending('-setup.exe') ?? ending('-portable.exe') : ending('-portable.exe') ?? ending('-setup.exe'),
    'macos' => ending('.dmg') ?? ending('.zip'),
    'linux' => portableAppImage ? ending('.appimage') ?? ending('.deb') : ending('.deb') ?? ending('.appimage'),
    _ => null,
  };
}

/// Inno Setup keeps `unins000.exe` next to the app; the portable launcher unpacks without one.
bool _hasUninstaller() {
  try {
    for (final entry in File(Platform.resolvedExecutable).parent.listSync()) {
      final name = entry.uri.pathSegments.last.toLowerCase();
      if (name.startsWith('unins') && name.endsWith('.exe')) return true;
    }
  } on FileSystemException {
    return false;
  }
  return false;
}

final _languageBlock = RegExp(r'<!--\s*([a-zA-Z-]+)\s*-->([\s\S]*?)<!--\s*/\1\s*-->');

/// A body may carry one block per language, marked `<!-- zh -->`; pick the one the app speaks.
/// Bodies without markers are shown as they are, which keeps older releases readable.
String releaseNotesFor(String notes, String languageCode) {
  final blocks = <String, String>{};
  for (final match in _languageBlock.allMatches(notes)) {
    // The first block for a language wins, so a stray repeated marker cannot shadow the real one.
    blocks.putIfAbsent(match[1]!.toLowerCase(), () => match[2]!.trim());
  }
  if (blocks.isEmpty) return _alternatingNotes(notes, languageCode);
  final wanted = languageCode.toLowerCase();
  final exact = blocks[wanted];
  if (exact != null) return exact;
  for (final entry in blocks.entries) {
    if (entry.key.startsWith('$wanted-')) return entry.value;
  }
  return blocks['en'] ?? blocks.values.first;
}

final _cjk = RegExp(r'[㐀-䶿一-鿿豈-﫿]');
final _latin = RegExp(r'[A-Za-z]');

/// A body written as one Chinese line followed by its English line, without marker blocks. Only non-empty
/// lines outside code fences count, and at least two pairs must strictly alternate between the two languages;
/// a mixed line or any other arrangement is shown as written rather than risking dropped content.
String _alternatingNotes(String notes, String languageCode) {
  final lines = notes.split('\n');
  final chinese = List<bool?>.filled(lines.length, null);
  var previous = false, seen = 0, zh = 0, en = 0, fenced = false;
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i].trim();
    if (text.startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    if (fenced || text.isEmpty) continue;
    final hasCjk = _cjk.hasMatch(text), hasLatin = _latin.hasMatch(text);
    if (!hasCjk && !hasLatin) return notes.trim();
    final isZh = hasCjk;
    if (seen > 0 && isZh == previous) return notes.trim();
    previous = isZh;
    chinese[i] = isZh;
    seen++;
    isZh ? zh++ : en++;
  }
  // Two pairs is the smallest body that reads as a translation rather than one sentence beside another.
  if (zh < 2 || en < 2) return notes.trim();
  final wanted = languageCode.toLowerCase().startsWith('zh');
  final kept = [
    for (var i = 0; i < lines.length; i++)
      if (chinese[i] == null || chinese[i] == wanted) lines[i],
  ];
  final text = kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return text.isEmpty ? notes.trim() : text;
}

/// Whether [candidate] is a later dotted number than [current]; anything unreadable counts as not newer.
bool isNewerVersion(String candidate, String current) {
  final a = _numbers(candidate), b = _numbers(current);
  if (a.isEmpty || b.isEmpty) return false;
  for (var i = 0; i < a.length || i < b.length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

List<int> _numbers(String version) {
  final out = <int>[];
  for (final part in version.split(RegExp(r'[.+-]'))) {
    final number = int.tryParse(part);
    if (number == null) break;
    out.add(number);
  }
  return out;
}

abstract class ReleaseSource {
  Future<List<ReleaseNote>> fetch();
}

class GithubReleaseSource implements ReleaseSource {
  GithubReleaseSource({HttpClient Function()? clientFactory, this.timeout = const Duration(seconds: 10)})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration timeout;
  static const maxResponseBytes = 2 << 20;

  @override
  Future<List<ReleaseNote>> fetch() async {
    final client = _clientFactory();
    client.connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(_releasesUrl)).timeout(timeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Sshairy/$appVersion');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final body = await response
          .fold<List<int>>(<int>[], (all, chunk) {
            if (all.length + chunk.length > maxResponseBytes) throw const HttpException('release list too large');
            all.addAll(chunk);
            return all;
          })
          .timeout(timeout);
      return parseReleases(jsonDecode(utf8.decode(body, allowMalformed: true)));
    } finally {
      client.close(force: true);
    }
  }
}

final releaseSourceProvider = Provider<ReleaseSource>((_) => GithubReleaseSource());

enum UpdateStatus { idle, checking, upToDate, available, failed }

class UpdateState {
  const UpdateState(this.status, {this.releases = const []});

  final UpdateStatus status;
  final List<ReleaseNote> releases;

  ReleaseNote? get latest => releases.isEmpty ? null : releases.first;
}

class UpdateCheck extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateState(UpdateStatus.idle);

  /// A [silent] check runs behind the user's back: it shows no checking or failed state and keeps
  /// whatever the last visible answer was, so the title-bar reminder does not flicker or lie.
  Future<void> check({bool silent = false}) async {
    if (state.status == UpdateStatus.checking) return;
    if (!silent) state = const UpdateState(UpdateStatus.checking);
    try {
      final releases = await ref.read(releaseSourceProvider).fetch();
      final newest = releases.isEmpty ? null : releases.first;
      state = UpdateState(
        newest != null && isNewerVersion(newest.version, appVersion) ? UpdateStatus.available : UpdateStatus.upToDate,
        releases: releases,
      );
    } on Object {
      if (!silent) state = const UpdateState(UpdateStatus.failed);
    }
  }
}

final updateCheckProvider = NotifierProvider<UpdateCheck, UpdateState>(UpdateCheck.new);
