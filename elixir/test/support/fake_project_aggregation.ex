defmodule SymphonyElixir.TestSupport.FakeProjectAggregation do
  @moduledoc false

  alias SymphonyElixir.Tracker.ProjectAggregation

  def aggregate(project_entries, fetcher) do
    send(self(), {:project_aggregation_called, project_entries})
    ProjectAggregation.aggregate(project_entries, fetcher)
  end
end
