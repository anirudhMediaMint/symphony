#!/usr/bin/env bash
# sdd-team TaskCreated hook
# Rejects task creations that lack a clear deliverable or assignee.
# Quality gate, not a security gate.
#
# Exit codes:
#   0 — allow creation
#   2 — block; the message is sent back to the agent

set -u

# Claude Code passes the task definition as JSON via stdin or env var.
# Try multiple sources to be tolerant of API variation.
TASK_JSON="${CLAUDE_TASK_JSON:-}"
if [ -z "$TASK_JSON" ]; then
  if [ ! -t 0 ]; then
    TASK_JSON=$(cat)
  fi
fi

if [ -z "$TASK_JSON" ]; then
  # No task JSON received — can't validate; allow rather than block on uncertainty.
  exit 0
fi

VERDICT=$(python3 - <<PY
import json, sys
try:
    t = json.loads("""$TASK_JSON""")
except Exception:
    print("OK")  # malformed JSON — let agent-teams runtime handle
    sys.exit(0)

issues = []
desc = (t.get("description") or t.get("title") or "").strip()
if not desc or desc.upper() in ("TBD", "TODO", "..."):
    issues.append("description is empty or placeholder")

assignee = (t.get("assignee") or t.get("assigned_to") or "").strip()
if not assignee:
    issues.append("no assignee (set to a teammate name or 'default')")

if issues:
    print("BAD|" + "; ".join(issues))
else:
    print("OK")
PY
)

case "$VERDICT" in
  OK) exit 0;;
  BAD\|*)
    REASON="${VERDICT#BAD|}"
    echo "Task rejected: $REASON" >&2
    exit 2
    ;;
  *) exit 0;;
esac
