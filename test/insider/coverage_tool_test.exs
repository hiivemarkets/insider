defmodule Insider.TestSupport.CoverageToolTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Insider.TestSupport.CoverageTool

  test "summary counts unique executable lines and excludes other modules" do
    results = [
      {{Alpha, 0}, {0, 1}},
      {{Alpha, 1}, {0, 1}},
      {{Alpha, 1}, {1, 0}},
      {{Alpha, 2}, {1, 0}},
      {{Beta, 1}, {0, 1}},
      {{Ignored, 1}, {1, 0}}
    ]

    assert {per_module, total} = CoverageTool.summarize(results, [Alpha, Beta])
    assert per_module == [{100.0, Alpha}, {+0.0, Beta}]
    assert total == 2 / 3 * 100
  end

  test "an empty project retains Mix 1.17 compatible total and table width" do
    assert {[], 100.0} = CoverageTool.summarize([], [])
    assert CoverageTool.summary_name_width([]) == 10

    output = capture_io(fn -> CoverageTool.print_summary([], [], threshold: 90) end)
    assert output =~ "| Percentage | Module"
    assert output =~ "100.00%"
    assert output =~ "Total"
  end

  test "HTML writer finishes each module before opening the next report", context do
    output = Path.join(System.tmp_dir!(), "insider-coverage-#{context.test}")
    on_exit(fn -> File.rm_rf!(output) end)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    analyzer = fn module, path, options ->
      Agent.update(calls, &[{module, List.to_string(path), options} | &1])
      {:ok, path}
    end

    assert :ok = CoverageTool.write_html([Alpha, Beta, Gamma], output, analyzer)

    assert Agent.get(calls, &Enum.reverse/1) == [
             {Alpha, Path.join(output, "#{Alpha}.html"), [:html]},
             {Beta, Path.join(output, "#{Beta}.html"), [:html]},
             {Gamma, Path.join(output, "#{Gamma}.html"), [:html]}
           ]
  end

  test "HTML writer makes an analyzer failure authoritative", context do
    output = Path.join(System.tmp_dir!(), "insider-coverage-failure-#{context.test}")
    on_exit(fn -> File.rm_rf!(output) end)

    assert_raise Mix.Error, ~r/Failed to generate coverage for Alpha: :emfile/, fn ->
      CoverageTool.write_html([Alpha], output, fn _module, _path, _options ->
        {:error, :emfile}
      end)
    end
  end
end
