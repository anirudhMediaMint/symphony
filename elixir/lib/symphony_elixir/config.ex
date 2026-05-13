defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker
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
        with :ok <- validate_jira_required_fields(settings.tracker.jira),
             :ok <- validate_jira_poll_interval(settings.tracker.jira, settings.polling) do
          validate_jira_workflow_state_resolvability()
        end

      true ->
        :ok
    end
  end

  # FR-037 / US5: invoke the optional adapter callback at preflight time.
  # Only runs when tracker.kind == "jira"; the caller's `cond` already guards
  # that. On `{:ok, []}` proceed. On `{:ok, [_ | _]}` fail with the typed
  # tuple. On `{:error, _}` log WARN and fail-open (transport flake).
  defp validate_jira_workflow_state_resolvability do
    case Tracker.validate_state_resolvability() do
      {:ok, []} ->
        :ok

      {:ok, unresolved} when is_list(unresolved) ->
        {:error, {:workflow_state_unresolvable, unresolved}}

      {:error, reason} ->
        Logger.warning(
          "workflow_state_resolvability preflight failed; proceeding (fail-open): #{inspect(reason)}"
        )

        :ok
    end
  end

  # FR-036: when tracker.kind == "jira" and polling.interval_ms < 30_000,
  # require explicit `tracker.jira.allow_aggressive_polling: true` override.
  # Tuple shape names the configured interval, the 30_000 ms minimum, and
  # the override key so operators get a one-step fix.
  defp validate_jira_poll_interval(jira, polling) do
    minimum_ms = 30_000
    actual_ms = polling && polling.interval_ms
    allow = jira && jira.allow_aggressive_polling

    cond do
      not is_integer(actual_ms) ->
        :ok

      actual_ms >= minimum_ms ->
        :ok

      allow == true ->
        :ok

      true ->
        {:error,
         {:jira_poll_interval_too_aggressive, actual_ms, minimum_ms,
          :"tracker.jira.allow_aggressive_polling"}}
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

  @doc """
  Extracts distinct project keys referenced by a JQL string.

  Literal-aware: identifiers inside `"..."` or `'...'` string literals are
  ignored (e.g. `summary ~ "PROJ"` does NOT yield `PROJ`). Reuses the same
  string-literal recognition shape as `validate_jql_no_order_by/1` (research.md
  R-3) so the two preflights stay consistent.

  Recognized forms (case-insensitive `project` keyword):
    * `project = KEY` / `project != KEY`
    * `project in (K1, K2, ...)` / `project not in (...)`

  Returns a list of unique uppercase-or-mixed-case identifiers in
  declaration order.
  """
  @spec extract_project_keys(String.t()) :: [String.t()]
  def extract_project_keys(jql) when is_binary(jql) do
    jql
    |> scan_project_keys(:default, [])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  def extract_project_keys(_jql), do: []

  # Scanner: same string-literal modes as scan_jql/2. In :default mode, after
  # seeing the case-insensitive `project` keyword followed by whitespace, we
  # consume the operator and value(s) and emit identifiers.
  defp scan_project_keys(<<>>, _mode, acc), do: acc

  defp scan_project_keys(<<?", rest::binary>>, :default, acc),
    do: scan_project_keys(rest, :double_string, acc)

  defp scan_project_keys(<<?', rest::binary>>, :default, acc),
    do: scan_project_keys(rest, :single_string, acc)

  defp scan_project_keys(<<p, r, o, j, e, c, t, ws, rest::binary>>, :default, acc)
       when p in [?P, ?p] and r in [?R, ?r] and o in [?O, ?o] and j in [?J, ?j] and
              e in [?E, ?e] and c in [?C, ?c] and t in [?T, ?t] and
              ws in [?\s, ?\t, ?\n, ?\r] do
    # Word-boundary check: previous-char check is implicit (start-of-input or a
    # non-identifier char consumed before). The trailing `ws` enforces the
    # right boundary so `projects` does not match.
    {new_acc, after_value} = parse_project_predicate(rest, acc)
    scan_project_keys(after_value, :default, new_acc)
  end

  defp scan_project_keys(<<_ch, rest::binary>>, :default, acc),
    do: scan_project_keys(rest, :default, acc)

  defp scan_project_keys(<<?\\, ?\\, rest::binary>>, :double_string, acc),
    do: scan_project_keys(rest, :double_string, acc)

  defp scan_project_keys(<<?", rest::binary>>, :double_string, acc),
    do: scan_project_keys(rest, :default, acc)

  defp scan_project_keys(<<_ch, rest::binary>>, :double_string, acc),
    do: scan_project_keys(rest, :double_string, acc)

  defp scan_project_keys(<<?\\, ?\\, rest::binary>>, :single_string, acc),
    do: scan_project_keys(rest, :single_string, acc)

  defp scan_project_keys(<<?', rest::binary>>, :single_string, acc),
    do: scan_project_keys(rest, :default, acc)

  defp scan_project_keys(<<_ch, rest::binary>>, :single_string, acc),
    do: scan_project_keys(rest, :single_string, acc)

  # Sits immediately after `project<ws>`. Skip extra whitespace, then dispatch
  # on operator: `=`/`!=` → single ident; `in`/`not in` → parenthesised list.
  # Any unrecognized operator returns acc unchanged with rest preserved so the
  # outer scanner keeps walking.
  defp parse_project_predicate(input, acc) do
    rest = skip_ws(input)

    case rest do
      <<?=, more::binary>> ->
        extract_single_ident(more, acc)

      <<?!, ?=, more::binary>> ->
        extract_single_ident(more, acc)

      <<i, n, ws, more::binary>>
      when i in [?I, ?i] and n in [?N, ?n] and ws in [?\s, ?\t, ?\n, ?\r] ->
        extract_in_list(<<ws, more::binary>>, acc)

      <<n, o, t, ws, more::binary>>
      when n in [?N, ?n] and o in [?O, ?o] and t in [?T, ?t] and
             ws in [?\s, ?\t, ?\n, ?\r] ->
        rest_after_not = skip_ws(<<ws, more::binary>>)

        case rest_after_not do
          <<i, n2, ws2, in_more::binary>>
          when i in [?I, ?i] and n2 in [?N, ?n] and ws2 in [?\s, ?\t, ?\n, ?\r] ->
            extract_in_list(<<ws2, in_more::binary>>, acc)

          _ ->
            {acc, rest}
        end

      _ ->
        {acc, rest}
    end
  end

  defp extract_single_ident(input, acc) do
    rest = skip_ws(input)

    case rest do
      # Quoted value — Jira accepts "KEY" but we ignore quoted forms here
      # because the literal-aware scanner already handles them as data. Skip
      # past the closing quote to keep the outer scanner aligned.
      <<?", _::binary>> ->
        {acc, rest}

      <<?', _::binary>> ->
        {acc, rest}

      _ ->
        case take_ident(rest, <<>>) do
          {"", after_ident} -> {acc, after_ident}
          {ident, after_ident} -> {[ident | acc], after_ident}
        end
    end
  end

  defp extract_in_list(input, acc) do
    rest = skip_ws(input)

    case rest do
      <<?(, more::binary>> -> collect_in_idents(more, acc)
      _ -> {acc, rest}
    end
  end

  defp collect_in_idents(<<>>, acc), do: {acc, <<>>}
  defp collect_in_idents(<<?), rest::binary>>, acc), do: {acc, rest}

  defp collect_in_idents(<<ws, rest::binary>>, acc)
       when ws in [?\s, ?\t, ?\n, ?\r, ?,],
       do: collect_in_idents(rest, acc)

  # Skip quoted values in IN-lists (they're not bare project keys).
  defp collect_in_idents(<<?", rest::binary>>, acc) do
    rest |> skip_until_quote(?") |> collect_in_idents(acc)
  end

  defp collect_in_idents(<<?', rest::binary>>, acc) do
    rest |> skip_until_quote(?') |> collect_in_idents(acc)
  end

  defp collect_in_idents(input, acc) do
    case take_ident(input, <<>>) do
      {"", <<_, rest::binary>>} -> collect_in_idents(rest, acc)
      {"", <<>>} -> {acc, <<>>}
      {ident, after_ident} -> collect_in_idents(after_ident, [ident | acc])
    end
  end

  defp skip_until_quote(<<>>, _q), do: <<>>
  defp skip_until_quote(<<?\\, ?\\, rest::binary>>, q), do: skip_until_quote(rest, q)
  defp skip_until_quote(<<q, rest::binary>>, q), do: rest
  defp skip_until_quote(<<_ch, rest::binary>>, q), do: skip_until_quote(rest, q)

  defp take_ident(<<ch, rest::binary>>, acc)
       when ch in ?A..?Z or ch in ?a..?z or ch in ?0..?9 or ch == ?_ or ch == ?- do
    take_ident(rest, <<acc::binary, ch>>)
  end

  defp take_ident(rest, acc), do: {acc, rest}

  defp skip_ws(<<ws, rest::binary>>) when ws in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

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
