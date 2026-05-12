#!/usr/bin/env bash
# sdd-team TeammateIdle hook
# Catches teammates who go idle while still having pending tasks assigned.
# Re-prompts them to continue or report a blocker.
#
# Exit codes:
#   0 — allow idle
#   2 — block; the message is sent back to the teammate

set -u

TEAMMATE_NAME="${CLAUDE_TEAMMATE_NAME:-${1:-}}"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

# Find the active feature's agent-assignments.yml. Same heuristic as the
# task-completed hook — most recently modified state file.
find_active_feature() {
  local d="$PROJECT_ROOT/.sdd/state"
  [ -d "$d" ] || return 1
  local latest
  latest=$(ls -t "$d"/*.json 2>/dev/null | head -n1)
  [ -n "$latest" ] || return 1
  basename "$latest" .json
}

FEATURE=$(find_active_feature) || exit 0
ASSIGNMENTS="$PROJECT_ROOT/.specify/specs/$FEATURE/agent-assignments.yml"

# If the assignments file doesn't exist, we're not in /implement — allow idle.
[ -f "$ASSIGNMENTS" ] || exit 0

# Count tasks for this teammate that are not completed. Use a Python one-liner
# for YAML parsing; bash + YAML doesn't end well.
COUNT_AND_LIST=$(python3 - "$ASSIGNMENTS" "$TEAMMATE_NAME" <<'PY'
import sys, yaml
path, teammate = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f) or {}
tasks = data.get("tasks", []) or []
pending = [t for t in tasks if t.get("assignee") == teammate and t.get("status") != "completed"]
if not pending:
    print("0")
else:
    names = ", ".join(t.get("id") or t.get("description","?") for t in pending[:5])
    suffix = "" if len(pending) <= 5 else f" (+{len(pending)-5} more)"
    print(f"{len(pending)}|{names}{suffix}")
PY
)

if [ "$COUNT_AND_LIST" = "0" ]; then
  exit 0
fi

COUNT=$(echo "$COUNT_AND_LIST" | cut -d'|' -f1)
LIST=$(echo "$COUNT_AND_LIST" | cut -d'|' -f2-)

cat >&2 <<EOF
You have $COUNT pending task(s): $LIST
Continue working, or message the lead to report a blocker.
EOF

exit 2
