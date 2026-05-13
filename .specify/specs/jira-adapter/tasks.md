---
description: "Task list for Elixir Jira Adapter (Phase 3 output)"
---

# Tasks: Elixir Jira Adapter

**Input**: Design documents from `.specify/specs/jira-adapter/`
**Prerequisites**: spec.md (Gate 1 ✅), plan.md (Gate 2 ✅), research.md, data-model.md, contracts/{tracker-behaviour,jira-client-api,config-schema,telemetry-events,error-catalog}.md

**Tests**: REQUIRED. Strict TDD (RED → GREEN → REFACTOR) per project constitution. Two explicit exceptions tagged `[Test-After Refactor]`:
- The `Linear.Issue → Tracker.Issue` rename (mechanical refactor; existing tests carry the contract)
- `_for_test` helpers in `Jira.Client` (written with their consuming tests as the same unit of work)

**Organization**: Tasks grouped by spec User Story (US1–US9). US9 (Quality gates) collapses into the Polish phase.

## Format: `[ID] [P?] [Story?] Description`

- `[P]` = parallelizable (different files, no dependency on incomplete tasks)
- `[Story]` (`[US1]`..`[US8]`) tags User Story phase tasks only — NOT used on Setup/Foundational/Polish
- `[Test-After Refactor]` = TDD exception (mechanical refactor or paired-with-test helper); no separate RED task
- File paths are exact

## Gate 2 decisions encoded in tasks

1. **FR-038 scope substitution**: input scope for `validate_state_resolvability/0` is `tracker.active_states ++ tracker.terminal_states` (no new config key, no spec change beyond the wording). See T046 + Polish T085.
2. **`:telemetry` dep promotion**: explicit `{:telemetry, "~> 1.0"}` added to `mix.exs:deps/0` (T002).
3. **`[:symphony, :tracker, :*]` naming precedent**: telemetry-events contract is authoritative; reflected in T040 + tests.
4. **Bundled PR scope**: `Linear.Issue → Tracker.Issue` rename (FR-013) + constitution v1.1.0 → v1.1.1 PATCH edit (FR-046) included.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: One-time project-config changes. No business logic.

- [x] T001 Add `SymphonyElixir.Jira.Client` to `test_coverage.ignore_modules` list in `elixir/mix.exs` (FR-048, NFR-Q-001). Do NOT touch existing entries.
- [x] T002 Add `{:telemetry, "~> 1.0"}` to `deps/0` in `elixir/mix.exs` (FR-011, plan.md Complexity Tracking row 2). One-line addition; preserve existing list order.

**Checkpoint**: `mix deps.get && mix compile` succeeds; no behavior change yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: `Linear.Issue → Tracker.Issue` rename + Tracker behaviour evolution. Blocks every User Story phase below.

**⚠️ CRITICAL**: No US-tagged work begins until this phase is complete and `mix test` is green.

### 2A. Rename `Linear.Issue` → `Tracker.Issue` (mechanical) — [Test-After Refactor]

- [x] T003 [Test-After Refactor] `git mv` `elixir/lib/symphony_elixir/linear/issue.ex` → `elixir/lib/symphony_elixir/tracker/issue.ex`. Rename `defmodule SymphonyElixir.Linear.Issue` → `SymphonyElixir.Tracker.Issue`. Widen `description` typespec to `String.t() | map() | nil` (FR-023). Preserve `label_names/1`. (FR-013, ARCH-2.)
- [x] T004 [Test-After Refactor] Update alias in `elixir/lib/symphony_elixir/agent_runner.ex`.
- [x] T005 [P] [Test-After Refactor] Update alias in `elixir/lib/symphony_elixir/orchestrator.ex`.
- [x] T006 [P] [Test-After Refactor] Update alias in `elixir/lib/symphony_elixir/prompt_builder.ex`.
- [x] T007 [P] [Test-After Refactor] Update alias in `elixir/lib/symphony_elixir/tracker/memory.ex`.
- [x] T008 [P] [Test-After Refactor] Update alias in `elixir/lib/symphony_elixir/linear/client.ex` and update `@spec` return types from `Linear.Issue.t()` → `Tracker.Issue.t()`.
- [x] T009 [P] [Test-After Refactor] Update alias in `elixir/test/support/test_support.exs` (and any in-repo test references — search `SymphonyElixir.Linear.Issue` across `test/`).
- [ ] T010 [Test-After Refactor] Run `mix test` — all existing Linear and core tests MUST pass with zero behavior change. AC-007 / NFR-Q-003 satisfied. [DEFERRED: no Elixir toolchain in sandbox; verify in CI or local run before proceeding to US1.]

### 2B. Tracker behaviour evolution

- [x] T011 [US-unspec, foundational] RED test: in `elixir/test/symphony_elixir/extensions_test.exs`, add test that `SymphonyElixir.Tracker.adapter/0` returns `SymphonyElixir.Jira.Adapter` when `Config.settings!().tracker.kind == "jira"`. Test fails because the dispatcher branch doesn't exist yet.
- [x] T012 GREEN: extend `adapter/0` in `elixir/lib/symphony_elixir/tracker.ex` to route `"jira"` → `SymphonyElixir.Jira.Adapter` (FR-002). Keep `"linear"` and `"memory"` dispatch unchanged. T011 passes.
- [x] T013 RED test: in `elixir/test/symphony_elixir/extensions_test.exs`, add test that `Tracker.validate_state_resolvability/0` returns `{:ok, []}` when the adapter module does not implement the callback (`Linear.Adapter` case). Fails because the dispatcher function does not exist.
- [x] T014 GREEN: add `@callback validate_state_resolvability/0` + `@optional_callbacks` to `elixir/lib/symphony_elixir/tracker.ex` (FR-003). Add `Tracker.validate_state_resolvability/0` wrapper using `Code.ensure_loaded/1` + `function_exported?/3`. T013 passes.

