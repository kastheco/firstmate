#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.
#
# No platform gate: nothing in this adapter checks the OS. What differs by
# platform is the CLI's own resolution contract (fm_backend_orca_bin below),
# taken verbatim from Orca's bundled `orca-cli` skill (`orca skills get
# orca-cli`), never hardcoded or hand-searched here. On Linux the installed
# binary is named `orca-ide`, not `orca` - deliberately, to avoid colliding
# with /usr/bin/orca (the GNOME Orca screen reader); falling back to a bare
# `orca` lookup on Linux would risk launching the screen reader instead of
# failing closed, so this adapter never does that.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/cmux.sh's and bin/backends/zellij.sh's identical fallback.
FM_BACKEND_ORCA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_ORCA_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_ORCA_ROOT/bin/fm-composer-lib.sh"

# fm_backend_orca_bin: resolve the Orca CLI executable per Orca's own
# documented resolution contract (orca-cli skill): an explicit
# ORCA_CLI_COMMAND override always wins; ORCA_DEV_REPO_ROOT selects the
# orca-dev wrapper for a dev checkout; otherwise orca-ide on Linux, or orca
# everywhere else. Never falls back to bare `orca` on Linux (see header
# comment) - a resolution failure there is reported, not silently widened.
fm_backend_orca_bin() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    printf '%s' "$ORCA_CLI_COMMAND"
    return 0
  fi
  if [ -n "${ORCA_DEV_REPO_ROOT:-}" ] && command -v orca-dev >/dev/null 2>&1; then
    printf 'orca-dev'
    return 0
  fi
  if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    command -v orca-ide >/dev/null 2>&1 || return 1
    printf 'orca-ide'
    return 0
  fi
  command -v orca >/dev/null 2>&1 || return 1
  printf 'orca'
}

# fm_backend_orca_cli: run the resolved Orca CLI with the given arguments.
# Every call site below routes through this instead of invoking `orca`
# directly, mirroring bin/backends/cmux.sh's fm_backend_cmux_cli.
fm_backend_orca_cli() {  # <orca-subcommand-and-args...>
  local bin
  bin=$(fm_backend_orca_bin) || return 1
  "$bin" "$@"
}

# fm_backend_orca_lane_root: the optional --parent-worktree selector from
# config/orca-lane-root (first non-empty line, whitespace-stripped), mirroring
# the read idiom in fm_backend_name (bin/fm-backend.sh) and
# fm_backend_cmux_password (bin/backends/cmux.sh). Stored and passed through
# verbatim as whatever selector form the operator configured (for example
# `folder:<id>` or `worktree:<repoId>::<worktreePath>`, both accepted by
# Orca's own `worktree create --parent-worktree`) - this adapter does not
# parse or validate the selector, since a wrong value only costs a misplaced
# worktree, never data loss. Absent or empty means "not configured": callers
# fall back to today's --no-parent rather than silently inheriting whatever
# parent context the calling terminal happens to be running in.
fm_backend_orca_lane_root() {
  local config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" f line v
  f="$config_dir/orca-lane-root"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    v=$(printf '%s' "$line" | tr -d '[:space:]')
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done < "$f"
}

fm_backend_orca_tool_check() {
  local bin
  bin=$(fm_backend_orca_bin) && command -v "$bin" >/dev/null 2>&1 && return 0
  echo "error: backend=orca selected but no Orca CLI executable was found (checked \$ORCA_CLI_COMMAND, orca-dev, then orca-ide/orca per the documented resolution order - see docs/orca-backend.md)" >&2
  return 1
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(fm_backend_orca_cli status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(fm_backend_orca_cli repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal lane_root
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  # Lineage: with a configured lane root, the new worktree hangs under it in
  # Orca's own dashboard view; absent one, this falls back to today's
  # --no-parent rather than silently inheriting whatever parent context the
  # calling terminal happens to be running in (config/orca-lane-root; see
  # fm_backend_orca_lane_root above).
  lane_root=$(fm_backend_orca_lane_root)
  if [ -n "$lane_root" ]; then
    out=$(fm_backend_orca_cli worktree create --repo "id:$repo_id" --name "$name" --parent-worktree "$lane_root" --setup skip --json) || return 1
  else
    out=$(fm_backend_orca_cli worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  fi
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 0
  fm_backend_orca_cli terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
