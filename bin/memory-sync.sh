#!/usr/bin/env bash
# memory-sync.sh — sync the data directory with the storages the user configured.
# Design: docs/sync.md. Run through `memory-3layer sync`.
#
# The data directory stays one plain tree. Each storage is a private git repository
# cloned under the state directory, and those clones are only transport.

set -u

SELF_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
DATA="${MEMORY_3LAYER_HOME:?}"
STATE="${MEMORY_3LAYER_STATE:?}"
CONFIG_DIR="${MEMORY_3LAYER_CONFIG_DIR:?}"
LOCAL_CONF="$CONFIG_DIR/storage.conf"
ROUTING_CONF="$DATA/routing.conf"
STORES="$STATE/stores"
HOST=$(hostname -s 2>/dev/null || echo unknown)

MODE=full
QUIET=0
NET_TIMEOUT=30

declare -A RULE=()
declare -A ACCESS=()
NET_WHY=""
declare -A SKIPPED=()

say() { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }

# --- configuration ------------------------------------------------------------

read_conf() {
  # key = value, [project <key>], # comment. The first file read wins on the same rule.
  local file=$1 line section="" storage="" k v
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line=$(printf '%s' "$line" | sed -E 's/(^|[[:space:]])#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^\[project[[:space:]]+([^]]+)\]$ ]]; then
      section=${BASH_REMATCH[1]}; storage=""; continue
    fi
    if [[ "$line" =~ ^\[storage[[:space:]]+([^]]+)\]$ ]]; then
      # Access is per machine: key paths differ, and routing.conf travels.
      section=""; storage=""
      if [[ "$file" == "$LOCAL_CONF" ]]; then
        storage=${BASH_REMATCH[1]}
      else
        printf 'memory-3layer: [storage] is read only from %s, ignored in %s\n' "$LOCAL_CONF" "$file" >&2
        section="?"
      fi
      continue
    fi
    if [[ "$line" == \[* ]]; then
      printf 'memory-3layer: unknown section in %s: %s\n' "$file" "$line" >&2; section="?"; continue
    fi
    [[ "$line" == *=* ]] || { printf 'memory-3layer: bad line in %s, ignored\n' "$file" >&2; continue; }
    k=${line%%=*}; v=${line#*=}
    k=$(printf '%s' "$k" | tr -d '[:space:]'); v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//')
    [[ "$section" == "?" ]] && continue
    if [[ -n "$storage" ]]; then
      case "$k" in
        ssh_key|ssh_agent) ACCESS[$storage|$k]=${v/#\~/$HOME} ;;
        username) ACCESS[$storage|$k]=$v ;;
        password)
          if [[ "$v" == secret://* ]]; then
            ACCESS[$storage|$k]=${v#secret://}
          else
            ACCESS[$storage|bad]=1
            printf 'memory-3layer: password must be secret://<name>, in [storage] of %s\n' "$file" >&2
          fi ;;
        *) printf 'memory-3layer: unknown key in [storage] of %s: %s\n' "$file" "$k" >&2 ;;
      esac
      continue
    fi
    case "$k" in
      default|project|session|archive) ;;
      identity) [[ -z "$section" ]] || { printf 'memory-3layer: identity is global only, ignored in [project %s]\n' "$section" >&2; continue; } ;;
      *) printf 'memory-3layer: unknown key in %s: %s\n' "$file" "$k" >&2; continue ;;
    esac
    [[ -n "${RULE[$section|$k]:-}" ]] || RULE[$section|$k]=$v
  done < "$file"
}

load_conf() {
  RULE=(); ACCESS=()
  read_conf "$LOCAL_CONF"
  read_conf "$ROUTING_CONF"
}

first_rule() {
  local id
  for id in "$@"; do
    if [[ -n "${RULE[$id]:-}" ]]; then printf '%s' "${RULE[$id]}"; return 0; fi
  done
  printf none
}

route() {
  # route <key> <layer>: the most specific rule wins, and a project beats a layer.
  # An archive follows the L2 storage unless it has its own rule.
  local key=$1 layer=$2
  case "$layer" in
    identity) first_rule '|identity' '|default' ;;
    meta) first_rule '|default' ;;
    archive) first_rule "$key|archive" "$key|session" "$key|default" '|archive' '|session' '|default' ;;
    *) first_rule "$key|$layer" "$key|default" "|$layer" '|default' ;;
  esac
}