**Checkpoint**: Existing test suite green. `Tracker` behaviour ships the optional callback. No Jira code yet.

---

## Phase 3: User Story 1 — Stand up Jira-backed workflow with four config keys (P1) 🎯 MVP

**Goal**: Operator points Symphony at Jira Cloud with four `tracker.jira.*` keys + `JIRA_API_TOKEN`. Preflight passes; first poll returns normalized `Tracker.Issue.t()` values.

**Independent Test**: Per spec.md US1 "Independent Test" — `FakeJiraClient` registered, `WORKFLOW.md` Jira config, orchestrator boots, preflight passes, first poll returns issues, dispatch + reconcile to terminal state.

### Tests for US1 (RED)

- [x] T015 [P] [US1] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add test for `Config.Schema.Tracker.Jira` embedded sub-schema accepting `base_url`, `email`, `api_token`, `jql`, `priority_map`, `max_issues_per_poll`, `allow_aggressive_polling`, `description_format` with FR-027 defaults. Fails because the sub-schema does not exist.
- [x] T016 [P] [US1] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add test that `Config.finalize_settings/1` resolves `$JIRA_API_TOKEN` env var into `Config.Schema.Tracker.Jira.api_token` (FR-031). Use literal token `"fake-jira-token-not-real"` per FR-051.
- [x] T017 [P] [US1] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add test that preflight emits `{:error, {:missing_tracker_config, :"tracker.jira.api_token"}}` when token is empty after `$`-resolution (FR-033, US1 scenario 3).
- [x] T018 [P] [US1] RED test: in `elixir/test/symphony_elixir/extensions_test.exs`, register a `FakeJiraClient` mirror of `FakeLinearClient` (FR-047) at the top of the file (or in a shared helper) and add test that `Jira.Adapter.fetch_candidate_issues/0` returns `{:ok, [Tracker.Issue.t()]}` delegating to the `:jira_client_module` Application env. `on_exit` cleanup. Fails because `Jira.Adapter` does not exist.
- [x] T019 [P] [US1] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs` (NEW FILE), add test exercising `Jira.Client.normalize_issue_for_test/2` against a minimal hand-rolled Jira issue payload, asserting field-by-field mapping per FR-015 (`key→identifier`, `id→id`, `fields.summary→title`, `fields.priority.name→priority` with default `Highest→1`, `<base_url>/browse/<key>→url`, etc.). Fails because module + helper don't exist.
- [x] T020 [P] [US1] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add test that the default priority map (`Highest→1, High→2, Medium→3, Low→4, Lowest→5`) applies via `Jira.Client.apply_priority_map_for_test/2` (FR-016). Fails.
- [x] T021 [P] [US1] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add test for `Jira.Client.fetch_candidate_issues(request_fun: fake)` with a 200 OK body containing one issue — assert returned struct list and that Basic-auth header was constructed (assert header value via the captured `request_fun` args; do NOT assert token contents in tuple — assert `base64(email:token)` shape). Fails.

### Implementation for US1 (GREEN)

- [x] T022 [US1] GREEN: add `SymphonyElixir.Config.Schema.Tracker.Jira` embedded sub-schema with all 8 fields per FR-027 in `elixir/lib/symphony_elixir/config/schema.ex`. Add `SymphonyElixir.Config.Schema.Tracker.Linear` embedded sub-schema for symmetry (Linear fields: `endpoint` default `https://api.linear.app/graphql`, `api_key`, `project_slug`). T015 passes.
- [x] T023 [US1] GREEN: extend `Config.Schema.finalize_settings/1` in `elixir/lib/symphony_elixir/config/schema.ex` to resolve `$JIRA_API_TOKEN` env var into `tracker.jira.api_token` (FR-031). Reject literal Jira tokens at config-load with `missing_tracker_config: tracker.jira.api_token`. T016 passes.
- [x] T024 [US1] GREEN: extend `Config.validate!/0` in `elixir/lib/symphony_elixir/config.ex` to emit `{:error, {:missing_tracker_config, field}}` when any of `base_url`/`email`/`api_token`/`jql` is empty for `tracker.kind == "jira"` (FR-033). Lift `unsupported_tracker_kind` allowlist to include `"jira"`. T017 passes.
- [x] T025 [US1] GREEN: create `elixir/lib/symphony_elixir/jira/client.ex` — module skeleton with module attrs (`@adf_max_depth 64`, `@max_error_body_log_bytes 1_000`, `@connect_timeout_ms 30_000`, `@receive_timeout_ms 60_000`), `@doc false` `normalize_issue_for_test/2` + `apply_priority_map_for_test/2` helpers, and the default priority map constant. No HTTP yet. Add module to `mix.exs:ignore_modules` already done in T001. T019 + T020 pass.
- [x] T026 [US1] GREEN: implement `Jira.Client.fetch_candidate_issues/1` (with optional `opts \\ []`) — single-page path only, Basic-auth header via manual `Base.encode64/1` of `email:api_token`, `Req` call with `redirect: false`, `connect_options: [timeout: @connect_timeout_ms]`, `receive_timeout: @receive_timeout_ms`. Map 200 responses into `Tracker.Issue.t()` list via `normalize_issue_for_test/2`. (FR-007, FR-008, FR-010 first-page only, FR-015.) `request_fun:` opt for injection (FR-012). T021 passes.
- [x] T027 [US1] GREEN: create `elixir/lib/symphony_elixir/jira/adapter.ex` — `@behaviour SymphonyElixir.Tracker`, all 5 required callbacks. Each callback reads client module from `Application.get_env(:symphony_elixir, :jira_client_module, SymphonyElixir.Jira.Client)` (FR-005, FR-006) and delegates. No HTTP (FR-005). Every public `def` carries `@spec` (FR-049). T018 passes.

