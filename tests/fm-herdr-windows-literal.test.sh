#!/usr/bin/env bash
# A slash command is terminal data, not a path for MSYS to rewrite.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_HERDR_WINDOWS_LITERAL_LIVE herdr
if [ ! -r "/proc/$$/winpid" ] || [ -z "${FM_HERDR_WINDOWS_LITERAL_TARGET:-}" ]; then
  echo "skip: native Windows and an owned idle-shell lab target required"
  exit 0
fi
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
session=${FM_HERDR_WINDOWS_LITERAL_TARGET%%:*}
pane=${FM_HERDR_WINDOWS_LITERAL_TARGET#*:}
[ -f "$(fm_herdr_lab_tripwire_path "$session")" ] || fail "the lab has no ownership tripwire"
fm_herdr_lab_refuse_if_default "$session" || fail "the target is not a disposable lab"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
marker="__FM_LITERAL_${BASHPID:-$$}_${RANDOM}__"
fm_herdr_lab_cli "$session" pane run "$pane" "read -r value; printf '%s=%s\\n' '$marker' \"\$value\"" >/dev/null \
  || fail "could not start the literal receiver"
fm_backend_herdr_send_literal "$FM_HERDR_WINDOWS_LITERAL_TARGET" /exit \
  || fail "literal transport failed"
fm_herdr_lab_cli "$session" pane send-keys "$pane" enter >/dev/null || fail "receiver Enter failed"
sleep 0.3
out=$(fm_herdr_lab_cli "$session" pane read "$pane" --source recent-unwrapped --lines 200)
printf '%s\n' "$out" | tr -d '\r' | grep -Fxq "$marker=/exit" \
  || fail "slash command was not delivered byte-for-byte to the shell receiver"
pass "Windows Herdr terminal transport preserves slash commands as literal data"
