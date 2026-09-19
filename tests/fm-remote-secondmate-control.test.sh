#!/usr/bin/env bash
# Portable contract test for the remote secondmate control transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-control)
CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"

make_home() {
  local dir=$1
  mkdir -p "$dir/bin"
  printf '%s\n' ios > "$dir/.fm-secondmate-home"
  : > "$dir/AGENTS.md"
}

test_remote_copilot_launch_is_rejected() {
  local home=$TMP_ROOT/launch out rc=0
  make_home "$home"

  out=$(FM_HOME="$home" "$CONTROL" launch ios copilot - - herdr 2>&1) || rc=$?

  expect_code 1 "$rc" "remote Copilot launch should be rejected"
  assert_contains "$out" "unverified remote secondmate harness: copilot" \
    "remote Copilot launch rejection should name the unsupported harness"
  assert_absent "$home/state/parent-route/ios.meta" \
    "rejected remote Copilot launch published endpoint metadata"
  pass "remote secondmate control rejects Copilot launch"
}

test_remote_copilot_relaunch_is_rejected() {
  local home=$TMP_ROOT/relaunch out rc=0
  make_home "$home"

  out=$(FM_HOME="$home" "$CONTROL" relaunch ios copilot - - 2>&1) || rc=$?

  expect_code 1 "$rc" "remote Copilot relaunch should be rejected"
  assert_contains "$out" "unverified remote secondmate harness: copilot" \
    "remote Copilot relaunch rejection should name the unsupported harness"
  assert_absent "$home/state/parent-route/ios.meta" \
    "rejected remote Copilot relaunch published endpoint metadata"
  pass "remote secondmate control rejects Copilot relaunch"
}

test_remote_copilot_launch_is_rejected
test_remote_copilot_relaunch_is_rejected

echo "# all fm-remote-secondmate-control tests passed"