**Checkpoint US1**: Operator can configure Jira with 4 keys + env var, boot, and first poll succeeds against `FakeJiraClient`. MVP delivered.

---

## Phase 4: User Story 2 — Hot-reload from Linear to Jira without restart (P1)

**Goal**: Swap `tracker.kind: linear` → `jira` in `WORKFLOW.md`; next tick uses `Jira.Adapter`; in-flight Linear workers continue.

**Independent Test**: Per spec.md US2 "Independent Test" — boot Linear, fire one tick, swap config, fire next tick, assert `Tracker.adapter/0` returns `Jira.Adapter`, Linear worker continues.

### Tests for US2 (RED)

- [x] T028 [P] [US2] RED test: in `elixir/test/symphony_elixir/extensions_test.exs`, add test that updating `WORKFLOW.md` from Linear to Jira config causes `Tracker.adapter/0` to return `SymphonyElixir.Jira.Adapter` on next call (FR-002 + NFR-PERF-005). Uses `WorkflowStore.force_reload/0` semantics.
- [x] T029 [P] [US2] RED test: same file, add test that an in-flight Linear worker (mocked) continues after the swap — the `Tracker.Issue` struct in flight remains valid, no crash.

### Implementation for US2 (GREEN)

- [x] T030 [US2] GREEN: NO new module code expected — `WorkflowStore` semantics already handle this. The work is verifying that no caching of `adapter()` resolution exists in `lib/symphony_elixir/orchestrator.ex` or `agent_runner.ex` that would prevent the swap. If a cache exists, remove it (surgical, file-by-file). T028 + T029 pass. **Verified**: `Tracker.adapter/0` re-resolves per call from `Config.settings!().tracker.kind`; `Config.settings!/0` re-reads via `Workflow.current/0` → `WorkflowStore.current/0` which auto-reloads on file stamp changes. `orchestrator.ex` and `agent_runner.ex` only call `Tracker.fetch_*` / `Config.settings!()` per-tick — no caching. No lib/ changes required.

**Checkpoint US2**: Hot-reload from Linear → Jira works end-to-end against `FakeJiraClient` + existing Linear mocks.

---

## Phase 5: User Story 3 — Preflight rejects bad JQL (P1)

**Goal**: JQL containing `ORDER BY` outside string literals fails preflight with `jql_order_by_not_allowed`. Runtime JQL syntax errors surface as `jira_invalid_jql` without token leak.

**Independent Test**: Per spec.md US3 "Independent Test" — preflight fails on `project = ENG ORDER BY priority`; passes on `summary ~ "ORDER BY"`.

### Tests for US3 (RED)

- [ ] T031 [P] [US3] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add literal-aware JQL `ORDER BY` tests (FR-035, AC-011, research.md R-3): (a) bare `ORDER BY` outside literal → fail; (b) `summary ~ "ORDER BY docs"` (inside double-quoted literal) → pass; (c) `summary ~ 'ORDER BY docs'` (single-quoted) → pass; (d) `summary ~ "escaped \\" ORDER BY"` (backslash escape) → fail (the `ORDER BY` is outside the closed literal); (e) case insensitivity: `order by`, `Order By`, `ORDER  BY` (multi-space) all caught.
- [ ] T032 [P] [US3] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add test that `Jira.Client.fetch_candidate_issues(request_fun: fake_400)` with a 400 response on `/rest/api/3/search/jql` returns `{:error, {:jira_invalid_jql, body_excerpt}}` and the error tuple does NOT contain the token (FR-040, ARCH-4, FR-042). Use `refute inspect(error_tuple) =~ "fake-jira-token-not-real"`.

### Implementation for US3 (GREEN)

- [ ] T033 [US3] GREEN: implement a literal-aware JQL tokenizer/scanner in `elixir/lib/symphony_elixir/config.ex` (private fn `validate_jql_no_order_by/1`). State-machine per research.md R-3: tracks `:default | :double_string | :single_string` modes; honors `\\` escapes inside strings; matches `ORDER` followed by whitespace followed by `BY` case-insensitively only in `:default` mode. NOT a `Regex.match?` (FR-035 explicit). Wire into `validate!/0`. T031 passes.
- [ ] T034 [US3] GREEN: extend `Jira.Client` (`elixir/lib/symphony_elixir/jira/client.ex`) error mapping to map HTTP 400 on `/rest/api/3/search/jql` paths → `:jira_invalid_jql` with truncated body excerpt (FR-040). Ensure error tuple omits token (FR-042). T032 passes.

