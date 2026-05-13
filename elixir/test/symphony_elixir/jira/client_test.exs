defmodule SymphonyElixir.Jira.ClientTest do
  use ExUnit.Case, async: true

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
