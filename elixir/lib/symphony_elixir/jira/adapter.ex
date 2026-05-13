defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira Cloud-backed tracker adapter.

  Implements `SymphonyElixir.Tracker`. Every callback delegates to the
  module returned by `Application.get_env(:symphony_elixir,
  :jira_client_module, SymphonyElixir.Jira.Client)` (FR-005, FR-006). The
  adapter performs NO HTTP itself — all egress lives in `Jira.Client`.
  """

  @behaviour SymphonyElixir.Tracker

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

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end
end