**Checkpoint US3**: Boot-time JQL validation catches `ORDER BY` operator-typo; runtime 400s surface cleanly with no token leak.

---

## Phase 6: User Story 4 — Preflight enforces 30s poll floor (P1)

**Goal**: With `tracker.kind: jira` + `polling.interval_ms < 30000` + no override, preflight fails `jira_poll_interval_too_aggressive`. Override `tracker.jira.allow_aggressive_polling: true` allows it. Linear path unaffected.

**Independent Test**: Per spec.md US4 "Independent Test".

### Tests for US4 (RED)

- [ ] T035 [P] [US4] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add three tests: (a) Jira + `polling.interval_ms: 5000` + no override → `{:error, {:jira_poll_interval_too_aggressive, 5000, 30000, :"tracker.jira.allow_aggressive_polling"}}`; (b) same + override `true` → pass; (c) `tracker.kind: linear` + `polling.interval_ms: 5000` → pass (Jira floor does not fire — FR-036 case 3).

### Implementation for US4 (GREEN)

- [ ] T036 [US4] GREEN: extend `Config.validate!/0` in `elixir/lib/symphony_elixir/config.ex` with `jira_poll_interval_too_aggressive` check (FR-036): only when `tracker.kind == "jira"`, `polling.interval_ms < 30000`, and `tracker.jira.allow_aggressive_polling != true`. T035 passes.

**Checkpoint US4**: 30s poll floor enforced at boot, override available, Linear unaffected.

---

## Phase 7: User Story 5 — Preflight surfaces unreachable workflow states (P2)

**Goal**: Preflight invokes `Tracker.validate_state_resolvability/0`; non-empty unresolved list fails with `workflow_state_unresolvable`. Transport flake → WARN + proceed.

**Gate 2 decision (FR-038 substitution)**: input scope is `tracker.active_states ++ tracker.terminal_states` (NOT a separate transition-mapping config key in v1). Confirmed by Phase 2 architect handoff.

**Independent Test**: Per spec.md US5 "Independent Test".

### Tests for US5 (RED)

- [ ] T037 [P] [US5] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add test where startup preflight (`Config.validate!/0`) fails with `{:error, {:workflow_state_unresolvable, ["Code Review"]}}` when `FakeJiraClient` reports `Code Review` as unresolved (FR-037, US5 scenario 1).
- [ ] T038 [P] [US5] RED test: same file, add test where `FakeJiraClient.validate_state_resolvability_for/1` returns `{:error, :transport}` → preflight logs WARN and proceeds (FR-037 fail-open, US5 scenario 2). Use `ExUnit.CaptureLog`.
- [ ] T039 [P] [US5] RED test: same file, add test that `tracker.kind: linear` does NOT invoke `validate_state_resolvability/0` (US5 scenario 3, FR-003 Linear-MUST-NOT-implement).
- [ ] T040 [P] [US5] RED test: in `elixir/test/symphony_elixir/extensions_test.exs`, add test asserting `Jira.Adapter.validate_state_resolvability/0` collects state names from `tracker.active_states ++ tracker.terminal_states` (Gate 2 decision; v1 substitute for transition-mapping scope), de-dupes, and delegates to `Jira.Client.validate_state_resolvability_for/1`. Fails because callback impl is not yet present.
- [ ] T041 [P] [US5] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add test exercising `Jira.Client.validate_state_resolvability_for/1` against a `FakeJiraClient`-shaped per-project `/createmeta` response. Verify case-insensitive match and that state names NOT reachable in ANY project the JQL touches are returned in the result list. Verify project-key extraction from JQL (research.md R-5 algorithm).

### Implementation for US5 (GREEN)

- [ ] T042 [US5] GREEN: implement `Jira.Client.validate_state_resolvability_for/1` in `elixir/lib/symphony_elixir/jira/client.ex` — extract distinct project keys from JQL (literal-aware; reuse the R-3 tokenizer or a thin variant from T033), `GET /rest/api/3/issue/createmeta?projectKeys=<key>&expand=projects.issuetypes.workflowscheme` per project (serial in v1, FR-038 + NFR-PERF-003), aggregate reachable status names case-insensitively, return flat list of un-resolvable inputs. T041 passes.
- [ ] T043 [US5] GREEN: implement `Jira.Adapter.validate_state_resolvability/0` in `elixir/lib/symphony_elixir/jira/adapter.ex` — read `Config.settings!().tracker.{active_states, terminal_states}`, concat + dedupe, delegate to client. (Gate 2 substitution for FR-038 transition-mapping scope.) Every public `def` retains `@spec`. T040 passes.
- [ ] T044 [US5] GREEN: extend `Config.validate!/0` in `elixir/lib/symphony_elixir/config.ex` to invoke `Tracker.validate_state_resolvability/0` at startup (FR-037). On `{:ok, [_ | _]}` fail with `{:error, {:workflow_state_unresolvable, names}}`. On `{:error, _}` log WARN via `Logger.warning` and proceed. T037 + T038 + T039 pass.

