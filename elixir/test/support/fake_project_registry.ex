defmodule SymphonyElixir.TestSupport.FakeProjectRegistry do
  @moduledoc false

  def normalized_entries do
    send(self(), :project_registry_normalized_entries_called)

    entries =
      Process.get({__MODULE__, :entries}) ||
        [
          %{
            project_key: "project-a",
            display_name: nil,
            enabled: true,
            max_concurrent_agents: 15
          }
        ]

    {:ok, entries}
  end
end
