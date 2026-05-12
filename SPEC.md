# Symphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(Linear and Jira Cloud in this specification version), creates an isolated workspace for each issue,
and runs a coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the workflow/runtime environment.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses front matter into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (tracker adapters)
   - API calls and normalization for tracker data.
   - One adapter per supported tracker kind (Linear, Jira Cloud). All adapters produce the same
     normalized issue model defined in Section 4.1.1.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `tracker.kind: linear`; Jira Cloud REST v3 for `tracker.kind: jira`).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports the targeted Codex app-server mode.
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

Design note:

- `WORKFLOW.md` SHOULD be self-contained enough to describe and run different workflows (prompt,
  runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `prompt_template`: trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The workflow front matter is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.

#### 5.3.1 `tracker` (object)

Common fields (apply to every adapter):

- `kind` (string)
  - REQUIRED for dispatch.
  - Supported values: `linear`, `jira`.
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
  - Compared after `lowercase` normalization against the adapter's normalized state names.
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`
  - Compared after `lowercase` normalization against the adapter's normalized state names.

Adapter-specific fields nest under `tracker.<kind>` and are documented in the adapter sections of
Section 11. The keys recognized for each adapter are:

- `tracker.linear` (see Section 11.3):
  - `endpoint`, `api_key`, `project_slug`
- `tracker.jira` (see Section 11.4):
  - `base_url`, `email`, `api_token`, `jql`, `priority_map` (OPTIONAL; see Section 11.4 for
    semantics), `max_issues_per_poll` (OPTIONAL; default `200`, MUST be ≥ 1),
    `allow_aggressive_polling` (OPTIONAL; default `false`)

For backward compatibility with `tracker.kind == "linear"` configurations written before this
specification version, flat keys (`tracker.endpoint`, `tracker.api_key`, `tracker.project_slug`) MAY
be accepted as synonyms for the corresponding `tracker.linear.*` fields when `tracker.kind ==
"linear"`. Flat keys are deprecated; new configurations SHOULD use the nested form.

Precedence rules when both flat and nested keys are present for the same logical field (e.g., both
`tracker.api_key` and `tracker.linear.api_key`):

- If the values are **identical**: the nested key wins. Implementations SHOULD log a warning that
  the flat key is redundant.
- If the values **differ**: preflight validation (Section 6.3) MUST fail with a
  `tracker_config_conflict` error. The error message MUST name both conflicting keys.

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to the directory containing `WORKFLOW.md`.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.

#### 5.3.6 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on an issue from the configured tracker.`).
- Workflow file read/parse failures are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the workflow file path (explicit runtime setting, otherwise cwd default).
2. Parse YAML front matter into a raw config map.
3. Apply built-in defaults for missing OPTIONAL fields.
4. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
5. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative `workspace.root` values resolve relative to the directory containing the selected
  `WORKFLOW.md`.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect `WORKFLOW.md` changes.
- On change, it MUST re-read and re-apply workflow config and prompt template without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, codex settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- All adapter-required fields for the selected `tracker.kind` are present after `$` resolution
  (see the adapter section for the selected kind in Section 11). Examples:
  - `linear`: `api_key`, `project_slug`
  - `jira`: `base_url`, `email`, `api_token`, `jql`; `priority_map` is OPTIONAL (see Section 11.4)
- `codex.command` is present and non-empty.
- Workflow-state resolvability. Preflight MUST invoke the configured tracker adapter's optional
  `validate_state_resolvability()` operation when the adapter implements it. If the operation
  returns one or more unresolvable workflow-named states, preflight fails with
  `workflow_state_unresolvable` (a new entry in Section 11.5 Common errors), naming each
  unresolved state.
- Jira poll-interval floor. When `tracker.kind == jira` and `agent.poll_interval_ms < 30000` and
  `tracker.jira.allow_aggressive_polling` is `false`, preflight MUST fail with
  `jira_poll_interval_too_aggressive` (see Section 11.5). The error message MUST name the
  configured interval, the minimum (`30000` ms), and the override key
  (`tracker.jira.allow_aggressive_polling`).
- JQL `ORDER BY` rejection. When `tracker.kind == jira`, preflight MUST parse
  `tracker.jira.jql` (case-insensitive token scan) for the literal `ORDER BY` keyword pair. If
  present, preflight MUST fail with `jql_order_by_not_allowed` (see Section 11.5). The error
  message MUST quote the offending JQL fragment and reference Section 8.2's canonical dispatch
  ordering.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `tracker.kind`: string, REQUIRED, one of `linear`, `jira`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `tracker.linear.endpoint`: string, default `https://api.linear.app/graphql` (when `tracker.kind=linear`)