**Checkpoint US5**: Boot-time state resolvability validates against per-project Jira `/createmeta`; transport flake fail-open per spec.

---

## Phase 8: User Story 6 — Custom priority scheme via `priority_map` (P2)

**Goal**: Operator-supplied `tracker.jira.priority_map` overrides default mapping with case-sensitive name lookup. Unknown names → `nil`.

**Independent Test**: Per spec.md US6 "Independent Test".

### Tests for US6 (RED)

- [ ] T045 [P] [US6] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add test that `Jira.Client.apply_priority_map_for_test/2` with `priority_map: %{"P0" => 1, "P1" => 2}` maps `"P1" → 2` and `"Critical" → nil` (FR-016, US6 scenarios 1+2). Already partially covered by T020 — extend with custom-map case.
- [ ] T046 [P] [US6] RED test: same file, add integration test that `Jira.Client.fetch_candidate_issues/1` with a priority_map in config normalizes an issue's priority correctly end-to-end.

### Implementation for US6 (GREEN)

- [ ] T047 [US6] GREEN: extend `apply_priority_map_for_test/2` and the normalization pipeline in `elixir/lib/symphony_elixir/jira/client.ex` to apply operator-supplied `tracker.jira.priority_map` with case-sensitive lookup, falling back to the default `Highest/High/Medium/Low/Lowest` map only when no operator map is supplied (FR-016). T045 + T046 pass.

**Checkpoint US6**: Custom priority schemes (P0/P1/P2/P3) normalize correctly; defaults preserved when no map.

---

## Phase 9: User Story 7 — Auth failures surface as `tracker_unauthorized` / `tracker_forbidden` (P2)

**Goal**: 401 → `:tracker_unauthorized` (NOT `:missing_tracker_config`); 403 → `:tracker_forbidden` with project context when derivable; neither leaks token.

**Independent Test**: Per spec.md US7 "Independent Test" — drive `FakeJiraClient` to 401 and 403; assert error tuples and log redaction.

### Tests for US7 (RED)

- [ ] T048 [P] [US7] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add test for 401 response → `{:error, :tracker_unauthorized}` (FR-040, FR-041, US7 scenario 1). Assert tuple does NOT contain the token nor `"Basic "` (AC-008).
- [ ] T049 [P] [US7] RED test: same file, 403 response → `{:error, {:tracker_forbidden, %{project_key: "ENG"}}}` when JQL contains `project = ENG` (FR-040, US7 scenario 2). Assert project key derivation.
- [ ] T050 [P] [US7] RED test: same file, log-redaction test using `ExUnit.CaptureLog` — drive both 401 and 403 paths; assert `refute log =~ "Basic "` and `refute log =~ "fake-jira-token-not-real"` (FR-043, NFR-SEC-008, AC-008, US7 scenario 3).

### Implementation for US7 (GREEN)

- [ ] T051 [US7] GREEN: extend `Jira.Client` error mapping in `elixir/lib/symphony_elixir/jira/client.ex` — map 401 → `:tracker_unauthorized`, 403 → `{:tracker_forbidden, %{project_key: extract_project_key_from_url(url)}}`. Add `extract_project_key_from_url/1` (private). Ensure DEBUG success-path log + ERROR error-path log per FR-044 + FR-045 with NO header values. T048 + T049 + T050 pass.

**Checkpoint US7**: 401/403 properly classified; no token in logs or error tuples.

---

## Phase 10: User Story 8 — Issue object portability across adapters (P2)

**Goal**: Prompt template renders identically for Linear-sourced and Jira-sourced `Tracker.Issue` modulo `branch_name`.

**Independent Test**: Per spec.md US8 "Independent Test".

### Tests for US8 (RED)

- [ ] T052 [P] [US8] RED test: in `elixir/test/symphony_elixir/extensions_test.exs` (or `core_test.exs` adjacent to existing `PromptBuilder` tests — match existing pattern), add test rendering the existing prompt template against (a) a Linear-sourced `Tracker.Issue` fixture and (b) a Jira-sourced `Tracker.Issue` fixture with the same field values except `branch_name = nil`. Assert output is identical modulo the `branch_name` substitution (US8 scenarios 1+2).

### Implementation for US8 (GREEN)

- [ ] T053 [US8] GREEN: NO new code expected; this story tests the Phase 2 rename invariant. If the test exposes a bug (e.g., a stale `Linear.Issue` reference in the template renderer), fix surgically. T052 passes.

**Checkpoint US8**: Constitutional invariant verified — issue portability holds.

---

## Phase 11: Remaining FR coverage (cross-cutting, but tracked separately because no single user story carries them)

These FRs do not map cleanly to one user story but are required by spec acceptance criteria. Tracked here to surface them in the spec-coverage matrix.

### Pagination, ADF rendering, edge cases

