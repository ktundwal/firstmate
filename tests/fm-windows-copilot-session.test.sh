#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WINDOWS_COPILOT_SESSION_LIVE pwsh

if [ ! -r "/proc/$$/winpid" ] || [ "${COPILOT_CLI:-}" != 1 ] || [ -z "${COPILOT_LOADER_PID:-}" ]; then
  if [ "${FM_WINDOWS_COPILOT_SESSION_LIVE:-}" = 1 ]; then
    fail "this live regression requires native Windows inside Copilot CLI"
  fi
  echo "skip: native Windows Copilot session required"
  exit 0
fi

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-windows-copilot-session)
identity=$(fm_harness_ancestry_pid) || fail "real Windows Copilot session was not identified"
case "$identity" in
  "win:$COPILOT_LOADER_PID:"[0-9]*) ;;
  *) fail "owner must bind the actual Copilot PID and process creation time, got '$identity'" ;;
esac
fm_harness_pid_alive "$identity" || fail "fresh Windows owner was reported dead"
fm_harness_pid_alive "win:$COPILOT_LOADER_PID:1" && fail "a different process generation was accepted"
fm_harness_pid_alive "win:$COPILOT_LOADER_PID:bad" && fail "a malformed process identity was accepted"
fm_session_pid_valid "win:12garbage:34" && fail "a malformed Windows PID was accepted"
fm_session_pid_valid 123 || fail "Unix owner compatibility was lost"
pass "Windows owner identity is generation-bound and keeps the Unix representation"

mkdir -p "$TMP_ROOT/state"
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/state" "$ROOT/bin/fm-lock.sh") || fail "isolated lock acquisition failed: $out"
[ "$(cat "$TMP_ROOT/state/.lock")" = "$identity" ] || fail "lock publication changed the owner"
fm_session_lock_owned_by_self "$TMP_ROOT/state" || fail "the owning session cannot recognize itself"
out=$(FM_STATE_OVERRIDE="$TMP_ROOT/state" "$ROOT/bin/fm-lock.sh") || fail "same-session reacquisition failed: $out"
[ "$(cat "$TMP_ROOT/state/.lock")" = "$identity" ] || fail "reacquisition changed the owner"
pass "real Windows acquisition and reacquisition preserve the same owner"

if COPILOT_LOADER_PID=1 fm_harness_ancestry_pid >/dev/null; then
  fail "an unrelated published loader PID acquired this session's identity"
fi
printf 'win:%s:1\n' "$COPILOT_LOADER_PID" > "$TMP_ROOT/state/.lock"
if fm_session_lock_owned_by_self "$TMP_ROOT/state"; then
  fail "an old generation retained same-session ownership"
fi
pass "foreign claims and previous process generations do not own this session"