- `tracker.linear.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY`, REQUIRED when `tracker.kind=linear`
- `tracker.linear.project_slug`: string, REQUIRED when `tracker.kind=linear`
- `tracker.jira.base_url`: string or `$VAR`, REQUIRED when `tracker.kind=jira` (e.g. `https://acme.atlassian.net`)
- `tracker.jira.email`: string or `$VAR`, REQUIRED when `tracker.kind=jira`
- `tracker.jira.api_token`: string or `$VAR`, canonical env `JIRA_API_TOKEN`, REQUIRED when `tracker.kind=jira`
- `tracker.jira.jql`: string, REQUIRED when `tracker.kind=jira`; raw JQL string used for candidate selection
- `tracker.jira.priority_map`: map of string -> positive integer, OPTIONAL when `tracker.kind=jira`; resolves custom priority scheme names per Section 11.4
- `tracker.jira.max_issues_per_poll`: integer, default `200`, MUST be ≥ 1; cap on cumulative normalized-issue count fetched per poll cycle (see Section 11.4)
- `tracker.jira.allow_aggressive_polling`: boolean, default `false`; when `false`, preflight rejects `agent.poll_interval_ms < 30000` for Jira (see Sections 6.3 and 11.4)
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `codex.command`: shell command string, default `codex app-server`
- `codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker MAY continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state, the worker SHOULD start another turn on the same live
  coding-agent thread in the same workspace, up to `agent.max_turns`.
- The first turn SHOULD use the full rendered task prompt.
- Continuation turns SHOULD send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Codex Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (without a durable orchestrator DB).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval SHOULD be updated when workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from tracker using active states.
4. Sort issues by dispatch priority.
5. Dispatch eligible issues while slots remain.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule for `Todo` state passes:
  - If the issue state is `Todo`, do not dispatch when any blocker is non-terminal.

Sorting order (stable intent):

1. `priority` ascending (1..4 are preferred; null/unknown sorts last)
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_codex_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms > codex.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized absolute path)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines Symphony's language-neutral responsibilities when integrating a Codex
app-server. The Codex app-server protocol for the targeted Codex version is the source of truth for
protocol schemas, message payloads, transport framing, and method names.

Protocol source of truth:

- Implementations MUST send messages that are valid for the targeted Codex app-server version.
- Implementations MUST consult the targeted Codex app-server documentation or generated schema
  instead of treating this specification as a protocol schema.
- If this specification appears to conflict with the targeted Codex app-server protocol, the Codex
  protocol controls protocol shape and transport behavior.
- Symphony-specific requirements in this section still control orchestration behavior, workspace
  selection, prompt construction, continuation handling, and observability extraction.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `codex.command`
- Invocation: `bash -lc <codex.command>`
- Working directory: workspace path
- Transport/framing: the protocol transport required by the targeted Codex app-server version

Notes:

- The default command is `codex app-server`.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the targeted Codex app-server version.

RECOMMENDED additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Responsibilities

Reference: https://developers.openai.com/codex/app-server/

Startup MUST follow the targeted Codex app-server contract. Symphony additionally requires the
client to:

- Start the app-server subprocess in the per-issue workspace.
- Initialize the app-server session using the targeted Codex app-server protocol.
- Create or resume a coding-agent thread according to the targeted protocol.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Start the first turn with the rendered issue prompt.
- Start later in-worker continuation turns on the same live thread with continuation guidance rather
  than resending the original issue prompt.
- Supply the implementation's documented approval and sandbox policy using fields supported by the
  targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the targeted
  protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Extract `thread_id` from the thread identity returned by the targeted Codex app-server protocol.
- Extract `turn_id` from each turn identity returned by the targeted Codex app-server protocol.
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client processes app-server updates according to the targeted Codex app-server protocol until
the active turn terminates.

Completion conditions:

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it SHOULD start another turn on the same
  live thread using the targeted protocol.
- The app-server subprocess SHOULD remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Transport handling requirements:

- Follow the transport and framing rules of the targeted Codex app-server version.
- For stdio-based transports, keep protocol stream handling separate from diagnostic stderr
  handling unless the targeted protocol specifies otherwise.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event SHOULD
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid` (if available)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation MUST document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely. An
  implementation MAY either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime SHOULD
  be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, return a tool failure response
  using the targeted protocol and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation MAY expose a limited set of client-side tools to the app-server session.
- Current standardized optional tool: `linear_graphql`.
- If implemented, supported tools SHOULD be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Codex app-server version.
- Unsupported tool names SHOULD still return a failure result using the targeted protocol and
  continue the session.

`linear_graphql` extension contract:

- Purpose: execute a raw GraphQL query or mutation against Linear using Symphony's configured
  tracker auth for the current session.
- Availability: only meaningful when `tracker.kind == "linear"` and valid Linear auth is configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST be a non-empty string.
- `query` MUST contain exactly one GraphQL operation.
- `variables` is OPTIONAL and, when present, MUST be a JSON object.
- Implementations MAY additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Symphony workflow/runtime config; do
  not require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.

User-input-required policy:

- Implementations MUST document how targeted-protocol user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming implementation MAY fail the run, surface the request to an operator, satisfy it
  through an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `codex.read_timeout_ms`: request/response timeout during startup and sync requests
