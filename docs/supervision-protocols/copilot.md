Mode: Copilot attached asynchronous supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh` as its own attached asynchronous shell task.
4. Trust only the arm's one-line status.
5. `watcher: started ...` or `watcher: attached ...` means one live cycle exists.
   On attach, the task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. After a successful start or attach status, end the turn.
   The asynchronous task remains the live wait until it returns an actionable notification or failure.
7. On completion, the notification hook or the next `agentStop` consumes the real arm's recent root/home-bound receipt and delivers the typed watcher wake; drain first, read the task result when needed, handle the queued event, and start the next attached asynchronous arm if supervision remains required.
8. Failure or missing cycle only: inspect the failure, then start one replacement asynchronous arm.
9. Never use shell `&`, detached execution, a truncating pipe, or a bundled command for Firstmate supervision.
   The PreToolUse seatbelt denies those command shapes before execution.
10. Waiting on a healthy asynchronous cycle is silent.

The tracked repository `agentStop` hook is both the turn-end backstop and the fallback for CLI releases that surface a shell completion to the model without invoking the notification hook.
It consumes a receipt exactly once, or otherwise forces one bounded continuation when supervision is required but no healthy cycle exists, using Copilot's native block decision and `stop_hook_active` loop guard.