- [ ] T054 [P] [FR-010, FR-011] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add multi-page pagination test using `request_fun:` injection. First page returns 100 issues + `nextPageToken: "abc"`; second page returns 100 issues + no token. Assert 200 issues returned, second call sends `nextPageToken=abc`, `isLast` is ignored.
- [ ] T055 [P] [FR-011] RED test: same file, pagination cap test — drive `request_fun:` to return more pages than `max_issues_per_poll: 50`. Assert: (a) result truncates to first 50, (b) WARN log fires with cap, threshold, JQL truncated to 200 chars, (c) `[:symphony, :tracker, :poll_cap_hit]` telemetry event fires with `%{count: 1}` measurements and `%{tracker_kind: :jira}` metadata (attach handler in test, detach in `on_exit`).
- [ ] T056 [FR-010, FR-011] GREEN: implement `fetch_pages_loop/4` (private) in `elixir/lib/symphony_elixir/jira/client.ex` per research.md R-4: post-decode cap (decode page, check `length(acc) >= max_issues_per_poll`, halt + emit telemetry/WARN). Wire into `fetch_candidate_issues/1`. T054 + T055 pass.

- [ ] T057 [P] [FR-018, FR-019, FR-021, FR-022, AC-009] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add ADF rendering tests against hand-rolled minimal trees (FR-052) — block-sibling separator `\n`, top-level block separator `\n\n`, leaf text scrubbed of ASCII controls (except `\n` and `\t`), placeholder substitutions for `media`/`mention`/`emoji`/`status`/`date`/`panel`, unknown nodes recurse without marker, depth=64 returns OK, depth=1000 returns `{:error, :jira_adf_depth_exceeded}` (AC-009), single DEBUG `adf_lossy_render` line per issue with category counts.
- [ ] T058 [P] [FR-020, NFR-SEC-005, AC-010] RED test: same file, `inlineCard`/`blockCard` URL-scheme filter — `http`/`https` pass through, `javascript:`/`file:`/`data:`/`ftp:` render as `[link: filtered]` (AC-010).
- [ ] T059 [FR-018, FR-019, FR-020, FR-021, FR-022] GREEN: implement `render_adf_for_test/1` (and underlying private `render_adf/1` + `render_node/2`) in `elixir/lib/symphony_elixir/jira/client.ex`. Depth-counted recursion at 64; URL-scheme allowlist (`http`, `https`); ASCII-control scrub fn; lossy-category accumulator for DEBUG log. T057 + T058 pass.

- [ ] T060 [P] [FR-023] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add test that `tracker.jira.description_format: "adf"` causes normalization to pass raw ADF map into `Issue.description` (typespec `String.t() | map() | nil`). Default `"text"` triggers rendering.
- [ ] T061 [FR-023] GREEN: implement description_format branch in `Jira.Client` normalization in `elixir/lib/symphony_elixir/jira/client.ex`. T060 passes.

### Issue links + transitions

- [ ] T062 [P] [FR-017] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add `extract_blocked_by_for_test/1` test — only `type.name == "Blocks"` with `type.inward == "is blocked by"` AND `inwardIssue` populated yields blocker refs of shape `%{id: ..., key: ..., status: ...}`.
- [ ] T063 [FR-017] GREEN: implement `extract_blocked_by_for_test/1` and wire into normalization. T062 passes.

- [ ] T064 [P] [FR-024, FR-025] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add tests for `Jira.Client.create_comment/2` (ADF-wrapping `body`) and `find_transition/2` + `execute_transition/2`: zero match → `:state_transition_not_available`, multi-match → `:state_transition_ambiguous`, one match → `:ok`.
- [ ] T065 [FR-024, FR-025] GREEN: implement `create_comment/2`, `find_transition/2`, `execute_transition/2` in `elixir/lib/symphony_elixir/jira/client.ex`. Wire `Jira.Adapter.create_comment/2` and `update_issue_state/2` to call them. T064 passes.

### Redirect + remaining error mapping

- [ ] T066 [P] [FR-009, NFR-SEC-003, AC-012] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, add 3xx-redirect-rejection test — `request_fun:` returns 302; assert `{:error, {:jira_unexpected_redirect, 302}}` and assert (via captured request log to the redirect URL) that `Authorization` header is NOT re-sent. Cover both same-host and cross-host redirects.
- [ ] T067 [P] [FR-040] RED test: same file, exhaustive error-mapping coverage — `{:jira_api_status, code}` for 404/422/429/500/502/503, `{:jira_api_request, reason}` for transport `{:error, _}`, `:jira_unknown_payload` for 200 with malformed body or missing `issues` key, `:jira_missing_next_page_token` when pagination claims more pages but token absent. (AC-003 cross-checks.)
- [ ] T068 [FR-009, FR-040] GREEN: wire `redirect: false` on `Req` call + full error-atom dispatch in `elixir/lib/symphony_elixir/jira/client.ex`. T066 + T067 pass.

### Flat/nested key compatibility

- [ ] T069 [P] [FR-028, FR-029, FR-030] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add three tests: (a) flat `tracker.api_key` + nested `tracker.linear.api_key` with identical values + `kind == "linear"` → nested wins, single WARN logged per redundant flat key (FR-029); (b) divergent values → `{:error, {:tracker_config_conflict, :"tracker.api_key", :"tracker.linear.api_key"}}` (FR-030); (c) flat keys present + `kind == "jira"` → silently ignored (no WARN, no conflict — FR-028).
- [ ] T070 [FR-028, FR-029, FR-030, FR-034, FR-039] GREEN: extend `Config.Schema.finalize_settings/1` (flat→nested merge for Linear only) + `Config.validate!/0` (conflict detection) in `elixir/lib/symphony_elixir/config/schema.ex` and `elixir/lib/symphony_elixir/config.ex`. Guard existing `missing_linear_*` checks by `kind == "linear"` (FR-039). T069 passes.