route_path() {
  # route_path <path relative to the data dir>
  local p=$1 name key layer
  case "$p" in
    identity/*) route - identity; return ;;
    routing.conf|aliases.tsv) route - meta; return ;;
    projects/*) ;;
    *) printf none; return ;;
  esac
  p=${p#projects/}; name=${p##*/}
  case "$p" in
    */imported/*) key=${p%%/imported/*} ;;
    */superseded/*) key=${p%%/superseded/*} ;;
    *) key=${p%/*} ;;
  esac
  case "$name" in
    SESSION.md) layer=session ;;
    SESSION.*) layer=archive ;;
    *) layer=project ;;
  esac
  route "$key" "$layer"
}

has_password() { [[ "$1" =~ ://[^/@:]+:[^/@]+@ ]]; }

all_stores() {
  # The default storage first: it can carry the routing for the others.
  local id v default
  default=$(first_rule '|default')
  [[ "$default" != none ]] && printf '%s\n' "$default"
  for id in "${!RULE[@]}"; do
    v=${RULE[$id]}
    [[ "$v" == none || "$v" == "$default" ]] || printf '%s\n' "$v"
  done | sort -u
}

# --- helpers ------------------------------------------------------------------

store_id() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

stamp_of() {
  # Seconds from the last_updated marker of a file, or nothing.
  local s
  s=$(grep -oE 'last_updated:[[:space:]]*[0-9T:.Z+-]+' "$1" 2>/dev/null | head -n1 | sed 's/last_updated:[[:space:]]*//')
  [[ -n "$s" ]] && date -d "$s" +%s 2>/dev/null
}

theirs_is_newer() {
  # theirs_is_newer <ours file> <theirs file> <ours fallback> <theirs fallback>
  local a b
  a=$(stamp_of "$1"); b=$(stamp_of "$2")
  [[ -n "$a" ]] || a=$3
  [[ -n "$b" ]] || b=$4
  [[ "${b:-0}" -gt "${a:-0}" ]]
}

loser_path() {
  # Where the losing version of a conflict goes, next to the file.
  local p=$1 host=$2 dir=.
  [[ "$p" == */* ]] && dir=${p%/*}
  printf '%s/superseded/conflict-%s/%s' "$dir" "$host" "${p##*/}"
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

put() {
  # put <source> <destination>
  # Through a temp file, so a session reading the destination never sees half of it.
  mkdir -p "${2%/*}" && cp -p "$1" "$2.$$.tmp" && mv -f "$2.$$.tmp" "$2"
}

routed_files() {
  # Paths in the data dir that go to this storage. Aliases are written per storage.
  local addr=$1 p
  [[ -d "$DATA" ]] || return 0
  while IFS= read -r p; do
    p=${p#"$DATA"/}
    case "$p" in *.template.md|*.tmp|aliases.tsv|.*) continue ;; esac
    [[ "$(route_path "$p")" == "$addr" ]] && printf '%s\n' "$p"
  done < <(find "$DATA" -type f | sort)
  return 0
}

# --- one storage --------------------------------------------------------------

g() { git -C "$CLONE" -c user.name=memory-3layer -c "user.email=memory-3layer@$HOST" -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }

access_problem() {
  # What is wrong with this storage's access settings, before going to the network.
  local a=$1 v
  [[ -z "${ACCESS[$a|bad]:-}" ]] || { printf 'password in storage.conf is not a secret:// reference'; return; }
  v=${ACCESS[$a|ssh_key]:-}
  [[ -z "$v" || -f "$v" ]] || { printf 'ssh key file is missing'; return; }
  v=${ACCESS[$a|ssh_agent]:-}
  [[ -z "$v" || -S "$v" ]] || { printf 'ssh agent socket is not running'; return; }
  v=${ACCESS[$a|password]:-}
  if [[ -n "$v" ]] && ! bash "$SELF_DIR/memory-secrets.sh" has "$v" >/dev/null 2>&1; then
    printf 'secret %s is missing on this machine' "$v"
  fi
}

classify() {
  # classify <exit code> <stderr>. Only this label is shown, never git's own text.
  local e; e=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  [[ "$1" == 124 ]] && { printf 'unreachable'; return; }
  case "$e" in
    *"host key verification failed"*) printf 'host key not trusted' ;;
    *"permission denied"*|*"authentication failed"*|*"could not read username"*|*"could not read password"*|*"not allowed"*|*"access denied"*|*"not authorized"*|*" 401"*|*" 403"*) printf 'access denied' ;;
    *"could not resolve"*|*"timed out"*|*"connection refused"*|*"network is unreachable"*|*"no route to host"*|*"connection reset"*|*"closed by remote host"*) printf 'unreachable' ;;
    *"repository not found"*|*"does not exist"*|*"does not appear to be a git repository"*|*"not found"*) printf 'not found' ;;
    *) printf 'failed' ;;
  esac
}

