defmodule SymphonyElixir.Jira.ClientTest do
  use ExUnit.Case, async: false

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
end
