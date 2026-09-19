#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_PWSH pwsh

LAUNCHER="$ROOT/bin/fm-claude-hook-launch.ps1"
SETTINGS="$ROOT/.claude/settings.json"
COPILOT_HOOKS="$ROOT/.github/hooks/fm-primary.json"
TMP_ROOT=$(fm_test_tmproot fm-claude-hook-launch-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"
cp -R "$ROOT/bin" "$PRIMARY/bin"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_launcher() {
  local stdin=$1 dir=$2 rc=0 windir
  shift 2
  [ "${1:-}" = -- ] && shift
  windir=$(cygpath -w "$dir")
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$stdin" | pwsh -NoProfile -Command "& \"$windir\\fm-claude-hook-launch.ps1\" $*; exit \$LASTEXITCODE" \
    > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

test_forwards_guard_behavior() {
  local rc=0
  run_launcher '{"tool_name":"Read","tool_input":{}}' "$PRIMARY/bin" -- \
    -Script fm-subagent-pretool-check.sh --claude || rc=$?
  expect_code 0 "$rc" "ordinary tools should pass through the Windows launcher"

  rc=0
  run_launcher '{"tool_name":"Agent","tool_input":{}}' "$PRIMARY/bin" -- \
    -Script fm-subagent-pretool-check.sh --claude || rc=$?
  expect_code 2 "$rc" "guard denials should preserve exit 2 through the Windows launcher"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "the launcher lost the guard's native denial"
  pass "the Windows launcher preserves guard input, output, and exit status"
}

test_rejects_untracked_targets() {
  local rc=0
  run_launcher '' "$PRIMARY/bin" -- -Script '../evil.sh' || rc=$?
  expect_code 1 "$rc" "the Windows launcher should reject path traversal"
  assert_contains "$(cat "$ERR")" "rejected -Script value" \
    "the launcher should explain a rejected target"
  pass "the Windows launcher confines targets to tracked bin scripts"
}

test_hook_configs_expose_native_commands() {
  local bad
  jq -e . "$SETTINGS" >/dev/null 2>&1 || fail ".claude/settings.json is not valid JSON"
  jq -e . "$COPILOT_HOOKS" >/dev/null 2>&1 || fail "fm-primary.json is not valid JSON"
  bad=$(jq '[.. | objects | select(has("command") and .command != null)
             | select((.powershell // "") | test("fm-claude-hook-launch\\.ps1") | not)] | length' "$SETTINGS")
  [ "$bad" -eq 0 ] || fail "$bad Claude hook entries lack a native PowerShell command"
  bad=$(jq '[.hooks[][] | select((.powershell // "") | test("fm-claude-hook-launch\\.ps1") | not)] | length' "$COPILOT_HOOKS")
  [ "$bad" -eq 0 ] || fail "$bad Copilot hook entries lack a native PowerShell command"
  [[ "powershell" =~ $(jq -r '.hooks.PreToolUse[0].matcher' "$SETTINGS") ]] \
    || fail "Claude compatibility pre-tool hooks do not accept PowerShell"
  [[ "powershell" =~ $(jq -r '.hooks.preToolUse[0].matcher' "$COPILOT_HOOKS") ]] \
    || fail "Copilot pre-tool hooks do not accept PowerShell"
  pass "tracked hook configurations expose native PowerShell commands"
}

test_forwards_guard_behavior
test_rejects_untracked_targets
test_hook_configs_expose_native_commands
