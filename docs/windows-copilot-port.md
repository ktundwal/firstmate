# Native Windows Copilot port: approach and status

Audience: maintainer architecture.

## Purpose and current scope

This fork develops Firstmate on native Windows with GitHub Copilot CLI, Git Bash, and Herdr.
The goal is to use Firstmate's existing supervisor, isolated-worker, steering, recovery, and cleanup paths without substituting an unrelated task runner or requiring WSL.
The port adds platform-specific evidence at existing boundaries rather than replacing the Bash architecture.

The current milestone is a bounded real-worker lifecycle, not general Windows support.
The dated results and their limits live in the [native Windows verification record](verification/runtime-backends.md#native-windows-copilot-pilot).
Current operator requirements belong to [configuration](configuration.md#harness-support), and the [Copilot adapter reference](../.agents/skills/harness-adapters/references/harness/copilot.md) routes launch and hook mechanics.
Application code, credentials, private operating homes, installed tools, and local investigation artifacts are not part of this port.

## Start from upstream work

The implementation reused existing proposals instead of creating a competing Copilot adapter.
These revisions were pinned during integration; a proposal's later merge state or updated head is not evidence that this fork contains it.

| Upstream proposal | Pinned revision | Use in this fork |
| --- | --- | --- |
| [Copilot integration, PR 3588](https://github.com/kunchenguid/firstmate/pull/3588) | `56a83de756febc93040d48ed48df6788640c83b9` | Imported the primary and worker integration, including hooks, lifecycle control, supervision, and regression coverage. |
| [MSYS directory locking, PR 3231](https://github.com/kunchenguid/firstmate/pull/3231) | `5fc967b553bc00303da5d13a56db533cfec9dff8` | Imported atomic directory-lock publication and its regressions. |
| [Windows socket paths, PR 2918](https://github.com/kunchenguid/firstmate/pull/2918) | `72e411c15cd9a1f5b7fa8697b2cea8cb741fde5b` | Adapted drive-letter socket normalization at the existing Herdr boundary. |
| [Windows ownership, PR 3553](https://github.com/kunchenguid/firstmate/pull/3553) | `92561828fb9540ab6c77437def67a954e44b0418` | Used the process-namespace findings as design evidence; its Claude-specific published-PID implementation was not imported wholesale. |
| [Windows groundwork, PR 3963](https://github.com/kunchenguid/firstmate/pull/3963) | `840374bb3c9786cc468c1d73d2f089d5e689ecee` | Consulted for process, path, and transport gaps without adopting eval-based test seams, global symlink settings, or permission-check bypasses. |
| [Durable Treehouse leases, PR 4324](https://github.com/kunchenguid/firstmate/pull/4324) | `5f97ab33ccd63ed9daaae28573a045642852d3b6` | Identified as follow-up work, not integrated. |

The Copilot patch was applied with three-way conflict resolution against the existing source baseline.
Resolution preserved newer harness-detection precedence, AGY support, task-environment isolation, and existing slot-ownership protections.
The resulting changes were transferred onto this fork's own history, preserving its executable and symlink modes rather than publishing an unrelated snapshot history.
This keeps a future upstream contribution based on the original repository's ancestry.

## Repair the platform boundaries

### Process ownership must come from native evidence

Git Bash's process view does not implement the Unix `ps -o` queries used by the original ownership walk.
Its MSYS parent chain can also end before reaching the native Copilot process.
A missing parent is not proof that no agent exists.

The Windows path reads native process facts through PowerShell/CIM and binds ownership to both a PID and its creation time.
It rejects missing or unreadable identity, a parent created after its child, and cyclic ancestry.
These checks matter because native Windows can retain dangling parent IDs that later refer to another process.
When the MSYS chain is severed, Copilot's published identity must be corroborated by the native executable and its independently parsed session argument; an environment PID alone is insufficient.

The shared Windows owner is [fm-windows-process-lib.sh](../bin/fm-windows-process-lib.sh), backed by [fm-windows-process.ps1](../bin/fm-windows-process.ps1).
Session-lock acquisition, holder liveness, hook attribution, and other affected readers use that shared representation.
Unix identities remain numeric, and an unreadable Windows owner does not become permission to take over its work.
The [shared process classifier](../bin/fm-harness-process-lib.sh) remains the common owner for harness classification.

### Hooks must reach the correct host once

Copilot's tracked primary hooks and generated worker hooks have native PowerShell command entries.
Those entries reuse the [Windows hook launcher](../bin/fm-claude-hook-launch.ps1) to invoke Git Bash explicitly.
They do not depend on an unqualified `bash.exe`, which can select WSL.

Copilot also reads Claude-compatible settings.
The [compatibility hook](../bin/fm-claude-compat-hook.sh) checks the actual host before delegating, so the same session does not run both primary adapters.
The Copilot [primary hook](../bin/fm-copilot-hook.sh) and [worker hook](../bin/fm-copilot-worker-hook.sh) translate native events into the existing Firstmate owners rather than introducing a second lifecycle.
Generated worker hooks remain task-scoped and are removed before reuse.

### A new terminal is a separate environment boundary

The real worker pilot exposed assumptions that a shell-only test did not: a newly created pane could lack the launching process's tool PATH, and native Treehouse could choose `cmd.exe` rather than Git Bash.
Windows acquisition now supplies the resolved Treehouse executable, pool root, and Git Bash shell explicitly.
Copilot launch carries the required tool PATH and disables automatic updates during managed work.
These changes live in [fm-spawn.sh](../bin/fm-spawn.sh); they do not change system PATH, shell profiles, or the user's global runtime selection.

### A recorded directory is not live location proof

The Windows Herdr response did not provide the live foreground directory field required by the spawn assertion.
Its startup directory could not safely stand in for that field.
The [Herdr adapter](../bin/backends/herdr.sh) therefore supports a fresh nonce-delimited shell-directory probe at the pre-launch discovery boundary.
The probe accepts one absolute directory result and requires the foreground identity to remain unchanged.
Ordinary directory reads do not inject shell commands into a running agent.

### Terminal text must remain literal

MSYS rewrote a slash command into a Windows filesystem path when it crossed into the native Herdr CLI.
The worker then received chat text instead of the intended exit command.
The Herdr adapter now disables argument conversion only for its terminal-text operations.
Path-bearing operations retain their normal conversion behavior.
This fixes the data boundary instead of teaching lifecycle control to recognize one corrupted command.

### Windows privacy requires ACLs, not a successful chmod

Git Bash could report mode `755` after `chmod 700` for directories with very different native permissions.
One inspected directory was genuinely private, while another inherited broader read and modify access.
Skipping the mode check would have accepted the unsafe case.

[fm-private-path-lib.sh](../bin/fm-private-path-lib.sh) retains Unix mode checks and delegates Windows privacy to the read-only [native ACL validator](../bin/fm-windows-private-path.ps1).
The validator owns the exact accepted ACL shape and path constraints.
It never changes permissions automatically.
The pilot's private home was corrected only after explicit approval; shared namespace and global permissions were not changed.

Completion receipts are checked before payload writing and after publication.
Their existing one-time claim, freshness, ownership-context, size, device, and link-count boundaries remain in the [receipt owner](../bin/fm-copilot-watcher-receipt-lib.sh).
The primary hook also recognizes PowerShell completion notifications while retaining exact-message matching and receipt replay rejection.

## How the work was exercised

Development happened in an independent repair copy with a separate private operating home and repair-local tools.
A disposable project and a named non-default Herdr lab supplied the real lifecycle test.
The worker was started through Firstmate's normal spawn path, not a generic background-agent shortcut.
Each failure was corrected at its owning boundary and the affected path was exercised again.

The observed sequence covered a real isolated worker, a worker-written report, acknowledged durable steering, native busy/stop hooks, relaunch in the same worktree with the same HEAD and report, verified exit, and guarded cleanup.
Post-cleanup reads confirmed task closure, report retention, removal of the owned lab, and an available pool slot.
These observations are stronger than a saved session record, but they do not establish every recovery guarantee.

Focused regressions cover process generations and malformed claims, native ACL acceptance and rejection, one-time completion receipts, native path transport, and socket identity.
Separate owned-lab guards cover fresh directory discovery and literal slash-command delivery.
The exact commands, versions, output, and unproven cases belong to the [verification record](verification/runtime-backends.md#native-windows-copilot-pilot).

## Before an upstream contribution

1. Exercise automatic startup and notification handling in a freshly launched Firstmate primary, not only direct invocation of its hook command.
2. Prove cancellation during active work; the current interrupt observation confirms delivery and agent liveness, not cancellation.
3. Exercise recovery after loss of the entire Herdr server with uncommitted worker changes, rather than treating an ordinary worker relaunch as crash-recovery proof.
4. Run the affected Linux/macOS regression paths and account explicitly for Unix-only process fixtures that Git Bash cannot execute.
5. Resolve the Windows process-group cleanup and remote-job orphan-scanning gaps before claiming those guarantees.
6. Reconcile the pinned proposals with upstream's current implementation and complete the normal contribution and delivery process.

Until that work is complete, this fork is an experimental integration checkpoint, not a finished Windows release.