- `codex.turn_timeout_ms`: total turn stream timeout
- `codex.stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (RECOMMENDED normalized categories):

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start app-server session.
4. Forward app-server events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

## 11. Issue Tracker Integration Contract

Symphony talks to issue trackers through a pluggable `TrackerAdapter` contract. Each supported
tracker kind ships an adapter that implements the same contract and produces the same normalized
issue shape. The orchestrator, polling loop, reconciliation, and observability code MUST NOT depend
on the selected tracker kind.

Currently specified adapters:

- Linear (Section 11.3) — `tracker.kind == "linear"`
- Jira Cloud (Section 11.4) — `tracker.kind == "jira"`

### 11.1 TrackerAdapter Contract

An adapter is a value with the operations below. Operation signatures are written in language-neutral
pseudocode; the unit of exchange between the adapter and the orchestrator is the normalized issue
model from Section 4.1.1.

REQUIRED read operations:

1. `fetch_candidate_issues() -> {ok, [Issue]} | {error, ErrorClass}`
   - Returns issues that are dispatch candidates per the adapter's configured selection input.
   - Each returned issue's `state` MUST be set so the orchestrator can apply `active_states` /
     `terminal_states` filtering after `lowercase` normalization.
   - Pagination is the adapter's responsibility; the caller sees a single fully-paginated list.

2. `fetch_issues_by_states(state_names) -> {ok, [Issue]} | {error, ErrorClass}`
   - Used during startup terminal workspace cleanup (Section 8.6).
   - `state_names` is the list of configured terminal states.
   - An empty `state_names` list SHOULD short-circuit to `{ok, []}` without an API call.

3. `fetch_issue_states_by_ids(issue_ids) -> {ok, [Issue]} | {error, ErrorClass}`
   - Used during active-run reconciliation (Section 8.5).
   - Returned issues SHOULD include at least `id`, `identifier`, and `state`.
   - Missing IDs are silently omitted from the result rather than producing an error.

Concurrency and statefulness:

- Adapters MUST be safe for concurrent calls from multiple orchestrator tasks. The orchestrator may
  invoke read operations from polling, reconciliation, and dispatch loops simultaneously, on the
  same adapter instance, against the same or different issues.
- Adapters SHOULD be stateless apart from connection pools and credential caches. Adapters MUST NOT
  cache issue state across operations; every read fetches authoritative state from the tracker.

OPTIONAL write operations (NOT used by the orchestration loop; defined solely so adapters MAY
expose them to the coding agent as client-side tools — see Section 11.6 for the orchestrator
boundary):

4. `create_comment(issue_id, body) -> ok | {error, ErrorClass}`
   - Post a comment on the issue. `body` is **plain text**. Adapters MUST NOT interpret Markdown or
     HTML in `body`.
   - Per-adapter rendering (for example, wrapping `body` into Atlassian Document Format for Jira) is
     an adapter implementation detail transparent to the caller.

5. `update_issue_state(issue_id, state_name) -> ok | {error, ErrorClass}`
   - Move the issue to the named state.
   - The adapter is responsible for translating `state_name` into whatever underlying mechanism the
     tracker requires (direct state assignment for Linear; transition-by-target-state-name for Jira).
   - If `state_name` does not correspond to a reachable state from the current state, return
     `{error, state_transition_not_available}` rather than guessing.
   - If `state_name` is ambiguous (more than one transition would reach a state with that name),
     return `{error, state_transition_ambiguous}` rather than guessing.

Rationale for "name a target state, let the adapter resolve the path":

- Linear allows direct state assignment, so resolution is trivial.
- Jira requires an intermediate transition step. Naming the transition explicitly in `WORKFLOW.md`
  would leak Jira-specific concepts into the contract; naming the target state is the lowest common
  vocabulary. Reversible: a future revision MAY add `update_issue_via_transition(issue_id,
  transition_name)` as a second, adapter-specific entry point without breaking existing callers.

OPTIONAL read operations (NOT used by the orchestration loop directly; invoked by preflight
validation — see Section 6.3):

6. `validate_state_resolvability() -> {ok, []} | {ok, [UnresolvedStateName]} | {error, ErrorClass}`
   - Read-only adapter introspection. Returns the list of workflow-named states referenced by
     Symphony's configuration (e.g., the transition mapping in `WORKFLOW.md`) that the adapter
     cannot resolve to a reachable server-side state.
   - An empty list means every referenced state name is resolvable.
   - Adapters that cannot introspect server-side workflow state SHOULD omit this operation (or
     return `{error, not_implemented}`); preflight skips the check in that case.
   - This operation is read-only and does not violate Principle VI; it issues no tracker
     mutations.

PR-link surface:

- Associating a pull-request URL with a tracker issue is OPTIONAL. When implemented, adapters
  expose it as a `link_pr(issue_id, pr_url, title?) -> ok | {error, ErrorClass}` operation that the
  agent toolchain may invoke.
- `title` is OPTIONAL. When `title` is omitted, adapters MUST default to a reasonable display string
  derived from `pr_url` (for example, the path segment after the host). Implementations MAY choose
  richer defaults, but the contract guarantees a non-empty display string for every link.
- Implementation differs per tracker:
  - Linear: native attachment via the GraphQL `attachmentLinkURL` mutation.
  - Jira Cloud: remote issue link via `POST /rest/api/3/issue/{issueIdOrKey}/remotelink`.
  Neither operation is invoked by the orchestrator and neither is REQUIRED for conformance.

Contract versioning:

- The TrackerAdapter contract is versioned together with this specification (see Section 1 /
  document version). Adapters MAY expose adapter-specific operations beyond the contract surface in
  this section, but conforming orchestrator code MUST NOT depend on adapter-specific operations.
- Future revisions of this contract MAY add new optional operations; adapters predating the
  addition remain conforming and SHOULD return a `not_implemented` error for unknown operations
  rather than silently no-op.

### 11.2 Normalized Issue Model

All adapters MUST produce issues that conform to Section 4.1.1.

Common normalization rules (apply to every adapter):

- `labels` -> lowercase strings.
- `priority` -> integer only (non-integers become `null`).
- `created_at` and `updated_at` -> ISO-8601 timestamps; absent fields become `null`.
- `state` -> the tracker's human-visible state name as a string (no enum coercion).

Cross-adapter symmetry notes:

- `branch_name` is populated by adapters whose tracker provides per-issue branch metadata (Linear
  does). Adapters whose tracker does not (Jira Cloud) MUST set `branch_name = null`. Workflow
  templates SHOULD NOT assume `branch_name` is present.
- `blocked_by` is populated when the tracker exposes a "blocked-by" relation (Linear does via inverse
  relations of type `blocks`; Jira does via `Blocks` issue links). If the tracker does not expose
  such a relation, the adapter MUST return `blocked_by = []`. Adapters that cannot expose blocker
  relations (`blocked_by` always empty) will never gate dispatch on blocker state; operators who
  rely on blocker-gating MUST use a tracker adapter that populates `blocked_by`.

Nullable fields and template safety:

- Normalized fields documented as adapter-conditional (e.g., `branch_name`, `priority` under custom
  Jira schemes) MAY be `null`. Workflow templates referencing such fields MUST either guard with
  `{% if issue.branch_name %}` or expect empty-string rendering on adapters that return null. The
  reference Liquid renderer treats nil field access as empty string; it does NOT raise.
- Adapters MUST enumerate their nullable-field set in their adapter section: Linear (Section 11.3) —
  none. Jira (Section 11.4) — `branch_name` (always), `priority` (when project uses a non-default
  scheme without a configured `tracker.jira.priority_map`).

### 11.3 Linear Adapter (`tracker.kind == "linear"`)

Configuration (under `tracker.linear` in `WORKFLOW.md`; flat `tracker.endpoint`, `tracker.api_key`,
`tracker.project_slug` accepted as backward-compatible synonyms per Section 5.3.1):

- `endpoint` (string) — default `https://api.linear.app/graphql`
- `api_key` (string or `$VAR`) — REQUIRED. Canonical env var: `LINEAR_API_KEY`. Sent in the
  `Authorization` request header.
