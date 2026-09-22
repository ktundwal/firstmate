#!/usr/bin/env bash

# shellcheck source=bin/fm-private-path-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-private-path-lib.sh"

FM_COPILOT_WATCH_RECEIPT_SCHEMA=${FM_COPILOT_WATCH_RECEIPT_SCHEMA:-fm-copilot-watch-arm-receipt.v1}
_FM_COPILOT_WATCH_RECEIPT_UNAME=${_FM_COPILOT_WATCH_RECEIPT_UNAME:-$(uname 2>/dev/null || echo unknown)}

fm_copilot_watch_receipt_real_dir() {
  local dir=${1:-}
  [ -n "$dir" ] || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

fm_copilot_watch_receipt_path() {
  local state_real=${1:-}
  printf '%s/.copilot-watch-arm/completion.receipt\n' "$state_real"
}

fm_copilot_watch_receipt_max_age() {
  local age=${FM_COPILOT_WATCH_RECEIPT_MAX_AGE:-300}
  case "$age" in ''|*[!0-9]*) age=300 ;; esac
  [ "$age" -gt 0 ] || age=300
  printf '%s\n' "$age"
}

fm_copilot_watch_receipt_device() {
  if [ "$_FM_COPILOT_WATCH_RECEIPT_UNAME" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_copilot_watch_receipt_links() {
  if [ "$_FM_COPILOT_WATCH_RECEIPT_UNAME" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_copilot_watch_receipt_prepare_dir() {
  local state_real=${1:-} dir
  [ -n "$state_real" ] || return 1
  dir="$state_real/.copilot-watch-arm"
  [ ! -L "$dir" ] || return 1
  if [ ! -e "$dir" ]; then
    mkdir -p "$dir" || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  chmod 700 "$dir" 2>/dev/null || return 1
  fm_private_data_path_matches "$dir" directory || return 1
  printf '%s\n' "$dir"
}

fm_copilot_watch_receipt_publish() {
  local root_real home_real state_real dir receipt tmp now
  root_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  home_real=$(fm_copilot_watch_receipt_real_dir "$2") || return 1
  state_real=$(fm_copilot_watch_receipt_real_dir "$3") || return 1
  dir=$(fm_copilot_watch_receipt_prepare_dir "$state_real") || return 1
  receipt=$(fm_copilot_watch_receipt_path "$state_real") || return 1
  now=$(date +%s) || return 1
  tmp=$(mktemp "$dir/.completion.receipt.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || {
    rm -f -- "$tmp"
    return 1
  }
  fm_private_data_path_matches "$tmp" file || {
    rm -f -- "$tmp"
    return 1
  }
  if ! {
    printf 'schema=%s\n' "$FM_COPILOT_WATCH_RECEIPT_SCHEMA"
    printf 'completed_at=%s\n' "$now"
    printf 'root=%s\n' "$root_real"
    printf 'home=%s\n' "$home_real"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  [ ! -L "$receipt" ] || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$receipt" || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 600 "$receipt" 2>/dev/null || {
    rm -f -- "$receipt"
    return 1
  }
  fm_private_data_path_matches "$receipt" file || {
    rm -f -- "$receipt"
    return 1
  }
}

fm_copilot_watch_receipt_validate_claimed() {
  local claimed=$1 root_real=$2 home_real=$3 state_real=$4
  local state_device max_age size line key value schema='' completed_at='' receipt_root='' receipt_home=''
  local seen_schema=0 seen_completed=0 seen_root=0 seen_home=0 age
  [ -f "$claimed" ] && [ ! -L "$claimed" ] || return 1
  fm_private_data_path_matches "$claimed" file || return 1
  [ "$(fm_copilot_watch_receipt_links "$claimed")" = 1 ] || return 1
  state_device=$(fm_copilot_watch_receipt_device "$state_real") || return 1
  [ "$(fm_copilot_watch_receipt_device "$claimed")" = "$state_device" ] || return 1
  size=$(wc -c < "$claimed" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -le 1024 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema)
        [ "$seen_schema" -eq 0 ] || return 1
        schema=$value
        seen_schema=1
        ;;
      completed_at)
        [ "$seen_completed" -eq 0 ] || return 1
        completed_at=$value
        seen_completed=1
        ;;
      root)
        [ "$seen_root" -eq 0 ] || return 1
        receipt_root=$value
        seen_root=1
        ;;
      home)
        [ "$seen_home" -eq 0 ] || return 1
        receipt_home=$value
        seen_home=1
        ;;
      *)
        return 1
        ;;
    esac
  done < "$claimed"
  [ "$seen_schema$seen_completed$seen_root$seen_home" = 1111 ] || return 1
  [ "$schema" = "$FM_COPILOT_WATCH_RECEIPT_SCHEMA" ] || return 1
  case "$completed_at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$receipt_root" = "$root_real" ] || return 1
  [ "$receipt_home" = "$home_real" ] || return 1
  max_age=$(fm_copilot_watch_receipt_max_age) || return 1
  age=$(( $(date +%s) - completed_at ))
  [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ]
}

