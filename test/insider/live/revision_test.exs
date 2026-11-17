defmodule Insider.Live.RevisionTest do
  use ExUnit.Case, async: true

  alias Insider.Live.Revision.Git

  @commit "0123456789abcdef0123456789abcdef01234567"
  @other "89abcdef0123456789abcdef0123456789abcdef"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(System.tmp_dir!(), "insider-revision-" <> suffix)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp put(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # A hand-built common git directory: `HEAD`, `objects`, and `refs`, as Git
  # always creates them.
  defp common(git, head) do
    put(Path.join(git, "HEAD"), head)
    File.mkdir_p!(Path.join(git, "objects"))
    File.mkdir_p!(Path.join(git, "refs"))
  end

  test "resolves a branch from a loose ref, then from packed refs", %{root: root} do
    git = Path.join(root, ".git")
    common(git, "ref: refs/heads/main\n")
    put(Path.join(git, "packed-refs"), "# pack-refs with: peeled\n#{@other} refs/heads/main\n")

    assert Git.head_commit(root) == @other

    put(Path.join(git, "refs/heads/main"), @commit <> "\n")
    assert Git.head_commit(root) == @commit
  end

  test "resolves a detached HEAD and a linked worktree's .git file", %{root: root} do
    common = Path.join(root, "main/.git")
    worktree_git = Path.join(common, "worktrees/feature")
    common(common, "ref: refs/heads/main\n")
    put(Path.join(common, "refs/heads/feature"), @commit <> "\n")
    put(Path.join(worktree_git, "HEAD"), "ref: refs/heads/feature\n")
    put(Path.join(worktree_git, "commondir"), "../..\n")
    put(Path.join(root, "feature/.git"), "gitdir: #{worktree_git}\n")

    assert Git.head_commit(Path.join(root, "feature")) == @commit

    put(Path.join(worktree_git, "HEAD"), @other <> "\n")
    assert Git.head_commit(Path.join(root, "feature")) == @other
  end

  test "is nil without a checkout or with an unresolvable HEAD", %{root: root} do
    assert Git.head_commit(root) == nil

    put(Path.join(root, ".git/HEAD"), "ref: refs/heads/missing\n")
    assert Git.head_commit(root) == nil

    put(Path.join(root, ".git/HEAD"), "not a commit\n")
    assert Git.head_commit(root) == nil
  end

  # A ref or commondir that points outside the git directory must never be
  # read, even when a commit-shaped file is waiting there.
  test "refuses HEAD refs that leave the git directory", %{root: root} do
    git = Path.join(root, "checkout/.git")
    common(git, "ref: refs/heads/none\n")
    outside = Path.join(root, "outside")
    put(Path.join(outside, "ref"), @commit <> "\n")
    put(Path.join(root, "checkout/x"), @commit <> "\n")
    put(Path.join(git, "x"), @commit <> "\n")
    put(Path.join(git, "packed-refs"), "#{@commit} ../../outside/ref\n#{@commit} refs/../x\n")

    for ref <- [
          "../../outside/ref",
          Path.join(outside, "ref"),
          "refs/../x",
          "refs/../../x",
          "refs//heads/main",
          "refs/heads/main\u0001",
          "/refs/heads/main",
          "x"
        ] do
      put(Path.join(git, "HEAD"), "ref: #{ref}\n")
      assert Git.head_commit(Path.join(root, "checkout")) == nil, ref
    end
  end

  test "refuses a commondir that is not a git common directory", %{root: root} do
    worktree_git = Path.join(root, "main/.git/worktrees/feature")
    outside = Path.join(root, "outside")
    put(Path.join(outside, "refs/heads/feature"), @commit <> "\n")
    put(Path.join(worktree_git, "HEAD"), "ref: refs/heads/feature\n")
    put(Path.join(root, "feature/.git"), "gitdir: #{worktree_git}\n")

    for commondir <- ["../../../../outside", outside, "../..\u0001", ""] do
      put(Path.join(worktree_git, "commondir"), commondir <> "\n")
      assert Git.head_commit(Path.join(root, "feature")) == nil, inspect(commondir)
    end
  end

  # This runs at compile time, so a filesystem error must give an unknown
  # revision, never an exception.
  test "unreadable or misshapen Git files give an unknown revision", %{root: root} do
    git = Path.join(root, ".git")
    common(git, "ref: refs/heads/main\n")
    main = Path.join(git, "refs/heads/main")
    packed = Path.join(git, "packed-refs")
    commondir = Path.join(git, "commondir")
    put(main, @commit <> "\n")
    put(packed, "#{@commit} refs/heads/main\n")
    put(commondir, ".\n")
    assert Git.head_commit(root) == @commit

    worktree = Path.join(root, "linked")
    put(Path.join(worktree, ".git"), "gitdir: #{git}\n")

    for path <- [main, packed, commondir, Path.join(git, "HEAD"), Path.join(worktree, ".git")] do
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)
    end

    assert Git.head_commit(root) == nil
    assert Git.head_commit(worktree) == nil

    for path <- [main, packed, commondir, Path.join(git, "HEAD")], do: File.chmod!(path, 0o600)
    File.rm!(main)
    File.chmod!(packed, 0o000)
    assert Git.head_commit(root) == nil

    # A path component that is a file (ENOTDIR).
    File.chmod!(packed, 0o600)
    File.rm_rf!(Path.join(git, "refs/heads"))
    put(Path.join(git, "refs/heads"), "not a directory\n")
    File.rm!(packed)
    assert Git.head_commit(root) == nil
  end

  describe "real Git layouts" do
    # Each case is built by Git itself and checked against `git rev-parse`.
    setup %{root: root} do
      origin = Path.join(root, "origin")
      git!(root, ["init", "-q", "-b", "main", origin])
      File.write!(Path.join(origin, "file"), "one\n")
      git!(origin, ["add", "file"])
      git!(origin, ["commit", "-q", "-m", "one"])
      {:ok, origin: origin}
    end

    test "a linked worktree, with relative, absolute, and same-directory commondir",
         %{root: root, origin: origin} do
      linked = Path.join(root, "linked")
      git!(origin, ["worktree", "add", "-q", "-b", "feature", linked])
      expected = rev_parse(linked)
      assert Git.head_commit(linked) == expected

      worktree_git = Path.join(origin, ".git/worktrees/linked")
      File.write!(Path.join(worktree_git, "commondir"), Path.join(origin, ".git") <> "\n")
      assert rev_parse(linked) == expected
      assert Git.head_commit(linked) == expected

      File.write!(Path.join(origin, ".git/commondir"), ".\n")
      assert rev_parse(origin) == expected
      assert Git.head_commit(origin) == expected
    end

    test "--separate-git-dir and a submodule-style relative gitdir", %{root: root} do
      separate = Path.join(root, "separate")
      store = Path.join(root, "store/separate.git")
      File.mkdir_p!(Path.dirname(store))
      git!(root, ["init", "-q", "-b", "main", "--separate-git-dir", store, separate])
      File.write!(Path.join(separate, "file"), "two\n")
      git!(separate, ["add", "file"])
      git!(separate, ["commit", "-q", "-m", "two"])
      assert Git.head_commit(separate) == rev_parse(separate)

      super_project = Path.join(root, "super")
      sub = Path.join(super_project, "sub")
      File.mkdir_p!(Path.join(super_project, ".git/modules"))
      File.rename!(store, Path.join(super_project, ".git/modules/sub"))
      File.rename!(separate, sub)
      File.write!(Path.join(sub, ".git"), "gitdir: ../.git/modules/sub\n")
      git!(sub, ["config", "core.worktree", "../../../sub"])
      assert Git.head_commit(sub) == rev_parse(sub)
    end

    test "symlinks out of the git directories are never followed",
         %{root: root, origin: origin} do
      expected = rev_parse(origin)
      git = Path.join(origin, ".git")
      outside = Path.join(root, "outside")
      put(Path.join(outside, "heads/main"), @other <> "\n")
      put(Path.join(outside, "packed-refs"), "#{@other} refs/heads/main\n")

      heads = Path.join(git, "refs/heads")
      File.rename!(heads, heads <> ".real")
      File.ln_s!(Path.join(outside, "heads"), heads)
      assert Git.head_commit(origin) == nil

      File.rm!(heads)
      File.rename!(heads <> ".real", heads)
      File.rm!(Path.join(heads, "main"))
      File.ln_s!(Path.join(outside, "heads/main"), Path.join(heads, "main"))
      assert Git.head_commit(origin) == nil

      File.rm!(Path.join(heads, "main"))
      File.ln_s!(Path.join(outside, "packed-refs"), Path.join(git, "packed-refs"))
      assert Git.head_commit(origin) == nil

      File.rm!(Path.join(git, "packed-refs"))
      put(Path.join(heads, "main"), expected <> "\n")
      assert Git.head_commit(origin) == expected
    end
  end

  # Git with no user or system configuration, so the host's settings cannot
  # change the layout under test, and without the git variables a hook
  # exports, so it acts on the scratch directory and never on the repository
  # the hook runs for.
  defp git!(directory, arguments) do
    environment =
      Insider.Test.GitIsolation.clean() ++
        [
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@example.com"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@example.com"}
        ]

    {output, 0} =
      System.cmd("git", arguments, cd: directory, env: environment, stderr_to_stdout: true)

    output
  end

  defp rev_parse(directory), do: directory |> git!(["rev-parse", "HEAD"]) |> String.trim()
end
