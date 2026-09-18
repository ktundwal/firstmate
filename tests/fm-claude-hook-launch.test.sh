#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-hook-launch.ps1 and its wiring into
# .claude/settings.json: the Windows-native launcher GitHub Copilot CLI's
# "powershell" hook fields invoke, since Copilot runs .claude/settings.json
# hook commands through PowerShell on Windows rather than Bash and only the
# "command" field previously existed (POSIX syntax that fails to parse there).
#
# These tests exercise the launcher directly via `pwsh`, not through a live
# Copilot session, and skip cleanly on a host without pwsh installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_PWSH pwsh cygpath git.exe

SETTINGS="$ROOT/.claude/settings.json"
TMP_ROOT=$(fm_test_tmproot fm-claude-hook-launch-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# A primary-home fixture (AGENTS.md + state/ + git init), matching the fixture
# shape tests/fm-subagent-pretool-check.test.sh uses, so the real guard
# scripts classify it as a genuine primary rather than INERT. The launcher
# itself must live alongside the target script (it resolves targets relative
# to its own directory), so bin/ is copied wholesale rather than symlinked.
PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"
cp -R "$ROOT/bin" "$PRIMARY/bin"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_launcher() {
  # run_launcher <stdin> <launcher-dir> -- <launcher-args...>
  #
  # pwsh is a native Windows executable, not an MSYS one, and a POSIX-style
  # path embedded inside a larger -Command string argument (rather than
  # standing alone as a whole argument) is not auto-translated by Git Bash's
  # path-mangling heuristics. cygpath -w makes the conversion explicit instead
  # of relying on that heuristic.
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

test_forwards_args_and_stdin_and_allow_exit_code() {
  local rc=0
  run_launcher '{"tool_name":"Read","tool_input":{}}' "$PRIMARY/bin" -- -Script fm-subagent-pretool-check.sh --claude || rc=$?
  [ "$rc" -eq 0 ] || fail "ordinary tool must allow through the launcher, got exit $rc: $(cat "$ERR")"
  pass "the launcher forwards stdin and args and preserves an allow (exit 0)"
}

test_preserves_nonzero_guard_exit_code() {
  # Regression test: pwsh -Command collapses a nonzero `exit N` raised inside
  # an &-invoked nested script to a bare 1 unless the launcher avoids calling
  # `exit` on that path and instead leaves $LASTEXITCODE for the caller's own
  # top-level `exit $LASTEXITCODE` to propagate. A delegation-shaped tool
  # denial (exit 2) is the guard's real signal; collapsing it to a generic
  # exit 1 is indistinguishable from "hook errored" and one step from a
  # silent fail-open on deny.
  local rc=0
  run_launcher '{"tool_name":"Agent","tool_input":{}}' "$PRIMARY/bin" -- -Script fm-subagent-pretool-check.sh --claude || rc=$?
  [ "$rc" -eq 2 ] || fail "delegation-shaped tool must deny with exit 2 through the launcher, got $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "deny decision JSON missing or malformed on stderr (--claude mode writes it there, not stdout): $(cat "$ERR")"
  pass "a guard's nonzero (deny) exit code survives the pwsh -Command / launcher boundary intact"
}

test_skip_if_grok_short_circuits() {
  local rc=0
  GROK_AGENT=1 run_launcher '{"tool_name":"Agent","tool_input":{}}' "$PRIMARY/bin" -- -Script fm-subagent-pretool-check.sh -SkipIfGrok --claude || rc=$?
  [ "$rc" -eq 0 ] || fail "-SkipIfGrok must allow (exit 0) without consulting the guard when GROK_AGENT is set, got $rc"
  [ ! -s "$OUT" ] || fail "-SkipIfGrok short-circuit must not run the guard: $(cat "$OUT")"
  pass "-SkipIfGrok short-circuits before the guard runs, matching the existing GROK_AGENT/GROK_HOOK_EVENT bash convention"
}

test_rejects_path_traversal_in_script_name() {
  local rc=0
  run_launcher '' "$PRIMARY/bin" -- -Script '../evil.sh' || rc=$?
  [ "$rc" -eq 1 ] || fail "a -Script value with a path separator must be rejected with exit 1, got $rc"
  grep -q 'rejected -Script value' "$ERR" || fail "traversal rejection did not explain itself on stderr: $(cat "$ERR")"
  pass "the launcher rejects a -Script value containing a path separator"
}

test_rejects_missing_target_script() {
  local rc=0
  run_launcher '' "$PRIMARY/bin" -- -Script 'does-not-exist.sh' || rc=$?
  [ "$rc" -eq 1 ] || fail "a missing target script must be rejected with exit 1, got $rc"
  grep -q 'target script not found' "$ERR" || fail "missing-target rejection did not explain itself on stderr: $(cat "$ERR")"
  pass "the launcher rejects a -Script value that does not resolve to an existing file"
}

test_settings_json_wires_every_entry_for_windows() {
  jq -e . "$SETTINGS" >/dev/null 2>&1 || fail ".claude/settings.json is not valid JSON"

  local expect_count=6
  local got_count
  got_count=$(jq '[.. | objects | select(has("command") and .command != null)] | length' "$SETTINGS")
  [ "$got_count" -eq "$expect_count" ] \
    || fail "expected $expect_count command hook entries in .claude/settings.json, found $got_count"

  # Every command entry must now also carry cwd + powershell, and the
  # powershell field must end with the caller-side `exit $LASTEXITCODE` this
  # launcher's contract requires (see fm-claude-hook-launch.ps1).
  local bad
  bad=$(jq '[.. | objects | select(has("command") and .command != null)
             | select((.cwd // "") != "."
                      or ((.powershell // "") | test("fm-claude-hook-launch\\.ps1") | not)
                      or ((.powershell // "") | test("exit \\$LASTEXITCODE$") | not))] | length' "$SETTINGS")
  [ "$bad" -eq 0 ] \
    || fail "$bad command hook entr(ies) are missing cwd/powershell wiring or the required trailing exit \$LASTEXITCODE"

  # The catch-all PreToolUse entry (fm-subagent-pretool-check.sh) deliberately
  # has no GROK short-circuit upstream (its bash "command" has none either);
  # every other entry does.
  local skip_grok_count
  skip_grok_count=$(jq '[.. | objects | select(has("powershell") and (.powershell // "" | test("-SkipIfGrok")))] | length' "$SETTINGS")
  [ "$skip_grok_count" -eq 5 ] \
    || fail "expected exactly 5 of 6 powershell entries to carry -SkipIfGrok (matching the bash GROK_AGENT/GROK_HOOK_EVENT short-circuit), found $skip_grok_count"

  pass "every .claude/settings.json command entry has matching cwd/powershell Windows wiring"
}

test_bash_matcher_now_also_matches_copilot_shell_tool() {
  local matcher
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$SETTINGS")
  [[ "Bash" =~ $matcher ]] || fail "broadened matcher '$matcher' must still match Claude's Bash tool"
  [[ "powershell" =~ $matcher ]] || fail "broadened matcher '$matcher' must also match Copilot's Windows shell tool name"
  [[ "BashSomethingElse" =~ $matcher ]] && fail "broadened matcher '$matcher' must be anchored, not a substring match"
  pass "the Bash-matcher PreToolUse guards (fm-arm/fm-cd) also cover Copilot's Windows shell tool"
}

test_forwards_args_and_stdin_and_allow_exit_code
test_preserves_nonzero_guard_exit_code
test_skip_if_grok_short_circuits
test_rejects_path_traversal_in_script_name
test_rejects_missing_target_script
test_settings_json_wires_every_entry_for_windows
test_bash_matcher_now_also_matches_copilot_shell_tool
