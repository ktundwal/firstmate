#!/usr/bin/env bash
# Windows process facts for the shared harness-identity owner.
# Native identities are win:<PID>:<creation ticks>, never MSYS signal targets.
# Requires Git Bash's /proc PID bridge, PowerShell and jq; performs no writes.

FM_WINDOWS_PROCESS_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fm_session_pid_valid() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ || "${1:-}" =~ ^win:[1-9][0-9]*:[1-9][0-9]*$ ]]
}

fm_windows_process_query() {  # <ancestry|inspect|copilot-owner> <value>
  local shell script
  [ -r "/proc/$$/winpid" ] || return 2
  shell=$(command -v pwsh) || shell=$(command -v powershell) || {
    echo "error: native Windows process evidence requires PowerShell" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: native Windows process evidence requires jq" >&2
    return 2
  }
  script=$(cygpath -w "$FM_WINDOWS_PROCESS_DIR/fm-windows-process.ps1") || return 2
  "$shell" -NoProfile -NonInteractive -File "$script" -Operation "$1" -Value "$2" || return 2
}

fm_windows_normalize_command() {
  local path=${1//\\//}
  case "$path" in *.[eE][xX][eE]) path=${path%.*} ;; esac
  printf '%s\n' "$path" | tr '[:upper:]' '[:lower:]'
}

fm_windows_copilot_identity() {
  local winpid payload rows identity path pid
  [ "${COPILOT_CLI:-}" = 1 ] || return 1
  [[ "${COPILOT_LOADER_PID:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  [ -r "/proc/$$/winpid" ] || return 1
  read -r winpid < "/proc/$$/winpid" || return 1
  payload=$(fm_windows_process_query ancestry "$winpid") || return 2
  rows=$(printf '%s' "$payload" | jq -er '
    .processes[] | [.Identity, .Path] | @tsv
  ') || return 1
  while IFS=$'\t' read -r identity path; do
    path=${path//\\\\/\\}
    path=$(fm_windows_normalize_command "$path") || return 1
    if fm_harness_process_matches "$path" "$path"; then
      [ "$FM_HARNESS_MATCH_NAME" = copilot ] || return 1
      pid=${identity#win:}
      pid=${pid%%:*}
      [ "$pid" = "$COPILOT_LOADER_PID" ] || return 1
      printf '%s\n' "$identity"
      return 0
    fi
  done <<< "$rows"
  payload=$(fm_windows_process_query copilot-owner "$COPILOT_LOADER_PID") || return 2
  printf '%s' "$payload" | jq -er 'select(.found == true) | .process.Identity'
}

fm_windows_harness_alive() {
  local identity=$1 payload path
  fm_session_pid_valid "$identity" || return 1
  payload=$(fm_windows_process_query inspect "$identity") || return 2
  printf '%s' "$payload" | jq -e '.found == true' >/dev/null || return 1
  path=$(printf '%s' "$payload" | jq -er '.process.Path') || return 2
  path=$(fm_windows_normalize_command "$path") || return 2
  fm_harness_process_matches "$path" "$path"
}
