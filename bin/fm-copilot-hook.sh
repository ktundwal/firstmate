#!/usr/bin/env bash
# Copilot CLI repository-hook adapter for Firstmate primary sessions.
# Usage: fm-copilot-hook.sh session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop|notification
#
# The shared scripts remain authoritative.
# This file translates only Copilot's native hook output objects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-copilot-watcher-receipt-lib.sh
. "$SCRIPT_DIR/fm-copilot-watcher-receipt-lib.sh"
MODE=${1:-}

copilot_hook_real_dir() {
  local dir=${1:-}
  [ -n "$dir" ] || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

copilot_hook_root() {
  pwd -P 2>/dev/null
}

copilot_hook_home() {
  local root=${1:-} home
  home=${FM_HOME:-$root}
  copilot_hook_real_dir "$home" || printf '%s\n' "$home"
}

copilot_hook_state() {
  local root=${1:-} state
  state=${FM_STATE_OVERRIDE:-$(copilot_hook_home "$root")/state}
  copilot_hook_real_dir "$state" || printf '%s\n' "$state"
}

copilot_notification_has_named_watcher_completion() {
  local payload=${1:-} title title_folded message prefix rest shell_id
  [ -n "$payload" ] || return 1
  title=$(printf '%s' "$payload" | jq -r '.title // empty' 2>/dev/null) || return 1
  title_folded=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
  case "$title_folded" in
    'arm firstmate watcher'|'arm the firstmate watcher') ;;
    *) return 1 ;;
  esac
  message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null) || return 1
  prefix="Shell command \"$title\" (shellId: "
  rest=${message#"$prefix"}
  [ "$rest" != "$message" ] || return 1
  shell_id=${rest%%)*}
  case "$shell_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$message" = "$prefix$shell_id) has completed successfully. Use read_bash with shellId \"$shell_id\" to retrieve the output." ]
}