net_git() {
  # git against the current storage, with its access settings and never a prompt.
  # The password reaches git through the environment, so it is not in any argument.
  local rc=0 err ssh key agent user pass
  local -a envs=(GIT_TERMINAL_PROMPT=0) opts=() wrap=()
  NET_WHY=$(access_problem "$ADDR")
  [[ -z "$NET_WHY" ]] || return 1
  ssh="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=$NET_TIMEOUT"
  key=${ACCESS[$ADDR|ssh_key]:-}; agent=${ACCESS[$ADDR|ssh_agent]:-}
  user=${ACCESS[$ADDR|username]:-}; pass=${ACCESS[$ADDR|password]:-}
  [[ -z "$key" ]] || ssh+=" -i $(printf '%q' "$key") -o IdentitiesOnly=yes -o IdentityAgent=none"
  [[ -z "$agent" ]] || envs+=("SSH_AUTH_SOCK=$agent")
  [[ -z "$user" ]] || opts+=(-c "credential.username=$user")
  if [[ -n "$pass" ]]; then
    envs+=("MEMORY_3LAYER_GIT_USER=${user:-git}")
    wrap=(bash "$SELF_DIR/memory-secrets.sh" run "MEMORY_3LAYER_GIT_PASS=$pass" --)
    opts+=(-c credential.helper= -c 'credential.helper=!f() { test "$1" = get && printf "username=%s\npassword=%s\n" "$MEMORY_3LAYER_GIT_USER" "$MEMORY_3LAYER_GIT_PASS"; }; f')
  fi
  err=$(env "${envs[@]}" GIT_SSH_COMMAND="$ssh" "${wrap[@]}" timeout "$NET_TIMEOUT" git "${opts[@]}" "$@" 2>&1 >/dev/null) || rc=$?
  [[ $rc -eq 0 ]] && return 0
  NET_WHY=$(classify "$rc" "$err")
  return "$rc"
}

remote_ref() {
  git -C "$CLONE" rev-parse -q --verify "origin/$BRANCH" >/dev/null 2>&1
}

copy_out() {
  # Data dir -> clone. On the first sync the two have no common history, so a file
  # that differs follows the conflict rule instead of silently replacing the remote.
  local addr=$1 first=$2 p f c loser
  while IFS= read -r p; do
    f="$DATA/$p"; c="$CLONE/$p"
    [[ -f "$c" ]] && cmp -s "$f" "$c" && continue
    if ! bash "$SELF_DIR/memory-secrets.sh" scan "$f" >/dev/null; then
      SKIPPED[$p]=1
      printf 'SECRET, stays local: %s\n' "$f"
      continue
    fi
    if [[ "$first" == 1 && -f "$c" ]]; then
      loser=$(loser_path "$p" "$HOST")
      if theirs_is_newer "$f" "$c" "$(mtime "$f")" "$(mtime "$c")"; then
        put "$f" "$CLONE/$loser"
        continue
      fi
      put "$c" "$CLONE/$(loser_path "$p" remote)"
    fi
    put "$f" "$c"
  done < <(routed_files "$addr")
  return 0
}

remove_deleted() {
  # A file that was synced before and is gone from the data dir was deleted on purpose.
  # With no recorded base nothing counts as deleted: a new machine starts empty.
  local addr=$1 base=$2 p
  [[ -n "$base" ]] || return 0
  git -C "$CLONE" cat-file -e "$base" 2>/dev/null || return 0
  while IFS= read -r p; do
    [[ -e "$DATA/$p" || ! -e "$CLONE/$p" ]] && continue
    [[ "$(route_path "$p")" == "$addr" ]] && rm -f "$CLONE/$p"
  done < <(git -C "$CLONE" ls-tree -r --name-only "$base")
  return 0
}

