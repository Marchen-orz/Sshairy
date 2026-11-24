/// Which entries a remote directory holds, for path completion (docs/TERMINAL_ASSISTANCE.md). Rules, cache and query
/// scheduling are here; the SFTP reader is `adapters/terminal_paths.dart`. Nothing in this file touches a shell.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../../../foundation/cancellation.dart';
import '../../../foundation/file_system.dart';

enum RemotePathKind { directory, file, symlink }

enum RemotePathFailure { invalid, unavailable, denied, notFound, failed, timeout, cancelled }

class RemotePathException implements Exception {
  const RemotePathException(this.kind);

  final RemotePathFailure kind;

  @override
  String toString() => 'RemotePathException(${kind.name})';
}

/// [directory] is absolute (`/…`), `~` or `~/…`; relative input is [RemotePaths.absolute]'s job. [prefix] is the
/// last typed segment, matched case-sensitively.
class RemotePathQuery {
  const RemotePathQuery({required this.directory, this.prefix = '', this.foldersOnly = false});

  final String directory;
  final String prefix;
  final bool foldersOnly;
}

class RemotePathEntry {
  const RemotePathEntry(this.name, this.kind, this.path, {this.linkToDirectory = false});

  /// The raw name as the server reports it; encoding for a shell is the caller's.
  final String name;
  final RemotePathKind kind;

  /// [RemotePaths.child] of the listed directory, for navigating; never written to a terminal as is.
  final String path;

  /// A symlink whose target is a directory.
  final bool linkToDirectory;

  bool get enterable => kind == RemotePathKind.directory || linkToDirectory;
}

class RemotePathResult {
  const RemotePathResult({
    required this.directory,
    required this.prefix,
    required this.entries,
    required this.truncated,
    required this.generation,
    required this.cached,
  });

  /// Normalised and with `~` expanded.
  final String directory;
  final String prefix;

  /// At most [RemotePaths.maxVisible]; directories first, then UTF-16 code unit order.
  final List<RemotePathEntry> entries;

  /// Entries may be missing: more matched than [entries] holds, or the directory was too large to be read to the end
  /// ([RemotePaths.maxScanned]).
  final bool truncated;
  final int generation;
  final bool cached;
}

abstract interface class RemotePathSource {
  /// Throws [RemotePathException]; callers treat every failure as "no remote candidates".
  Future<RemotePathResult> browse(RemotePathQuery query, {CancellationToken? cancel});

  /// Forgets what is cached for [directory], or for everything.
  void invalidate([String? directory]);

  void dispose();
}

/// One entry as a reader saw it, before names are vetted.
class RemoteDirectoryItem {
  const RemoteDirectoryItem(this.name, this.kind, {this.linkToDirectory = false});

  final String name;
  final RemotePathKind kind;
  final bool linkToDirectory;

  bool get enterable => kind == RemotePathKind.directory || linkToDirectory;
}

/// What a reader found in one directory. [complete] is false when it stopped at [RemotePaths.maxScanned] names with
/// more unread.
class RemoteDirectoryListing {
  const RemoteDirectoryListing(this.items, {this.complete = true});

  final List<RemoteDirectoryItem> items;
  final bool complete;
}

/// Reads directories over a connection that is already verified. Throws [RemotePathException]. Cancelling [cancel]
/// must stop the work and release what it holds, not just stop waiting.
abstract interface class RemoteDirectoryReader {
  /// The login user's home directory.
  Future<String> home(CancellationToken cancel);

  /// At most [RemotePaths.maxScanned] names, in the server's order.
  Future<RemoteDirectoryListing> list(String directory, CancellationToken cancel);

  void close();
}

abstract final class RemotePaths {
  static const maxPathBytes = 4096;
  static const maxSegments = 128;
  static const maxNameBytes = 255;
  static const maxVisible = 200;

  /// Names read from one directory; what lies beyond is not offered (and not asked for).
  static const maxScanned = 4096;