copilot_notification_has_watcher_completion() {
  local payload=${1:-} root=${2:-} home=${3:-} state=${4:-}
  local policy command verdict saw_command=0 can_classify=0
  FM_COPILOT_WATCH_RECEIPT_CLAIMED=
  [ -n "$payload" ] || return 1
  [ -n "$root" ] && [ -n "$home" ] && [ -n "$state" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '
    ((.notification_type // .notificationType // "") | type) == "string"
    and ((.notification_type // .notificationType) | ascii_downcase) == "shell_completed"
  ' >/dev/null 2>&1 || return 1
  policy="$SCRIPT_DIR/fm-arm-command-policy.mjs"
  if command -v node >/dev/null 2>&1 && [ -f "$policy" ]; then
    can_classify=1
  fi
  while IFS= read -r -d '' command; do
    [ -n "$command" ] || continue
    saw_command=1
    [ "$can_classify" -eq 1 ] || continue
    verdict=$(node "$policy" watcher-arm --root "$root" --home "$home" --command "$command" 2>/dev/null || true)
    if [ "$verdict" = watch-arm ]; then
      fm_copilot_watch_receipt_acquire "$root" "$home" "$state" >/dev/null 2>&1 && return 0
      return 1
    fi
  done < <(printf '%s' "$payload" | jq -j '
  [
    .command,
    .commandLine,
    .command_line,
    .toolArgs.command,
    .toolInput.command,
    .tool_input.command,
    .task.command,
    .task.commandLine,
    .task.command_line,
    .data.command,
    .data.commandLine,
    .data.command_line
  ]
  | map(select(type == "string" and length > 0))
  | unique[]
  | ., "\u0000"
' 2>/dev/null)
  [ "$saw_command" -eq 0 ] || return 1
  copilot_notification_has_named_watcher_completion "$payload" || return 1
  fm_copilot_watch_receipt_acquire "$root" "$home" "$state"
}

copilot_watch_followup() {
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  local body='FIRSTMATE WATCHER WAKE: shell_completed: bin/fm-watch-arm.sh

Inspect the completed task result for the reason line when needed. Run bin/fm-wake-drain.sh first, handle every emitted wake, reconcile open decisions and unread status lines, then run the exact WAKE_ACK_REQUIRED --ack-through command printed by the drain. Until that post-handling acknowledgement, interruption leaves the work durable for idempotent re-handling. Start the next attached asynchronous arm only if supervision remains required.'
  fm_operational_input_encode watcher "$body" COPILOT_WATCH_FOLLOWUP
}

copilot_watch_receipt_cleanup() {
  local claimed=${FM_COPILOT_WATCH_RECEIPT_CLAIMED:-}
  [ -n "$claimed" ] || return 0
  if [ -n "${COPILOT_WATCH_PENDING_EXPECTED:-}" ] \
     && fm_copilot_watch_pending_matches "$STATE" "$COPILOT_WATCH_PENDING_EXPECTED"; then
    fm_copilot_watch_receipt_commit "$claimed" >/dev/null 2>&1 || true
  else
    fm_copilot_watch_receipt_restore "$STATE" "$claimed" >/dev/null 2>&1 || true
  fi
}

copilot_watch_wake_cleanup() {
  if [ -n "${FM_COPILOT_WATCH_PENDING_CLAIMED:-}" ]; then
    fm_copilot_watch_pending_restore "$STATE" "$FM_COPILOT_WATCH_PENDING_CLAIMED" >/dev/null 2>&1 || true
  fi
  if [ -n "${FM_COPILOT_WATCH_RECEIPT_CLAIMED:-}" ]; then
    fm_copilot_watch_receipt_restore "$STATE" "$FM_COPILOT_WATCH_RECEIPT_CLAIMED" >/dev/null 2>&1 || true
  fi
}

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
[ "$(fm_hook_actual_host)" = copilot ] || exit 0

case "$MODE" in
  session-start)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    OUT=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-session-start.XXXXXX") || exit 0
    trap 'rm -f "$OUT"' EXIT HUP INT TERM
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh" --copilot > "$OUT" 2>/dev/null || true
    [ -s "$OUT" ] || exit 0
    jq -Rs '{additionalContext:.}' < "$OUT"
    ;;
  pretool-arm)
    ROOT=$(copilot_hook_root) || exit 0
    HOME=$(copilot_hook_home "$ROOT")
    STATE=$(copilot_hook_state "$ROOT")
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$ROOT" "$STATE" || exit 0
    exec "$SCRIPT_DIR/fm-arm-pretool-check.sh" --copilot
    ;;
  pretool-cd)
    exec "$SCRIPT_DIR/fm-cd-pretool-check.sh" --copilot
    ;;
  pretool-subagent)
    exec "$SCRIPT_DIR/fm-subagent-pretool-check.sh" --copilot
    ;;
  agent-stop)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    ROOT=$(copilot_hook_root) || exit 0
    HOME=$(copilot_hook_home "$ROOT")
    STATE=$(copilot_hook_state "$ROOT")
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    if fm_primary_scope_matches "$ROOT" "$STATE"; then
      FM_COPILOT_WATCH_PENDING_CLAIMED=
      FM_COPILOT_WATCH_PENDING_CONTEXT=
      FM_COPILOT_WATCH_RECEIPT_CLAIMED=
      trap copilot_watch_wake_cleanup EXIT
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM
      REASON=
      if fm_copilot_watch_pending_acquire "$STATE" >/dev/null 2>&1; then
        REASON=$FM_COPILOT_WATCH_PENDING_CONTEXT
      elif fm_copilot_watch_receipt_acquire "$ROOT" "$HOME" "$STATE" >/dev/null 2>&1; then
        copilot_watch_followup || exit 0
        REASON=$COPILOT_WATCH_FOLLOWUP
      fi
      if [ -n "$REASON" ]; then
        BLOCK_JSON=$(jq -cn --arg reason "$REASON" '{decision:"block",reason:$reason}') || exit 0
        if [ -n "${FM_COPILOT_WATCH_PENDING_CLAIMED:-}" ]; then
          fm_copilot_watch_pending_commit "$FM_COPILOT_WATCH_PENDING_CLAIMED" || exit 0
          FM_COPILOT_WATCH_PENDING_CLAIMED=
        fi
        if [ -n "${FM_COPILOT_WATCH_RECEIPT_CLAIMED:-}" ]; then
          fm_copilot_watch_receipt_commit "$FM_COPILOT_WATCH_RECEIPT_CLAIMED" || exit 0
          FM_COPILOT_WATCH_RECEIPT_CLAIMED=
        fi
        trap - EXIT HUP INT TERM
        printf '%s\n' "$BLOCK_JSON"
        exit 0
      fi
      trap - EXIT HUP INT TERM
    fi
    REASON_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-copilot-agent-stop.XXXXXX") || exit 0
    trap 'rm -f "$REASON_FILE"' EXIT HUP INT TERM
    if printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --copilot >/dev/null 2>"$REASON_FILE"; then
      exit 0
    else
      STATUS=$?
    fi
    [ "$STATUS" -eq 2 ] || exit 0
    REASON=$(cat "$REASON_FILE" 2>/dev/null || true)
    [ -n "$REASON" ] || REASON='Restore Firstmate supervision before ending this turn.'
    jq -cn --arg reason "$REASON" '{decision:"block",reason:$reason}'
    ;;
  notification)
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    ROOT=$(copilot_hook_root) || exit 0
    HOME=$(copilot_hook_home "$ROOT")
    STATE=$(copilot_hook_state "$ROOT")
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$ROOT" "$STATE" || exit 0
    FM_COPILOT_WATCH_RECEIPT_CLAIMED=
    COPILOT_WATCH_PENDING_EXPECTED=
    trap copilot_watch_receipt_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    copilot_notification_has_watcher_completion "$PAYLOAD" "$ROOT" "$HOME" "$STATE" || exit 0
    copilot_watch_followup || exit 0
    COPILOT_WATCH_PENDING_EXPECTED=$COPILOT_WATCH_FOLLOWUP
    fm_copilot_watch_pending_publish "$STATE" "$COPILOT_WATCH_FOLLOWUP" || exit 0
    fm_copilot_watch_receipt_commit "$FM_COPILOT_WATCH_RECEIPT_CLAIMED" || exit 0
    FM_COPILOT_WATCH_RECEIPT_CLAIMED=
    trap - EXIT HUP INT TERM
    jq -cn --arg text "$COPILOT_WATCH_FOLLOWUP" '{additionalContext:$text}'
    ;;
  *)
    echo "usage: $(basename "$0") session-start|pretool-arm|pretool-cd|pretool-subagent|agent-stop|notification" >&2
    exit 2
    ;;
esac