write_aliases() {
  # An alias names a project, so it goes only to that project's own storage.
  local addr=$1 old new
  [[ -f "$DATA/aliases.tsv" ]] || return 0
  [[ -f "$CLONE/.gitattributes" ]] || printf 'aliases.tsv merge=union\n' > "$CLONE/.gitattributes"
  while IFS=$'\t' read -r old new; do
    [[ -n "$new" ]] || continue
    if [[ "$(route "$new" project)" == "$addr" ]]; then
      grep -qxFe "$old"$'\t'"$new" "$CLONE/aliases.tsv" 2>/dev/null || printf '%s\t%s\n' "$old" "$new" >> "$CLONE/aliases.tsv"
    fi
  done < "$DATA/aliases.tsv"
  return 0
}

commit_local() {
  g add -A
  g diff --cached --quiet && return 0
  g commit -q -m "sync $HOST"
}

resolve_conflicts() {
  # Different parts of a file were merged by git already. For the rest the newer
  # version keeps the name and the other is kept next to it, so nothing is lost.
  local p from ours theirs tmp
  tmp=$(mktemp -d)
  from=$(g log -1 --format=%s "origin/$BRANCH" | sed -E 's/^sync //')
  [[ -n "$from" ]] || from=remote
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    ours="$tmp/ours"; theirs="$tmp/theirs"
    g show ":2:$p" > "$ours" 2>/dev/null || : > "$ours"
    g show ":3:$p" > "$theirs" 2>/dev/null || : > "$theirs"
    if ! g cat-file -e ":3:$p" 2>/dev/null; then
      cp "$ours" "$CLONE/$p"
    elif ! g cat-file -e ":2:$p" 2>/dev/null; then
      mkdir -p "$(dirname "$CLONE/$p")"; cp "$theirs" "$CLONE/$p"
    elif theirs_is_newer "$ours" "$theirs" "$(g log -1 --format=%ct HEAD -- "$p")" "$(g log -1 --format=%ct "origin/$BRANCH" -- "$p")"; then
      mkdir -p "$(dirname "$CLONE/$(loser_path "$p" "$HOST")")"
      cp "$ours" "$CLONE/$(loser_path "$p" "$HOST")"
      cp "$theirs" "$CLONE/$p"
    else
      mkdir -p "$(dirname "$CLONE/$(loser_path "$p" "$from")")"
      cp "$theirs" "$CLONE/$(loser_path "$p" "$from")"
      cp "$ours" "$CLONE/$p"
    fi
  done < <(g diff --name-only --diff-filter=U)
  rm -rf "$tmp"
  g add -A
  g commit -q --no-edit -m "sync $HOST: merge"
}

merge_remote() {
  remote_ref || return 0
  if ! git -C "$CLONE" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    g reset -q --hard "origin/$BRANCH"
    return 0
  fi
  g merge -q --no-edit "origin/$BRANCH" >/dev/null 2>&1 || resolve_conflicts
}

keep_local_write() {
  # keep_local_write <path> <commit before the merge>. Sessions keep writing while a sync
  # runs. Succeeds if the data dir has a write made after copy_out and it has been kept;
  # it reaches the storage at the next sync.
  local p=$1 pre=$2 before after here
  before=$(git -C "$CLONE" rev-parse -q --verify "$pre:$p" 2>/dev/null || true)
  after=$(git -C "$CLONE" rev-parse -q --verify "HEAD:$p" 2>/dev/null || true)
  [[ "$before" == "$after" ]] && return 0
  here=$(git -C "$CLONE" hash-object --no-filters "$DATA/$p")
  [[ "$here" == "$before" ]] && return 1
  put "$CLONE/$p" "$DATA/$(loser_path "$p" remote)"
  return 0
}

