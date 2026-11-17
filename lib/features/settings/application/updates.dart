import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../foundation/app_info.dart';

/// One published release, newest first.
class ReleaseNote {
  const ReleaseNote({required this.version, required this.title, required this.notes, required this.url});

  final String version;
  final String title;
  final String notes;
  final String url;
}

const _releasesUrl = 'https://api.github.com/repos/Marchen-orz/Sshairy/releases?per_page=20';

/// Published, non-prerelease entries in the order the API returned them; anything malformed is skipped.
List<ReleaseNote> parseReleases(Object? json) {
  if (json is! List) return const [];
  final out = <ReleaseNote>[];
  for (final entry in json) {
    if (entry is! Map<String, dynamic> || entry['draft'] == true || entry['prerelease'] == true) continue;
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
  return ReleaseNote(version: version, title: title, notes: notes, url: url);
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
  if (blocks.isEmpty) return notes.trim();
  final wanted = languageCode.toLowerCase();
  final exact = blocks[wanted];
  if (exact != null) return exact;
  for (final entry in blocks.entries) {
    if (entry.key.startsWith('$wanted-')) return entry.value;
  }
  return blocks['en'] ?? blocks.values.first;
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

  Future<void> check() async {
    if (state.status == UpdateStatus.checking) return;
    state = const UpdateState(UpdateStatus.checking);
    try {
      final releases = await ref.read(releaseSourceProvider).fetch();
      final newest = releases.isEmpty ? null : releases.first;
      state = UpdateState(
        newest != null && isNewerVersion(newest.version, appVersion) ? UpdateStatus.available : UpdateStatus.upToDate,
        releases: releases,
      );
    } on Object {
      state = const UpdateState(UpdateStatus.failed);
    }
  }
}

final updateCheckProvider = NotifierProvider<UpdateCheck, UpdateState>(UpdateCheck.new);
