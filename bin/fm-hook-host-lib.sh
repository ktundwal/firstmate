#!/usr/bin/env bash
# Shared "which harness delivered this hook payload?" predicate for the tracked
# Claude-shaped hook entries.
# This file is sourced by hook entrypoints and has no side effects on source.
#
# Why it exists: Cursor Agent CLI loads `<project>/.claude/settings.json` in
# addition to its own `<project>/.cursor/hooks.json` (verified live, cursor-agent
# 2026.08.11-e8db854), and Copilot CLI loads that same Claude settings file in
# addition to its own `.github/hooks/` registration. A primary running in a
# Firstmate checkout can therefore fire BOTH registrations for the same event,
# which would run session start twice and evaluate each PreToolUse or turn-end
# seatbelt twice. The harness's native Firstmate registration owns those events,
# so the tracked Claude-shaped entry must stand down.
#
# The signal for Cursor is the PAYLOAD, not the environment, and that choice is
# load-bearing. Cursor exports CURSOR_INVOKED_AS, CURSOR_PROJECT_DIR, and
# CURSOR_VERSION into every child process, so an environment guard would also
# fire inside a Claude session a human started by hand from a Cursor pane and
# would silently disable Claude's own supervision. The delivered payload
# describes THIS event and cannot be inherited: Cursor stamps every hook payload
# with its own `cursor_version`, and Claude never emits that key.
#
# The signal for Copilot requires BOTH its exported marker and actual host
# process ancestry. A Claude session started from a Copilot shell can retain
# COPILOT_CLI=1, so the marker only avoids unnecessary ancestry walks when it
# is absent; a positive marker still needs the ancestry proof before a real
# Claude hook may stand down.
#
# Fail direction: when the host cannot be determined, the caller RUNS. A
# redundant run under a foreign host wastes work; a skipped run under Claude
# breaks the primary's supervision, which is the worse failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-harness-process-lib.sh
. "$SCRIPT_DIR/fm-harness-process-lib.sh"

fm_hook_actual_host() {
  local pid=$$ comm args host
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    if host=$(fm_harness_process_name "$comm" "$args"); then
      case "$host" in
        claude|copilot)
          printf '%s\n' "$host"
          return 0
          ;;
      esac
    fi
    [ "$pid" -eq 1 ] && break
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  printf 'unknown\n'
}

fm_hook_payload_is_foreign_host() {  # <payload>
  local payload=${1-} host
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1 \
     && printf '%s' "$payload" | jq -e '
          type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
        ' >/dev/null 2>&1; then
    return 0
  fi
  # Copilot exports this marker to every hook process. It is not sufficient to
  # identify the host by itself because a nested Claude can inherit it, but its
  # absence proves this is not a Copilot-hosted duplicate and avoids a process
  # ancestry walk on every ordinary Claude/Codex/Grok hook invocation.
  [ "${COPILOT_CLI:-}" = 1 ] || return 1
  host=$(fm_hook_actual_host)
  [ "$host" = copilot ]
}