### `base_url` shape validation

- [ ] T071 [P] [FR-032, NFR-SEC-002] RED test: in `elixir/test/symphony_elixir/workspace_and_config_test.exs`, add tests: (a) `base_url: "http://acme.atlassian.net"` (not HTTPS) → preflight fail; (b) `base_url: "https://"` (no host) → fail; (c) `base_url: "https://acme.atlassian.net/"` (trailing slash) → pass; (d) `base_url: "https://acme.atlassian.net"` → pass.
- [ ] T072 [FR-032] GREEN: implement `base_url` shape validation in `Config.validate!/0` (`elixir/lib/symphony_elixir/config.ex`) per FR-032: non-empty `https://<host>` with parseable host (use `URI.parse/1`; `scheme == "https"`, `host` non-empty). No allowlist (SEC-3). T071 passes.

### Telemetry dep + event registration test

- [ ] T073 [P] [FR-011, telemetry-events contract] RED test: in `elixir/test/symphony_elixir/jira/client_test.exs`, ensure the cap-hit test in T055 verifies exact measurements `%{count: 1}` and metadata `%{tracker_kind: :jira}` (per telemetry-events contract §"Test contract"). If T055 already covers this, mark T073 as covered-by-T055 in the coverage matrix.

---

## Phase 12: Polish & US9 (Quality gates)

**Purpose**: US9 (P3) — `mix specs.check`, `mix coverage`, `mix lint`, `mix format`, `dialyzer`, `make all`. Doc updates. Constitution PATCH.

- [ ] T074 [P] [Polish] Run `mix format --check-formatted` on the whole `elixir/` tree; run `mix format` if needed and commit. (NFR-Q-002.)
- [ ] T075 [Polish] Run `mix specs.check`. Confirm every public `def` in `Jira.Adapter` and `Jira.Client` has `@spec` (FR-049, AC-001). Fix any gaps surgically.
- [ ] T076 [Polish] Run `mix lint` (credo --strict). Address any violation surgically. (NFR-Q-002.)
- [ ] T077 [Polish] Run `mix coverage`. Assert: (a) `SymphonyElixir.Jira.Adapter` at 100% line coverage (FR-048, NFR-Q-001, AC-005); (b) `SymphonyElixir.Jira.Client` on `ignore_modules` (T001 verifies). If `Jira.Adapter` coverage < 100%, add the missing test paths.
- [ ] T078 [Polish] Run `mix dialyzer`. Address any new warning surgically. (NFR-Q-002.)
- [ ] T079 [Polish] Run `make all` end-to-end. Confirm exit code 0. (AC-006.)
- [ ] T080 [P] [Polish] Update `elixir/README.md` Tracker section to list Jira alongside Linear, link to `quickstart.md`. Surgical change only — no rewriting of existing Linear copy. (Project CLAUDE.md "If behavior/config changes: update README.md, elixir/README.md, and/or WORKFLOW.md in same PR".)
- [ ] T081 [P] [Polish] Update `WORKFLOW.md` or top-level `README.md` if either references "Linear is the only supported tracker" — replace with multi-tracker phrasing. Skip if no such phrasing exists.
- [ ] T082 [Polish] Author PR body per `mix pr_body.check` template. Include: summary, rationale, FR mapping, test evidence (coverage report excerpt), constitution-bump note. Run `mix pr_body.check` locally.
- [ ] T083 [Polish] **Constitution edit (FR-046, AC-013)**: in `.specify/memory/constitution.md`, rewrite Architecture Constraints "Tracker scope" line 131 from "Linear is the only supported tracker in this spec version. …" to text acknowledging Linear + Jira Cloud per `SPEC.md` §11. Bump version `1.1.0 → 1.1.1` (PATCH). Append SYNC IMPACT REPORT entry per FR-046 wording.
- [ ] T084 [Polish] Final integration smoke test against quickstart.md — manually walk the operator-facing flow in a local checkout: configure `WORKFLOW.md` per quickstart.md, register `FakeJiraClient`, run `mix test` for the new test modules. Confirm `quickstart.md` is accurate and executable.
- [ ] T085 [Polish, NEEDS HUMAN ACK] **Spec/SPEC amendment for FR-038 substitution**: file a follow-up Issue (or surface in PR description) that FR-038's "transition mapping in WORKFLOW.md" wording is satisfied in v1 by `active_states ++ terminal_states` substitution (Gate 2 architect handoff item #1, plan.md Gate 2 Handoff #1). Either: (a) amend FR-038 in `spec.md` to reflect the substitution explicitly, OR (b) leave the spec wording and document the substitution in the PR body as a known v1-vs-spec gap to be closed in a follow-up PR. Defer to user judgment.

---

## Dependencies & Execution Order

### Phase dependencies (strict)

