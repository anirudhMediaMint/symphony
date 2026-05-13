defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "jira", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.tracker.kind == "jira" ->
        validate_jira_required_fields(settings.tracker.jira)

      true ->
        :ok
    end
  end

  # FR-033: required `tracker.jira.*` fields. Checked in declaration order
  # so the first missing field surfaces — operators fix one error at a time.
  defp validate_jira_required_fields(jira) do
    cond do
      not present?(jira && jira.base_url) ->
        {:error, {:missing_tracker_config, :"tracker.jira.base_url"}}

      not present?(jira && jira.email) ->
        {:error, {:missing_tracker_config, :"tracker.jira.email"}}

      not present?(jira && jira.api_token) ->
        {:error, {:missing_tracker_config, :"tracker.jira.api_token"}}

      not present?(jira && jira.jql) ->
        {:error, {:missing_tracker_config, :"tracker.jira.jql"}}

      true ->
        validate_jql_no_order_by(jira.jql)
    end
  end

  # FR-035 / AC-011 / research.md R-3:
  # Reject `ORDER BY` (case-insensitive) appearing outside a JQL string literal.
  # Hand-rolled state machine — Regex.match? is explicitly forbidden by FR-035
  # because a naive regex flags legitimate substrings like `summary ~ "ORDER BY"`.
  #
  # Modes: :default | :double_string | :single_string
  # Escape policy: `\\` (one literal backslash) followed by `\\` is an escape pair
  # consumed as data; any other backslash is regular data. Therefore `\"` inside
  # a double-quoted literal CLOSES the literal (the `\` is data; the `"` matches).
  defp validate_jql_no_order_by(jql) when is_binary(jql) do
    scan_jql(jql, :default)
  end

  defp validate_jql_no_order_by(_jql), do: :ok

  # End of input — no ORDER BY found.
  defp scan_jql(<<>>, _mode), do: :ok

  # In :default mode, enter a string on a quote.
  defp scan_jql(<<?", rest::binary>>, :default), do: scan_jql(rest, :double_string)
  defp scan_jql(<<?', rest::binary>>, :default), do: scan_jql(rest, :single_string)

  # In :default mode, look for case-insensitive ORDER followed by 1+ whitespace
  # chars followed by BY. Consume one char at a time on miss so retries advance.
  defp scan_jql(<<o, r1, d, e, r2, ws, rest::binary>>, :default)
       when o in [?O, ?o] and r1 in [?R, ?r] and d in [?D, ?d] and e in [?E, ?e] and
              r2 in [?R, ?r] and ws in [?\s, ?\t, ?\n, ?\r] do
    case skip_whitespace_then_by(rest) do
      {:match, fragment_tail} ->
        {:error,
         {:jql_order_by_not_allowed,
          <<o, r1, d, e, r2, ws>> <> fragment_tail}}

      :no_match ->
        scan_jql(<<r1, d, e, r2, ws, rest::binary>>, :default)
    end
  end

  defp scan_jql(<<_ch, rest::binary>>, :default), do: scan_jql(rest, :default)

  # In :double_string mode — `\\` (backslash + backslash) is a data escape;
  # any other char including `\"` treats `\` as plain data, so `"` still closes.
  defp scan_jql(<<?\\, ?\\, rest::binary>>, :double_string),
    do: scan_jql(rest, :double_string)

  defp scan_jql(<<?", rest::binary>>, :double_string), do: scan_jql(rest, :default)
  defp scan_jql(<<_ch, rest::binary>>, :double_string), do: scan_jql(rest, :double_string)

  # In :single_string mode — same escape policy as double-string.
  defp scan_jql(<<?\\, ?\\, rest::binary>>, :single_string),
    do: scan_jql(rest, :single_string)

  defp scan_jql(<<?', rest::binary>>, :single_string), do: scan_jql(rest, :default)
  defp scan_jql(<<_ch, rest::binary>>, :single_string), do: scan_jql(rest, :single_string)

  # After consuming `ORDER<ws>`, look for one or more whitespace chars (already
  # consumed one) followed by case-insensitive `BY`. Returns {:match, tail} or
  # :no_match. `tail` is up to 20 chars of context for the error fragment.
  defp skip_whitespace_then_by(<<ws, rest::binary>>) when ws in [?\s, ?\t, ?\n, ?\r] do
    skip_whitespace_then_by(rest)
  end

  defp skip_whitespace_then_by(<<b, y, rest::binary>>)
       when b in [?B, ?b] and y in [?Y, ?y] do
    {:match, <<b, y>> <> String.slice(rest, 0, 20)}
  end

  defp skip_whitespace_then_by(_other), do: :no_match

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
