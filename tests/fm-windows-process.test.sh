#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WINDOWS_PROCESS_UNIT pwsh

script="$ROOT/tests/fm-windows-process.test.ps1"
library="$ROOT/bin/fm-windows-process.ps1"
if command -v cygpath >/dev/null 2>&1; then
  script=$(cygpath -w "$script") || exit 1
  library=$(cygpath -w "$library") || exit 1
fi
pwsh -NoProfile -NonInteractive -File "$script" -Library "$library" || exit $?

if [ -r "/proc/$$/winpid" ]; then
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  for executable in copilot.exe 'C:\tools\copilot.exe'; do
    out=$(fm_agent_process_classify "$executable" "$executable" "$executable")
    [ "$out" = agent ] || fail "native Copilot executable classified as '$out'"
  done
  out=$(fm_agent_process_classify 'bash.exe' 'C:\Program Files\Git\bin\bash.exe' '')
  [ "$out" = shell ] || fail "native Git Bash classified as '$out'"
  out=$(fm_agent_process_classify 'C:\copilot-notes\helper.exe' '' '')
  [ "$out" = other ] || fail "a native executable-path decoy classified as '$out'"
  pass "native Windows executable names preserve agent, shell, and unrelated-process distinctions"
fi