- `project_slug` (string) — REQUIRED. Maps to Linear project `slugId`.

Transport:

- GraphQL over HTTPS.
- Network timeout: `30000 ms`.
- Pagination REQUIRED for candidate issues; page size default `50`.

Issue selection input:

- Implicit. Candidates are all issues in `tracker.linear.project_slug` whose state name is in
  `tracker.active_states`.
- Candidate query filters the project with `project: { slugId: { eq: $projectSlug } }`.
- Issue-state refresh query uses GraphQL ID typing (`[ID!]`).

Normalized field mapping (Linear field -> normalized field):

- `id` -> `id`
- `identifier` -> `identifier` (e.g. `ABC-123`)
- `title` -> `title`
- `description` -> `description`
- `priority` -> `priority`
- `state.name` -> `state`
- `branchName` -> `branch_name`
- `url` -> `url`
- `labels.nodes[].name` -> `labels` (lowercased)
- inverse relations of type `blocks` -> `blocked_by`
- `createdAt` / `updatedAt` -> `created_at` / `updated_at`

Nullable fields: none.

State transitions (`update_issue_state`):

- Resolve the workflow's target state name to a Linear `WorkflowState` ID scoped to the issue's team
  (`team.states(filter: {name: {eq: $stateName}}, first: 1)`).
- Call `issueUpdate(id: $issueId, input: {stateId: $stateId})`.
- If no state with the requested name exists on the team, return
  `{error, state_transition_not_available}`.

Comments (`create_comment`):

- Call `commentCreate(input: {issueId: $issueId, body: $body})`. The caller's `body` is plain text
  per Section 11.1; the adapter passes it through without interpreting Markdown or HTML. Linear
  renders the resulting comment as plain text.

PR links (`link_pr`, OPTIONAL):

- Call Linear `attachmentLinkURL` or `attachmentCreate` with the PR URL. Recommended title shape:
  `<issue.identifier>: <pr_title>` when `pr_title` is supplied.

Rate limits and operational notes:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.
- Linear rate-limit behavior is documented by Linear; Symphony does not impose a client-side rate
  limiter and treats `429` as a transport-level error subject to normal retry behavior.
- Linear has no minimum poll interval imposed by this spec.

### 11.4 Jira Cloud Adapter (`tracker.kind == "jira"`)

Scope: Jira Cloud only. Jira Server and Jira Data Center are out of scope for this specification
version.

Configuration (under `tracker.jira` in `WORKFLOW.md`):

- `base_url` (string or `$VAR`) — REQUIRED. The Jira Cloud site root, e.g. `https://acme.atlassian.net`.
  Trailing slash is tolerated. The adapter appends `/rest/api/3/...` for REST calls.
- `email` (string or `$VAR`) — REQUIRED. The Atlassian account email associated with the API token.
- `api_token` (string or `$VAR`) — REQUIRED. Canonical env var: `JIRA_API_TOKEN`. Created via
  `https://id.atlassian.com/manage-profile/security/api-tokens`.
- `jql` (string) — REQUIRED. Raw JQL string evaluated for candidate selection. See "Issue selection"
  below.
- `priority_map` (map of string -> positive integer) — OPTIONAL. Resolves custom Jira priority
  scheme names to the normalized integer priority. See "Normalized field mapping" below.

Transport:

