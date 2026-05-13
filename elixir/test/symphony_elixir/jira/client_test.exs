defmodule SymphonyElixir.Jira.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias SymphonyElixir.Jira.Client
  alias SymphonyElixir.Tracker.Issue

  describe "normalize_issue_for_test/2 (T019, FR-015)" do
    test "maps a minimal Jira issue payload to Tracker.Issue.t() field-by-field" do
      payload = %{
        "id" => "10001",
        "key" => "ENG-42",
        "fields" => %{
          "summary" => "Onboard Jira adapter",
          "description" => "Wire it up.",
          "priority" => %{"name" => "Highest"},
          "status" => %{"name" => "In Progress"},
          "labels" => ["Symphony", "Tracker"],
          "created" => "2026-05-01T12:00:00Z",
          "updated" => "2026-05-12T18:30:00Z"
        }
      }

      assert %Issue{} =
               issue =
               Client.normalize_issue_for_test(payload, base_url: "https://jira.test")

      assert issue.id == "10001"
      assert issue.identifier == "ENG-42"
      assert issue.title == "Onboard Jira adapter"
      assert issue.description == "Wire it up."
      assert issue.priority == 1
      assert issue.state == "In Progress"
      assert issue.branch_name == nil
      assert issue.url == "https://jira.test/browse/ENG-42"
      assert issue.assignee_id == nil
      assert issue.blocked_by == []
      assert issue.labels == ["symphony", "tracker"]
      assert issue.assigned_to_worker == true
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "tolerates trailing slash on base_url when building url" do
      payload = %{"id" => "1", "key" => "ENG-1", "fields" => %{}}

      issue = Client.normalize_issue_for_test(payload, base_url: "https://jira.test/")

      assert issue.url == "https://jira.test/browse/ENG-1"
    end
  end

  describe "fetch_candidate_issues/1 with request_fun injection (T021, FR-007/008/010/015)" do
    test "returns normalized issues and constructs a Basic-auth header per request_fun call" do
      env_var = "JIRA_API_TOKEN_T021_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      test_pid = self()

      fake_request = fn method, url, headers, body ->
        send(test_pid, {:jira_request, method, url, headers, body})

        {:ok,
         %{
           status: 200,
           body: %{
             "issues" => [
               %{
                 "id" => "10001",
                 "key" => "ENG-42",
                 "fields" => %{
                   "summary" => "Onboard Jira adapter",
                   "priority" => %{"name" => "Medium"},
                   "status" => %{"name" => "In Progress"}
                 }
               }
             ]
           }
         }}
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: fake_request)
      assert %Issue{identifier: "ENG-42", title: "Onboard Jira adapter", priority: 3} = issue
      assert issue.url == "https://jira.test/browse/ENG-42"

      assert_receive {:jira_request, :get, url, headers, _body}
      assert String.starts_with?(url, "https://jira.test/rest/api/3/search/jql")

      auth_header =
        Enum.find_value(headers, fn
          {"Authorization", value} -> value
          _ -> nil
        end)

      assert is_binary(auth_header)
      assert String.starts_with?(auth_header, "Basic ")
      "Basic " <> encoded = auth_header
      assert {:ok, "dev@example.com:fake-jira-token-not-real"} == Base.decode64(encoded)
    end
  end

  describe "fetch_candidate_issues/1 maps HTTP 400 to jira_invalid_jql (T032, US3, FR-040, FR-042)" do
    test "returns {:error, {:jira_invalid_jql, body_excerpt}} and never leaks the token" do
      env_var = "JIRA_API_TOKEN_T032_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t032-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      fake_400 = fn :get, _url, _headers, _body ->
        {:ok,
         %{
           status: 400,
           body: ~s({"errorMessages":["Field 'priorityz' does not exist"]})
         }}
      end

      assert {:error, {:jira_invalid_jql, body_excerpt}} =
               result = Client.fetch_candidate_issues(request_fun: fake_400)

      assert is_binary(body_excerpt)
      assert body_excerpt =~ "priorityz"

      # FR-042 / NFR-SEC-008 — token MUST NOT appear in the error tuple.
      refute inspect(result) =~ "fake-jira-token-not-real"
      refute inspect(result) =~ "Basic "
    end
  end

  describe "validate_state_resolvability_for/1 (T041, US5, FR-037, FR-038)" do
    setup do
      env_var = "JIRA_API_TOKEN_T041_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t041-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG OR project = ACME OR summary ~ \\"PROJ\\""
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      {:ok, env_var: env_var}
    end

    test "case-insensitive match; project keys extracted only from JQL identifiers (not string literals); per-project createmeta aggregated; unresolved names returned" do
      test_pid = self()

      # Per-project createmeta responses keyed by projectKeys query param.
      # ENG project reaches {Todo, In Progress, Done}; ACME reaches {Closed, Backlog}.
      # Union: {Todo, In Progress, Done, Closed, Backlog} (case-insensitive).
      # Input states: ["Todo", "in progress", "Code Review", "DONE", "Closed"]
      # Unresolved: ["Code Review"] (case preserved from input).
      # PROJ in string literal must NOT yield a createmeta call.
      fake_request = fn :get, url, _headers, _body ->
        send(test_pid, {:jira_createmeta_request, url})

        cond do
          String.contains?(url, "projectKeys=ENG") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "projects" => [
                   %{
                     "issuetypes" => [
                       %{
                         "name" => "Task",
                         "statuses" => [
                           %{"name" => "Todo"},
                           %{"name" => "In Progress"},
                           %{"name" => "Done"}
                         ]
                       }
                     ]
                   }
                 ]
               }
             }}

          String.contains?(url, "projectKeys=ACME") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "projects" => [
                   %{
                     "issuetypes" => [
                       %{
                         "name" => "Bug",
                         "statuses" => [
                           %{"name" => "Closed"},
                           %{"name" => "Backlog"}
                         ]
                       }
                     ]
                   }
                 ]
               }
             }}

          true ->
            send(test_pid, {:unexpected_url, url})
            {:ok, %{status: 404, body: %{}}}
        end
      end

      assert {:ok, ["Code Review"]} =
               SymphonyElixir.Jira.Client.validate_state_resolvability_for(
                 ["Todo", "in progress", "Code Review", "DONE", "Closed"],
                 request_fun: fake_request
               )

      # Two distinct projects → two requests, no third.
      assert_receive {:jira_createmeta_request, url1}
      assert_receive {:jira_createmeta_request, url2}

      requested =
        [url1, url2]
        |> Enum.map(fn u ->
          %URI{query: q} = URI.parse(u)
          %{"projectKeys" => key} = URI.decode_query(q)
          key
        end)
        |> Enum.sort()

      assert requested == ["ACME", "ENG"]

      # PROJ was inside a string literal — MUST NOT be treated as a project key.
      refute_received {:jira_createmeta_request, _}
      refute_received {:unexpected_url, _}
    end
  end

  describe "apply_priority_map_for_test/2 (T020, FR-016)" do
    test "default map maps Highest/High/Medium/Low/Lowest -> 1..5" do
      assert Client.apply_priority_map_for_test("Highest", %{}) == 1
      assert Client.apply_priority_map_for_test("High", %{}) == 2
      assert Client.apply_priority_map_for_test("Medium", %{}) == 3
      assert Client.apply_priority_map_for_test("Low", %{}) == 4
      assert Client.apply_priority_map_for_test("Lowest", %{}) == 5
    end

    test "default map returns nil for unknown priority names and nil input" do
      assert Client.apply_priority_map_for_test("Critical", %{}) == nil
      assert Client.apply_priority_map_for_test(nil, %{}) == nil
    end
  end

  describe "apply_priority_map_for_test/2 with operator-supplied map (T045, US6, FR-016)" do
    test "custom priority_map takes precedence over the default with case-sensitive lookup" do
      custom = %{"P0" => 1, "P1" => 2}

      # Known name in custom map — returns mapped value.
      assert Client.apply_priority_map_for_test("P1", custom) == 2
      assert Client.apply_priority_map_for_test("P0", custom) == 1

      # Unknown name (not in custom map) — returns nil, no fallback to default
      # map, even though "Critical" would otherwise be a valid Jira priority.
      assert Client.apply_priority_map_for_test("Critical", custom) == nil

      # FR-016 case-sensitive: "p1" does NOT match "P1" key.
      assert Client.apply_priority_map_for_test("p1", %{"P1" => 2}) == nil
    end
  end

  describe "fetch_candidate_issues/1 with operator priority_map (T046, US6, FR-016)" do
    test "end-to-end: issue with fields.priority.name == \"P0\" and priority_map %{\"P0\" => 1} yields Issue.priority == 1" do
      env_var = "JIRA_API_TOKEN_T046_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t046-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
          priority_map:
            P0: 1
            P1: 2
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      fake_request = fn :get, _url, _headers, _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "issues" => [
               %{
                 "id" => "10042",
                 "key" => "ENG-100",
                 "fields" => %{
                   "summary" => "Custom priority issue",
                   "priority" => %{"name" => "P0"},
                   "status" => %{"name" => "In Progress"}
                 }
               }
             ]
           }
         }}
      end

      assert {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: fake_request)
      assert %Issue{identifier: "ENG-100", priority: 1} = issue
    end
  end

  describe "fetch_candidate_issues/1 maps HTTP 401 to tracker_unauthorized (T048, US7, FR-040, FR-041, AC-008)" do
    test "returns {:error, :tracker_unauthorized} and never leaks the token or Basic-auth blob" do
      env_var = "JIRA_API_TOKEN_T048_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t048-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      fake_401 = fn :get, _url, _headers, _body ->
        {:ok, %{status: 401, body: ~s({"errorMessages":["Unauthorized"]})}}
      end

      assert {:error, :tracker_unauthorized} =
               result = Client.fetch_candidate_issues(request_fun: fake_401)

      # FR-040/FR-041: MUST be :tracker_unauthorized, NOT conflated with
      # :missing_tracker_config or :jira_api_status.
      refute match?({:error, {:missing_tracker_config, _}}, result)
      refute match?({:error, {:jira_api_status, _}}, result)

      # AC-008 / FR-042 / NFR-SEC-008 — neither the token nor the Basic-auth
      # blob may appear in the bubbled error tuple.
      refute inspect(result) =~ "fake-jira-token-not-real"
      refute inspect(result) =~ "Basic "
    end
  end

  describe "fetch_candidate_issues/1 maps HTTP 403 to tracker_forbidden with project_key (T049, US7, FR-040)" do
    test "single-project JQL — error carries project_key derived from JQL" do
      env_var = "JIRA_API_TOKEN_T049A_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t049a-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      fake_403 = fn :get, _url, _headers, _body ->
        {:ok, %{status: 403, body: ~s({"errorMessages":["Forbidden"]})}}
      end

      assert {:error, {:tracker_forbidden, %{project_key: "ENG"}}} =
               result = Client.fetch_candidate_issues(request_fun: fake_403)

      refute inspect(result) =~ "fake-jira-token-not-real"
      refute inspect(result) =~ "Basic "
    end

    test "multi-project JQL — error carries the FIRST extracted project_key; string-literal keys ignored" do
      env_var = "JIRA_API_TOKEN_T049B_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t049b-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      # `summary ~ "PROJ"` is a string literal — Config.extract_project_keys/1
      # must NOT yield PROJ. Declaration order is ACME, then ENG — first key
      # is ACME.
      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ACME OR project = ENG OR summary ~ \\"PROJ\\""
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      fake_403 = fn :get, _url, _headers, _body ->
        {:ok, %{status: 403, body: ~s({"errorMessages":["Forbidden"]})}}
      end

      assert {:error, {:tracker_forbidden, %{project_key: "ACME"}}} =
               Client.fetch_candidate_issues(request_fun: fake_403)
    end
  end

  describe "fetch_candidate_issues/1 log redaction on 401/403 (T050, US7, FR-043, NFR-SEC-008, AC-008)" do
    setup do
      env_var = "JIRA_API_TOKEN_T050_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t050-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      :ok
    end

    test "401 path — log MUST NOT contain the API token or Basic-auth blob" do
      fake_401 = fn :get, _url, _headers, _body ->
        {:ok, %{status: 401, body: ~s({"errorMessages":["Unauthorized"]})}}
      end

      log =
        capture_log(fn ->
          assert {:error, :tracker_unauthorized} =
                   Client.fetch_candidate_issues(request_fun: fake_401)
        end)

      refute log =~ "Basic "
      refute log =~ "fake-jira-token-not-real"
    end

    test "403 path — log MUST NOT contain the API token or Basic-auth blob" do
      fake_403 = fn :get, _url, _headers, _body ->
        {:ok, %{status: 403, body: ~s({"errorMessages":["Forbidden"]})}}
      end

      log =
        capture_log(fn ->
          assert {:error, {:tracker_forbidden, _}} =
                   Client.fetch_candidate_issues(request_fun: fake_403)
        end)

      refute log =~ "Basic "
      refute log =~ "fake-jira-token-not-real"
    end
  end

  describe "fetch_candidate_issues/1 multi-page pagination (T054, FR-010, FR-011)" do
    setup do
      env_var = "JIRA_API_TOKEN_T054_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t054-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      :ok
    end

    test "follows nextPageToken across pages; ignores isLast; returns merged issues" do
      test_pid = self()

      page1_issues =
        for i <- 1..100 do
          %{
            "id" => Integer.to_string(10_000 + i),
            "key" => "ENG-#{i}",
            "fields" => %{
              "summary" => "Issue #{i}",
              "status" => %{"name" => "Todo"}
            }
          }
        end

      page2_issues =
        for i <- 101..200 do
          %{
            "id" => Integer.to_string(10_000 + i),
            "key" => "ENG-#{i}",
            "fields" => %{
              "summary" => "Issue #{i}",
              "status" => %{"name" => "Todo"}
            }
          }
        end

      fake_request = fn :get, url, _headers, _body ->
        send(test_pid, {:jira_request, url})

        cond do
          String.contains?(url, "nextPageToken=abc") ->
            # Page 2 — no nextPageToken; isLast=false MUST be ignored.
            {:ok,
             %{
               status: 200,
               body: %{
                 "issues" => page2_issues,
                 "isLast" => false
               }
             }}

          true ->
            # Page 1 — issues + nextPageToken; isLast=true MUST be ignored
            # (we follow the token regardless).
            {:ok,
             %{
               status: 200,
               body: %{
                 "issues" => page1_issues,
                 "nextPageToken" => "abc",
                 "isLast" => true
               }
             }}
        end
      end

      assert {:ok, issues} = Client.fetch_candidate_issues(request_fun: fake_request)
      assert length(issues) == 200
      assert hd(issues).identifier == "ENG-1"
      assert List.last(issues).identifier == "ENG-200"

      assert_receive {:jira_request, url1}
      assert_receive {:jira_request, url2}
      refute String.contains?(url1, "nextPageToken")
      assert String.contains?(url2, "nextPageToken=abc")
    end
  end

  describe "fetch_candidate_issues/1 pagination cap (T055/T073, FR-011)" do
    setup do
      env_var = "JIRA_API_TOKEN_T055_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end
      end)

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t055-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      # Long JQL (>200 chars) to verify the WARN-log truncation. Kept free of
      # double-quotes so it embeds cleanly into the YAML scalar below.
      long_jql =
        "project = ENG AND " <>
          String.duplicate("status = Todo OR ", 30) <> "status = InProgress"

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "#{long_jql}"
          max_issues_per_poll: 50
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      {:ok, long_jql: long_jql}
    end

    test "truncates to cap, fires telemetry [:symphony, :tracker, :poll_cap_hit], and WARN logs cap/threshold/JQL≤200ch" do
      test_pid = self()
      handler_id = "poll-cap-hit-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:symphony, :tracker, :poll_cap_hit],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Page returns 100 issues (cap is 50); cap is hit on page 1.
      page_issues =
        for i <- 1..100 do
          %{
            "id" => Integer.to_string(20_000 + i),
            "key" => "ENG-#{i}",
            "fields" => %{
              "summary" => "Capped #{i}",
              "status" => %{"name" => "Todo"}
            }
          }
        end

      fake_request = fn :get, _url, _headers, _body ->
        {:ok,
         %{
           status: 200,
           body: %{"issues" => page_issues, "nextPageToken" => "next-page-token"}
         }}
      end

      log =
        capture_log(fn ->
          assert {:ok, issues} = Client.fetch_candidate_issues(request_fun: fake_request)
          assert length(issues) == 50
        end)

      # (c) telemetry event fires with exact measurements + metadata.
      assert_receive {:telemetry, [:symphony, :tracker, :poll_cap_hit], %{count: 1},
                      %{tracker_kind: :jira}}

      # (b) WARN log mentions cap (50), threshold, JQL truncated to ≤200 chars.
      assert log =~ "[warning]" or log =~ "[warn]"
      assert log =~ "poll_cap_hit"
      assert log =~ "50"
      # JQL excerpt must be truncated to at most 200 chars — verify by extracting
      # the jql=... field and asserting its length.
      jql_excerpt =
        case Regex.run(~r/jql="([^"]*)"/, log) do
          [_, captured] -> captured
          _ -> ""
        end

      assert String.length(jql_excerpt) > 0
      assert String.length(jql_excerpt) <= 200
    end
  end

  describe "render_adf_for_test/1 (T057, FR-018, FR-019, FR-021, FR-022, AC-009)" do
    test "concatenates leaf text within a paragraph block" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Hello "},
              %{"type" => "text", "text" => "world"}
            ]
          }
        ]
      }

      assert {:ok, "Hello world"} = Client.render_adf_for_test(adf)
    end

    test "inserts \\n\\n between top-level block nodes" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "First"}]},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Second"}]}
        ]
      }

      assert {:ok, "First\n\nSecond"} = Client.render_adf_for_test(adf)
    end

    test "scrubs ASCII controls from leaf text but preserves \\n and \\t" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "a\x00b\x01c\nd\te\x7Ff"}
            ]
          }
        ]
      }

      assert {:ok, "abc\nd\tef"} = Client.render_adf_for_test(adf)
    end

    test "media node renders as [image: <alt or title or 'file'>]" do
      adf_alt = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "media", "attrs" => %{"alt" => "diagram"}}]
          }
        ]
      }

      assert {:ok, "[image: diagram]"} = Client.render_adf_for_test(adf_alt)

      adf_title = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "media", "attrs" => %{"title" => "the-file"}}]
          }
        ]
      }

      assert {:ok, "[image: the-file]"} = Client.render_adf_for_test(adf_title)

      adf_none = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "media", "attrs" => %{}}]
          }
        ]
      }

      assert {:ok, "[image: file]"} = Client.render_adf_for_test(adf_none)
    end

    test "mention/emoji/status/date placeholders render per SPEC §11.4" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "mention", "attrs" => %{"text" => "Alice"}},
              %{"type" => "text", "text" => " "},
              %{"type" => "emoji", "attrs" => %{"shortName" => ":thumbsup:"}},
              %{"type" => "text", "text" => " "},
              %{"type" => "status", "attrs" => %{"text" => "In Progress"}},
              %{"type" => "text", "text" => " "},
              %{"type" => "date", "attrs" => %{"timestamp" => "1700000000000"}}
            ]
          }
        ]
      }

      assert {:ok, rendered} = Client.render_adf_for_test(adf)
      assert rendered =~ "@Alice"
      assert rendered =~ ":thumbsup:"
      assert rendered =~ "[In Progress]"
      assert rendered =~ "2023-"
    end

    test "panel node renders with [panel:<panelType>] marker" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "panel",
            "attrs" => %{"panelType" => "info"},
            "content" => [
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "text", "text" => "note"}]
              }
            ]
          }
        ]
      }

      assert {:ok, rendered} = Client.render_adf_for_test(adf)
      assert rendered =~ "[panel:info]"
      assert rendered =~ "note"
    end

    test "unknown node recurses into children without marker" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "someUnknownNode",
                "content" => [%{"type" => "text", "text" => "inner"}]
              }
            ]
          }
        ]
      }

      assert {:ok, "inner"} = Client.render_adf_for_test(adf)
    end

    test "depth=64 (at cap) returns :ok" do
      adf = build_deep_adf(64)
      assert {:ok, _rendered} = Client.render_adf_for_test(adf)
    end

    test "depth=1000 exceeds cap and returns {:error, :jira_adf_depth_exceeded} (AC-009)" do
      adf = build_deep_adf(1000)
      assert {:error, :jira_adf_depth_exceeded} = Client.render_adf_for_test(adf)
    end

    test "lossy DEBUG log fires once with category counts" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "media", "attrs" => %{"alt" => "a"}},
              %{"type" => "media", "attrs" => %{"alt" => "b"}},
              %{"type" => "mention", "attrs" => %{"text" => "Alice"}}
            ]
          }
        ]
      }

      Logger.configure(level: :debug)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = Client.render_adf_for_test(adf)
        end)

      assert log =~ "adf_lossy_render"
      assert log =~ "media=2"
      assert log =~ "mention=1"
    end

    defp build_deep_adf(depth) do
      leaf = %{"type" => "text", "text" => "x"}

      nested =
        Enum.reduce(1..depth, leaf, fn _, acc ->
          %{"type" => "paragraph", "content" => [acc]}
        end)

      %{"type" => "doc", "version" => 1, "content" => [nested]}
    end
  end

  describe "extract_blocked_by_for_test/1 (T062, FR-017)" do
    test "returns [] when fields.issuelinks is absent or empty" do
      assert Client.extract_blocked_by_for_test(%{"fields" => %{}}) == []
      assert Client.extract_blocked_by_for_test(%{"fields" => %{"issuelinks" => []}}) == []
      assert Client.extract_blocked_by_for_test(%{}) == []
    end

    test "yields blocker refs only for type.name=='Blocks' with type.inward=='is blocked by' AND inwardIssue populated" do
      payload = %{
        "fields" => %{
          "issuelinks" => [
            # Inward "is blocked by" Blocks — INCLUDE
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by", "outward" => "blocks"},
              "inwardIssue" => %{
                "id" => "20001",
                "key" => "ENG-100",
                "fields" => %{"status" => %{"name" => "Open"}}
              }
            },
            # Outward "blocks" — SKIP (we only follow inward "is blocked by")
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by", "outward" => "blocks"},
              "outwardIssue" => %{
                "id" => "20002",
                "key" => "ENG-101",
                "fields" => %{"status" => %{"name" => "Done"}}
              }
            },
            # Different link type (Relates) — SKIP
            %{
              "type" => %{"name" => "Relates", "inward" => "relates to", "outward" => "relates to"},
              "inwardIssue" => %{
                "id" => "20003",
                "key" => "ENG-102",
                "fields" => %{"status" => %{"name" => "Open"}}
              }
            },
            # Blocks but wrong inward phrasing — SKIP
            %{
              "type" => %{"name" => "Blocks", "inward" => "blocked by", "outward" => "blocks"},
              "inwardIssue" => %{
                "id" => "20004",
                "key" => "ENG-103",
                "fields" => %{"status" => %{"name" => "Open"}}
              }
            },
            # Inward populated but it's a different type — SKIP
            %{
              "type" => %{"name" => "Duplicate", "inward" => "is duplicated by"},
              "inwardIssue" => %{
                "id" => "20005",
                "key" => "ENG-104",
                "fields" => %{"status" => %{"name" => "Open"}}
              }
            }
          ]
        }
      }

      assert [blocker] = Client.extract_blocked_by_for_test(payload)
      assert blocker == %{id: "20001", key: "ENG-100", status: "Open"}
    end

    test "yields multiple blockers in declared order, preserving status name" do
      payload = %{
        "fields" => %{
          "issuelinks" => [
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by"},
              "inwardIssue" => %{
                "id" => "1",
                "key" => "ENG-1",
                "fields" => %{"status" => %{"name" => "Open"}}
              }
            },
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by"},
              "inwardIssue" => %{
                "id" => "2",
                "key" => "ENG-2",
                "fields" => %{"status" => %{"name" => "In Progress"}}
              }
            }
          ]
        }
      }

      assert [
               %{id: "1", key: "ENG-1", status: "Open"},
               %{id: "2", key: "ENG-2", status: "In Progress"}
             ] = Client.extract_blocked_by_for_test(payload)
    end

    test "tolerates missing inwardIssue.fields.status (status :: nil)" do
      payload = %{
        "fields" => %{
          "issuelinks" => [
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by"},
              "inwardIssue" => %{"id" => "9", "key" => "ENG-9"}
            }
          ]
        }
      }

      assert [%{id: "9", key: "ENG-9", status: nil}] =
               Client.extract_blocked_by_for_test(payload)
    end
  end

  describe "normalize_issue_for_test/2 wiring of blocked_by (T063, FR-017)" do
    test "normalize_issue populates blocked_by from issuelinks" do
      payload = %{
        "id" => "1",
        "key" => "ENG-1",
        "fields" => %{
          "issuelinks" => [
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by"},
              "inwardIssue" => %{
                "id" => "99",
                "key" => "ENG-99",
                "fields" => %{"status" => %{"name" => "Open"}}
              }
            }
          ]
        }
      }

      issue = Client.normalize_issue_for_test(payload, base_url: "https://jira.test")
      assert issue.blocked_by == [%{id: "99", key: "ENG-99", status: "Open"}]
    end
  end

  describe "create_comment/2 ADF wrapping (T064, FR-024)" do
    test "POSTs to /rest/api/3/issue/{key}/comment with body wrapped in ADF doc/paragraph/text" do
      test_pid = self()

      fake_request = fn method, url, headers, body ->
        send(test_pid, {:jira_request, method, url, headers, body})
        {:ok, %{status: 201, body: %{"id" => "10100"}}}
      end

      assert :ok =
               Client.create_comment("ENG-42", "Hello comment",
                 request_fun: fake_request,
                 base_url: "https://jira.test",
                 email: "dev@example.com",
                 api_token: "fake-jira-token-not-real"
               )

      assert_receive {:jira_request, :post, url, headers, body}
      assert url == "https://jira.test/rest/api/3/issue/ENG-42/comment"

      assert %{
               "body" => %{
                 "version" => 1,
                 "type" => "doc",
                 "content" => [
                   %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello comment"}]}
                 ]
               }
             } = body

      assert Enum.any?(headers, fn
               {"Authorization", _} -> true
               _ -> false
             end)
    end

    test "non-2xx response maps via the error-atom dispatch" do
      fake_request = fn :post, _url, _headers, _body ->
        {:ok, %{status: 401, body: ~s({"errorMessages":["nope"]})}}
      end

      assert {:error, :tracker_unauthorized} =
               Client.create_comment("ENG-42", "x",
                 request_fun: fake_request,
                 base_url: "https://jira.test",
                 email: "dev@example.com",
                 api_token: "fake-jira-token-not-real"
               )
    end
  end

  describe "find_transition/2 + execute_transition/2 (T064, FR-025)" do
    test "zero match yields :state_transition_not_available" do
      fake_request = fn :get, _url, _headers, _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "transitions" => [
               %{"id" => "11", "to" => %{"name" => "In Progress"}}
             ]
           }
         }}
      end

      assert {:error, :state_transition_not_available} =
               Client.find_transition("ENG-42", "Code Review",
                 request_fun: fake_request,
                 base_url: "https://jira.test",
                 email: "dev@example.com",
                 api_token: "fake-jira-token-not-real"
               )
    end

    test "multi-match (case-insensitive on to.name) yields :state_transition_ambiguous" do
      fake_request = fn :get, _url, _headers, _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "transitions" => [
               %{"id" => "11", "to" => %{"name" => "Done"}},
               %{"id" => "12", "to" => %{"name" => "done"}}
             ]
           }
         }}
      end

      assert {:error, :state_transition_ambiguous} =
               Client.find_transition("ENG-42", "Done",
                 request_fun: fake_request,
                 base_url: "https://jira.test",
                 email: "dev@example.com",
                 api_token: "fake-jira-token-not-real"
               )
    end

    test "single match yields {:ok, transition_id}, case-insensitive" do
      fake_request = fn :get, url, _headers, _body ->
        send(self(), {:transitions_url, url})

        {:ok,
         %{
           status: 200,
           body: %{
             "transitions" => [
               %{"id" => "11", "to" => %{"name" => "In Progress"}},
               %{"id" => "31", "to" => %{"name" => "Done"}}
             ]
           }
         }}
      end

      assert {:ok, "31"} =
               Client.find_transition("ENG-42", "done",
                 request_fun: fake_request,
                 base_url: "https://jira.test",
                 email: "dev@example.com",
                 api_token: "fake-jira-token-not-real"
               )

      assert_received {:transitions_url, url}
      assert url == "https://jira.test/rest/api/3/issue/ENG-42/transitions"
    end

    test "execute_transition/2 POSTs body {\"transition\": {\"id\": <id>}}; 204 -> :ok" do
      test_pid = self()

      fake_request = fn method, url, headers, body ->
        send(test_pid, {:exec_request, method, url, headers, body})
        {:ok, %{status: 204, body: ""}}
      end

      assert :ok =
               Client.execute_transition("ENG-42", "31",
                 request_fun: fake_request,
                 base_url: "https://jira.test",
                 email: "dev@example.com",
                 api_token: "fake-jira-token-not-real"
               )

      assert_receive {:exec_request, :post, url, _headers, body}
      assert url == "https://jira.test/rest/api/3/issue/ENG-42/transitions"
      assert body == %{"transition" => %{"id" => "31"}}
    end
  end

  describe "fetch_candidate_issues/1 redirect rejection (T066, FR-009, NFR-SEC-003, AC-012)" do
    setup do
      env_var = "JIRA_API_TOKEN_T066_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t066-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end

        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      :ok
    end

    test "302 same-host returns {:error, {:jira_unexpected_redirect, 302}} and does not re-send" do
      test_pid = self()

      fake_302 = fn :get, url, _headers, _body ->
        send(test_pid, {:redirect_called, url})
        {:ok, %{status: 302, body: "", headers: [{"location", "https://jira.test/elsewhere"}]}}
      end

      assert {:error, {:jira_unexpected_redirect, 302}} =
               Client.fetch_candidate_issues(request_fun: fake_302)

      # Only ONE request should have been made — no re-follow.
      assert_received {:redirect_called, _}
      refute_received {:redirect_called, _}
    end

    test "302 cross-host returns {:error, {:jira_unexpected_redirect, 302}} and does not re-send Authorization" do
      test_pid = self()

      fake_302 = fn :get, url, headers, _body ->
        send(test_pid, {:redirect_called, url, headers})
        {:ok, %{status: 302, body: "", headers: [{"location", "https://evil.example.com/leak"}]}}
      end

      assert {:error, {:jira_unexpected_redirect, 302}} =
               Client.fetch_candidate_issues(request_fun: fake_302)

      # First (and ONLY) call carried Authorization to jira.test only.
      assert_received {:redirect_called, url, _headers}
      assert String.starts_with?(url, "https://jira.test/")

      # No second call — Authorization MUST NOT be re-sent to the redirect target.
      refute_received {:redirect_called, _, _}
    end
  end

  describe "fetch_candidate_issues/1 exhaustive error mapping (T067, FR-040)" do
    setup do
      env_var = "JIRA_API_TOKEN_T067_#{System.unique_integer([:positive])}"
      previous = System.get_env(env_var)
      System.put_env(env_var, "fake-jira-token-not-real")

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-jira-client-test-t067-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")

      File.write!(workflow_file, """
      ---
      tracker:
        kind: "jira"
        active_states: ["Todo", "In Progress"]
        terminal_states: ["Closed", "Done"]
        jira:
          base_url: "https://jira.test"
          email: "dev@example.com"
          api_token: "$#{env_var}"
          jql: "project = ENG"
      polling:
        interval_ms: 30000
      ---
      You are an agent for this repository.
      """)

      SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn ->
        case previous do
          nil -> System.delete_env(env_var)
          val -> System.put_env(env_var, val)
        end

        Application.delete_env(:symphony_elixir, :workflow_file_path)
        File.rm_rf(workflow_root)
      end)

      :ok
    end

    test "non-2xx status codes 404/422/429/500/502/503 map to {:jira_api_status, code}" do
      for status <- [404, 422, 429, 500, 502, 503] do
        fake = fn :get, _url, _headers, _body ->
          {:ok, %{status: status, body: ~s({"errorMessages":["boom"]})}}
        end

        assert {:error, {:jira_api_status, ^status}} =
                 Client.fetch_candidate_issues(request_fun: fake)
      end
    end

    test "transport-level {:error, reason} maps to {:jira_api_request, reason}" do
      fake = fn :get, _url, _headers, _body ->
        {:error, :timeout}
      end

      assert {:error, {:jira_api_request, :timeout}} =
               Client.fetch_candidate_issues(request_fun: fake)
    end

    test "200 with malformed body (missing issues key) maps to :jira_unknown_payload" do
      fake = fn :get, _url, _headers, _body ->
        {:ok, %{status: 200, body: %{"unexpected" => "shape"}}}
      end

      assert {:error, {:jira_unknown_payload, _excerpt}} =
               Client.fetch_candidate_issues(request_fun: fake)
    end

    test "200 with non-map body maps to :jira_unknown_payload" do
      fake = fn :get, _url, _headers, _body ->
        {:ok, %{status: 200, body: "<<not json>>"}}
      end

      assert {:error, {:jira_unknown_payload, _excerpt}} =
               Client.fetch_candidate_issues(request_fun: fake)
    end
  end

  describe "render_adf_for_test/1 URL-scheme filter (T058, FR-020, NFR-SEC-005, AC-010)" do
    test "http and https inlineCard/blockCard URLs pass through as <url>" do
      adf = %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "inlineCard", "attrs" => %{"url" => "http://example.com/a"}},
              %{"type" => "text", "text" => " "},
              %{"type" => "blockCard", "attrs" => %{"url" => "https://example.com/b"}}
            ]
          }
        ]
      }

      assert {:ok, rendered} = Client.render_adf_for_test(adf)
      assert rendered =~ "<http://example.com/a>"
      assert rendered =~ "<https://example.com/b>"
    end

    test "javascript/file/data/ftp URLs render as [link: filtered] (AC-010)" do
      for scheme <- [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,abc",
            "ftp://x"
          ] do
        adf = %{
          "type" => "doc",
          "version" => 1,
          "content" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "inlineCard", "attrs" => %{"url" => scheme}}]
            }
          ]
        }

        assert {:ok, rendered} = Client.render_adf_for_test(adf)

        assert rendered =~ "[link: filtered]",
               "expected filtered marker for #{scheme}, got: #{inspect(rendered)}"

        refute rendered =~ scheme, "raw URL leaked for #{scheme}"
      end
    end
  end
end
