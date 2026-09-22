#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WINDOWS_PRIVATE_PATH_LIVE pwsh
if [ ! -r "/proc/$$/winpid" ]; then
  echo "skip: native Windows ACLs required"
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-windows-private-path)
mkdir -p "$TMP_ROOT/state"
# shellcheck source=bin/fm-copilot-watcher-receipt-lib.sh
. "$ROOT/bin/fm-copilot-watcher-receipt-lib.sh"
fm_copilot_watch_receipt_publish "$TMP_ROOT" "$TMP_ROOT" "$TMP_ROOT/state" \
  || fail "a native private ACL could not publish a completion receipt"
fm_copilot_watch_receipt_claim "$TMP_ROOT" "$TMP_ROOT" "$TMP_ROOT/state" \
  || fail "a native private completion receipt could not be claimed"
fm_copilot_watch_receipt_claim "$TMP_ROOT" "$TMP_ROOT" "$TMP_ROOT/state" \
  && fail "a completion receipt was reusable"
pass "native private ACLs support one-time completion receipts"

script=$(cygpath -w "$ROOT/tests/fm-windows-private-path.test.ps1")
library=$(cygpath -w "$ROOT/bin/fm-windows-private-path.ps1")
pwsh -NoProfile -NonInteractive -File "$script" -Library "$library"
result=$?
[ "$result" -eq 0 ] || exit "$result"

if [ "${COPILOT_CLI:-}" = 1 ] && [ -n "${COPILOT_LOADER_PID:-}" ]; then
  git -C "$TMP_ROOT" init -q
  mkdir -p "$TMP_ROOT/bin"
  printf 'Firstmate notification fixture.\n' > "$TMP_ROOT/AGENTS.md"
  fm_copilot_watch_receipt_publish "$TMP_ROOT" "$TMP_ROOT" "$TMP_ROOT/state" \
    || fail "could not publish the native notification receipt"
  payload='{"notification_type":"shell_completed","title":"Arm Firstmate watcher","message":"Shell command \"Arm Firstmate watcher\" (shellId: windows-pilot) has completed successfully. Use read_powershell with shellId \"windows-pilot\" to retrieve the output."}'
  out=$(cd "$TMP_ROOT" && printf '%s' "$payload" | FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-copilot-hook.sh" notification)
  printf '%s' "$out" | jq -e '.additionalContext | contains("FIRSTMATE WATCHER WAKE")' >/dev/null \
    || fail "native PowerShell completion did not deliver watcher context"
  out=$(cd "$TMP_ROOT" && printf '%s' "$payload" | FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-copilot-hook.sh" notification)
  [ -z "$out" ] || fail "a replayed native notification reused its receipt"
  pass "native PowerShell completion consumes one matching receipt and rejects replay"
fi
