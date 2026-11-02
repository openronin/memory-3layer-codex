#!/usr/bin/env bash
# memory-secrets.sh — machine-local secret store plus a scanner for memory files.
#
# Memory may be synced, so it holds references (secret://<name>), never values.
# Values live in one mode-600 file per secret, outside any synced directory.
# No command prints a value to a pipe; agents use `run`, humans can use `get`.
# Files are protected by permissions only: they are not encrypted at rest.

set -u

STORE="${MEMORY_3LAYER_SECRETS:-${XDG_DATA_HOME:-$HOME/.local/share}/memory-3layer-secrets}"
MEMORY_HOME="${MEMORY_3LAYER_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/memory-3layer}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
IGNORE_MARK='secret-scan:ignore'

die() { printf 'memory-secrets: %s\n' "$*" >&2; exit 2; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad name '$1' (use letters, digits, . _ -)"; }

ensure_store() {
  ( umask 077; mkdir -p "$STORE" ) || die "cannot create $STORE"
  chmod 700 "$STORE"
}

read_value() {
  # Read from stdin and strip one trailing newline. A value never comes from argv,
  # because argv is visible in `ps` and in the agent's transcript.
  local v
  if [[ -t 0 ]]; then
    IFS= read -r -s -p "value: " v; echo >&2
  else
    v=$(cat)
  fi
  [[ -n "$v" ]] || die "empty value"
  printf '%s' "$v"
}

store_value() {
  # store_value <name> <value>: a new file is created mode 600 by the umask.
  ensure_store
  ( umask 077; printf '%s' "$2" > "$STORE/$1.tmp" && mv "$STORE/$1.tmp" "$STORE/$1" ) || die "cannot write '$1'"
}

# --- detection ---------------------------------------------------------------

KV_KEYS='[Pp]ass(word|wd|phrase)?|PASS(WORD|WD)?|[Пп]ароль|[Tt]oken|TOKEN|[Тт]окен|[Ss]ecret|SECRET|[Aa]pi[_-]?[Kk]ey|API[_-]?KEY'

is_placeholder() {
  local v="$1" low
  low=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$v" in '<'*|'$'*|'{'*|'%'*|'['*|'('*|secret://*|*'('*|*'$'*|*'{{'*|*'->'*|/*|./*|~/*) return 0 ;; esac
  case "$low" in *xxx*|*'***'*|*'...'*|*'…'*|*example*|*changeme*|*placeholder*|*redacted*|*your*|*dummy*|*sample*) return 0 ;; esac
  return 1
}

looks_random() {
  # Generic key=value only: prose such as "token: required" has no digits or
  # mixed case. This is a heuristic that trades some recall for few false blocks.
  [[ "$1" =~ [0-9] || ( "$1" =~ [a-z] && "$1" =~ [A-Z] ) ]]
}

kv_value() {
  # Strip "key<sep><quote>" from a key=value match, leaving the value.
  printf '%s' "$1" | sed -E 's/^[^:=]*[:=][[:space:]]*["'"'"'`]?//'
}

url_value() {
  # Password part of scheme://user:password@host.
  printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^:/@ ]*:##; s#@$##'
}

