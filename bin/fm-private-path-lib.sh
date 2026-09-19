#!/usr/bin/env bash
# Private-data access checks. Unix mode semantics stay unchanged.
# Windows requires native ownership/ACL proof, not an ignored chmod or a mode bypass.
# This library and its PowerShell helper never modify permissions.
FM_PRIVATE_PATH_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fm_private_data_path_matches() {  # <path> <file|directory>
  local path=$1 kind=$2 expected mode shell script
  case "$kind" in
    file) expected=600 ;;
    directory) expected=700 ;;
    *) echo "error: unknown private-data path kind: $kind" >&2; return 2 ;;
  esac
  if [ -r "/proc/$$/winpid" ]; then
    shell=$(command -v pwsh) || shell=$(command -v powershell) || {
      echo "error: native private-path validation requires PowerShell" >&2
      return 2
    }
    path=$(cygpath -w "$path") || return 2
    script=$(cygpath -w "$FM_PRIVATE_PATH_DIR/fm-windows-private-path.ps1") || return 2
    "$shell" -NoProfile -NonInteractive -File "$script" -Path "$path" -Kind "$kind"
    return $?
  fi
  if [ "$(uname -s)" = Darwin ]; then
    mode=$(stat -f %Lp "$path") || return 1
  else
    mode=$(stat -c %a "$path") || return 1
  fi
  [ "$mode" = "$expected" ]
}
