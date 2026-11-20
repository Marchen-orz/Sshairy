/// Shell integration (docs/TERMINAL_ASSISTANCE.md): an opt-in rc line makes Sshairy sessions report prompt and
/// command boundaries (OSC 133) and the working directory (OSC 7). The client side already parses both.
library;

import 'dart:convert';

import 'directory.dart';

const _marker = '# sshairy-shell-integration';
const _file = r'$HOME/.sshairy/shell-integration.sh';

/// bash saves `$?` first and returns it unchanged so the user's own prompt commands still see it.
const _script =
    r'''# Sshairy shell integration: OSC 133 command boundaries and OSC 7 cwd. Remove it from Sshairy's terminal menu.
case $- in *i*) ;; *) return 0 2>/dev/null ;; esac
[ -z "$__sshairy_si" ] || return 0 2>/dev/null
__sshairy_si=1
__sshairy_keep() { __sshairy_status=$?; return $__sshairy_status; }
__sshairy_cwd() {
  local p="${PWD//\%/%25}"
  printf '\033]133;D;%s\007\033]7;file://%s%s\007' "$__sshairy_status" "$1" "${p// /%20}"
}
if [ -n "$BASH_VERSION" ]; then
  __sshairy_prompt() {
    __sshairy_cwd "$HOSTNAME"
    case $PS1 in *'133;B'*) ;; *) PS1='\[\033]133;A\007\]'"$PS1"'\[\033]133;B\007\]' ;; esac
    return $__sshairy_status
  }
  PROMPT_COMMAND=$'__sshairy_keep\n'"$PROMPT_COMMAND"$'\n__sshairy_prompt'
  PS0="$PS0"$'\033]133;C\007'
elif [ -n "$ZSH_VERSION" ]; then
  __sshairy_prompt() {
    __sshairy_cwd "$HOST"
    case $PS1 in *'133;B'*) ;; *) PS1=$'%{\033]133;A\007%}'"$PS1"$'%{\033]133;B\007%}' ;; esac
    return $__sshairy_status
  }
  __sshairy_exec() { printf '\033]133;C\007'; }
  precmd_functions=(__sshairy_keep $precmd_functions __sshairy_prompt)
  preexec_functions+=(__sshairy_exec)
fi''';

/// Writes the script and appends one guarded line to each existing `.bashrc`/`.zshrc`; idempotent.
final shellIntegrationInstall = _encoded('''set -e
mkdir -p "\$HOME/.sshairy"
cat > "$_file" <<'SSHAIRY_EOF'
$_script
SSHAIRY_EOF
for rc in "\$HOME/.bashrc" "\$HOME/.zshrc"; do
  [ -f "\$rc" ] || continue
  grep -qF '$_marker' "\$rc" && continue
  [ -z "\$(tail -c 1 "\$rc")" ] || echo >> "\$rc"
  echo 'if [ -n "\$$directoryVariable" ] && [ -r "$_file" ]; then . "$_file"; fi $_marker' >> "\$rc"
done''');

/// Drops the marked lines and the script. A failed rewrite leaves the full copy in `<rc>.sshairy-tmp`.
final shellIntegrationRemove = _encoded('''status=0
for rc in "\$HOME/.bashrc" "\$HOME/.zshrc"; do
  [ -f "\$rc" ] && grep -qF '$_marker' "\$rc" || continue
  grep -vF '$_marker' "\$rc" > "\$rc.sshairy-tmp"
  [ \$? -le 1 ] && cat "\$rc.sshairy-tmp" > "\$rc" && rm -f "\$rc.sshairy-tmp" || status=1
done
rm -f "$_file"
rmdir "\$HOME/.sshairy" 2>/dev/null
exit \$status''');

/// base64 keeps the script out of the login shell's quoting rules, whichever shell that is.
String _encoded(String script) => 'printf %s ${base64.encode(utf8.encode(script))} | base64 -d | sh';