fm_copilot_watch_receipt_acquire() {
  local root_real home_real state_real dir receipt claimed attempt=0
  FM_COPILOT_WATCH_RECEIPT_CLAIMED=
  root_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  home_real=$(fm_copilot_watch_receipt_real_dir "$2") || return 1
  state_real=$(fm_copilot_watch_receipt_real_dir "$3") || return 1
  dir="$state_real/.copilot-watch-arm"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fm_private_data_path_matches "$dir" directory || return 1
  receipt=$(fm_copilot_watch_receipt_path "$state_real") || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  while :; do
    claimed="$dir/.claimed.$$.$attempt"
    [ ! -e "$claimed" ] && [ ! -L "$claimed" ] && break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || return 1
  done
  FM_COPILOT_WATCH_RECEIPT_CLAIMED=$claimed
  mv -- "$receipt" "$claimed" 2>/dev/null || {
    FM_COPILOT_WATCH_RECEIPT_CLAIMED=
    return 1
  }
  if ! fm_copilot_watch_receipt_validate_claimed "$claimed" "$root_real" "$home_real" "$state_real"; then
    rm -f -- "$claimed"
    FM_COPILOT_WATCH_RECEIPT_CLAIMED=
    return 1
  fi
}

fm_copilot_watch_receipt_commit() {
  local claimed=${1:-}
  [ -n "$claimed" ] || return 1
  rm -f -- "$claimed"
}

fm_copilot_watch_receipt_restore() {
  local state_real dir receipt claimed=${2:-}
  state_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  dir="$state_real/.copilot-watch-arm"
  case "$claimed" in "$dir"/.claimed.*) ;; *) return 1 ;; esac
  [ -f "$claimed" ] && [ ! -L "$claimed" ] || return 1
  fm_private_data_path_matches "$claimed" file || return 1
  receipt=$(fm_copilot_watch_receipt_path "$state_real") || return 1
  if ln "$claimed" "$receipt" 2>/dev/null; then
    rm -f -- "$claimed"
    return 0
  fi
  if [ -f "$receipt" ] && [ ! -L "$receipt" ] \
     && fm_private_data_path_matches "$receipt" file; then
    rm -f -- "$claimed"
    return 0
  fi
  return 1
}

fm_copilot_watch_receipt_claim() {
  fm_copilot_watch_receipt_acquire "$@" || return 1
  fm_copilot_watch_receipt_commit "$FM_COPILOT_WATCH_RECEIPT_CLAIMED"
}

fm_copilot_watch_pending_path() {
  local state_real=${1:-}
  printf '%s/.copilot-watch-arm/pending-context\n' "$state_real"
}