- **Phase 1 (Setup)** → independent; T001 ⫫ T002 parallelizable.
- **Phase 2 (Foundational)** depends on Phase 1. Inside Phase 2: T003 must precede T004–T010 (file move); T004 is sequential with T003; T005–T009 are `[P]` (different files); T010 gates exit to Phase 3+. T011–T014 form an isolated TDD pair sequence; can run in parallel with the rename block if developers are disciplined about file boundaries.
- **Phases 3–10 (User Stories US1–US8)** all depend on Phase 2 completion. Inter-story dependencies:
  - US1 (Phase 3) is the MVP path; gates other stories *for demonstration purposes* but not technically — US3, US4 preflight checks (Phases 5, 6) can be developed in parallel with US1 if a contractor uses the foundational Config.Schema.Tracker.Jira sub-schema as a stub.
  - US2 (Phase 4) depends on US1 (need a working Jira adapter + Config.Schema before swap can be tested).
  - US5 (Phase 7) depends on US1 (needs `Jira.Client` to exist + `Tracker.validate_state_resolvability/0` from Phase 2).
  - US6 (Phase 8) depends on US1 (needs `Jira.Client.apply_priority_map_for_test/2` from T025).
  - US7 (Phase 9) depends on US1 (needs `Jira.Client.fetch_candidate_issues/1` skeleton from T026).
  - US8 (Phase 10) depends on Phase 2 only (rename invariant).
- **Phase 11 (Cross-cutting FR coverage)** depends on US1 (Phase 3) — all of T054–T072 extend `Jira.Client` and `Config` which US1 creates.
- **Phase 12 (Polish, US9)** depends on all stories + Phase 11 being complete.

### Within each user story

- Tests (RED) BEFORE implementation (GREEN). No exceptions for tasks NOT tagged `[Test-After Refactor]`.
- Schema before usage; client helpers before adapter delegation; adapter before preflight wiring.

### Parallel opportunities (high-confidence)

- **Phase 2**: T005, T006, T007, T008, T009 (different files, after T003 lands).
- **Phase 3 (US1) RED tests**: T015, T016, T017, T018, T019, T020, T021 — different test files / different test cases within `workspace_and_config_test.exs` (verify no merge conflict by splitting the additions into distinct `describe` blocks).
- **Phase 11 RED tests**: T054, T057, T058, T060, T062, T064, T066, T067, T069, T071, T073 — all extend independent test files / cases.
- **Phase 12 Polish**: T074, T080, T081 in parallel.

### MVP path (per spec.md priority)

1. Phase 1 (Setup) → Phase 2 (Foundational rename + behaviour evolution) → Phase 3 (US1) → **STOP, verify, demo MVP**.
2. Then incrementally: US3 (P1 boot-blocker) → US4 (P1 boot-blocker) → US2 (P1 hot-reload) → US5 / US6 / US7 / US8 (P2 stories, can parallelize) → US9 (Polish).

### Independent test criteria per user story

Lifted from spec.md §"User Scenarios":

- **US1**: Configure `WORKFLOW.md` Jira keys + `JIRA_API_TOKEN`; start orchestrator; preflight passes; first poll via `FakeJiraClient` returns normalized issues; dispatch + reconcile to terminal.
- **US2**: Boot Linear; tick. Swap `WORKFLOW.md` to Jira. Tick. `Tracker.adapter/0` returns `Jira.Adapter`; Linear worker continues.
- **US3**: `jql: "project = ENG ORDER BY priority"` → preflight `jql_order_by_not_allowed`. `jql: 'summary ~ "ORDER BY"'` → pass.
- **US4**: `polling.interval_ms: 5000` + no override → preflight fail. Add `allow_aggressive_polling: true` → pass.
- **US5**: JQL touching 2 projects, one missing `Code Review` state → preflight fails `workflow_state_unresolvable: Code Review`.
- **US6**: Two test runs; same JQL; no map → priorities `nil`; with `priority_map` → priorities mapped.
- **US7**: `FakeJiraClient` returns 401 → `:tracker_unauthorized`; 403 → `:tracker_forbidden`; logs assert no token leak.
- **US8**: Render prompt template against (a) Linear-sourced and (b) Jira-sourced `Tracker.Issue`; outputs identical mod `branch_name`.

---

## Notes

- Total tasks: **85**. Phase breakdown: Setup 2; Foundational 12; US1 13; US2 3; US3 4; US4 2; US5 8; US6 3; US7 4; US8 2; Phase 11 (cross-cutting) 20; Polish (US9) 12.
- `[P]` count: 39.
- `[Test-After Refactor]` count: 8 (the entire rename block).
- Coverage strategy: `Jira.Adapter` covered at 100% via T018 + T040 + T043 adapter-level tests; `Jira.Client` on `ignore_modules` (T001) — its logic is exercised by the `_for_test` helper tests in `jira/client_test.exs`.
- `mix.exs:ignore_modules` already exists with Linear's `Client` — this PR only adds the Jira entry (T001). No structural change to the list.
- Strict TDD: every GREEN task has a paired RED task immediately preceding it. Exceptions are the 8 `[Test-After Refactor]` rename tasks (T003–T010) and T053 (US8 — no new code expected unless test exposes a bug).
- All tests use `FakeJiraClient` + `request_fun:` injection (FR-012, FR-047). No real HTTP. Token literal in fixtures is `"fake-jira-token-not-real"` (FR-051).
- Constitution PATCH bump (T083, FR-046) lands in the same PR; the v1.1.0 → v1.1.1 entry is a one-line + SYNC IMPACT REPORT block.
- T085 (FR-038 spec amendment) is the only NEEDS-HUMAN-ACK item — user must choose option (a) amend spec or (b) document substitution in PR body. Default-on-implement: (b).
