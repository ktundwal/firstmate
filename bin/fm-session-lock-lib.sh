#!/usr/bin/env bash
# Shared session-lock ownership, using the side-effect-free process-identity owner.

# shellcheck source=bin/fm-harness-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-harness-process-lib.sh"

# True only when this home's recorded owner is one of this session's harness ancestors.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