# find_secrets: read text on stdin, emit "line<TAB>kind<TAB>value".
# Internal only: every public command must drop the value before printing.
find_secrets() {
  local text kind re m ln raw v
  text=$(cat; printf x); text=${text%x}
  local -a kinds=(
    'anthropic|sk-ant-[A-Za-z0-9_-]{20,}'
    'openai|sk-(proj-)?[A-Za-z0-9_-]{32,}'
    'gitlab|glpat-[A-Za-z0-9_-]{16,}'
    'github|gh[pousr]_[A-Za-z0-9]{30,}'
    'github|github_pat_[A-Za-z0-9_]{30,}'
    'slack|xox[abprs]-[A-Za-z0-9-]{10,}'
    'aws|AKIA[0-9A-Z]{16}'
    'jwt|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  )
  for kind in "${kinds[@]}"; do
    re=${kind#*|}; kind=${kind%%|*}
    while IFS=: read -r ln m; do
      [[ -n "$ln" ]] && printf '%s\t%s\t%s\n' "$ln" "$kind" "$m"
    done < <(printf '%s' "$text" | grep -nEoa -- "$re" || true)
  done
  while IFS=: read -r ln raw; do
    [[ -n "$ln" ]] || continue
    v=$(url_value "$raw")
    is_placeholder "$v" || printf '%s\t%s\t%s\n' "$ln" url-password "$v"
  done < <(printf '%s' "$text" | grep -nEoa '[a-zA-Z][a-zA-Z0-9+.-]*://[^:/@[:space:]]*:[^/@[:space:]]{3,}@' || true)
  while IFS=: read -r ln raw; do
    [[ -n "$ln" ]] || continue
    v=$(kv_value "$raw")
    is_placeholder "$v" && continue
    looks_random "$v" || continue
    printf '%s\t%s\t%s\n' "$ln" key-value "$v"
  done < <(printf '%s' "$text" | grep -nEoa "($KV_KEYS)[\"'\`]?[[:space:]]*[:=][[:space:]]*[\"'\`]?[^[:space:]\"'\`,;)]{8,}" || true)
}

# scan_text: findings with lines carrying the ignore mark removed.
scan_text() {
  local text ln kind v
  text=$(cat; printf x); text=${text%x}
  while IFS=$'\t' read -r ln kind v; do
    printf '%s' "$text" | sed -n "${ln}p" | grep -q "$IGNORE_MARK" && continue
    printf '%s\t%s\t%s\n' "$ln" "$kind" "$v"
  done < <(printf '%s' "$text" | find_secrets)
}

default_paths() {
  local d
  [[ -d "$MEMORY_HOME" ]] && printf '%s\n' "$MEMORY_HOME"
  [[ -d "$CLAUDE_HOME/memory" ]] && printf '%s\n' "$CLAUDE_HOME/memory"
  for d in "$CLAUDE_HOME"/projects/*/memory; do [[ -d "$d" ]] && printf '%s\n' "$d"; done
}

cmd_scan() {
  local found=0 f p ln kind v
  local -a paths=()
  if [[ $# -gt 0 ]]; then paths=("$@"); else mapfile -t paths < <(default_paths); fi
  [[ ${#paths[@]} -gt 0 ]] || return 0
  while IFS= read -r f; do
    while IFS=$'\t' read -r ln kind v; do
      printf '%s:%s\t%s\n' "$f" "$ln" "$kind"
      found=1
    done < <(scan_text < "$f")
  done < <(for p in "${paths[@]}"; do
      # A file named directly is always scanned, whatever its extension.
      if [[ -f "$p" ]]; then printf '%s\n' "$p"; else find -L "$p" -type f \( -name '*.md' -o -name '*.md.bak*' -o -name '*.txt' \) 2>/dev/null; fi
    done | sort)
  return $found
}

cmd_adopt() {
  # adopt <file>:<line> <name>: move the value found on that line into the store
  # and replace every occurrence in the file with secret://<name>.
  [[ $# -eq 2 ]] || die "usage: adopt <file>:<line> <name>"
  local f=${1%:*} want=${1##*:} name=$2 ln kind v val=""
  valid_name "$name"
  [[ -f "$f" && "$want" =~ ^[0-9]+$ ]] || die "expected <file>:<line>, got '$1'"
  while IFS=$'\t' read -r ln kind v; do
    [[ "$ln" == "$want" ]] || continue
    [[ "$kind" == private-key ]] && die "$f:$ln: a private key spans lines; move it by hand"
    val=$v; break
  done < <(scan_text < "$f")
  [[ -n "$val" ]] || die "no finding at $f:$want"
  [[ -e "$STORE/$name" ]] && [[ "$(cat "$STORE/$name")" != "$val" ]] && die "'$name' already holds a different value"
  store_value "$name" "$val"
  local tmp; tmp=$(mktemp "$f.XXXXXX") || die "cannot create a temp file next to $f"
  V="$val" R="secret://$name" awk 'BEGIN{v=ENVIRON["V"];r=ENVIRON["R"]}
    {o="";s=$0;while((i=index(s,v))>0){o=o substr(s,1,i-1) r;s=substr(s,i+length(v))};print o s}' "$f" > "$tmp" \
    && { chmod --reference="$f" "$tmp" 2>/dev/null; mv "$tmp" "$f"; } || { rm -f "$tmp"; die "cannot rewrite $f"; }
  printf 'adopted %s:%s as secret://%s\n' "$f" "$want" "$name"
}

# --- Claude Code guard: PreToolUse JSON on stdin, exit 2 blocks the write --------

is_memory_path() {
  case "$1" in
    "$MEMORY_HOME"/*|"~${MEMORY_HOME#"$HOME"}"/*) return 0 ;;
  esac
  case "$1" in
    */.claude/memory/*|*/.claude/projects/*/memory/*|*/.claude-docs/*|*/CLAUDE.md|*/AGENTS.md|*/IDENTITY.md|*/SESSION*.md) return 0 ;;
  esac
  return 1
}

bash_writes_memory() {
  # True when a command writes to a memory file: redirect, tee or sed -i. Merely
  # mentioning a memory path, as a test fixture does, is not a write.
  local text=$1 word line
  while IFS= read -r word; do
    word=${word##*>}; word=${word#tee}; word=${word# -a}
    word=$(printf '%s' "$word" | sed -E "s/^[[:space:]]+//; s/[\"']//g")
    is_memory_path "$word" && return 0
  done < <(printf '%s\n' "$text" | grep -oE "(>>?|tee( -a)?)[[:space:]]*[\"']?[^[:space:]\"'|;&]+" || true)
  while IFS= read -r line; do
    for word in $line; do
      word=${word//[\"\']/}
      is_memory_path "$word" && return 0
    done
  done < <(printf '%s\n' "$text" | grep -E '(^|[[:space:];&|])sed[[:space:]]+-i' || true)
  return 1
}

cmd_guard() {
  # Blocks a secret on its way into memory. A clean Read, Write or Edit inside the
  # data dir is approved, because a plugin hook is the only way to grant this access
  # without editing the user's settings. Paths are resolved first, so neither ".."
  # nor a symlink can lead the approval outside, and the secret store is excluded.
  local input tool path inside text parsed kinds
  input=$(cat)
  command -v python3 >/dev/null 2>&1 || return 0
  parsed=$(printf '%s' "$input" | M_HOME="$MEMORY_HOME" M_STORE="$STORE" python3 -c '
import json, os, sys
d = json.load(sys.stdin); i = d.get("tool_input") or {}
t = d.get("tool_name", "")
patch = i.get("command", "") if isinstance(i.get("command"), str) else ""
cwd = d.get("cwd") or os.getcwd()
if t == "apply_patch" or patch.lstrip().startswith("*** Begin Patch"):
    # Codex: the paths and the added lines of a patch.
    t = "Patch"; files = []; added = []
    for l in patch.splitlines():
        for mark in ("*** Add File: ", "*** Update File: ", "*** Move to: "):
            if l.startswith(mark):
                files.append(os.path.realpath(os.path.join(cwd, os.path.expanduser(l[len(mark):].strip()))))
        if l.startswith("+"): added.append(l[1:])
    home = os.path.realpath(os.environ["M_HOME"])
    print(t); print("\t".join(files)); print(0); sys.stdout.write("\n".join(added)); sys.exit()
if t == "Write": text = i.get("content", "")
elif t == "Edit": text = i.get("new_string", "")
elif t == "MultiEdit": text = "\n".join(e.get("new_string", "") for e in i.get("edits", []))
elif t == "Bash": text = i.get("command", "")
else: text = ""
p = i.get("file_path", "")
real = os.path.realpath(os.path.expanduser(p)) if p else ""
home = os.path.realpath(os.environ["M_HOME"]); store = os.path.realpath(os.environ["M_STORE"])
inside = real.startswith(home + os.sep) and real != store and not real.startswith(store + os.sep)
print(t); print(real); print(1 if inside else 0); sys.stdout.write(text)
' 2>/dev/null) || return 0
  tool=$(printf '%s\n' "$parsed" | sed -n 1p)
  path=$(printf '%s\n' "$parsed" | sed -n 2p)
  inside=$(printf '%s\n' "$parsed" | sed -n 3p)
  text=$(printf '%s\n' "$parsed" | sed 1,3d)
  case "$tool" in
    Bash) bash_writes_memory "$text" || return 0 ;;
    Patch)
      local f hit=0
      while IFS= read -r f; do is_memory_path "$f" && hit=1; done < <(printf '%s\n' "$path" | tr '\t' '\n')
      [[ $hit -eq 1 ]] || return 0 ;;
    Read|Write|Edit|MultiEdit) [[ "$inside" == 1 ]] || is_memory_path "$path" || return 0 ;;
    *) return 0 ;;
  esac
  kinds=$(printf '%s\n' "$text" | scan_text | cut -f2 | sort -u | paste -sd, -)
  if [[ -n "$kinds" ]]; then
    printf 'BLOCKED: this write to memory contains a secret (%s). Memory may be synced, so it holds references only. Ask the user to store the value with `memory-3layer secret put <name>`, then write secret://<name>. Do not repeat the value. If this is a false positive, add %s to that line.\n' "$kinds" "$IGNORE_MARK" >&2
    return 2
  fi
  if [[ "$tool" != Bash && "$tool" != Patch && "$inside" == 1 ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"memory-3layer data directory"}}\n'
  fi
  return 0
}