  static bool isHome(String normalized, {PathStyle style = PathStyle.posix}) =>
      normalized == '~' || normalized.startsWith('~/') || (style == PathStyle.windows && normalized.startsWith(r'~\'));

  static final _windowsDriveRoot = RegExp(r'^[A-Za-z]:[\\/]');
  static final _windowsUnc = RegExp(r'^\\\\[^\\/]+\\[^\\/]+(?:[\\/]|$)');

  /// A name worth offering: no separators, controls, line breaks or bidirectional overrides, and bytes that the
  /// server's name round-trips through UTF-8.
  static bool validName(String name, {PathStyle style = PathStyle.posix}) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      (style != PathStyle.windows || !name.contains(r'\')) &&
      _cleanText(name) &&
      _byteLength(name) <= maxNameBytes;

  static bool validPrefix(String prefix, {PathStyle style = PathStyle.posix}) =>
      prefix.isEmpty ||
      (!prefix.contains('/') &&
          (style != PathStyle.windows || !prefix.contains(r'\')) &&
          _cleanText(prefix) &&
          _byteLength(prefix) <= maxNameBytes);

  /// The canonical form of an absolute or home-relative [directory]: no empty or `.` segments, no trailing slash
  /// (except `/` or Windows drive root `C:\`). `..` stays, so the filesystem resolves it on the real path.
  static String normalize(String directory, {PathStyle style = PathStyle.posix}) {
    if (style == PathStyle.windows) return _normalizeWindows(directory);
    final home = isHome(directory);
    if (!home && !directory.startsWith('/')) throw const RemotePathException(RemotePathFailure.invalid);
    if (directory.length > maxPathBytes || !_cleanText(directory)) {
      throw const RemotePathException(RemotePathFailure.invalid);
    }
    final segments = [
      for (final part in directory.split('/'))
        if (part.isNotEmpty && part != '.') part,
    ];
    if (segments.length > maxSegments || segments.any((s) => _byteLength(s) > maxNameBytes)) {
      throw const RemotePathException(RemotePathFailure.invalid);
    }
    final path = home ? segments.join('/') : '/${segments.join('/')}';
    if (_byteLength(path) > maxPathBytes) throw const RemotePathException(RemotePathFailure.invalid);
    return path;
  }

  static String _normalizeWindows(String directory) {
    if (directory.length > maxPathBytes || !_cleanText(directory)) {
      throw const RemotePathException(RemotePathFailure.invalid);
    }
    final home = isHome(directory, style: PathStyle.windows);
    String root;
    String rest;
    if (home) {
      root = '~';
      rest = directory.length > 1 ? directory.substring(2) : '';
    } else if (_windowsDriveRoot.hasMatch(directory)) {
      root = '${directory[0].toUpperCase()}:\\';
      rest = directory.substring(3);
    } else if (_windowsUnc.hasMatch(directory)) {
      final parts = directory.substring(2).split(RegExp(r'[/\\]'));
      if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
        throw const RemotePathException(RemotePathFailure.invalid);
      }
      root = '\\\\${parts[0]}\\${parts[1]}';
      rest = parts.skip(2).join(r'\');
    } else {
      throw const RemotePathException(RemotePathFailure.invalid);
    }
    final segments = [
      for (final part in rest.split(RegExp(r'[/\\]')))
        if (part.isNotEmpty && part != '.') part,
    ];
    if (segments.length > maxSegments || segments.any((s) => _byteLength(s) > maxNameBytes)) {
      throw const RemotePathException(RemotePathFailure.invalid);
    }
    final path = segments.isEmpty
        ? root
        : root.endsWith(r'\')
        ? '$root${segments.join(r'\')}'
        : '$root\\${segments.join(r'\')}';
    if (_byteLength(path) > maxPathBytes) throw const RemotePathException(RemotePathFailure.invalid);
    return path;
  }

  /// Replaces a leading `~` of [normalized] with [home], an absolute path.
  static String expandHome(String normalized, String home, {PathStyle style = PathStyle.posix}) {
    if (!isHome(normalized, style: style)) return normalized;
    final base = normalize(home, style: style);
    if (isHome(base, style: style)) throw const RemotePathException(RemotePathFailure.invalid);
    final rest = normalized.substring(1);
    if (style == PathStyle.windows) {
      final joined = rest.isEmpty ? base : (base.endsWith(r'\') ? '$base${rest.substring(1)}' : '$base$rest');
      return normalize(joined, style: style);
    }
    return normalize(base == '/' ? (rest.isEmpty ? '/' : rest) : '$base$rest');
  }

  /// [name] inside [directory]; [name] must be valid (an [ArgumentError] otherwise).
  static String child(String directory, String name, {PathStyle style = PathStyle.posix}) {
    if (!validName(name, style: style)) throw ArgumentError.value(name, 'name');
    final dir = normalize(directory, style: style);
    if (style == PathStyle.windows) {
      return normalize(dir.endsWith(r'\') ? '$dir$name' : '$dir\\$name', style: style);
    }
    return normalize(dir == '/' ? '/$name' : '$dir/$name');
  }

  /// The directory above [directory]; the root is its own parent. Above a `..` or a bare `~` that is one more `..`.
  static String parent(String directory, {PathStyle style = PathStyle.posix}) {
    final dir = normalize(directory, style: style);
    if (style == PathStyle.windows) {
      if (RegExp(r'^[A-Za-z]:\\$').hasMatch(dir) || RegExp(r'^\\\\[^\\]+\\[^\\]+$').hasMatch(dir)) return dir;
      if (dir == '~') return r'~\..';
      final i = dir.lastIndexOf(r'\');
      if (dir.substring(i + 1) == '..') return normalize('$dir\\..', style: style);
      return i == 2 && dir[1] == ':' ? dir.substring(0, 3) : dir.substring(0, i);
    }
    if (dir == '/') return '/';
    if (dir == '~') return '~/..';
    final i = dir.lastIndexOf('/');
    if (dir.substring(i + 1) == '..') return normalize('$dir/..');
    return i == 0 ? '/' : dir.substring(0, i);
  }

  /// An absolute or `~` [directory] in canonical form; a relative one is taken from [cwd]. Null when it cannot be
  /// told: relative without a [cwd], `~user` and the like, or a path that is not valid.
  static String? absolute(String directory, {String? cwd, PathStyle style = PathStyle.posix}) {
    try {
      if (style == PathStyle.windows) {
        if (_windowsDriveRoot.hasMatch(directory) ||
            _windowsUnc.hasMatch(directory) ||
            isHome(directory, style: style)) {
          return normalize(directory, style: style);
        }
        if (cwd == null || directory.startsWith('~')) return null;
        final base = normalize(cwd, style: style);
        if (directory.startsWith('/') || directory.startsWith(r'\')) {
          if (!_windowsDriveRoot.hasMatch(base)) return null;
          return normalize('${base.substring(0, 3)}$directory', style: style);
        }
        if (directory.isEmpty) return base;
        return normalize(base.endsWith(r'\') ? '$base$directory' : '$base\\$directory', style: style);
      }
      if (directory.startsWith('/') || isHome(directory)) return normalize(directory);
      if (cwd == null || directory.startsWith('~')) return null;
      final base = normalize(cwd);
      return normalize(directory.isEmpty ? base : '$base/$directory');
    } on RemotePathException {
      return null;
    }
  }

  static int _byteLength(String text) => utf8.encode(text).length;

  /// Rejects what cannot be told apart from layout or what the server could not have sent as UTF-8: C0/C1
  /// controls, line and paragraph separators, bidirectional controls, lone surrogates and U+FFFD.
  static bool _cleanText(String text) {
    final units = text.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final c = units[i];
      if (c < 0x20 || (c >= 0x7f && c <= 0x9f) || c == 0xfffd) return false;
      if (c == 0x061c || c == 0x200e || c == 0x200f || c == 0x2028 || c == 0x2029) return false;
      if ((c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)) return false;
      if (c >= 0xd800 && c <= 0xdbff) {
        if (i + 1 >= units.length || units[i + 1] < 0xdc00 || units[i + 1] > 0xdfff) return false;
        i++;
      } else if (c >= 0xdc00 && c <= 0xdfff) {
        return false;
      }
    }
    return true;
  }
}

/// A [RemotePathSource] over one [RemoteDirectoryReader] (one connection generation). Same-directory queries share
/// one listing; a query for another directory supersedes the running one. See docs/TERMINAL_ASSISTANCE.md.
class RemotePathBrowser implements RemotePathSource {
  RemotePathBrowser(
    this._reader, {
    required this.generation,
    this.style = PathStyle.posix,
    this.timeout = const Duration(seconds: 3),
    Duration cacheTtl = const Duration(seconds: 5),
    int maxDirectories = 16,
    int maxCachedEntries = 16384,
    int maxEntriesPerDirectory = 4096,
    DateTime Function()? clock,
  }) : _cache = _Cache(
         clock ?? DateTime.now,
         ttl: cacheTtl,
         maxDirectories: maxDirectories,
         maxEntries: maxCachedEntries,
         maxEntriesPerDirectory: maxEntriesPerDirectory,
       );

  final RemoteDirectoryReader _reader;
  final int generation;
  final PathStyle style;

  /// For home lookup and listing together; the flight is aborted when it runs out.
  final Duration timeout;
  final _Cache _cache;
  final _flights = <String, _Flight>{};
  String? _home;
  var _disposed = false;

  String _cacheKey(String expanded) => style == PathStyle.windows ? expanded.toLowerCase() : expanded;

  @override
  Future<RemotePathResult> browse(RemotePathQuery query, {CancellationToken? cancel}) async {
    if (_disposed) throw const RemotePathException(RemotePathFailure.unavailable);
    final directory = RemotePaths.normalize(query.directory, style: style);
    if (!RemotePaths.validPrefix(query.prefix, style: style)) {
      throw const RemotePathException(RemotePathFailure.invalid);
    }
    if (cancel?.isCancelled ?? false) throw const RemotePathException(RemotePathFailure.cancelled);
    final expanded = _expanded(directory);
    if (expanded != null) {
      final hit = _cache.get(generation, _cacheKey(expanded));
      if (hit != null) {
        final failure = hit.failure;
        if (failure != null) throw RemotePathException(failure);
        return _answer(expanded, hit.items, query, complete: hit.complete, cached: true);
      }
    }
    final flight = _flight(directory);
    flight.waiters++;
    try {
      final listing = await (cancel == null
          ? flight.done
          : Future.any([
              flight.done,
              cancel.whenCancelled.then<_Listing>((_) => throw const RemotePathException(RemotePathFailure.cancelled)),
            ]));
      return _answer(listing.directory, listing.items, query, complete: listing.complete, cached: false);
    } finally {
      flight.waiters--;
      // Nobody is left to use the listing, so stop reading it.
      if (flight.waiters == 0 && !flight.finished) flight.abort.cancel();
    }
  }

  @override
  void invalidate([String? directory]) {
    if (directory == null) {
      _cache.clear();
      return;
    }
    try {
      final expanded = _expanded(RemotePaths.normalize(directory, style: style));
      if (expanded != null) _cache.remove(generation, _cacheKey(expanded));
    } on RemotePathException {
      // Nothing is cached under a path that is not valid.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final flight in [..._flights.values]) {
      flight.abort.cancel();
    }
    _flights.clear();
    _cache.clear();
    _home = null;
    _reader.close();
  }

  String? _expanded(String directory) {
    if (!RemotePaths.isHome(directory, style: style)) return directory;
    final home = _home;
    return home == null ? null : RemotePaths.expandHome(directory, home, style: style);
  }

  /// Joins the running listing of [directory], or supersedes whatever else is running with a new one.
  _Flight _flight(String directory) {
    final key = _cacheKey(directory);
    final existing = _flights[key];
    if (existing != null && !existing.abort.isCancelled) return existing;
    final running = [..._flights.values];
    for (final other in running) {
      other.abort.cancel();
    }
    final flight = _Flight(directory);
    _flights[key] = flight;
    unawaited(_run(flight, [for (final other in running) other.settled.future]));
    return flight;
  }

  Future<void> _run(_Flight flight, List<Future<void>> before) async {
    try {
      // The superseded listing closes its channel first; this one must not start on a channel that is going away.
      await Future.wait(before);
      if (flight.abort.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
      flight.deadline = Timer(timeout, () {
        flight.timedOut = true;
        flight.abort.cancel();
      });
      var expanded = _expanded(flight.directory);
      if (expanded == null) {
        final String home;
        try {
          home = RemotePaths.normalize(await _reader.home(flight.abort), style: style);
        } on RemotePathException catch (e) {
          // A home the server reported that is not an absolute, valid path is the server's fault, not the query's.
          throw e.kind == RemotePathFailure.invalid ? const RemotePathException(RemotePathFailure.unavailable) : e;
        }
        if (RemotePaths.isHome(home, style: style)) throw const RemotePathException(RemotePathFailure.unavailable);
        if (!_disposed) _home = home;
        expanded = RemotePaths.expandHome(flight.directory, home, style: style);
      }
      flight.expanded = expanded;
      final raw = await _reader.list(expanded, flight.abort);
      if (flight.abort.isCancelled) throw const RemotePathException(RemotePathFailure.cancelled);
      // The reader is trusted to stop at the limit; whatever it hands over beyond it is dropped all the same.
      final complete = raw.complete && raw.items.length <= RemotePaths.maxScanned;
      final items = _vetted(raw.items.take(RemotePaths.maxScanned), style: style);
      if (!_disposed) _cache.put(generation, _cacheKey(expanded), items: items, complete: complete);
      flight.complete(_Listing(expanded, items, complete));
    } on RemotePathException catch (e) {
      var kind = e.kind;
      if (kind == RemotePathFailure.cancelled) {
        if (_disposed) {
          kind = RemotePathFailure.unavailable;
        } else if (flight.timedOut) {
          kind = RemotePathFailure.timeout;
        }
      }
      final expanded = flight.expanded;
      if (expanded != null && !_disposed && _remembered.contains(kind)) {
        _cache.put(generation, _cacheKey(expanded), failure: kind);
      }
      flight.fail(RemotePathException(kind));
    } on Object catch (e, stack) {
      flight.fail(e, stack);
    } finally {
      flight.deadline?.cancel();
      flight.finished = true;
      final key = _cacheKey(flight.directory);
      if (identical(_flights[key], flight)) _flights.remove(key);
      flight.settled.complete();
    }
  }

  /// A slow, missing or forbidden directory is not asked again on every key press; the other failures say nothing
  /// about the directory.
  static const _remembered = {
    RemotePathFailure.denied,
    RemotePathFailure.notFound,
    RemotePathFailure.failed,
    RemotePathFailure.timeout,
  };

  /// The listing with unusable names and repeats removed.
  static List<RemoteDirectoryItem> _vetted(Iterable<RemoteDirectoryItem> raw, {PathStyle style = PathStyle.posix}) {
    final seen = HashSet<String>();
    final fold = style == PathStyle.windows;
    return [
      for (final item in raw)
        if (RemotePaths.validName(item.name, style: style) && seen.add(fold ? item.name.toLowerCase() : item.name))
          item,
    ];
  }

  RemotePathResult _answer(
    String directory,
    List<RemoteDirectoryItem> items,
    RemotePathQuery query, {
    required bool complete,
    required bool cached,
  }) {
    final prefix = query.prefix;
    final fold = style == PathStyle.windows;
    final lowerPrefix = fold ? prefix.toLowerCase() : prefix;
    final showHidden = prefix.startsWith('.');
    final matched = [
      for (final item in items)
        if ((fold ? item.name.toLowerCase().startsWith(lowerPrefix) : item.name.startsWith(prefix)) &&
            (showHidden || !item.name.startsWith('.')) &&
            (!query.foldersOnly || item.enterable))
          item,
    ];
    matched.sort((a, b) {
      if (a.enterable != b.enterable) return a.enterable ? -1 : 1;
      return fold ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : a.name.compareTo(b.name);
    });
    final entries = <RemotePathEntry>[];
    for (final item in matched) {
      if (entries.length == RemotePaths.maxVisible) break;
      final String path;
      try {
        path = RemotePaths.child(directory, item.name, style: style);
      } on RemotePathException {
        continue; // the path would be too long to navigate to
      }
      entries.add(RemotePathEntry(item.name, item.kind, path, linkToDirectory: item.linkToDirectory));
    }
    return RemotePathResult(
      directory: directory,
      prefix: prefix,
      entries: entries,
      truncated: matched.length > entries.length || !complete,
      generation: generation,
      cached: cached,
    );
  }
}

class _Listing {
  const _Listing(this.directory, this.items, this.complete);

  final String directory;
  final List<RemoteDirectoryItem> items;
  final bool complete;
}

/// One listing in progress, shared by everyone who asked for the same directory.
class _Flight {
  _Flight(this.directory) {
    _done.future.ignore();
  }

  /// Normalised, `~` not yet expanded.
  final String directory;
  final abort = CancellationToken();
  final settled = Completer<void>();
  final _done = Completer<_Listing>();
  Timer? deadline;
  String? expanded;
  var waiters = 0;
  var timedOut = false;
  var finished = false;

  Future<_Listing> get done => _done.future;

  void complete(_Listing listing) {
    if (!_done.isCompleted) _done.complete(listing);
  }

  void fail(Object error, [StackTrace? stack]) {
    if (!_done.isCompleted) _done.completeError(error, stack);
  }
}

class _Cached {
  const _Cached(this.at, this.items, this.complete, this.failure);

  final DateTime at;
  final List<RemoteDirectoryItem> items;
  final bool complete;
  final RemotePathFailure? failure;
}

/// Bounded by age, by directory count and by the entries held in all; the least recently used goes first.
class _Cache {
  _Cache(
    this._now, {
    required this.ttl,
    required this.maxDirectories,
    required this.maxEntries,
    required this.maxEntriesPerDirectory,
  });

  final DateTime Function() _now;
  final Duration ttl;
  final int maxDirectories, maxEntries, maxEntriesPerDirectory;
  final _held = <(int, String), _Cached>{};
  var _count = 0;

  _Cached? get(int generation, String directory) {
    final key = (generation, directory);
    final hit = _held.remove(key);
    if (hit == null) return null;
    _count -= hit.items.length;
    if (_now().difference(hit.at) >= ttl) return null;
    _held[key] = hit;
    _count += hit.items.length;
    return hit;
  }

  void put(
    int generation,
    String directory, {
    List<RemoteDirectoryItem> items = const [],
    bool complete = true,
    RemotePathFailure? failure,
  }) {
    if (items.length > maxEntriesPerDirectory) return;
    remove(generation, directory);
    final now = _now();
    _held.removeWhere((_, cached) {
      final expired = now.difference(cached.at) >= ttl;
      if (expired) _count -= cached.items.length;
      return expired;
    });
    _held[(generation, directory)] = _Cached(now, items, complete, failure);
    _count += items.length;
    while (_held.length > maxDirectories || _count > maxEntries) {
      final oldest = _held.keys.first;
      _count -= _held.remove(oldest)!.items.length;
    }
  }

  void remove(int generation, String directory) {
    final removed = _held.remove((generation, directory));
    if (removed != null) _count -= removed.items.length;
  }

  void clear() {
    _held.clear();
    _count = 0;
  }
}
