defmodule SymphonyElixir.Tracker.ProjectCandidate do
  @moduledoc """
  Runtime wrapper pairing a Linear issue with stable project context.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ProjectContext

  @enforce_keys [:issue, :project_context]
  defstruct [:issue, :project_context]

  @type t :: %__MODULE__{
          issue: Issue.t(),
          project_context: ProjectContext.t()
        }

  @spec new!(Issue.t(), ProjectContext.t()) :: t()
  def new!(%Issue{} = issue, %ProjectContext{} = project_context) do
    %__MODULE__{issue: issue, project_context: project_context}
  end
end
