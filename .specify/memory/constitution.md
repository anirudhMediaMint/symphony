<!--
SYNC IMPACT REPORT
Version change: (template / unversioned) → 1.0.0
Rationale: Initial ratified constitution. MAJOR bump because principles, constraints, and governance are introduced from scratch.

Added sections:
  - Core Principles (I–VII)
  - Architecture Constraints
  - Development Workflow
  - Governance

Modified principles: n/a (initial draft)
Removed sections: all [PLACEHOLDER] template scaffolding replaced with concrete Symphony-specific content.

Templates audited:
  - .specify/templates/plan-template.md ✅ no edit required (Constitution Check uses dynamic resolver: "[Gates determined based on constitution file]")
  - .specify/templates/spec-template.md ✅ no constitution references
  - .specify/templates/tasks-template.md ✅ no constitution references
  - .specify/templates/checklist-template.md ✅ no constitution references
  - .specify/templates/constitution-template.md ✅ template untouched (source of truth lives in this file)

Follow-up TODOs: none — every placeholder resolved.

---

Version change: 1.0.0 → 1.1.0
Rationale: MINOR bump — clause added to Principle II acknowledging that some tracker adapters (e.g., Jira) require server-side configuration consistent with workflow-named states, and pointing to SPEC §6.3 preflight resolvability checks. No principle removed or inverted.

Modified principles:
  - Principle II (Workflow Lives in the Repository): appended a clause on server-side state resolvability and preflight validation.

Added sections: none.
Removed sections: none.

Templates audited:
  - .specify/templates/plan-template.md ✅ no edit required (dynamic Constitution Check resolver).
  - .specify/templates/spec-template.md ✅ no constitution references.
  - .specify/templates/tasks-template.md ✅ no constitution references.
  - .specify/templates/checklist-template.md ✅ no constitution references.
  - .specify/templates/constitution-template.md ✅ template untouched.

Follow-up TODOs: none.

---

Version change: 1.1.0 → 1.1.1.
Rationale: PATCH — clarified Architecture Constraints "Tracker scope" bullet to
reflect Linear + Jira Cloud per SPEC §11. Multi-tracker support landed at v1.1.0
via Principle II; the Tracker-scope constraint still read pre-amendment text.
-->

# Symphony Constitution

Symphony is a long-running automation service that turns issue-tracker work into bounded,
isolated coding-agent runs. It exists so teams stop supervising agents and start managing
work. Every principle below is in service of that shift.

## Core Principles

### I. Manage Work, Not Agents
The unit of orchestration is the issue, never the agent session. Symphony polls a tracker,
claims work, runs an agent in an isolated workspace, and reconciles against tracker state
on every tick. The agent decides how to finish; Symphony only decides what runs, where, and
for how long. Trade-off: we give up fine-grained control over agent behavior — that control
lives in `WORKFLOW.md` and agent tooling, not in service code.

### II. Workflow Lives in the Repository
A single repo-owned `WORKFLOW.md` (YAML front matter + Markdown prompt body) is the
authoritative contract for tracker selection, runtime settings, hooks, and per-issue prompt.
Out-of-band service config is not a substitute. Workflow file read/parse errors block
new dispatches until fixed; template render errors fail only the affected run. Trade-off:
we accept that operators must edit a file in the repo (and reload) to change behavior —
no admin UI, no remote config plane.

