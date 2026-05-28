exunit_opts =
  case System.get_env("SYMPHONY_TEST_MAX_CASES") do
    nil ->
      []

    value ->
      case Integer.parse(value) do
        {max_cases, ""} when max_cases > 0 -> [max_cases: max_cases]
        _ -> []
      end
  end

ExUnit.start(exunit_opts)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
