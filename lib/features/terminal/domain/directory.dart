/// Following the shell's working directory (docs/MODULES.md §3): the shell is opened with a random marker in its
/// environment, and a read-only script finds the process that carries it.
library;

const directoryVariable = 'LC_SSHAIRY_SESSION';

final _token = RegExp(r'^[0-9a-f]{16}$');

/// The login shell is the session leader with a terminal whose parent lacks the marker (tmux panes and daemons
/// inherit it but fail one of the two). A shell in the terminal's foreground group that carries the marker, such
/// as a nested bash, comes second and wins.
const _script = r'''cd /proc 2>/dev/null || exit 0
ids=" $(grep -lzsx "VARIABLE=TOKEN" [0-9]*/environ | cut -d/ -f1 | tr "\n" " ")"
for p in $ids; do
  s=$(cat $p/stat 2>/dev/null) || continue
  set -- ${s##*) }
  [ "$4" = "$p" ] && [ "$5" != 0 ] || continue
  case "$ids" in *" $2 "*) continue;; esac
  readlink $p/cwd
  f=$6
  [ "$f" != "$p" ] || exit 0
  case "$ids" in *" $f "*) ;; *) exit 0;; esac
  case $(cat $f/comm 2>/dev/null) in
    bash|zsh|fish|sh|dash|ksh|mksh|ash|tcsh|csh) readlink $f/cwd;;
  esac
  exit 0
done''';

/// Throws on a [token] that is not 16 lowercase hex digits, so nothing else can reach the command.
String directoryQuery(String token) {
  if (!_token.hasMatch(token)) throw ArgumentError.value(token, 'token');
  return "sh -c '${_script.replaceFirst('VARIABLE', directoryVariable).replaceFirst('TOKEN', token)}'";
}

/// The last absolute path the script printed; null when it found nothing or the directory was deleted.
String? parseDirectoryQuery(String output) {
  final lines = output.split('\n').map((l) => l.trimRight()).where((l) => l.startsWith('/'));
  if (lines.isEmpty) return null;
  final path = lines.last;
  return path.endsWith(' (deleted)') ? null : path;
}

/// The path of an OSC 7 report (`file://host/path`, percent-encoded); null for anything else.
String? parseOsc7(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme != 'file') return null;
  final String path;
  try {
    path = Uri.decodeComponent(parsed.path);
  } on Object {
    return null;
  }
  return path.startsWith('/') ? path : null;
}