Some tracker adapters require server-side configuration (e.g., Jira project workflows
defining the named transitions Symphony's `WORKFLOW.md` references). The repository file
remains authoritative for Symphony's behavior, but adapters MAY require corresponding
server-side state for resolvability. Preflight validation (SPEC §6.3) SHOULD verify
resolvability where the adapter exposes the necessary introspection (Jira's
`/rest/api/3/issue/{key}/transitions` does); silent first-dispatch failure is
unacceptable.

### III. The Orchestrator Owns One Authoritative State
A single in-memory orchestrator process owns `running`, `claimed`, `retry_attempts`,
`completed`, and aggregate metrics. Dispatch, retry, reconciliation, and stop decisions all
flow through it. No persistent database is required; restart recovery comes from the tracker
and the filesystem. Trade-off: exact in-flight scheduler state (timers, retry queues) is
lost on restart — we accept that in exchange for operational simplicity and no schema to
migrate.

### IV. Per-Issue Workspace Isolation is a Safety Invariant
Each issue gets a deterministic workspace directory under `workspace.root`. The coding agent
is launched only when `cwd == workspace_path` and `workspace_path` is a prefix-contained
child of `workspace_root`. Workspace keys are sanitized to `[A-Za-z0-9._-]`. These
invariants are non-negotiable — they are the difference between a scheduler and a footgun.
Trade-off: we will not optimize away workspace creation, path normalization, or hook
execution even when it costs a few seconds per dispatch.

### V. Trust and Safety Posture is Explicit, Not Universal
Symphony does not mandate one approval, sandbox, or operator-confirmation policy.
Implementations MUST document the posture they ship (Codex `approval_policy`,
`thread_sandbox`, `turn_sandbox_policy`). The reference Elixir implementation targets
trusted environments with safer-by-default Codex policies, but the spec leaves this
implementation-defined. Trade-off: portability and honesty over a one-size-fits-all
security story. A run MUST NOT stall indefinitely on approvals or input requests —
implementations either satisfy, surface, auto-resolve, or fail.

### VI. Symphony Reads the Tracker; the Agent Writes It
Symphony is a scheduler/runner and tracker reader. Ticket mutations — state transitions,
comments, PR links — are performed by the agent through workflow-defined tools (including
the optional `linear_graphql` client-side tool). Success is workflow-defined; reaching a
handoff state like `Human Review` is as valid as reaching `Done`. Trade-off: we give up
the ability to centrally enforce ticket hygiene, but we keep the orchestrator out of
business logic that belongs in the prompt.

### VII. Observability Must Not Become Required
Structured logs with `issue_id`, `issue_identifier`, and `session_id` context are required.
The optional Phoenix LiveView dashboard, JSON API, and humanized event summaries are
extensions — they MUST draw from orchestrator state and MUST NOT be required for
correctness. Trade-off: dashboards can drift or fail without affecting dispatch, but we
will not let operator features creep into the orchestration critical path.

## Architecture Constraints

- **Reference runtime**: Elixir 1.19 on Erlang/OTP/BEAM. OTP supervision trees own all
  long-running processes (orchestrator, agent runners, workspace manager, HTTP server).
  Hot code reloading is expected during development and MUST NOT crash live agent runs.
- **Layering**: Policy (`WORKFLOW.md`) → Configuration (typed getters, Ecto schema) →
  Coordination (orchestrator) → Execution (workspace + agent subprocess) → Integration
  (Linear adapter) → Observability (logs + optional dashboard). Cross-layer leaks (e.g.,
  tracker calls from the agent runner, dashboard reads from disk) are constitutional
  violations.
- **Agent transport**: Coding agent runs as a `bash -lc <codex.command>` subprocess in the
  workspace, speaking the Codex app-server protocol over stdio. The targeted Codex
  app-server version is the source of truth for protocol shape; Symphony passes
  `approval_policy`, `thread_sandbox`, and `turn_sandbox_policy` through as Codex-owned
  values.
- **Tracker scope**: Linear and Jira Cloud are the supported trackers in this spec
  version (see `SPEC.md` §11). The tracker client normalizes payloads into a stable
  issue model; adding a new tracker means a new adapter that produces the same
  normalized shape.
- **Concurrency**: Global cap via `agent.max_concurrent_agents` (default 10) plus optional
  per-state caps. Stall detection uses `codex.stall_timeout_ms`. Retry backoff is
  `min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)` for failures, `1000ms` for
  clean continuation.
- **No persistent database**: SQLite, Postgres, or equivalent SHOULD NOT be introduced
  for orchestrator state. The filesystem (for workspaces and logs) and the tracker (for
  issue truth) are the durable substrate.
- **Workers**: Optional SSH worker support for remote agent execution exists; the
  transport surface MUST stay representative under test (`make e2e` uses real SSH).

## Development Workflow

- **Spec is canonical**: `SPEC.md` at the repo root is the language-agnostic source of
  truth. Reference implementations (currently `elixir/`) conform to it; when they diverge,
  either the spec or the implementation is wrong and the gap MUST be closed.
- **Testing tiers**: `make all` runs unit and integration tests with ExUnit. `make e2e`
  runs the real Linear/Codex end-to-end target — it creates disposable Linear resources
  and a real `codex app-server` session, with both local-worker and SSH-worker scenarios.
  E2E is gated on `LINEAR_API_KEY` and is not a default CI step.
- **Coverage threshold**: 100% module coverage is enforced via `mix test --cover`, with
  an explicit ignore list in `mix.exs` for boundary modules (CLI, HTTP, Codex transport,
  orchestrator state) where coverage is asserted via integration paths instead.
- **Lint**: `mix lint` runs `specs.check` plus `credo --strict`. Both MUST pass before
  merge.
- **PRs**: Small, surgical, focused on one concern. Commit messages follow the existing
  style (`fix(elixir): ...`, `feat: ...`, scope tags like `[codex]`). GitHub Actions
  references MUST be pinned to commit SHAs.
- **Reload, don't restart**: Workflow config changes (poll interval, concurrency, hooks)
  SHOULD apply at runtime via reload. A failed reload keeps the last known good config
  running and logs the error.

## Governance

- This constitution supersedes ad-hoc conventions, individual preferences, and prior
  in-repo guidance. Where this document and `SPEC.md` overlap, `SPEC.md` controls
  protocol and behavior; this document controls priorities and trade-offs.
- Amendments require a PR that (a) names the principle or constraint changing, (b) states
  what trade-off shifts, and (c) updates `SPEC.md` if the change is observable to
  implementors. Version bumps follow semver intent: MAJOR for removed/inverted principles,
  MINOR for added principles or constraints, PATCH for clarifications.
- New top-level workflow keys are an extension surface (see SPEC §5.3): they MAY be added
  without amending this constitution, but they MUST document schema, defaults, validation,
  and reload semantics.
- Complexity that violates a principle MUST be justified in writing in the PR description.
  "It works" is not a justification.

**Version**: 1.1.1 | **Ratified**: 2026-05-12 | **Last Amended**: 2026-05-13
