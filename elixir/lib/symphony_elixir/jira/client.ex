defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST client for polling candidate issues.

  Boundary module — listed in `mix.exs:test_coverage.ignore_modules` (FR-048).
  Tests exercise the module via `_for_test` helpers and the `request_fun:`
  injection point (FR-012, FR-050).
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  # ADF rendering depth cap (FR-019, NFR-SEC-004). Used by US1 follow-on work.
  @adf_max_depth 64
  @max_error_body_log_bytes 1_000
  @connect_timeout_ms 30_000
  @receive_timeout_ms 60_000

  # FR-016 default priority map. Lookup is case-sensitive against
  # `fields.priority.name` returned by Jira Cloud. Used only when the
  # operator-supplied `tracker.jira.priority_map` is the empty map (the
  # schema default). When the operator supplies a non-empty map, that map
  # is used exclusively — unknown names yield `nil` rather than falling
  # back to this default (FR-016, US6).
  @default_priority_map %{
    "Highest" => 1,
    "High" => 2,
    "Medium" => 3,
    "Low" => 4,
    "Lowest" => 5
  }

  @doc false
  @spec adf_max_depth() :: pos_integer()
  def adf_max_depth, do: @adf_max_depth

  @doc false
  @spec max_error_body_log_bytes() :: pos_integer()
  def max_error_body_log_bytes, do: @max_error_body_log_bytes

  @doc false
  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms, do: @connect_timeout_ms

  @doc false
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms, do: @receive_timeout_ms

  @doc false
  @spec default_priority_map() :: %{optional(String.t()) => pos_integer()}
  def default_priority_map, do: @default_priority_map

  @doc """
  Fetches candidate issues from Jira Cloud via `GET /rest/api/3/search/jql`.

  Single-page in v1 (FR-010 first-page only). Pagination lands in T056.
  Accepts an optional `request_fun:` keyword for unit-test injection
  (FR-012). Production callers MUST NOT pass `request_fun:`.
  """
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_candidate_issues([])

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts) when is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)
    jira = Config.settings!().tracker.jira

    cond do
      not is_binary(jira && jira.base_url) ->
        {:error, {:missing_tracker_config, :"tracker.jira.base_url"}}

      not is_binary(jira && jira.email) ->
        {:error, {:missing_tracker_config, :"tracker.jira.email"}}

      not is_binary(jira && jira.api_token) ->
        {:error, {:missing_tracker_config, :"tracker.jira.api_token"}}

      not is_binary(jira && jira.jql) ->
        {:error, {:missing_tracker_config, :"tracker.jira.jql"}}

      true ->
        do_fetch_candidate_issues(jira, request_fun)
    end
  end

  @doc """
  Verifies that the given workflow state names are reachable in the projects
  referenced by `tracker.jira.jql`.

  Algorithm (research.md R-5):
    1. Extract distinct project keys from JQL (literal-aware — keys inside
       string literals are ignored). Reuses `Config.extract_project_keys/1`.
    2. For each project key, GET `/rest/api/3/issue/createmeta?projectKeys=KEY
       &expand=projects.issuetypes.workflowscheme` serially (v1, FR-038 +
       NFR-PERF-003).
    3. Aggregate reachable status names across all issuetypes case-insensitively.
    4. Return `{:ok, unresolved}` where `unresolved` is the input names that
       did NOT match any reachable status (case preserved from input).

  Accepts `request_fun:` for test injection (FR-012). On transport failure
  returns `{:error, term()}` — Config.validate!/0 fail-opens (FR-037).
  """
  @spec validate_state_resolvability_for([String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def validate_state_resolvability_for(state_names) when is_list(state_names),
    do: validate_state_resolvability_for(state_names, [])

  @spec validate_state_resolvability_for([String.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def validate_state_resolvability_for(state_names, opts)
      when is_list(state_names) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)
    jira = Config.settings!().tracker.jira

    cond do
      not is_binary(jira && jira.base_url) ->
        {:error, {:missing_tracker_config, :"tracker.jira.base_url"}}

      not is_binary(jira && jira.email) ->
        {:error, {:missing_tracker_config, :"tracker.jira.email"}}

      not is_binary(jira && jira.api_token) ->
        {:error, {:missing_tracker_config, :"tracker.jira.api_token"}}

      not is_binary(jira && jira.jql) ->
        {:error, {:missing_tracker_config, :"tracker.jira.jql"}}

      true ->
        do_validate_state_resolvability_for(jira, state_names, request_fun)
    end
  end

  defp do_validate_state_resolvability_for(jira, state_names, request_fun) do
    project_keys = Config.extract_project_keys(jira.jql)

    case fetch_reachable_statuses(project_keys, jira, request_fun, MapSet.new()) do
      {:ok, reachable_lower} ->
        unresolved =
          Enum.reject(state_names, fn name ->
            MapSet.member?(reachable_lower, String.downcase(to_string(name)))
          end)

        {:ok, unresolved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_reachable_statuses([], _jira, _request_fun, acc), do: {:ok, acc}

  defp fetch_reachable_statuses([key | rest], jira, request_fun, acc) do
    url = build_createmeta_url(jira.base_url, key)
    headers = build_request_headers(jira.email, jira.api_token)

    case request_fun.(:get, url, headers, nil) do
      {:ok, %{status: 200, body: body}} ->
        statuses = collect_status_names(body)

        new_acc =
          Enum.reduce(statuses, acc, fn name, set ->
            MapSet.put(set, String.downcase(name))
          end)

        fetch_reachable_statuses(rest, jira, request_fun, new_acc)

      {:ok, %{status: status}} ->
        Logger.error("jira_createmeta_status=#{status} projectKey=#{key}")
        {:error, {:jira_createmeta_status, status}}

      {:error, reason} ->
        Logger.error("jira_createmeta_request: #{inspect(reason)}")
        {:error, {:jira_createmeta_request, reason}}
    end
  end

  defp build_createmeta_url(base_url, project_key) do
    String.trim_trailing(base_url, "/") <>
      "/rest/api/3/issue/createmeta?projectKeys=" <>
      URI.encode_www_form(project_key) <>
      "&expand=projects.issuetypes.workflowscheme"
  end

  defp collect_status_names(%{"projects" => projects}) when is_list(projects) do
    projects
    |> Enum.flat_map(fn
      %{"issuetypes" => issuetypes} when is_list(issuetypes) ->
        Enum.flat_map(issuetypes, fn
          %{"statuses" => statuses} when is_list(statuses) ->
            Enum.flat_map(statuses, fn
              %{"name" => name} when is_binary(name) -> [name]
              _ -> []
            end)

          _ ->
            []
        end)

      _ ->
        []
    end)
  end

  defp collect_status_names(_body), do: []

  @doc """
  Placeholder for reconciliation. Lands in T056 (Phase 11).
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(_states), do: {:error, :not_implemented}

  @doc """
  Placeholder for reconciliation. Lands in T056 (Phase 11).
  """
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(_ids), do: {:error, :not_implemented}

  @doc """
  Placeholder for the agent toolchain write-path. Lands in T065 (Phase 11).
  """
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_key, _body), do: {:error, :not_implemented}

  @doc """
  Placeholder for the agent toolchain write-path. Lands in T065 (Phase 11).
  """
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_key, _state_name), do: {:error, :not_implemented}

  defp do_fetch_candidate_issues(jira, request_fun) do
    cap = effective_cap(jira.max_issues_per_poll)
    fetch_pages_loop(jira, request_fun, nil, [], cap)
  end

  # FR-010 + FR-011 (research.md R-4): paginate `/rest/api/3/search/jql` via
  # `nextPageToken` query parameter (omitted on first request, included on
  # follow-ups). `isLast` is ignored — only `nextPageToken` absence terminates
  # the loop. Cap is enforced AFTER decoding each page (post-decode cap): we
  # accumulate, truncate to `cap`, and on overflow emit a single
  # `[:symphony, :tracker, :poll_cap_hit]` telemetry event + a single WARN log
  # naming the cap, threshold, and JQL (truncated to 200 chars).
  defp fetch_pages_loop(jira, request_fun, token, acc, cap) do
    url = build_search_url(jira.base_url, jira.jql, jira.max_issues_per_poll, token)
    headers = build_request_headers(jira.email, jira.api_token)

    case request_fun.(:get, url, headers, nil) do
      {:ok, %{status: 200, body: %{"issues" => issues} = body} = response}
      when is_list(issues) ->
        log_request_success(:get, url, response.status)

        normalized =
          issues
          |> Enum.map(
            &normalize_issue(
              &1,
              jira.base_url,
              jira.priority_map || %{},
              jira.description_format || "text"
            )
          )
          |> Enum.reject(&is_nil/1)

        merged = acc ++ normalized
        next_token = Map.get(body, "nextPageToken")

        cond do
          length(merged) >= cap ->
            truncated = Enum.take(merged, cap)
            emit_poll_cap_hit(jira.jql, cap)
            {:ok, truncated}

          is_binary(next_token) and next_token != "" ->
            fetch_pages_loop(jira, request_fun, next_token, merged, cap)

          true ->
            {:ok, merged}
        end

      {:ok, response} ->
        classify_error_response(response, url, jira.jql)

      {:error, reason} ->
        Logger.error("jira_api_request: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp effective_cap(value) when is_integer(value) and value > 0, do: value
  defp effective_cap(_value), do: 200

  defp emit_poll_cap_hit(jql, cap) do
    excerpt = jql_excerpt(jql)

    :telemetry.execute(
      [:symphony, :tracker, :poll_cap_hit],
      %{count: 1},
      %{tracker_kind: :jira}
    )

    Logger.warning(
      ~s(poll_cap_hit: tracker_kind=jira cap=#{cap} threshold=#{cap} jql="#{excerpt}")
    )
  end

  defp jql_excerpt(jql) when is_binary(jql), do: String.slice(jql, 0, 200)
  defp jql_excerpt(_jql), do: ""

  # FR-044: REST success-path logs MUST be DEBUG level — method, path (no
  # credential-bearing query string), status. Headers MUST NOT be logged.
  # We strip the entire query string to keep the redaction blanket-safe:
  # JQL is not a secret but the rule is "no credential-bearing query string"
  # — easiest path to honor is to log only the path.
  defp log_request_success(method, url, status) do
    Logger.debug(
      "jira_request method=#{method} path=#{request_path(url)} status=#{status}"
    )
  end

  defp request_path(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> path
      _ -> "<unknown>"
    end
  end

  defp request_path(_url), do: "<unknown>"

  # Maps non-2xx Jira responses to the typed error catalog. URL-aware: 400 on
  # /rest/api/3/search/jql becomes :jira_invalid_jql (FR-040, US3); 400 on other
  # endpoints falls through to :jira_api_status until those endpoints add their
  # own classifications. The error tuple/log NEVER includes auth headers (FR-042,
  # FR-045, NFR-SEC-008) — only the response body excerpt, truncated by
  # summarize_error_body/1 (capped at @max_error_body_log_bytes per FR-045).
  defp classify_error_response(%{status: 200, body: body}, _url, _jql) do
    Logger.error("jira_unknown_payload body=#{summarize_error_body(body)}")
    {:error, {:jira_unknown_payload, summarize_error_body(body)}}
  end

  defp classify_error_response(%{status: status}, _url, _jql) when status in 300..399 do
    Logger.error("jira_unexpected_redirect status=#{status}")
    {:error, {:jira_unexpected_redirect, status}}
  end

  defp classify_error_response(%{status: 400, body: body}, url, _jql) do
    if search_jql_path?(url) do
      Logger.error("jira_invalid_jql body=#{summarize_error_body(body)}")
      {:error, {:jira_invalid_jql, summarize_error_body(body)}}
    else
      Logger.error("jira_api_status=400 body=#{summarize_error_body(body)}")
      {:error, {:jira_api_status, 400}}
    end
  end

  # FR-040 / FR-041 — 401 maps to :tracker_unauthorized; MUST NOT be
  # conflated with :missing_tracker_config or :jira_api_status. The log
  # line is the literal atom name only — no headers, no token (FR-043).
  defp classify_error_response(%{status: 401}, _url, _jql) do
    Logger.error("tracker_unauthorized: jira")
    {:error, :tracker_unauthorized}
  end

  # FR-040 — 403 maps to :tracker_forbidden with the FIRST project key the
  # JQL touches (or :unknown when none derivable). Reuses
  # Config.extract_project_keys/1 (literal-aware) from US5.
  defp classify_error_response(%{status: 403}, _url, jql) do
    project_key = first_project_key(jql)
    Logger.error("tracker_forbidden: jira project_key=#{inspect(project_key)}")
    {:error, {:tracker_forbidden, %{project_key: project_key}}}
  end

  defp classify_error_response(%{status: status, body: body}, _url, _jql) do
    Logger.error("jira_api_status=#{status} body=#{summarize_error_body(body)}")
    {:error, {:jira_api_status, status}}
  end

  defp first_project_key(jql) when is_binary(jql) do
    case Config.extract_project_keys(jql) do
      [first | _] -> first
      [] -> :unknown
    end
  end

  defp first_project_key(_jql), do: :unknown

  defp search_jql_path?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> String.contains?(path, "/rest/api/3/search/jql")
      _ -> false
    end
  end

  defp search_jql_path?(_url), do: false

  defp build_search_url(base_url, jql, max_issues_per_poll, next_page_token \\ nil) do
    max_results = jira_max_results(max_issues_per_poll)

    base =
      String.trim_trailing(base_url, "/") <>
        "/rest/api/3/search/jql?jql=" <> URI.encode_www_form(jql) <>
        "&maxResults=" <> Integer.to_string(max_results)

    case next_page_token do
      token when is_binary(token) and token != "" ->
        base <> "&nextPageToken=" <> URI.encode_www_form(token)

      _ ->
        base
    end
  end

  defp jira_max_results(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp jira_max_results(_value), do: 100

  defp build_request_headers(email, api_token) do
    auth = "Basic " <> Base.encode64(email <> ":" <> api_token)

    [
      {"Authorization", auth},
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]
  end

  defp default_request(:get, url, headers, _body) do
    Req.get(url,
      headers: headers,
      redirect: false,
      retry: false,
      connect_options: [timeout: @connect_timeout_ms],
      receive_timeout: @receive_timeout_ms
    )
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.slice(0, @max_error_body_log_bytes)
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> String.slice(0, @max_error_body_log_bytes)
  end

  @doc false
  @spec apply_priority_map_for_test(String.t() | nil, map()) :: integer() | nil
  def apply_priority_map_for_test(priority_name, priority_map)
      when is_map(priority_map) do
    apply_priority(priority_name, priority_map)
  end

  @doc false
  @spec normalize_issue_for_test(map(), keyword()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, opts \\ []) when is_map(issue) and is_list(opts) do
    base_url = Keyword.get(opts, :base_url)
    priority_map = Keyword.get(opts, :priority_map, %{})
    description_format = Keyword.get(opts, :description_format, "text")
    normalize_issue(issue, base_url, priority_map, description_format)
  end

  @doc false
  @spec render_adf_for_test(map()) :: {:ok, String.t()} | {:error, :jira_adf_depth_exceeded}
  def render_adf_for_test(adf) when is_map(adf), do: render_adf(adf, log_lossy?: true)

  # ---------- Internal normalization ----------

  defp normalize_issue(%{"key" => key} = issue, base_url, priority_map, description_format)
       when is_binary(key) do
    fields = Map.get(issue, "fields", %{})

    %Issue{
      id: stringify(issue["id"]),
      identifier: key,
      title: fields["summary"],
      description: normalize_description(fields["description"], description_format),
      priority: apply_priority(get_in(fields, ["priority", "name"]), priority_map),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: build_issue_url(base_url, key),
      assignee_id: nil,
      blocked_by: [],
      labels: normalize_labels(fields["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue, _base_url, _priority_map, _description_format), do: nil

  defp apply_priority(nil, _priority_map), do: nil

  defp apply_priority(name, priority_map) when is_binary(name) do
    cond do
      Map.has_key?(priority_map, name) ->
        coerce_priority(Map.get(priority_map, name))

      Map.has_key?(@default_priority_map, name) and priority_map == %{} ->
        Map.get(@default_priority_map, name)

      priority_map == %{} ->
        nil

      true ->
        # Operator-supplied priority_map present but missing this name — FR-016
        # specifies case-sensitive lookup; unknown name yields nil rather than
        # falling back to the default map.
        nil
    end
  end

  defp apply_priority(_name, _priority_map), do: nil

  defp coerce_priority(value) when is_integer(value), do: value
  defp coerce_priority(_value), do: nil

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_labels(_labels), do: []

  defp normalize_description(nil, _format), do: nil
  defp normalize_description(value, "adf") when is_map(value), do: value
  defp normalize_description(value, _format) when is_binary(value), do: value
  defp normalize_description(_value, _format), do: nil

  defp build_issue_url(nil, _key), do: nil

  defp build_issue_url(base_url, key) when is_binary(base_url) and is_binary(key) do
    String.trim_trailing(base_url, "/") <> "/browse/" <> key
  end

  defp build_issue_url(_base_url, _key), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(_value), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  # ---------- ADF rendering (FR-018, FR-019, FR-020, FR-021, FR-022, AC-009/010) ----------

  # Renders an Atlassian Document Format document to plain text using the
  # deterministic algorithm in SPEC §11.4.
  #
  # - Depth is bounded at @adf_max_depth (FR-019, NFR-SEC-004). Overflow returns
  #   {:error, :jira_adf_depth_exceeded} and emits a WARN log.
  # - Lossy substitutions for media/mention/inlineCard/blockCard/panel/emoji/
  #   status/date are counted by category and surfaced in a single DEBUG line
  #   per render (FR-022). Counts are accumulated in the process dictionary
  #   for the duration of the render call.
  # - inlineCard/blockCard URLs are filtered by URL-scheme allowlist
  #   ({http, https}); any other scheme renders as `[link: filtered]`
  #   (FR-020, NFR-SEC-005, AC-010).
  # - Leaf text is scrubbed of ASCII control codepoints 0x00-0x1F and 0x7F,
  #   except \n (0x0A) and \t (0x09) (FR-021).
  # Block-level ADF node types. Within a doc, these get \n\n between
  # top-level siblings and \n between block-level siblings in nested
  # containers (panel, listItem, etc.). All other nodes are inline and
  # concatenate with no separator.
  @adf_block_types ~w(paragraph heading blockquote codeBlock listItem
                      bulletList orderedList rule mediaGroup mediaSingle
                      panel table tableRow tableCell tableHeader)

  defp render_adf(adf, opts) when is_map(adf) do
    log_lossy? = Keyword.get(opts, :log_lossy?, true)
    pdict_key = {:adf_lossy_counts, make_ref()}
    Process.put(pdict_key, %{})

    try do
      content = Map.get(adf, "content", [])
      # Top-level doc content uses \n\n between block siblings. Depth starts
      # at 0 so a chain of @adf_max_depth nested blocks fits exactly at the
      # cap; the (@adf_max_depth + 1)-th level throws.
      rendered = render_children(content, 0, pdict_key, "\n\n")

      if log_lossy? do
        log_lossy_render(Process.get(pdict_key, %{}))
      end

      {:ok, rendered}
    catch
      :throw, :adf_depth_exceeded ->
        Logger.warning("jira_adf_depth_exceeded: observed depth > #{@adf_max_depth}")
        {:error, :jira_adf_depth_exceeded}
    after
      Process.delete(pdict_key)
    end
  end

  defp render_adf(_adf, _opts), do: {:ok, ""}

  # Renders a children list using the provided block-sibling separator. Inline
  # nodes always join with empty string regardless of this separator.
  defp render_children(nodes, depth, pdict_key, block_sep) when is_list(nodes) do
    nodes
    |> Enum.map(&render_node(&1, depth, pdict_key))
    |> Enum.reduce({[], nil}, fn current, {acc, prev_kind} ->
      kind = current.kind
      text = current.text

      sep =
        case {prev_kind, kind} do
          {nil, _} -> ""
          {:block, _} -> block_sep
          {_, :block} -> block_sep
          _ -> ""
        end

      {[text, sep | acc], kind}
    end)
    |> (fn {acc, _kind} -> acc |> Enum.reverse() |> IO.iodata_to_binary() end).()
  end

  defp render_children(_nodes, _depth, _pdict_key, _block_sep), do: ""

  # render_node/3 returns %{text: binary, kind: :block | :inline}.
  defp render_node(_node, depth, _pdict_key) when depth > @adf_max_depth do
    throw(:adf_depth_exceeded)
  end

  defp render_node(%{"type" => "text"} = node, _depth, _pdict_key) do
    text =
      node
      |> Map.get("text", "")
      |> scrub_controls()

    %{text: text, kind: :inline}
  end

  defp render_node(%{"type" => "media"} = node, _depth, pdict_key) do
    bump_lossy(pdict_key, :media)
    attrs = Map.get(node, "attrs", %{})
    label = Map.get(attrs, "alt") || Map.get(attrs, "title") || "file"
    %{text: "[image: #{label}]", kind: :inline}
  end

  defp render_node(%{"type" => "mention"} = node, _depth, pdict_key) do
    bump_lossy(pdict_key, :mention)
    attrs = Map.get(node, "attrs", %{})
    display = Map.get(attrs, "text") || Map.get(attrs, "displayName")

    text =
      case display do
        name when is_binary(name) and name != "" ->
          "@" <> scrub_controls(name)

        _ ->
          account_id = Map.get(attrs, "id", "")
          "@" <> String.slice(account_id, 0, 8)
      end

    %{text: text, kind: :inline}
  end

  defp render_node(%{"type" => "emoji"} = node, _depth, pdict_key) do
    bump_lossy(pdict_key, :emoji)
    attrs = Map.get(node, "attrs", %{})
    text = Map.get(attrs, "shortName") || Map.get(attrs, "text") || ""
    %{text: text, kind: :inline}
  end

  defp render_node(%{"type" => "status"} = node, _depth, pdict_key) do
    bump_lossy(pdict_key, :status)
    attrs = Map.get(node, "attrs", %{})
    text = Map.get(attrs, "text") || ""
    %{text: "[#{scrub_controls(text)}]", kind: :inline}
  end

  defp render_node(%{"type" => "date"} = node, _depth, pdict_key) do
    bump_lossy(pdict_key, :date)
    attrs = Map.get(node, "attrs", %{})
    %{text: format_adf_date(Map.get(attrs, "timestamp")), kind: :inline}
  end

  defp render_node(%{"type" => type} = node, _depth, pdict_key)
       when type in ["inlineCard", "blockCard"] do
    attrs = Map.get(node, "attrs", %{})
    url = Map.get(attrs, "url", "")

    text =
      if allowed_url_scheme?(url) do
        "<" <> url <> ">"
      else
        bump_lossy(pdict_key, :link_filtered)
        "[link: filtered]"
      end

    %{text: text, kind: :inline}
  end

  defp render_node(%{"type" => "panel"} = node, depth, pdict_key) do
    bump_lossy(pdict_key, :panel)
    attrs = Map.get(node, "attrs", %{})
    panel_type = Map.get(attrs, "panelType", "info")
    children = Map.get(node, "content", [])
    inner = render_children(children, depth + 1, pdict_key, "\n")
    %{text: "[panel:#{panel_type}]\n" <> inner, kind: :block}
  end

  defp render_node(%{"type" => type} = node, depth, pdict_key) when type in @adf_block_types do
    children = Map.get(node, "content", [])
    inner = render_children(children, depth + 1, pdict_key, "\n")
    %{text: inner, kind: :block}
  end

  defp render_node(%{"content" => children}, depth, pdict_key) when is_list(children) do
    # Unknown node with children: recurse without marker; treat as inline so
    # text content concatenates without forced separators (FR-018).
    inner = render_children(children, depth + 1, pdict_key, "\n")
    %{text: inner, kind: :inline}
  end

  defp render_node(_node, _depth, _pdict_key), do: %{text: "", kind: :inline}

  defp scrub_controls(text) when is_binary(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.reject(fn b ->
      cond do
        b == 0x0A -> false
        b == 0x09 -> false
        b < 0x20 -> true
        b == 0x7F -> true
        true -> false
      end
    end)
    |> :binary.list_to_bin()
  end

  defp scrub_controls(_text), do: ""

  defp allowed_url_scheme?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp allowed_url_scheme?(_url), do: false

  defp format_adf_date(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {ms, _} -> format_adf_date_ms(ms)
      :error -> timestamp
    end
  end

  defp format_adf_date(timestamp) when is_integer(timestamp), do: format_adf_date_ms(timestamp)
  defp format_adf_date(_timestamp), do: ""

  defp format_adf_date_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> Integer.to_string(ms)
    end
  end

  defp bump_lossy(pdict_key, category) do
    counts = Process.get(pdict_key, %{})
    Process.put(pdict_key, Map.update(counts, category, 1, &(&1 + 1)))
  end

  defp log_lossy_render(counts) when map_size(counts) == 0, do: :ok

  defp log_lossy_render(counts) do
    parts =
      counts
      |> Enum.sort_by(fn {k, _v} -> Atom.to_string(k) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    Logger.debug("adf_lossy_render: #{parts}")
  end
end
