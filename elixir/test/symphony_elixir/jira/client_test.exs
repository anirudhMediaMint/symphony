defmodule SymphonyElixir.Jira.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
end