# --- store commands ----------------------------------------------------------

cmd_run() {
  # run VAR=name [VAR=name...] -- command: expose secrets only to that process.
  local a var name
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    a=$1; shift
    [[ "$a" == *=* ]] || die "expected VAR=name, got '$a'"
    var=${a%%=*}; name=${a#*=}
    [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "bad variable '$var'"
    valid_name "$name"
    [[ -f "$STORE/$name" ]] || die "no secret '$name' on this machine"
    export "$var=$(cat "$STORE/$name")"
  done
  [[ $# -ge 2 ]] || die "usage: run VAR=name... -- command [args]"
  shift
  exec "$@"
}

usage() {
  cat <<'USAGE'
memory-secrets.sh — local secret store; memory holds secret://<name> references only

  put <name>                 store a value from stdin or a hidden prompt
  list                       names on this machine, never values
  has <name>                 exit 0 if the secret exists here
  rm <name>                  delete a secret
  run VAR=name... -- cmd     run cmd with the secrets in its environment
  get <name>                 print a value to a terminal; refused in a pipe
  scan [path...]             report file:line and kind, exit 1 if anything is found
  adopt <file>:<line> <name> move a found value into the store, leave a reference
  guard                      Claude Code PreToolUse hook (JSON on stdin)
USAGE
}

cmd=${1:-}; [[ $# -gt 0 ]] && shift
case "$cmd" in
  put) [[ $# -eq 1 ]] || die "usage: put <name>"; valid_name "$1"; v=$(read_value) || exit 2; store_value "$1" "$v"; printf 'stored secret://%s\n' "$1" ;;
  list) for f in "$STORE"/*; do [[ -f "$f" && "$f" != *.tmp ]] && printf '%s\n' "${f##*/}"; done; exit 0 ;;
  has) [[ $# -eq 1 ]] || die "usage: has <name>"; valid_name "$1"; [[ -f "$STORE/$1" ]] ;;
  rm) [[ $# -eq 1 ]] || die "usage: rm <name>"; valid_name "$1"; rm -- "$STORE/$1" 2>/dev/null || die "no secret '$1'" ;;
  run) cmd_run "$@" ;;
  get)
    [[ $# -eq 1 ]] || die "usage: get <name>"; valid_name "$1"
    [[ -t 1 ]] || die "get prints to a terminal only; use: run VAR=$1 -- command"
    [[ -f "$STORE/$1" ]] || die "no secret '$1' on this machine"
    cat "$STORE/$1"; echo ;;
  scan) cmd_scan "$@" ;;
  adopt) cmd_adopt "$@" ;;
  guard) cmd_guard ;;
  ''|-h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
