defmodule Insider.DocumentationLinksTest do
  use ExUnit.Case, async: true

  # The README is a synopsis and `docs/` is the reference that agents read
  # one section at a time, so a moved heading or a stale size in the index
  # sends an agent to the wrong place. These checks run without `mix docs`.

  @root Path.expand("..", __DIR__)
  @index "docs/README.md"

  defp documents do
    (["README.md", "AGENTS.md", "usage-rules.md", "tools/insider_lab/README.md"] ++
       Path.wildcard(Path.join(@root, "{docs,guides}/**/*.md")))
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  test "every relative link, anchor, and image in the documentation resolves" do
    broken =
      for source <- documents(),
          {target, fragment} <- links(source),
          problem = problem(source, target, fragment),
          do: {source, target, fragment, problem}

    assert broken == []
  end

  test "every linked heading has the same anchor on GitHub and in ex_doc" do
    differing =
      for source <- documents(),
          {target, fragment} <- links(source),
          fragment != nil and String.ends_with?(target, ".md"),
          path = resolve(source, target),
          File.regular?(path),
          heading <- headings(path),
          github_anchor(heading.text) == fragment,
          exdoc_anchor(heading.text) != fragment,
          uniq: true,
          do: {Path.relative_to(path, @root), heading.text}

    assert differing == []
  end

  test "the index gives a size close to each section and file it links" do
    # Rows of the task table and the files table: links first, sizes last.
    rows =
      @index
      |> read()
      |> String.split("\n")
      |> Enum.filter(&(String.starts_with?(&1, "| ") and &1 =~ ~r/\| ~\d+ /))

    assert Enum.count_until(rows, 21) == 21

    far =
      for row <- rows,
          sizes = Regex.scan(~r/~(\d+)/, row |> String.split("|") |> Enum.at(-2)),
          {{target, fragment}, [_, size]} <- Enum.zip(row_links(row), sizes),
          listed = String.to_integer(size),
          actual = size(resolve(@index, target), fragment),
          abs(actual - listed) > max(15, div(listed, 4)),
          do: {target, fragment, listed, actual}

    assert far == []
  end

  test "every code fence is a bare fence line and each one is closed" do
    broken =
      for source <- documents(),
          lines = source |> read() |> String.split("\n"),
          fences = Enum.filter(lines, &String.match?(&1, ~r/^\s*```/)),
          bad = Enum.reject(fences, &String.match?(&1, ~r/^\s*```[\w-]*\s*$/)),
          bad != [] or rem(length(fences), 2) != 0,
          do: {source, bad}

    assert broken == []
  end

  test "topic files stay small enough to read whole and open with a contents list" do
    oversized =
      for path <- Path.wildcard(Path.join(@root, "docs/**/*.md")),
          not readiness_artifact?(path),
          lines = path |> File.read!() |> String.split("\n") |> length(),
          lines > 600 or not (File.read!(path) =~ "\n## Contents\n"),
          do: {Path.relative_to(path, @root), lines}

    assert oversized == []
  end

  test "each index row points at a section short enough to read in one go" do
    long =
      for row <- @index |> read() |> String.split("\n"),
          String.starts_with?(row, "| ") and row =~ ~r/\| ~\d+ /,
          {target, fragment} <- row_links(row),
          fragment != nil,
          lines = size(resolve(@index, target), fragment),
          lines > 150,
          do: {target, fragment, lines}

    assert long == []
  end

  test "each topic file's contents list names its headings in order" do
    differing =
      for path <- topic_files(),
          text = File.read!(path),
          listed = contents(text),
          actual =
            for(
              heading <- headings(path),
              heading.level in [2, 3],
              heading.text != "Contents",
              do: github_anchor(heading.text)
            ),
          listed != actual,
          do: {Path.relative_to(path, @root), listed -- actual, actual -- listed}

    assert differing == []
  end

  test "each topic file links back to the index, the glossary, and the cheat sheet" do
    missing =
      for path <- topic_files(),
          Path.basename(path) != "README.md",
          up = if(Path.dirname(path) == Path.join(@root, "docs"), do: "", else: "../"),
          line =
            "[Index](#{up}README.md) · [Glossary](#{up}glossary.md) · [Cheat sheet](#{up}cheat-sheet.md)",
          Enum.at(String.split(File.read!(path), "\n"), 2) != line,
          do: Path.relative_to(path, @root)

    assert missing == []
  end

  defp topic_files,
    do: Path.wildcard(Path.join(@root, "docs/**/*.md")) |> Enum.reject(&readiness_artifact?/1)

  # The anchors of the `## Contents` list, up to the next heading.
  defp contents(text) do
    case String.split(text, "\n## Contents\n", parts: 2) do
      [_, rest] ->
        rest
        |> String.split(~r/\n#/, parts: 2)
        |> hd()
        |> then(&Regex.scan(~r/^\s*- \[.*\]\(#([^)]+)\)/m, &1))
        |> Enum.map(fn [_, anchor] -> anchor end)

      [_] ->
        []
    end
  end

  test "every markdown file under docs/ is an ex_doc extra" do
    extras =
      for extra <- Mix.Project.config()[:docs][:extras] do
        case extra do
          {path, _options} -> path
          path -> path
        end
      end

    missing =
      for path <- Path.wildcard(Path.join(@root, "docs/**/*.md")),
          relative = Path.relative_to(path, @root),
          relative not in extras,
          do: relative

    assert missing == []
  end

  defp readiness_artifact?(path),
    do: Path.basename(path) =~ ~r/^(production-|staged-canary-)/

  defp read(relative), do: File.read!(Path.join(@root, relative))

  defp links(source) do
    text = source |> read() |> strip_code()

    markdown =
      for [_, href] <- Regex.scan(~r/\]\(([^)\s]+)\)/, text), do: href

    images = for [_, src] <- Regex.scan(~r/<img [^>]*src="([^"]+)"/, text), do: src

    for href <- markdown ++ images,
        not String.match?(href, ~r/^[a-z][a-z0-9+.-]*:/) do
      case String.split(href, "#", parts: 2) do
        ["", fragment] -> {source, fragment}
        [target, fragment] -> {target, fragment}
        [target] -> {target, nil}
      end
    end
    |> Enum.map(fn
      {^source, fragment} -> {Path.basename(source), fragment}
      other -> other
    end)
  end

  defp row_links(row) do
    ~r/\]\(([^)\s]+)\)/
    |> Regex.scan(row)
    |> Enum.map(fn [_, href] ->
      case String.split(href, "#", parts: 2) do
        [target, fragment] -> {target, fragment}
        [target] -> {target, nil}
      end
    end)
  end

  defp problem(source, target, fragment) do
    path = resolve(source, target)

    cond do
      not File.exists?(path) -> :missing_file
      fragment == nil -> nil
      not String.ends_with?(path, ".md") -> nil
      fragment not in Enum.map(headings(path), &github_anchor(&1.text)) -> :missing_anchor
      true -> nil
    end
  end

  defp resolve(source, target),
    do: Path.expand(target, Path.join(@root, Path.dirname(source)))

  # Lines from a heading to the next heading of the same or a higher level;
  # a whole file without a fragment.
  defp size(path, nil), do: path |> File.read!() |> String.split("\n") |> length()

  defp size(path, fragment) do
    all = headings(path)
    total = path |> File.read!() |> String.split("\n") |> length()
    index = Enum.find_index(all, &(github_anchor(&1.text) == fragment))
    heading = Enum.at(all, index)

    next =
      all
      |> Enum.drop(index + 1)
      |> Enum.find(&(&1.level <= heading.level))

    ((next && next.line) || total + 1) - heading.line
  end

  defp headings(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, number}, {fenced, acc} ->
      cond do
        String.match?(line, ~r/^\s*```/) ->
          {not fenced, acc}

        not fenced and String.match?(line, ~r/^\#{1,6} /) ->
          [_, hashes, text] = Regex.run(~r/^(#+) (.*)$/, line)
          {fenced, [%{level: String.length(hashes), text: text, line: number} | acc]}

        true ->
          {fenced, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp strip_code(text) do
    text
    |> String.replace(~r/^\s*```.*?^\s*```/ms, "")
    |> String.replace(~r/`[^`\n]*`/, "")
  end

  defp plain(heading) do
    heading
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace("`", "")
  end

  # GitHub: lowercase, drop punctuation except `-` and `_`, spaces to `-`.
  defp github_anchor(heading) do
    heading
    |> plain()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
    |> String.replace(~r/\s/u, "-")
  end

  # ex_doc: `ExDoc.Utils.text_to_id/1` on the heading's text.
  defp exdoc_anchor(heading) do
    heading
    |> plain()
    |> String.replace(~r/\W+/u, "-")
    |> String.trim("-")
    |> String.downcase()
  end
end