- HTTPS REST. Jira Cloud REST API v3 is the targeted version.
- Authentication: HTTP Basic, with `Authorization: Basic base64(email + ":" + api_token)`. Tokens
  MUST NOT appear in logs.
- Network timeout: `30000 ms` (matches Linear adapter default).
- Pagination REQUIRED for candidate issues.

Issue selection input:

- `tracker.jira.jql` is a raw JQL string written by the operator. Symphony does NOT synthesize JQL.
- Example: `project = ENG AND statusCategory != Done AND assignee = currentUser()`.
- The adapter issues `GET /rest/api/3/search/jql` (Jira Cloud's enhanced JQL search endpoint) with
  `jql=<configured-jql>` and a `fields` selector that requests at minimum the fields needed to
  populate the normalized issue model (see "Normalized field mapping" below).
- Pagination. The adapter sends `nextPageToken=<token>` as a query parameter on follow-up requests.
  The first request omits the parameter. The adapter reads the next token from the response body's
  top-level `nextPageToken` field. Pagination terminates when `nextPageToken` is absent from the
  response (the older `isLast` field is ignored for the `/search/jql` endpoint). Implementations
  SHOULD set a reasonable `maxResults` (e.g., 100) per request; adapters MUST NOT assume Jira
  honors arbitrarily large values.
- Result-set cap. The adapter paginates `/rest/api/3/search/jql` until either (a) the response
  signals exhaustion (no `nextPageToken`), or (b) the cumulative normalized-issue count reaches
  `tracker.jira.max_issues_per_poll` (default `200`). If the cap is hit while results remain
  unfetched, the adapter MUST log a WARN-level message naming the cap, the observed count
  threshold, and the JQL query (truncated to 200 chars). The adapter proceeds with the first N
  issues; the orchestrator dispatches normally against them. Operators with intentionally large
  polling sets MUST raise `max_issues_per_poll` explicitly; the adapter MUST NOT silently expand
  the cap.
- JQL contract. Operator JQL MUST NOT contain an `ORDER BY` clause. Symphony's dispatch ordering
  is canonical (Section 8.2: priority descending, then oldest creation timestamp); an
  operator-supplied `ORDER BY` would create ambiguity between adapter-fetch order and dispatch
  order. Preflight (Section 6.3) rejects such JQL with `jql_order_by_not_allowed`.
- The orchestrator still applies `tracker.active_states` filtering against normalized `state` after
  the adapter returns. The JQL is the broad candidate filter; `active_states` is the precise
  dispatch gate. Operators SHOULD ensure their JQL is at least as wide as `active_states` to avoid
  surprises.

Issue lookup by id (`fetch_issue_states_by_ids`):

- `issue_ids` are Jira **issue keys** (e.g., `ENG-123`). The adapter fetches state per key using
  `GET /rest/api/3/issue/{key}?fields=status`, or batches via
  `GET /rest/api/3/search/jql?jql=key in (KEY-1, KEY-2)&fields=status` when more than one key is
  requested.

Normalized field mapping (Jira field -> normalized field):

- `key` -> `identifier` (e.g. `ENG-123`)
- `id` -> `id`
- `fields.summary` -> `title`
- `fields.description` -> `description`. Jira returns ADF (Atlassian Document Format). The adapter
  MUST render the ADF document to plain text using the deterministic algorithm below. Raw ADF
  passthrough is an EXTENSION (see "Description format extension" below).
  - Concatenate the text content of all leaf nodes in document order.
  - Insert one `\n` between sibling **block nodes** (paragraph, heading, list item, code block,
    blockquote).
  - Insert two `\n` between **top-level block nodes**.
  - Ignore unknown marks; render the text content of unknown nodes (i.e., recurse into their
    children and emit leaf text).
  - **Non-text ADF nodes** are rendered as follows:
    - `media`, `mediaSingle`, `mediaGroup` (images/files): render as
      `[image: <attrs.alt or attrs.title or 'file'>]`. If the node has no alt/title, use the file
      collection ID truncated.
    - `mention`: render as `@<displayName>` using the mention's text content as the display name.
      If text content is absent, render `@<accountId>` truncated to 8 chars.
    - `inlineCard`, `blockCard`: render the URL in `attrs.url` enclosed in angle brackets:
      `<https://...>`.
    - `panel`: render the inner text content with a leading `[panel:<panelType>]` marker on its
      own line; preserve the inner block-node spacing rules.
    - `emoji`: render as the literal shortName, e.g. `:thumbsup:`.
    - `status`: render as `[<text>]` using the status node's text.
    - `date`: render as the ISO-8601 string from `attrs.timestamp` (epoch ms → ISO).
    - Unknown nodes: render the concatenated text content of their children (no marker).
  - Adapters that perform lossy rendering (any of the above placeholder substitutions executed on
    a given issue) MUST emit a single DEBUG-level log line per issue summarizing which
    placeholder categories fired (e.g., `adf_lossy_render: media=2 mention=1`). This is for
    operator diagnostics — it is NOT a WARN because lossy rendering is expected behavior, not a
    failure.
- `fields.priority.name` -> `priority` mapping. Jira's priority is a name, not a number. The adapter
  MUST map `Highest -> 1`, `High -> 2`, `Medium -> 3`, `Low -> 4`, `Lowest -> 5`, and unknown names
  to `null`, so the normalized `priority` integer ordering in Section 8.2 still works.
  - Custom priority schemes. Jira Cloud projects may configure non-default priority schemes (e.g.,
    `P0/P1/P2`, `Blocker/Critical/Major/Minor/Trivial`). Two behaviors are SPEC-conforming:
    - Default behavior (no operator action): unknown priority names normalize to `null`, and
      Section 8.2 dispatch ordering degenerates to oldest-creation-time for affected issues.
    - Operator opt-in: the operator MAY supply `tracker.jira.priority_map` in `WORKFLOW.md` — a map
      from priority name (case-sensitive, as it appears in Jira) to integer (lower is higher
      priority). The adapter resolves each issue's priority through this map; names absent from
      the map still normalize to `null`. Example:
      `{ "P0": 1, "P1": 2, "P2": 3, "P3": 4 }`.
- `fields.status.name` -> `state`
- (none) -> `branch_name` (always `null`; Jira has no native branch-name field)
- `<base_url>/browse/<key>` -> `url`
- `fields.labels` -> `labels` (lowercased)
- `fields.issuelinks` -> `blocked_by`. For each entry in `fields.issuelinks` where
  `type.name == "Blocks"`:
  - If the entry has `inwardIssue` set and `type.inward == "is blocked by"`, the issue identified
    by `inwardIssue.key` is treated as a `blocked_by` blocker of the current issue.
  - If the entry has `outwardIssue` set and `type.outward == "blocks"`, the current issue blocks
    `outwardIssue.key`; this direction is NOT recorded in `blocked_by`.
  The adapter MUST consult both `type.inward` and `type.outward` strings; do not infer direction
  from sub-field presence alone. Each blocker ref uses the linked issue's `id`, `key`, and
  `fields.status.name`.
- `fields.created` / `fields.updated` -> `created_at` / `updated_at`

Nullable fields: `branch_name` (always); `priority` (when the project uses a non-default priority
scheme without a configured `tracker.jira.priority_map`).

State transitions (`update_issue_state`):

- `GET /rest/api/3/issue/{key}/transitions` to enumerate transitions available from the issue's
  current state.
- Find the transition whose `to.name` matches the requested target state name (case-insensitive).
- If exactly one match: `POST /rest/api/3/issue/{key}/transitions` with `{"transition": {"id":
  "<id>"}}`. Return `ok`.
- If zero matches: return `{error, state_transition_not_available}`.
- If more than one match: return `{error, state_transition_ambiguous}`. Operators MUST NOT rely on
  the adapter guessing when a Jira project has duplicate transition target names.

State resolvability preflight (`validate_state_resolvability`):

- The Jira adapter implements `validate_state_resolvability()` by fetching
  `/rest/api/3/issue/createmeta?expand=projects.issuetypes.workflowscheme` (or equivalent
  introspection) for each project the configured JQL can resolve, then checking that every state
  name referenced in `WORKFLOW.md`'s transition mapping is reachable from at least one initial
  status. Unreachable names are returned as a list.
- This operation is read-only and is invoked by preflight (Section 6.3); it does not violate
  Principle VI.

Polling cadence:

- Jira Cloud enforces account-level rate limits that vary by license tier; a poll interval below
  30 seconds risks `429`s under load. The adapter requires `agent.poll_interval_ms ≥ 30000`
  unless `tracker.jira.allow_aggressive_polling: true` is set. Operators electing aggressive
  polling MUST own the rate-limit consequences; the orchestrator's existing backoff applies to
  `429` responses but does not protect the rate budget. Preflight (Section 6.3) rejects
  sub-30s intervals without the override with `jira_poll_interval_too_aggressive`.

Comments (`create_comment`):

- `POST /rest/api/3/issue/{key}/comment`.
- Caller passes a plain-text `body`. The adapter wraps it into Atlassian Document Format
  automatically:

  ```json
  {
    "body": {
      "type": "doc",
      "version": 1,
      "content": [
        {
          "type": "paragraph",
          "content": [{"type": "text", "text": "<body>"}]
        }
      ]
    }
  }
  ```

- The contract surface remains plain text; ADF is an adapter implementation detail.

PR links (`link_pr`, OPTIONAL):

- `POST /rest/api/3/issue/{key}/remotelink` with a body of the shape:

  ```json
  {
    "object": {
      "url": "<pr_url>",
      "title": "<title or pr_url>",
      "icon": {"url16x16": "https://github.githubassets.com/favicons/favicon.png"}
    }
  }
  ```

- This is Jira Cloud's portable analogue to Linear's native attachments. The contract surface is
  identical from the caller's perspective.

Description format extension (OPTIONAL):

- Adapters MAY offer raw ADF passthrough as an EXTENSION to the REQUIRED plain-text rendering above.
- If offered, it MUST be exposed under an adapter-specific extension key in `WORKFLOW.md`, namely
  `tracker.jira.description_format: "adf" | "text"`, with default `"text"`.
- Implementations MUST document that workflow templates relying on raw ADF (`"adf"`) are NOT
  portable across tracker kinds; the portable normalized contract is plain text.

Token requirements:

- The adapter authenticates with a classic Atlassian API token issued at
  `https://id.atlassian.com/manage-profile/security/api-tokens`, paired with the account email via
  HTTP Basic (see "Transport" above).
- The account MUST have **Browse Projects** permission on every project the configured JQL can
  resolve. Failure to do so will surface as `403 Forbidden` from Jira when the JQL touches a project
  the account cannot read.
- Authentication and authorization failures map as follows:
  - `401 Unauthorized` MUST be mapped to error category `tracker_unauthorized` (see Section 11.5).
    This is typically credential rot or a revoked token. Operator action: rotate the token.
  - `403 Forbidden` MUST be mapped to error category `tracker_forbidden` (see Section 11.5). This is
    typically a permission gap on a project the JQL touches. Operator action: grant Browse Projects
    on the affected project, or narrow `tracker.jira.jql` to projects the account can read.
  - Neither `401` nor `403` MUST be mapped to `missing_tracker_config`; that category is reserved
    for absent or malformed `WORKFLOW.md` configuration.

Webhooks:

- Out of scope for v1. Symphony polls. Adapters MUST NOT depend on webhook callbacks for state
  consistency. This is intentional and is not under reconsideration in this spec version.

Rate limits and operational notes:

- Jira Cloud enforces per-instance rate limits documented at
  `https://developer.atlassian.com/cloud/jira/platform/rate-limiting/`. Symphony does not impose a
  client-side rate limiter and treats `429` and `503 Retry-After` as transport-level errors subject
  to normal retry behavior. Implementations MAY honor `Retry-After` when present.

Worked example (candidate fetch; omit `nextPageToken` on the first request, include it on
subsequent requests once a token is known):

```http
GET /rest/api/3/search/jql?jql=project%20%3D%20ENG%20AND%20statusCategory%20!%3D%20Done&fields=summary,description,priority,status,labels,issuelinks,created,updated HTTP/1.1
Host: acme.atlassian.net
Authorization: Basic <base64(email:api_token)>
Accept: application/json
```

Worked example (state transition):

```http
GET  /rest/api/3/issue/ENG-123/transitions
POST /rest/api/3/issue/ENG-123/transitions
Content-Type: application/json

{"transition": {"id": "31"}}
```

### 11.5 Error Handling Contract

RECOMMENDED error categories at the adapter boundary:

Common:

- `unsupported_tracker_kind`
- `missing_tracker_config` (a REQUIRED adapter-specific config field is absent after `$` resolution)
- `tracker_config_conflict` (Section 5.3.1: flat and nested keys disagree on the same logical field)
- `tracker_unauthorized` (authentication failure at the tracker — typically credential rot or a
  revoked token; HTTP `401`-equivalent. Operator action: rotate credentials.)
- `tracker_forbidden` (authorization failure at the tracker — typically a permission gap on a
  resource the request touched; HTTP `403`-equivalent. Operator action: grant the necessary
  permission, or narrow the configured selection input.)
- `state_transition_not_available`
- `state_transition_ambiguous`
- `workflow_state_unresolvable` (raised by preflight, Section 6.3, when the adapter's
  `validate_state_resolvability()` operation returns one or more workflow-named states that the
  tracker cannot resolve to a reachable server-side state. The error message MUST name each
  unresolved state. Operator action: configure the tracker so each referenced state is reachable
  from at least one initial status, or correct the state name in `WORKFLOW.md`.)
- `jira_poll_interval_too_aggressive` (raised by preflight, Section 6.3, when
  `tracker.kind == jira`, `agent.poll_interval_ms < 30000`, and
  `tracker.jira.allow_aggressive_polling` is `false`. The error message MUST name the configured
  interval, the minimum (`30000` ms), and the override key. Operator action: raise
  `agent.poll_interval_ms` to at least `30000` ms, or set
  `tracker.jira.allow_aggressive_polling: true` and accept the rate-limit consequences.)
- `jql_order_by_not_allowed` (raised by preflight, Section 6.3, when `tracker.kind == jira` and
  `tracker.jira.jql` contains an `ORDER BY` clause (case-insensitive token scan). The error
  message MUST quote the offending JQL fragment and reference Section 8.2's canonical dispatch
  ordering. Operator action: remove the `ORDER BY` clause from `tracker.jira.jql`; Symphony's
  dispatch order is fixed.)

Both adapters MUST map authentication and authorization failures to `tracker_unauthorized` and
`tracker_forbidden` respectively. These categories MUST NOT be conflated with
`missing_tracker_config` (which is reserved for absent or malformed `WORKFLOW.md` configuration) or
with the adapter-specific `*_api_status` categories (which cover non-auth non-2xx statuses).

Linear-specific:

- `linear_api_request` (transport failure)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors` (top-level GraphQL `errors`)
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Jira-specific:

- `jira_api_request` (transport failure)
- `jira_api_status` (non-2xx HTTP)
- `jira_invalid_jql` (Jira returned `400` indicating JQL parse/eval failure)
- `jira_unknown_payload` (response did not match the expected shape)
- `jira_missing_next_page_token` (pagination integrity error)

Orchestrator behavior on tracker errors (unchanged regardless of adapter):

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.6 Tracker Writes (Important Boundary)

In a conforming Symphony implementation, the orchestrator MUST NOT invoke `create_comment`,
`update_issue_state`, or `link_pr` on any tracker adapter. These operations exist on the adapter
contract only so that adapters MAY expose them to the coding agent via client-side tools (for
example, `linear_graphql`, or an equivalent `jira_rest` tool). Any orchestrator-side mutation of
tracker state is a Principle VI violation.

- Ticket mutations (state transitions, comments, PR metadata) are handled by the coding agent using
  tools defined by the workflow prompt.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- The OPTIONAL adapter write operations in Section 11.1 (`create_comment`, `update_issue_state`,
  `link_pr`) exist so an implementation MAY expose them to the coding agent as client-side tools.
  Wiring them is not REQUIRED for conformance.
- If the `linear_graphql` client-side tool extension (Section 10.5) is implemented, it is still part
  of the agent toolchain rather than orchestrator business logic. An equivalent `jira_rest`
  client-side tool MAY be implemented for the Jira adapter under the same boundary.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count`
- `retrying` (list of retry queue rows)
- `codex_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events can include token counts in multiple payload shapes.
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `server.port` (integer, OPTIONAL)
  - Enables the HTTP server extension.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `server.port` when both are present.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `WORKFLOW.md` front matter.
- The `server` top-level key is owned by this extension.
- Positive `server.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "codex_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.
Restart recovery means the service can resume useful operation by polling tracker state and reusing
preserved workspaces. It does not mean retry timers, running sessions, or live worker state survive
process restart.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (prompt and most runtime settings).
- `WORKFLOW.md` changes are detected and re-applied automatically without restart according to
  Section 6.2.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Codex agents against repositories, issue trackers, and other inputs that can contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Codex approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Codex policy controls.
- Filtering which tracker issues, projects, teams, labels, or other tracker sources are eligible
  for dispatch (Linear `project_slug` + label filters; Jira `tracker.jira.jql`) so untrusted or
  out-of-scope tasks do not automatically reach the agent.
- Narrowing any tracker-passthrough client-side tool (for example `linear_graphql`) so it can only
  read or mutate data inside the intended project scope, rather than exposing general workspace-wide
  tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Workflow file changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when OPTIONAL values are missing
- `tracker.kind` validation accepts each supported kind (`linear`, `jira`) and rejects others
- Adapter-required fields for the selected `tracker.kind` are validated (Linear: `api_key`,
  `project_slug`; Jira: `base_url`, `email`, `api_token`, `jql`)
- Tracker credential fields work via `$VAR` indirection
- Backward-compatible flat `tracker.endpoint` / `tracker.api_key` / `tracker.project_slug` are
  accepted as synonyms for `tracker.linear.*` when `tracker.kind == "linear"`
- `$VAR` resolution works for tracker credentials and path values
- `~` path expansion works
- `codex.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

Cross-adapter:

- Empty `fetch_issues_by_states([])` returns empty without an API call
- Pagination preserves order across multiple pages
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues (`id`, `identifier`, `state`)
- Adapter selection by `tracker.kind` returns the correct adapter
- Normalized issue shape from each adapter matches Section 4.1.1 (fields absent on a given tracker
  are surfaced as `null` or empty lists, never as missing keys)

If the Linear adapter is implemented:

- Candidate issue fetch uses `tracker.active_states` and `tracker.linear.project_slug`
- Query uses the specified project filter field (`slugId`)
- Blockers are normalized from inverse relations of type `blocks`
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.3
- Error mapping for `linear_api_request`, `linear_api_status`, `linear_graphql_errors`,
  `linear_unknown_payload`, `linear_missing_end_cursor`
- `update_issue_state` resolves target state name to a team-scoped `WorkflowState` ID and returns
  `state_transition_not_available` for unknown state names

If the Jira Cloud adapter is implemented:

- Candidate issue fetch issues the configured `tracker.jira.jql` against `/rest/api/3/search/jql`
- Pagination follows `nextPageToken` until exhaustion
- Basic-auth header is constructed from `email` + `api_token` and is never logged
- Priority mapping (`Highest`..`Lowest` -> `1`..`5`, others -> `null`) is applied
- `branch_name` is always `null`
- Blockers are normalized from `fields.issuelinks` of type name `Blocks`, inward direction
- `update_issue_state` enumerates transitions, matches by `to.name` case-insensitively, and returns
  `state_transition_not_available` / `state_transition_ambiguous` when zero / multiple match
- `create_comment` wraps plain-text body in Atlassian Document Format before POSTing
- Error mapping for `jira_api_request`, `jira_api_status`, `jira_invalid_jql`,
  `jira_unknown_payload`, `jira_missing_next_page_token`

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <codex.command>`
- Session startup follows the targeted Codex app-server protocol.
- Client identity/capability payloads are valid when the targeted Codex app-server protocol requires
  them.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, diagnostic stderr handling is kept separate from the protocol stream
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs
  using the targeted app-server protocol
- If the `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI accepts a positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials for at least one supported adapter
  (Linear via `LINEAR_API_KEY` or a documented local bootstrap mechanism such as
  `~/.linear_api_key`; Jira Cloud via `JIRA_BASE_URL` + `JIRA_EMAIL` + `JIRA_API_TOKEN`).
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Issue tracker adapter(s) implementing the contract in Section 11.1 for at least one supported
  `tracker.kind` (Linear or Jira Cloud), with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Codex launch command config (`codex.command`, default `codex app-server`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the
  app-server session using configured Symphony auth.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI
  implementation details.
- TODO: Implement a `jira_rest` client-side tool extension (parallel to `linear_graphql` in Section
  10.5) so Jira adapter write operations can be exposed to the coding agent. Per Section 11.6, the
  orchestrator itself MUST NOT invoke tracker writes.
- TODO: Implement the Jira Cloud adapter against the contract in Section 11.4 in any reference
  implementation that currently ships only the Linear adapter.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