copy_in() {
  # Clone -> data dir, for files routed here. A file held back for a secret keeps its
  # local version, otherwise the older remote copy would overwrite it.
  local addr=$1 pre=$2 p old new
  while IFS= read -r p; do
    case "$p" in .gitattributes) continue ;; esac
    if [[ "$p" == aliases.tsv ]]; then
      mkdir -p "$DATA"
      while IFS=$'\t' read -r old new; do
        [[ -n "$new" ]] || continue
        grep -qxFe "$old"$'\t'"$new" "$DATA/aliases.tsv" 2>/dev/null || printf '%s\t%s\n' "$old" "$new" >> "$DATA/aliases.tsv"
      done < "$CLONE/aliases.tsv"
      continue
    fi
    [[ -n "${SKIPPED[$p]:-}" ]] && continue
    [[ "$(route_path "$p")" == "$addr" ]] || continue
    cmp -s "$CLONE/$p" "$DATA/$p" 2>/dev/null && continue
    if [[ -n "$pre" && -f "$DATA/$p" ]]; then
      keep_local_write "$p" "$pre" && continue
    fi
    put "$CLONE/$p" "$DATA/$p"
  done < <(git -C "$CLONE" ls-files)
  if [[ -n "$pre" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" && -z "${SKIPPED[$p]:-}" ]] || continue
      [[ "$(route_path "$p")" == "$addr" ]] && rm -f "$DATA/$p"
    done < <(git -C "$CLONE" diff --name-only --diff-filter=D "$pre" HEAD)
  fi
  return 0
}

write_state() {
  # write_state <clone> <ok|fail> <detail>. Read by `status` and by the session context.
  printf '%s\t%s\t%s\t%s\n' "$2" "$(date +%s)" "$ADDR" "$3" > "$1.state"
}

sync_store() {
  local ADDR=$1 CLONE BRANCH base pre first=0 lock
  local id; id=$(store_id "$ADDR")
  CLONE="$STORES/$id"
  mkdir -p "$STORES"
  if has_password "$ADDR"; then
    # Nothing identifying goes into the state file: the address holds a credential.
    printf 'refused: a storage address has a password in it. Use an ssh key or a credential helper.\n' >&2
    return 1
  fi
  lock="$CLONE.lock"
  if [[ -d "$lock" && -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
    rmdir "$lock" 2>/dev/null
  fi
  mkdir "$lock" 2>/dev/null || { say "$ADDR: another sync is running"; return 0; }

  if [[ ! -d "$CLONE/.git" ]]; then
    first=1
    if ! net_git clone -q -c core.autocrlf=false -c core.safecrlf=false -c core.eol=lf "$ADDR" "$CLONE"; then
      rm -rf "$CLONE"
      write_state "$CLONE" fail "$NET_WHY"
      printf '%s: %s, working on local data\n' "$ADDR" "$NET_WHY" >&2
      rmdir "$lock"; return 1
    fi
  elif ! net_git -C "$CLONE" fetch -q origin; then
    write_state "$CLONE" fail "$NET_WHY"
    printf '%s: %s, working on local data\n' "$ADDR" "$NET_WHY" >&2
    rmdir "$lock"; return 1
  fi

  # A clone is transport, so it must keep bytes as they are, whatever the user's git does.
  git -C "$CLONE" config core.autocrlf false
  git -C "$CLONE" config core.safecrlf false
  git -C "$CLONE" config core.eol lf

  BRANCH=$(git -C "$CLONE" symbolic-ref --short HEAD 2>/dev/null || echo main)
  [[ -n "$BRANCH" ]] || BRANCH=main
  git -C "$CLONE" symbolic-ref HEAD "refs/heads/$BRANCH" 2>/dev/null

  # A new machine learns the routing before it decides where anything goes.
  if [[ "$ADDR" == "$(first_rule '|default')" && ! -f "$ROUTING_CONF" ]] && remote_ref; then
    if git -C "$CLONE" cat-file -e "origin/$BRANCH:routing.conf" 2>/dev/null; then
      mkdir -p "$DATA"
      git -C "$CLONE" show "origin/$BRANCH:routing.conf" > "$ROUTING_CONF"
      load_conf
    fi
  fi

  base=$(cat "$CLONE.base" 2>/dev/null || true)
  [[ -n "$base" ]] || first=1
  SKIPPED=()
  copy_out "$ADDR" "$first"
  remove_deleted "$ADDR" "$base"
  write_aliases "$ADDR"
  commit_local
  pre=$(git -C "$CLONE" rev-parse -q --verify HEAD 2>/dev/null || true)
  [[ -n "$base" ]] || pre=""
  merge_remote
  copy_in "$ADDR" "$pre"

  if [[ "$MODE" == full ]] && git -C "$CLONE" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    if ! net_git -C "$CLONE" push -q origin "$BRANCH"; then
      # Another machine pushed in between: take its changes and try once more.
      pre=$(git -C "$CLONE" rev-parse HEAD)
      if net_git -C "$CLONE" fetch -q origin; then
        merge_remote
        copy_in "$ADDR" "$pre"
      fi
      if ! net_git -C "$CLONE" push -q origin "$BRANCH"; then
        git -C "$CLONE" rev-parse HEAD > "$CLONE.base"
        write_state "$CLONE" fail "push: $NET_WHY"
        printf '%s: push: %s, will retry at the next sync\n' "$ADDR" "$NET_WHY" >&2
        rmdir "$lock"; return 1
      fi
    fi
  fi
  git -C "$CLONE" rev-parse -q --verify HEAD > "$CLONE.base" 2>/dev/null
  write_state "$CLONE" ok ""
  say "$ADDR: synced"
  rmdir "$lock"
  return 0
}

# --- commands -----------------------------------------------------------------

cmd_sync() {
  local failed=0 addr
  load_conf
  mapfile -t stores < <(all_stores)
  if [[ ${#stores[@]} -eq 0 ]]; then
    say "No storage configured. Set one with: memory-3layer sync init <address>"
    return 0
  fi
  # The default storage may bring routing that adds more storages.
  sync_store "${stores[0]}" || failed=1
  load_conf
  mapfile -t stores < <(all_stores)
  for addr in "${stores[@]:1}"; do
    sync_store "$addr" || failed=1
  done
  return $failed
}

cmd_init() {
  [[ $# -eq 1 ]] || { echo "usage: sync init <address>" >&2; return 2; }
  if has_password "$1"; then
    echo "refused: the address has a password in it. Use an ssh key or a credential helper." >&2
    return 2
  fi
  mkdir -p "$CONFIG_DIR"
  if [[ -f "$LOCAL_CONF" ]] && grep -qE '^[[:space:]]*default[[:space:]]*=' "$LOCAL_CONF"; then
    echo "$LOCAL_CONF already has a default storage. Edit it to change that." >&2
    return 2
  fi
  printf 'default = %s\n' "$1" >> "$LOCAL_CONF"
  printf 'Default storage set in %s. Run: memory-3layer sync\n' "$LOCAL_CONF"
}

cmd_route() {
  # route [key]: where each layer of a project goes, and why it can be trusted.
  local key=${1:-} l
  load_conf
  printf 'identity  %s\n' "$(route - identity)"
  if [[ -n "$key" ]]; then
    for l in project session archive; do
      printf '%-9s %s\n' "$l" "$(route "$key" "$l")"
    done
  fi
}

hint() {
  # hint <address> <problem>: what the user can do about it.
  local a=$1 key=${ACCESS[$1|ssh_key]:-} ssh=0
  [[ "$a" == *@*:* || "$a" == ssh://* ]] && ssh=1
  case "$2" in
    *"access denied"*)
      if [[ -n "$key" ]]; then
        if ! ssh-keygen -y -P '' -f "$key" >/dev/null 2>&1; then
          printf 'the key has a passphrase, and nobody can enter it during a sync: use a key without one, or ssh_agent'
        else
          printf 'the server rejected this key: check it is added to the repository, with write access'
        fi
      elif [[ -n "${ACCESS[$a|ssh_agent]:-}" ]]; then
        printf 'the agent has no key this server accepts: check ssh-add -l'
      elif [[ -n "${ACCESS[$a|password]:-}" ]]; then
        printf 'the server rejected the login: check username and the secret, and that it can write'
      elif [[ $ssh -eq 1 ]]; then
        printf 'no usable key. A key with a passphrase needs an agent. Set ssh_key or ssh_agent under [storage %s] in %s' "$a" "$LOCAL_CONF"
      else
        printf 'no credentials. Set up a git credential helper, or username and password = secret://<name> under [storage %s] in %s' "$a" "$LOCAL_CONF"
      fi ;;
    "host key not trusted") printf 'connect once by hand to confirm the server: ssh -T <host>' ;;
    "not found") printf 'check the address. Some servers answer this way when access is missing too' ;;
    unreachable) printf 'no network or VPN, or the server is down' ;;
    "ssh key file"*|"ssh agent"*) printf 'check the path under [storage %s] in %s' "$a" "$LOCAL_CONF" ;;
    "secret "*) printf 'add it: memory-3layer secret put <name>' ;;
    "password in"*) printf 'store the value: memory-3layer secret put <name>, then write password = secret://<name>' ;;
  esac
}

cmd_check() {
  # Tries access with no changes, locally or on the server.
  local ADDR CLONE b failed=0 how id
  load_conf
  mapfile -t stores < <(all_stores)
  [[ ${#stores[@]} -gt 0 ]] || { echo "No storage configured."; return 0; }
  for ADDR in "${stores[@]}"; do
    how="git defaults"
    [[ -z "${ACCESS[$ADDR|ssh_key]:-}" ]] || how="ssh key ${ACCESS[$ADDR|ssh_key]}"
    [[ -z "${ACCESS[$ADDR|ssh_agent]:-}" ]] || how="ssh agent ${ACCESS[$ADDR|ssh_agent]}"
    [[ -z "${ACCESS[$ADDR|password]:-}" ]] || how="login, secret://${ACCESS[$ADDR|password]}"
    printf '%s\n  access: %s\n' "$ADDR" "$how"
    if has_password "$ADDR"; then
      echo "  refused: the address has a password in it"; failed=1; continue
    fi
    if ! net_git ls-remote "$ADDR"; then
      printf '  read: %s\n  fix: %s\n' "$NET_WHY" "$(hint "$ADDR" "$NET_WHY")"; failed=1; continue
    fi
    echo "  read: ok"
    id=$(store_id "$ADDR"); CLONE="$STORES/$id"
    b=$(git -C "$CLONE" symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$b" ]] || ! git -C "$CLONE" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      echo "  write: not checked, no local clone yet. The first sync shows it."
    elif net_git -C "$CLONE" push --dry-run origin "HEAD:refs/heads/$b"; then
      echo "  write: ok"
    elif [[ "$NET_WHY" == failed ]]; then
      # Behind the remote is not an access problem.
      echo "  write: ok"
    else
      printf '  write: %s\n  fix: %s\n' "$NET_WHY" "$(hint "$ADDR" "$NET_WHY")"; failed=1
    fi
  done
  for id in "${!ACCESS[@]}"; do
    ADDR=${id%|*}
    case " ${stores[*]} " in *" $ADDR "*) ;; *) printf 'note: no rule uses [storage %s]\n' "$ADDR" ;; esac
  done | sort -u
  return $failed
}

cmd_status() {
  local addr id clone st ts rest ahead moved p
  load_conf
  mapfile -t stores < <(all_stores)
  [[ ${#stores[@]} -gt 0 ]] || { echo "No storage configured."; return 0; }
  for addr in "${stores[@]}"; do
    id=$(store_id "$addr"); clone="$STORES/$id"
    st=never; ts=""; rest=""
    if [[ -f "$clone.state" ]]; then
      IFS=$'\t' read -r st ts _ rest < "$clone.state"
    fi
    ahead=0; moved=0
    if [[ -d "$clone/.git" ]]; then
      ahead=$(git -C "$clone" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
      while IFS= read -r p; do
        # Only memory counts: a storage can hold its own README and the like.
        case "$p" in identity/*|projects/*|routing.conf) ;; *) continue ;; esac
        [[ "$(route_path "$p")" == "$addr" ]] || moved=$((moved + 1))
      done < <(git -C "$clone" ls-files)
    fi
    printf '%s\n  state: %s%s%s\n  files here: %s, commits not pushed: %s\n' "$addr" "$st" "${rest:+ ($rest)}" \
      "${ts:+, $(date -d "@$ts" '+%F %T' 2>/dev/null)}" "$(routed_files "$addr" | wc -l | tr -d ' ')" "$ahead"
    if [[ $moved -gt 0 ]]; then
      printf '  %d files here are now routed elsewhere. They stay in this storage and its history until removed by hand.\n' "$moved"
    fi
  done
}

sub=${1:-}
case "$sub" in
  init) shift; cmd_init "$@" ;;
  status) cmd_status ;;
  route) shift; cmd_route "$@" ;;
  check) cmd_check ;;
  *)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pull) MODE=pull; NET_TIMEOUT=5 ;;
        --quiet) QUIET=1 ;;
        *) echo "usage: sync [--pull] [--quiet] | init <address> | status | check | route [key]" >&2; exit 2 ;;
      esac
      shift
    done
    cmd_sync
    ;;
esac
