defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira Cloud-backed tracker adapter.

  Implements `SymphonyElixir.Tracker`. Every callback delegates to the
  module returned by `Application.get_env(:symphony_elixir,
  :jira_client_module, SymphonyElixir.Jira.Client)` (FR-005, FR-006). The
  adapter performs NO HTTP itself — all egress lives in `Jira.Client`.

  ## FR-038 / Gate 2 substitution

  `validate_state_resolvability/0` reports workflow state names that the
  configured Jira projects cannot resolve. Spec FR-038 references a
  "transition mapping in WORKFLOW.md" config surface that does NOT exist
  in v1. Per the Gate 2 decision documented in tasks.md, the v1 substitute
  is `tracker.active_states ++ tracker.terminal_states` — the well-defined
  state list operators already configure.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Jira.Client
  alias SymphonyElixir.Tracker.Issue

  @impl true
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids), do: client_module().fetch_issue_states_by_ids(ids)

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name),
    do: client_module().update_issue_state(issue_id, state_name)

  @impl true
  @doc """
  Reports workflow state names the configured Jira projects cannot resolve.

  Per the Gate 2 decision (see module @moduledoc), input scope is
  `tracker.active_states ++ tracker.terminal_states`. FR-038 spec wording
  references a transition-mapping config surface not present in v1; this
  is the documented substitution.

  De-dupes case-preserving (first occurrence wins). Delegates to the
  configured client module's `validate_state_resolvability_for/1`.
  """
  @spec validate_state_resolvability() :: {:ok, [String.t()]} | {:error, term()}
  def validate_state_resolvability do
    tracker = Config.settings!().tracker
    active = tracker.active_states || []
    terminal = tracker.terminal_states || []

    names = Enum.uniq(active ++ terminal)
    client_module().validate_state_resolvability_for(names)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end
end