fm_copilot_watch_pending_publish() {  # <state-dir> <encoded-context>
  local state_real dir pending tmp text=$2 size
  FM_COPILOT_WATCH_PENDING_PUBLISHED=
  FM_COPILOT_WATCH_PENDING_STAGED=
  [ -n "$text" ] || return 1
  size=${#text}
  [ "$size" -le 8192 ] || return 1
  state_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  dir=$(fm_copilot_watch_receipt_prepare_dir "$state_real") || return 1
  pending=$(fm_copilot_watch_pending_path "$state_real") || return 1
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  fi
  tmp=$(mktemp "$dir/.pending-context.XXXXXX") || return 1
  FM_COPILOT_WATCH_PENDING_STAGED=$tmp
  chmod 600 "$tmp" 2>/dev/null || {
    FM_COPILOT_WATCH_PENDING_STAGED=
    rm -f -- "$tmp"
    return 1
  }
  printf '%s' "$text" > "$tmp" || {
    FM_COPILOT_WATCH_PENDING_STAGED=
    rm -f -- "$tmp"
    return 1
  }
  fm_private_data_path_matches "$tmp" file || {
    FM_COPILOT_WATCH_PENDING_STAGED=
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$pending" || {
    FM_COPILOT_WATCH_PENDING_STAGED=
    rm -f -- "$tmp"
    return 1
  }
  FM_COPILOT_WATCH_PENDING_PUBLISHED=1
  FM_COPILOT_WATCH_PENDING_STAGED=
}

fm_copilot_watch_pending_claim() {  # <state-dir>
  fm_copilot_watch_pending_acquire "$1" || return 1
  printf '%s' "$FM_COPILOT_WATCH_PENDING_CONTEXT"
  fm_copilot_watch_pending_commit "$FM_COPILOT_WATCH_PENDING_CLAIMED"
}

fm_copilot_watch_pending_acquire() {  # <state-dir>
  local state_real dir pending claimed size context_size
  FM_COPILOT_WATCH_PENDING_CLAIMED=
  FM_COPILOT_WATCH_PENDING_CONTEXT=
  state_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  dir="$state_real/.copilot-watch-arm"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fm_private_data_path_matches "$dir" directory || return 1
  pending=$(fm_copilot_watch_pending_path "$state_real") || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  claimed="$dir/.pending-claimed.$$.$RANDOM"
  FM_COPILOT_WATCH_PENDING_CLAIMED=$claimed
  mv -- "$pending" "$claimed" 2>/dev/null || {
    FM_COPILOT_WATCH_PENDING_CLAIMED=
    return 1
  }
  if [ -f "$claimed" ] && [ ! -L "$claimed" ] \
     && fm_private_data_path_matches "$claimed" file \
     && [ "$(fm_copilot_watch_receipt_links "$claimed")" = 1 ]; then
    size=$(wc -c < "$claimed" 2>/dev/null | tr -d '[:space:]') || size=
    case "$size" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$size" -gt 0 ] && [ "$size" -le 8192 ]; then
          FM_COPILOT_WATCH_PENDING_CONTEXT=$(cat "$claimed") || {
            rm -f -- "$claimed"
            FM_COPILOT_WATCH_PENDING_CLAIMED=
            FM_COPILOT_WATCH_PENDING_CONTEXT=
            return 1
          }
          context_size=$(printf '%s' "$FM_COPILOT_WATCH_PENDING_CONTEXT" | wc -c | tr -d '[:space:]')
          [ "$context_size" = "$size" ] && return 0
        fi
        ;;
    esac
  fi
  rm -f -- "$claimed"
  FM_COPILOT_WATCH_PENDING_CLAIMED=
  FM_COPILOT_WATCH_PENDING_CONTEXT=
  return 1
}

fm_copilot_watch_pending_commit() {
  local claimed=${1:-}
  [ -n "$claimed" ] || return 1
  rm -f -- "$claimed"
}

fm_copilot_watch_pending_restore() {
  local state_real dir pending claimed=${2:-}
  state_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  dir="$state_real/.copilot-watch-arm"
  case "$claimed" in "$dir"/.pending-claimed.*) ;; *) return 1 ;; esac
  [ -f "$claimed" ] && [ ! -L "$claimed" ] || return 1
  fm_private_data_path_matches "$claimed" file || return 1
  pending=$(fm_copilot_watch_pending_path "$state_real") || return 1
  if ln "$claimed" "$pending" 2>/dev/null; then
    rm -f -- "$claimed"
    return 0
  fi
  if [ -f "$pending" ] && [ ! -L "$pending" ] \
     && fm_private_data_path_matches "$pending" file; then
    rm -f -- "$claimed"
    return 0
  fi
  return 1
}

fm_copilot_watch_pending_matches() {  # <state-dir> <encoded-context>
  local state_real pending expected=$2 size expected_size actual
  state_real=$(fm_copilot_watch_receipt_real_dir "$1") || return 1
  pending=$(fm_copilot_watch_pending_path "$state_real") || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  fm_private_data_path_matches "$pending" file || return 1
  [ "$(fm_copilot_watch_receipt_links "$pending")" = 1 ] || return 1
  size=$(wc -c < "$pending" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  expected_size=$(printf '%s' "$expected" | wc -c | tr -d '[:space:]') || return 1
  [ "$size" = "$expected_size" ] || return 1
  actual=$(cat "$pending") || return 1
  [ "$actual" = "$expected" ]
}
