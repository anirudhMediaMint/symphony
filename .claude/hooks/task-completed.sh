#!/usr/bin/env bash
# sdd-team TaskCompleted hook
# Blocks completion of "spec-draft" and "plan-draft" tasks until the user
# has run /sdd-team approve-spec or /sdd-team approve-plan respectively.
#
# Exit codes:
#   0 — allow completion
#   2 — block; the message printed to stderr is sent back to the agent

set -u

# Claude Code passes hook context via env vars and/or args. Treat both.
TASK_NAME="${CLAUDE_TASK_NAME:-${1:-}}"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

# Determine the active feature from the most recent state file. We don't have
# a direct "current feature" signal in the hook, so we look at .sdd/state/ and
# pick the most recently modified one.
find_active_feature() {
  local d="$PROJECT_ROOT/.sdd/state"
  [ -d "$d" ] || return 1
  local latest
  latest=$(ls -t "$d"/*.json 2>/dev/null | head -n1)
  [ -n "$latest" ] || return 1
  basename "$latest" .json
}

block_with_msg() {
  echo "$1" >&2
  exit 2
}

case "$TASK_NAME" in
  spec-draft|spec-draft-*)
    FEATURE=$(find_active_feature) || exit 0
    SENTINEL="$PROJECT_ROOT/.sdd/state/$FEATURE/gates_passed/specify"
    if [ -f "$SENTINEL" ]; then exit 0; fi
    SPEC_PATH="$PROJECT_ROOT/.specify/specs/$FEATURE/spec.md"
    block_with_msg "Awaiting human review of $FEATURE/spec.md (Gate 1).

Review:    cat $SPEC_PATH
Approve:   /sdd-team approve-spec
Reject:    /sdd-team abort  (then re-run /sdd-team to redraft)"
    ;;

  plan-draft|plan-draft-*)
    FEATURE=$(find_active_feature) || exit 0
    SENTINEL="$PROJECT_ROOT/.sdd/state/$FEATURE/gates_passed/plan"
    if [ -f "$SENTINEL" ]; then exit 0; fi
    PLAN_PATH="$PROJECT_ROOT/.specify/specs/$FEATURE/plan.md"
    block_with_msg "Awaiting human review of $FEATURE/plan.md (Gate 2).

Review:    cat $PLAN_PATH
Approve:   /sdd-team approve-plan
Reject:    /sdd-team abort  (then re-run /sdd-team to redraft)"
    ;;

  *)
    # Not an sdd-team gate task. Allow completion.
    exit 0
    ;;
esac
