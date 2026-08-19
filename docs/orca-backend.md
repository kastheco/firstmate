# Orca runtime backend

Orca is an experimental backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

Orca ships an app for both macOS and Linux, and this adapter carries no platform gate.
On Linux, this repository has confirmed the Orca app running and reporting ready (`orca status --json` returns `reachable=true`, `state="ready"`), and this adapter's CLI resolution, config reads, and worktree-lineage logic have unit coverage exercised on Linux.
The full spawn-through-teardown task lifecycle against a real Orca app remains unproven on Linux: no task has yet been spawned through Orca from a Linux home, so treat Linux support as CLI-and-readiness-verified but lifecycle-unproven until a live spawn is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#orca).

## Setup

Pick Orca when you already use the Orca app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is explicit-only and does not support secondmate spawns.

Prerequisites:

- The Orca app installed, running, and ready (`/Applications/Orca.app` on macOS).
- The Orca CLI on the machine, resolved per Orca's own documented contract (`orca skills get orca-cli`): an `ORCA_CLI_COMMAND` override, then `orca-dev` when `ORCA_DEV_REPO_ROOT` is set, then `orca-ide` on Linux, then `orca` elsewhere.
  This adapter never falls back to a bare `orca` lookup on Linux, because that name collides with the GNOME Orca screen reader; a Linux install without `orca-ide` on `PATH` (and without `ORCA_CLI_COMMAND` set) is reported as not installed rather than risking that collision.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires the resolved Orca CLI's `status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with the CLI's `repo add --path` when needed.
No manual repository registration is required.

Optional local `config/orca-lane-root` names a single Orca worktree-selector value (for example `folder:<id>` or `worktree:<repoId>::<worktreePath>`, per Orca's own selector vocabulary) that every new task worktree is created under with `worktree create --parent-worktree <value>`, so Firstmate-created tasks appear under that lineage in Orca's own dashboard.
The file is LOCAL and gitignored, read fresh on every worktree creation, and inherited into secondmate homes like the rest of `config/` (`bin/fm-config-inherit-lib.sh`).
This adapter does not validate the configured value; an unresolvable or malformed selector surfaces as an ordinary Orca CLI error at worktree-creation time, and a wrong value only costs a misplaced worktree, not lost work.
Absent this file, worktree creation falls back to today's `worktree create --no-parent`, explicitly - this adapter never inherits an ambient parent worktree from whatever terminal context happens to be running Firstmate.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`fm-peek.sh` reads with `orca terminal read`.
`fm-send.sh` types and verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
The composer read is one bounded tail of the live terminal and never pages backward into scrollback, so a stale startup banner cannot compete with the bottom-anchored composer.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending`.
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Active limits

- Orca is explicit-only.
- The app must be running and report ready.
- The full spawn-through-teardown task lifecycle is unproven on Linux; see "Setup" above.
- Secondmate spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- `config/orca-lane-root`'s selector value is passed through to Orca unvalidated; Firstmate does not check that it resolves to a real folder or worktree.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
