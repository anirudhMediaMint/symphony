defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @doc """
  Optional preflight callback. Adapters that can validate workflow-state
  resolvability against the upstream tracker (e.g. Jira `/createmeta`) MUST
  implement this; adapters that cannot (e.g. Linear, in-memory) MUST NOT.

  Returns `{:ok, [String.t()]}` where the list contains state names that
  could not be resolved by the tracker. An empty list means all states are
  resolvable. Returns `{:error, term()}` on transport / upstream failure;
  callers are expected to fail-open (WARN + proceed).
  """
  @callback validate_state_resolvability() :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks validate_state_resolvability: 0

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @doc """
  Invokes the active adapter's optional `validate_state_resolvability/0` callback.

  Returns `{:ok, []}` when the adapter does not implement the callback
  (Linear, in-memory). Otherwise delegates to the adapter.
  """
  @spec validate_state_resolvability() :: {:ok, [String.t()]} | {:error, term()}
  def validate_state_resolvability do
    mod = adapter()

    with {:module, ^mod} <- Code.ensure_loaded(mod),
         true <- function_exported?(mod, :validate_state_resolvability, 0) do
      mod.validate_state_resolvability()
    else
      _ -> {:ok, []}
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "jira" -> SymphonyElixir.Jira.Adapter
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
