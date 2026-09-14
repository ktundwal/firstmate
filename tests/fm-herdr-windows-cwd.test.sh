#!/usr/bin/env bash
# Live read-only CWD proof in an explicitly supplied, owned Windows Herdr lab.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_HERDR_WINDOWS_CWD_LIVE herdr
if [ ! -r "/proc/$$/winpid" ] || [ -z "${FM_HERDR_WINDOWS_CWD_TARGET:-}" ]; then
  echo "skip: native Windows and an owned Herdr lab target required"
  exit 0
fi
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
session=${FM_HERDR_WINDOWS_CWD_TARGET%%:*}
[ -f "$(fm_herdr_lab_tripwire_path "$session")" ] || fail "the lab has no ownership tripwire"
fm_herdr_lab_refuse_if_default "$session" || fail "the target is not a disposable lab"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
out=$(fm_backend_herdr_current_path "$FM_HERDR_WINDOWS_CWD_TARGET" shell-discovery)
[ -n "$out" ] || fail "Windows Herdr returned no live shell directory"
actual=$(cd "$out" && pwd -P) || fail "the reported directory is unreadable"
expected=$(cd "$FM_HERDR_WINDOWS_CWD_EXPECTED" && pwd -P) || fail "expected directory is unreadable"
[ "$actual" = "$expected" ] || fail "the live shell directory is '$actual', expected '$expected'"
pass "Windows Herdr proves the live shell directory without using startup cwd metadata"
