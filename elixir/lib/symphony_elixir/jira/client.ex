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
  # `fields.priority.name` returned by Jira Cloud.
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

  defp do_fetch_candidate_issues(jira, request_fun) do
    url = build_search_url(jira.base_url, jira.jql, jira.max_issues_per_poll)
    headers = build_request_headers(jira.email, jira.api_token)

    case request_fun.(:get, url, headers, nil) do
      {:ok, %{status: 200, body: %{"issues" => issues}}} when is_list(issues) ->
        normalized =
          issues
          |> Enum.map(
            &normalize_issue(&1, jira.base_url, jira.priority_map || %{}, jira.description_format || "text")
          )
          |> Enum.reject(&is_nil/1)

        {:ok, normalized}

      {:ok, %{status: 200, body: body}} ->
        Logger.error("jira_unknown_payload body=#{summarize_error_body(body)}")
        {:error, {:jira_unknown_payload, summarize_error_body(body)}}

      {:ok, %{status: status, body: body}} when status in 300..399 ->
        Logger.error("jira_unexpected_redirect status=#{status}")
        _ = body
        {:error, {:jira_unexpected_redirect, status}}

      {:ok, %{status: 400, body: body}} ->
        Logger.error("jira_invalid_jql body=#{summarize_error_body(body)}")
        {:error, {:jira_invalid_jql, summarize_error_body(body)}}

      {:ok, %{status: 401}} ->
        Logger.error("tracker_unauthorized: jira")
        {:error, :tracker_unauthorized}

      {:ok, %{status: 403}} ->
        Logger.error("tracker_forbidden: jira")
        {:error, {:tracker_forbidden, %{project_key: nil}}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("jira_api_status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:jira_api_status, status}}

      {:error, reason} ->
        Logger.error("jira_api_request: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp build_search_url(base_url, jql, max_issues_per_poll) do
    max_results = jira_max_results(max_issues_per_poll)

    String.trim_trailing(base_url, "/") <>
      "/rest/api/3/search/jql?jql=" <> URI.encode_www_form(jql) <>
      "&maxResults=" <> Integer.to_string(max_results)
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
end
