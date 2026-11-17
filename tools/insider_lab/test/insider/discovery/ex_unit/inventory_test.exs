defmodule Insider.Discovery.ExUnit.InventoryTest do
  use ExUnit.Case, async: true

  alias Insider.Discovery.ExUnit.Inventory
  alias Insider.Discovery.ExUnit.InventoryCLI

  test "emits bounded explainable candidates without defect claims" do
    root =
      fixture_root!(%{
        "test/risky_test.exs" => """
        defmodule Example.RiskyTest do
          use ExUnit.Case, async: false

          setup do
            Application.put_env(:example, :mode, :test)
            :ok
          end

          test "waits" do
            Process.sleep(10)
            assert true
          end
        end
        """,
        "test/safe_test.exs" => """
        defmodule Example.SafeTest do
          use ExUnit.Case, async: true
          test "is isolated", do: assert(true)
        end
        """
      })

    assert {:ok, inventory} = Inventory.scan(root)
    assert inventory["schema"] == "insider.exunit-candidate-inventory/v2"

    assert inventory["scanner_revision"] ==
             "ast-v8-telemetry-event-targets"

    assert inventory["status"] == "candidates"
    assert inventory["completeness"] == "complete"
    assert inventory["candidate_count"] == 1
    assert inventory["scanned_file_count"] == 2
    assert inventory["truncated"] == false

    [candidate] = inventory["candidates"]
    assert candidate["path"] == "test/risky_test.exs"
    assert candidate["classification"] == "candidate"
    assert candidate["score"] > 0
    assert digest?(candidate["source_fingerprint"])

    assert Enum.map(candidate["reasons"], & &1["code"]) == [
             "application_env_mutation",
             "explicit_test_serialization",
             "sleep_or_timer_wait"
           ]

    assert MapSet.new(candidate["targets"]) ==
             MapSet.new([
               %{
                 "application" => "example",
                 "key" => "mode",
                 "kind" => "application_env",
                 "lines" => [5],
                 "operation" => "put_env",
                 "oracle" => %{
                   "schema" => "insider.application-env-oracle/v1",
                   "inputs" => %{
                     "INSIDER_ORACLE_APPLICATION" => "example",
                     "INSIDER_ORACLE_KEY" => "mode"
                   }
                 },
                 "reason" => "unqualified_module",
                 "status" => "syntactic"
               }
             ])

    assert candidate["target_count"] == 1
    assert candidate["targets_truncated"] == false

    refute inspect(inventory) =~ "confirmed"
    refute inspect(inventory) =~ "defect"
    assert digest?(inventory["configuration_fingerprint"])
    assert digest?(inventory["source_fingerprint"])
  end

  test "reports unsupported syntax as an incomplete scan, never as clean" do
    root = fixture_root!(%{"test/broken_test.exs" => "defmodule Broken do ("})

    assert {:ok, inventory} = Inventory.scan(root)
    assert inventory["status"] == "unsupported_source"
    assert inventory["completeness"] == "unsupported_source"
    assert inventory["candidate_count"] == 0

    assert inventory["unsupported"] == [
             %{"path" => "test/broken_test.exs", "reason" => "invalid_elixir_syntax"}
           ]

    assert {output, 4} = InventoryCLI.run(["--root", root])
    assert {:ok, %{"status" => "unsupported_source"}} = Jason.decode(output)
  end

  test "reports a selection without eligible test files as empty, never as clean" do
    root = fixture_root!(%{"test/support/helpers.ex" => "defmodule Helpers do\nend\n"})

    assert {:ok, inventory} = Inventory.scan(root, paths: ["test/support"])
    assert inventory["status"] == "empty_selection"
    assert inventory["completeness"] == "empty_selection"
    assert inventory["eligible_file_count"] == 0
    assert inventory["candidate_count"] == 0

    assert {output, 3} = InventoryCLI.run(["--root", root, "--path", "test/support"])
    assert {:ok, %{"status" => "empty_selection"}} = Jason.decode(output)
  end

  test "keeps candidates found beside sources that could not be analyzed" do
    root =
      fixture_root!(%{
        "test/broken_test.exs" => "defmodule Broken do (",
        "test/risky_test.exs" => risky_source("Risky")
      })

    assert {:ok, inventory} = Inventory.scan(root)
    assert inventory["status"] == "unsupported_source"
    assert Enum.map(inventory["candidates"], & &1["path"]) == ["test/risky_test.exs"]
    assert inventory["eligible_file_count"] == 2
    assert inventory["scanned_file_count"] == 2

    assert {output, 4} = InventoryCLI.run(["--root", root])

    assert {:ok, %{"status" => "unsupported_source", "candidate_count" => 1}} =
             Jason.decode(output)
  end

  test "reports an exact non-test file and an empty directory as empty selections" do
    root = fixture_root!(%{"mix.exs" => "defmodule Project do\nend\n"})
    File.mkdir_p!(Path.join(root, "test/empty"))

    for selector <- ["mix.exs", "test/empty"] do
      assert {:ok, %{"status" => "empty_selection", "eligible_file_count" => 0}} =
               Inventory.scan(root, paths: [selector])
    end
  end

  test "is clean only when a complete scan exactly reaches its bounds without candidates" do
    source = """
    defmodule ExampleTest do
      use ExUnit.Case, async: true
      test "safe", do: assert(true)
    end
    """

    root = fixture_root!(%{"test/example_test.exs" => source})

    assert {:ok, inventory} =
             Inventory.scan(root, max_files: 1, max_total_bytes: byte_size(source))

    assert inventory["status"] == "clean"
    assert inventory["completeness"] == "complete"
    assert inventory["truncated"] == false
    assert inventory["unsupported"] == []
    assert inventory["scanned_file_count"] == 1

    assert {:ok, %{"status" => "truncated", "truncation_reasons" => ["byte_limit"]}} =
             Inventory.scan(root, max_total_bytes: byte_size(source) - 1)
  end

  test "reports candidate-limit truncation with the kept candidates" do
    root =
      fixture_root!(%{
        "test/a_test.exs" => risky_source("A"),
        "test/b_test.exs" => risky_source("B")
      })

    assert {:ok, %{"status" => "candidates", "candidate_count" => 2}} =
             Inventory.scan(root, max_candidates: 2)

    assert {output, 5} = InventoryCLI.run(["--root", root, "--max-candidates", "1"])

    assert {:ok,
            %{
              "status" => "truncated",
              "completeness" => "truncated",
              "candidate_count" => 1,
              "truncation_reasons" => ["candidate_limit"]
            }} = Jason.decode(output)
  end

  test "orders completeness by truncation, then unsupported source, then empty selection" do
    root =
      fixture_root!(%{
        "test/a_test.exs" => risky_source("A"),
        "test/b_test.exs" => risky_source("B"),
        "test/c_broken_test.exs" => "defmodule Broken do ("
      })

    assert {:ok, truncated} = Inventory.scan(root, max_candidates: 1)
    assert truncated["status"] == "truncated"
    assert [%{"reason" => "invalid_elixir_syntax"}] = truncated["unsupported"]

    outside = fixture_root!(%{"outside_test.exs" => risky_source("Outside")})
    File.mkdir_p!(Path.join(root, "test/links"))
    File.ln_s!(outside, Path.join(root, "test/links/outside"))

    assert {:ok, linked} = Inventory.scan(root, paths: ["test/links"])
    assert linked["status"] == "unsupported_source"
    assert linked["eligible_file_count"] == 0
  end

  test "does not treat source embedded in a string as an executable signal" do
    root =
      fixture_root!(%{
        "test/string_fixture_test.exs" => """
        defmodule StringFixtureTest do
          use ExUnit.Case, async: true

          test "analyzes source" do
            source = \"Application.put_env(:example, :key, :value)\"
            assert is_binary(source)
          end
        end
        """
      })

    assert {:ok, %{"candidate_count" => 0}} = Inventory.scan(root)
  end

  test "does not treat quoted source or similarly named APIs as executable signals" do
    root =
      fixture_root!(%{
        "test/quoted_test.exs" => """
        defmodule QuotedTest do
          use ExUnit.Case, async: true
          @example quote do: Application.put_env(:example, :key, :value)
          test "keeps an example", do: assert(@example)
        end
        """,
        "test/generic_api_test.exs" => """
        defmodule GenericApiTest do
          use ExUnit.Case, async: true
          test "calls an unrelated API" do
            Example.set_tracer_provider(:local)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidate_count" => 0}} = Inventory.scan(root)
  end

  test "marks dynamic application targets unresolved without retaining values" do
    root =
      fixture_root!(%{
        "test/dynamic_target_test.exs" => """
        defmodule DynamicTargetTest do
          use ExUnit.Case, async: true
          test "changes dynamic target" do
            application = :example
            Application.put_env(application, dynamic_key(), "do-not-retain")
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]} = inventory} = Inventory.scan(root)

    assert candidate["targets"] == [
             %{
               "kind" => "application_env",
               "lines" => [5],
               "operation" => "put_env",
               "oracle" => nil,
               "reason" => "dynamic_identity",
               "status" => "unresolved"
             }
           ]

    refute Jason.encode!(inventory) =~ "do-not-retain"
  end

  test "deduplicates matching targets and retains every call-site line" do
    root =
      fixture_root!(%{
        "test/duplicate_target_test.exs" => """
        defmodule DuplicateTargetTest do
          use ExUnit.Case, async: true
          test "changes one target twice" do
            Elixir.Application.put_env(:example, :"Elixir.Example.Config", :first)
            Elixir.Application.put_env(:example, :"Elixir.Example.Config", :second)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert candidate["target_count"] == 1

    assert [
             %{
               "application" => "example",
               "key" => "Elixir.Example.Config",
               "lines" => [4, 5],
               "status" => "resolved"
             }
           ] =
             candidate["targets"]
  end

  test "does not confuse a source tuple with an encoded static atom" do
    atom_name = "insider_uninterned_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    root =
      fixture_root!(%{
        "test/marker_collision_test.exs" => """
        defmodule MarkerCollisionTest do
          use ExUnit.Case, async: true
          test "uses distinct runtime keys" do
            Application.put_env(:example, :#{atom_name}, true)
            Application.put_env(:example, {:__insider_static_atom__, "#{atom_name}"}, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    assert MapSet.new(candidate["targets"]) ==
             MapSet.new([
               %{
                 "application" => "example",
                 "key" => atom_name,
                 "kind" => "application_env",
                 "lines" => [4],
                 "operation" => "put_env",
                 "oracle" => %{
                   "schema" => "insider.application-env-oracle/v1",
                   "inputs" => %{
                     "INSIDER_ORACLE_APPLICATION" => "example",
                     "INSIDER_ORACLE_KEY" => atom_name
                   }
                 },
                 "reason" => "unqualified_module",
                 "status" => "syntactic"
               },
               %{
                 "kind" => "application_env",
                 "lines" => [5],
                 "operation" => "put_env",
                 "oracle" => nil,
                 "reason" => "dynamic_identity",
                 "status" => "unresolved"
               }
             ])
  end

  test "rejects app-env evidence when Application is visibly shadowed" do
    root =
      fixture_root!(%{
        "test/shadowed_application_test.exs" => """
        defmodule ShadowedApplicationTest do
          use ExUnit.Case, async: true
          alias Example.NotApplication, as: Application
          test "calls another module" do
            Application.put_env(:claimed_app, :claimed_key, :value)
          end
        end
        """
      })

    assert {:ok, %{"candidate_count" => 0}} = Inventory.scan(root)
  end

  test "keeps Application shadow and declaration order when grouped aliases disable key resolution" do
    root =
      fixture_root!(%{
        "test/grouped_shadow_test.exs" => """
        defmodule GroupedShadowTest do
          use ExUnit.Case, async: true
          alias External.NotApplication, as: Application
          alias Unrelated.{First, Second}
          test "does not attribute the shadow" do
            Application.put_env(:example, :shadowed, true)
          end
        end
        defmodule LaterShadowTest do
          use ExUnit.Case, async: true
          test "keeps the earlier unshadowed call" do
            Application.put_env(:example, :unshadowed, true)
            alias Unrelated.{First, Second}
            alias External.NotApplication, as: Application
            Application.put_env(:example, :shadowed, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_mutation"]

    assert [%{"application" => "example", "key" => "unshadowed", "lines" => [12]}] =
             candidate["targets"]
  end

  test "keeps real aliases and confines nested shadows to their lexical scope" do
    root =
      fixture_root!(%{
        "test/grouped_real_test.exs" => """
        defmodule GroupedRealTest do
          use ExUnit.Case, async: true
          alias Elixir.{Application, Agent}
          test "keeps the real grouped alias" do
            Application.put_env(:example, :grouped, true)
          end
        end
        """,
        "test/chained_real_test.exs" => """
        defmodule ChainedRealTest do
          use ExUnit.Case, async: true
          alias Elixir.Application, as: App
          alias Unrelated.{First, Second}
          alias App, as: Application
          test "keeps the chained real alias" do
            Application.put_env(:example, :chained, true)
          end
        end
        """,
        "test/nested_function_test.exs" => """
        defmodule NestedFunctionTest do
          use ExUnit.Case, async: true
          test "keeps an outer call after a nested shadow" do
            fn ->
              alias Example.NotApplication, as: Application
              Application.put_env(:example, :nested_shadow, true)
            end
            Application.put_env(:example, :outer_function, true)
          end
        end
        """,
        "test/nested_module_test.exs" => """
        defmodule NestedModuleTest do
          use ExUnit.Case, async: true
          test "keeps an outer call after a nested module" do
            defmodule Nested do
              alias Example.NotApplication, as: Application
              def call, do: Application.put_env(:example, :nested_shadow, true)
            end
            Application.put_env(:example, :outer_module, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => candidates, "candidate_count" => 4}} =
             Inventory.scan(root)

    assert Map.new(candidates, fn candidate ->
             {Path.basename(candidate["path"]), Enum.map(candidate["targets"], & &1["key"])}
           end) == %{
             "grouped_real_test.exs" => ["grouped"],
             "chained_real_test.exs" => ["chained"],
             "nested_function_test.exs" => ["outer_function"],
             "nested_module_test.exs" => ["outer_module"]
           }
  end

  test "does not credit a shadowed Application cleanup for a qualified mutation" do
    root =
      fixture_root!(%{
        "test/shadowed_cleanup_test.exs" => """
        defmodule ShadowedCleanupTest do
          use ExUnit.Case, async: true
          alias Example.NotApplication, as: Application
          test "leaves the real application environment changed" do
            Elixir.Application.put_env(:example, :mode, :temporary)
            on_exit(fn -> Application.delete_env(:example, :mode) end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_mutation"]

    assert [%{"operation" => "put_env", "status" => "resolved", "lines" => [5]}] =
             candidate["targets"]
  end

  test "does not credit cleanup behind a callback-local Application shadow" do
    root =
      fixture_root!(%{
        "test/callback_shadow_test.exs" => """
        defmodule CallbackShadowTest do
          use ExUnit.Case, async: true
          test "keeps the real mutation visible" do
            Elixir.Application.put_env(:example, :mode, :temporary)
            on_exit(fn ->
              alias Example.NotApplication, as: Application
              Application.delete_env(:example, :mode)
            end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_mutation"]
    assert [%{"operation" => "put_env", "status" => "resolved"}] = candidate["targets"]
  end

  test "an Application alias in a sibling test does not hide a real cleanup" do
    root =
      fixture_root!(%{
        "test/sibling_tests_test.exs" => """
        defmodule SiblingTestsTest do
          use ExUnit.Case, async: true
          test "shadows only here" do
            alias Example.NotApplication, as: Application
            Application.put_env(:example, :mode, :ignored)
          end
          test "declares a real cleanup" do
            Elixir.Application.put_env(:example, :mode, :temporary)
            on_exit(fn -> Application.delete_env(:example, :mode) end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_cleanup_present"]
    assert [%{"operation" => "put_env", "lines" => [8]}] = candidate["targets"]
  end

  test "an Application alias in a sibling module does not hide a real cleanup" do
    root =
      fixture_root!(%{
        "test/sibling_modules_test.exs" => """
        defmodule ShadowSiblingTest do
          use ExUnit.Case, async: true
          alias Example.NotApplication, as: Application
          test "calls the shadow" do
            Application.put_env(:example, :mode, :ignored)
          end
        end
        defmodule CleanSiblingTest do
          use ExUnit.Case, async: true
          test "declares a real cleanup" do
            Elixir.Application.put_env(:example, :mode, :temporary)
            on_exit(fn -> Application.delete_env(:example, :mode) end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_cleanup_present"]
    assert [%{"operation" => "put_env", "lines" => [11]}] = candidate["targets"]
  end

  test "a same-test alias cannot impersonate cleanup after its declaration" do
    root =
      fixture_root!(%{
        "test/local_shadowed_cleanup_test.exs" => """
        defmodule LocalShadowedCleanupTest do
          use ExUnit.Case, async: true
          test "leaves the real application environment changed" do
            Elixir.Application.put_env(:example, :mode, :temporary)
            alias Example.NotApplication, as: Application
            on_exit(fn -> Application.delete_env(:example, :mode) end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_mutation"]
  end

  test "a later same-test alias does not shadow an earlier cleanup" do
    root =
      fixture_root!(%{
        "test/late_shadowed_cleanup_test.exs" => """
        defmodule LateShadowedCleanupTest do
          use ExUnit.Case, async: true
          test "registers cleanup before shadowing" do
            Elixir.Application.put_env(:example, :mode, :temporary)
            on_exit(fn -> Application.delete_env(:example, :mode) end)
            alias Example.NotApplication, as: Application
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_cleanup_present"]
  end

  test "resolves a module-body alias key without loading adopter code" do
    root =
      fixture_root!(%{
        "test/alias_key_test.exs" => """
        defmodule AliasKeyTest do
          use ExUnit.Case, async: true
          alias Other.Config, as: Config
          test "uses an alias-expanded key" do
            Elixir.Application.put_env(:example, Config.Value, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert candidate["targets"] == [
             %{
               "application" => "example",
               "key" => "Elixir.Other.Config.Value",
               "kind" => "application_env",
               "lines" => [5],
               "operation" => "put_env",
               "oracle" => %{
                 "schema" => "insider.application-env-oracle/v1",
                 "inputs" => %{
                   "INSIDER_ORACLE_APPLICATION" => "example",
                   "INSIDER_ORACLE_KEY" => "Elixir.Other.Config.Value"
                 }
               },
               "reason" => "lexical_alias_without_macro_expansion",
               "status" => "syntactic"
             }
           ]
  end

  test "resolves explicit aliases and fully qualified Elixir module forms" do
    root =
      fixture_root!(%{
        "test/alias_targets_test.exs" => """
        defmodule AliasTargetsTest do
          use ExUnit.Case, async: true
          alias Other.Deep.Config, as: RuntimeConfig
          test "uses static module keys" do
            Application.put_env(:example, RuntimeConfig, true)
            Application.put_env(:example, Example.Direct.Config, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert Enum.any?(candidate["targets"], fn target ->
             target["key"] == "Elixir.Other.Deep.Config" and
               target["status"] == "syntactic"
           end)

    assert Enum.any?(candidate["targets"], fn target ->
             target["status"] == "unresolved" and target["lines"] == [6]
           end)
  end

  test "resolves a bare single-segment alias without disabling its siblings" do
    root =
      fixture_root!(%{
        "test/single_segment_alias_test.exs" => """
        defmodule SingleSegmentAliasTest do
          use ExUnit.Case, async: true
          alias Other.Deep.Config, as: RuntimeConfig
          alias Standalone
          test "uses both alias forms" do
            Application.put_env(:example, RuntimeConfig, true)
            Application.put_env(:example, Standalone, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert Enum.any?(candidate["targets"], fn target ->
             target["key"] == "Elixir.Standalone" and target["status"] == "syntactic"
           end)

    # A bare `alias Standalone` must not disable resolution for unrelated
    # aliases declared in the same scope.
    assert Enum.any?(candidate["targets"], fn target ->
             target["key"] == "Elixir.Other.Deep.Config" and target["status"] == "syntactic"
           end)
  end

  test "keeps a single non-rebound alias unresolved only before its declaration" do
    root =
      fixture_root!(%{
        "test/alias_declaration_order_test.exs" => """
        defmodule AliasDeclarationOrderTest do
          use ExUnit.Case, async: true
          test "precedes the declaration" do
            Application.put_env(:example, Config, true)
          end
          alias First.Config, as: Config
          test "follows the declaration" do
            Application.put_env(:example, Config, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    # The name is declared exactly once, so this isolates the ordering rule
    # from the ambiguous-rebind path, which rejects on a different branch.
    assert Enum.any?(candidate["targets"], fn target ->
             target["status"] == "unresolved" and target["lines"] == [4]
           end)

    assert Enum.any?(candidate["targets"], fn target ->
             target["key"] == "Elixir.First.Config" and target["status"] == "syntactic" and
               target["lines"] == [8]
           end)
  end

  test "keeps aliases unresolved before declaration and after rebinding" do
    root =
      fixture_root!(%{
        "test/unsafe_alias_targets_test.exs" => """
        defmodule UnsafeAliasTargetsTest do
          use ExUnit.Case, async: true
          test "precedes the declaration" do
            Application.put_env(:example, Config, true)
          end
          alias First.Config, as: Config
          alias Second.Config, as: Config
          test "follows a conflicting rebind" do
            Application.put_env(:example, Config, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert [%{"reason" => "dynamic_identity", "lines" => [4, 9]}] = candidate["targets"]
  end

  test "does not leak an alias declared inside a sibling lexical scope" do
    root =
      fixture_root!(%{
        "test/scoped_alias_target_test.exs" => """
        defmodule ScopedAliasTargetTest do
          use ExUnit.Case, async: true
          test "declares a local alias" do
            alias Hidden.Config, as: Config
            Application.put_env(:example, Config, true)
          end
          test "cannot see the sibling alias" do
            Application.put_env(:example, Config, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert MapSet.new(candidate["targets"]) ==
             MapSet.new([
               %{
                 "application" => "example",
                 "key" => "Elixir.Hidden.Config",
                 "kind" => "application_env",
                 "lines" => [5],
                 "operation" => "put_env",
                 "oracle" => %{
                   "schema" => "insider.application-env-oracle/v1",
                   "inputs" => %{
                     "INSIDER_ORACLE_APPLICATION" => "example",
                     "INSIDER_ORACLE_KEY" => "Elixir.Hidden.Config"
                   }
                 },
                 "reason" => "lexical_alias_without_macro_expansion",
                 "status" => "syntactic"
               },
               %{
                 "kind" => "application_env",
                 "lines" => [8],
                 "operation" => "put_env",
                 "oracle" => nil,
                 "reason" => "dynamic_identity",
                 "status" => "unresolved"
               }
             ])
  end

  test "keeps grouped aliases and their enclosing scope unresolved" do
    root =
      fixture_root!(%{
        "test/unsupported_alias_targets_test.exs" => """
        defmodule UnsupportedAliasTargetsTest do
          use ExUnit.Case, async: true
          alias Outer.{First, Second}
          test "uses unsupported aliases" do
            alias Hidden.Config, as: Local
            Application.put_env(:example, First.Value, true)
            Application.put_env(:example, Local.Value, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert [%{"reason" => "dynamic_identity", "lines" => [6, 7]}] = candidate["targets"]
  end

  test "emits alias strings without interning adopter module atoms" do
    segment = "InsiderUninternedAlias#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(segment) end

    root =
      fixture_root!(%{
        "test/uninterned_alias_target_test.exs" => """
        defmodule UninternedAliasTargetTest do
          use ExUnit.Case, async: true
          alias #{segment}.Config, as: RuntimeConfig
          test "uses an uninterned alias" do
            Application.put_env(:example, RuntimeConfig, "not-retained")
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]} = inventory} = Inventory.scan(root)
    assert_raise ArgumentError, fn -> String.to_existing_atom(segment) end
    expected_key = "Elixir.#{segment}.Config"
    assert [%{"key" => ^expected_key}] = candidate["targets"]
    refute Jason.encode!(inventory) =~ "not-retained"
  end

  test "resolves visible chained aliases syntactically" do
    root =
      fixture_root!(%{
        "test/chained_alias_target_test.exs" => """
        defmodule ChainedAliasTargetTest do
          use ExUnit.Case, async: true
          alias Actual.Root, as: Prefix
          alias Prefix.Config, as: RuntimeConfig
          test "uses the chained alias" do
            Elixir.Application.put_env(:example, RuntimeConfig, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert [
             %{
               "key" => "Elixir.Actual.Root.Config",
               "reason" => "lexical_alias_without_macro_expansion",
               "status" => "syntactic"
             }
           ] = candidate["targets"]
  end

  test "does not guess a multi-segment key that a macro could alias" do
    root =
      fixture_root!(%{
        "test/macro_alias_target_test.exs" => """
        defmodule MacroAliasTargetTest do
          use Example.Case
          test "uses a possibly injected alias" do
            Elixir.Application.put_env(:example, Config.Value, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert [%{"reason" => "dynamic_identity", "status" => "unresolved"}] = candidate["targets"]
  end

  test "uses source columns for same-line alias declaration order" do
    root =
      fixture_root!(%{
        "test/same_line_alias_target_test.exs" => """
        defmodule SameLineAliasTargetTest do
          use ExUnit.Case, async: true
          test "declares then uses" do
            alias SameLine.Config, as: Config; Application.put_env(:example, Config, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert [%{"key" => "Elixir.SameLine.Config", "status" => "syntactic"}] = candidate["targets"]
  end

  test "resolves local aliases independently across top-level modules" do
    root =
      fixture_root!(%{
        "test/multiple_modules_test.exs" => """
        defmodule FirstAliasTest do
          use ExUnit.Case, async: true
          test "uses a local alias" do
            alias First.Config, as: Config
            Application.put_env(:example, Config, true)
          end
        end
        defmodule SecondAliasTest do
          use ExUnit.Case, async: true
          test "uses another local alias" do
            alias Second.Config, as: Config
            Application.put_env(:example, Config, true)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert MapSet.new(Enum.map(candidate["targets"], &{&1["key"], &1["lines"], &1["status"]})) ==
             MapSet.new([
               {"Elixir.First.Config", [5], "syntactic"},
               {"Elixir.Second.Config", [12], "syntactic"}
             ])
  end

  test "fails closed when a nested scope shadows a visible alias" do
    root =
      fixture_root!(%{
        "test/nested_shadow_test.exs" => """
        defmodule NestedShadowTest do
          use ExUnit.Case, async: true
          test "nests a shadowing alias" do
            alias Visible.Config, as: Config
            fn ->
              alias Hidden.Config, as: Config
              Elixir.Application.put_env(:example, Config, "not-retained")
            end.()
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]} = inventory} = Inventory.scan(root)
    assert [%{"reason" => "dynamic_identity", "status" => "unresolved"}] = candidate["targets"]
    refute Jason.encode!(inventory) =~ "not-retained"
  end

  test "fails closed when a grouped alias rebinds a visible alias" do
    root =
      fixture_root!(%{
        "test/grouped_rebind_test.exs" => """
        defmodule GroupedRebindTest do
          use ExUnit.Case, async: true
          alias Visible.First, as: First
          alias Hidden.{First, Second}
          test "uses the rebound alias" do
            Elixir.Application.put_env(:example, First, "not-retained")
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]} = inventory} = Inventory.scan(root)
    assert [%{"reason" => "dynamic_identity", "status" => "unresolved"}] = candidate["targets"]
    refute Jason.encode!(inventory) =~ "not-retained"
  end

  test "fails closed for aliases in unsupported enclosing blocks" do
    root =
      fixture_root!(%{
        "test/enclosing_alias_test.exs" => """
        defmodule EnclosingAliasTest do
          use ExUnit.Case, async: true
          alias Visible.Config, as: Config
          if true do
            alias Hidden.Config, as: Config
            test "uses the nested alias" do
              Elixir.Application.put_env(:example, Config, "not-retained")
            end
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]} = inventory} = Inventory.scan(root)
    assert [%{"reason" => "dynamic_identity", "status" => "unresolved"}] = candidate["targets"]
    refute Jason.encode!(inventory) =~ "not-retained"
  end

  test "correlates root-qualified application cleanup in the same scope" do
    root =
      fixture_root!(%{
        "test/qualified_cleanup_test.exs" => """
        defmodule QualifiedCleanupTest do
          use ExUnit.Case, async: true
          test "restores a literal target" do
            Elixir.Application.put_env(:example, :mode, true)
            on_exit(fn -> Elixir.Application.delete_env(:example, :mode) end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert Enum.map(candidate["reasons"], & &1["code"]) == [
             "application_env_cleanup_present"
           ]

    assert [%{"status" => "resolved", "application" => "example", "key" => "mode"}] =
             candidate["targets"]
  end

  test "emits static telemetry handler identities beside the attached event" do
    mutations =
      Enum.map_join(1..3, "\n", fn index ->
        "Application.put_env(:example, :target_#{index}, true)"
      end)

    root =
      fixture_root!(%{
        "test/bounded_targets_test.exs" => """
        defmodule BoundedTargetsTest do
          use ExUnit.Case, async: true
          test "changes many targets" do
            :telemetry.attach(:known_handler, [:example], fn _, _, _, _ -> :ok end, nil)
            #{mutations}
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert candidate["target_count"] == 5
    refute candidate["targets_truncated"]

    assert [
             %{
               "handler" => "known_handler",
               "kind" => "telemetry_handler",
               "lines" => [4],
               "operation" => "attach",
               "oracle" => nil,
               "status" => "resolved"
             }
           ] = Enum.filter(candidate["targets"], &(&1["kind"] == "telemetry_handler"))

    assert [
             %{
               "event" => ["example"],
               "kind" => "telemetry_event",
               "lines" => [4],
               "operation" => "attach",
               "oracle" => %{
                 "schema" => "insider.telemetry-dead-handlers-oracle/v1",
                 "inputs" => %{"INSIDER_ORACLE_TELEMETRY_EVENT" => "example"}
               },
               "status" => "resolved"
             }
           ] = Enum.filter(candidate["targets"], &(&1["kind"] == "telemetry_event"))
  end

  test "emits one resolved telemetry_event target per literal captured event" do
    root =
      fixture_root!(%{
        "test/telemetry_capture_test.exs" => """
        defmodule TelemetryCaptureTest do
          use ExUnit.Case, async: true
          setup do
            :telemetry_test.attach_event_handlers(self(), [
              [:example, :request, :stop],
              [:example, :query, :exception]
            ])
            :ok
          end
          test "observes", do: assert(true)
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["global_telemetry_handler"]
    assert candidate["target_count"] == 2

    assert MapSet.new(candidate["targets"]) ==
             MapSet.new([
               %{
                 "event" => ["example", "request", "stop"],
                 "kind" => "telemetry_event",
                 "lines" => [4],
                 "operation" => "attach_event_handlers",
                 "oracle" => %{
                   "schema" => "insider.telemetry-dead-handlers-oracle/v1",
                   "inputs" => %{"INSIDER_ORACLE_TELEMETRY_EVENT" => "example,request,stop"}
                 },
                 "status" => "resolved"
               },
               %{
                 "event" => ["example", "query", "exception"],
                 "kind" => "telemetry_event",
                 "lines" => [4],
                 "operation" => "attach_event_handlers",
                 "oracle" => %{
                   "schema" => "insider.telemetry-dead-handlers-oracle/v1",
                   "inputs" => %{"INSIDER_ORACLE_TELEMETRY_EVENT" => "example,query,exception"}
                 },
                 "status" => "resolved"
               }
             ])
  end

  test "does not credit a literal detach as cleanup for a reference-identified capture" do
    root =
      fixture_root!(%{
        "test/telemetry_capture_cleanup_test.exs" => """
        defmodule TelemetryCaptureCleanupTest do
          use ExUnit.Case, async: true
          test "captures and detaches something else" do
            ref = :telemetry_test.attach_event_handlers(self(), [[:example, :event]])
            on_exit(fn -> :telemetry.detach(ref) end)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["global_telemetry_handler"]

    assert [%{"kind" => "telemetry_event", "event" => ["example", "event"]}] =
             candidate["targets"]
  end

  test "marks dynamic telemetry event lists and elements unresolved without an oracle hint" do
    root =
      fixture_root!(%{
        "test/dynamic_telemetry_test.exs" => """
        defmodule DynamicTelemetryTest do
          use ExUnit.Case, async: true
          test "captures dynamic events" do
            events = [[:example, :"do-not-retain"]]
            :telemetry_test.attach_event_handlers(self(), events)
          end
          test "captures a partly dynamic list" do
            :telemetry_test.attach_event_handlers(self(), [[:example, :literal], dynamic(), other()])
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]} = inventory} = Inventory.scan(root)

    assert MapSet.new(candidate["targets"]) ==
             MapSet.new([
               %{
                 "kind" => "telemetry_event",
                 "lines" => [5, 8],
                 "operation" => "attach_event_handlers",
                 "oracle" => nil,
                 "reason" => "dynamic_identity",
                 "status" => "unresolved"
               },
               %{
                 "event" => ["example", "literal"],
                 "kind" => "telemetry_event",
                 "lines" => [8],
                 "operation" => "attach_event_handlers",
                 "oracle" => %{
                   "schema" => "insider.telemetry-dead-handlers-oracle/v1",
                   "inputs" => %{"INSIDER_ORACLE_TELEMETRY_EVENT" => "example,literal"}
                 },
                 "status" => "resolved"
               }
             ])

    refute Jason.encode!(inventory) =~ "do-not-retain"
  end

  test "emits telemetry_event and telemetry_handler targets for attach_many" do
    root =
      fixture_root!(%{
        "test/attach_many_test.exs" => """
        defmodule AttachManyTest do
          use ExUnit.Case, async: true
          test "attaches many" do
            :telemetry.attach_many(
              :many_handler,
              [[:example, :one], [:example, :two]],
              fn _, _, _, _ -> :ok end,
              nil
            )
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert candidate["target_count"] == 3

    assert Enum.sort(Enum.map(candidate["targets"], &{&1["kind"], &1["handler"], &1["event"]})) ==
             [
               {"telemetry_event", nil, ["example", "one"]},
               {"telemetry_event", nil, ["example", "two"]},
               {"telemetry_handler", "many_handler", nil}
             ]

    assert Enum.all?(candidate["targets"], &(&1["operation"] == "attach_many"))
  end

  test "deduplicates the same captured event across tests and retains both lines" do
    root =
      fixture_root!(%{
        "test/shared_event_test.exs" => """
        defmodule SharedEventTest do
          use ExUnit.Case, async: true
          test "first capture" do
            :telemetry_test.attach_event_handlers(self(), [[:example, :shared]])
          end
          test "second capture" do
            :telemetry_test.attach_event_handlers(self(), [[:example, :shared]])
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert candidate["target_count"] == 1
    assert [%{"event" => ["example", "shared"], "lines" => [4, 7]}] = candidate["targets"]
  end

  test "omits an oracle hint when the artifact cannot accept the encoded event" do
    root =
      fixture_root!(%{
        "test/unencodable_event_test.exs" => """
        defmodule UnencodableEventTest do
          use ExUnit.Case, async: true
          test "uses a comma in a segment" do
            :telemetry_test.attach_event_handlers(self(), [[:example, :"with,comma"]])
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert [%{"event" => ["example", "with,comma"], "oracle" => nil, "status" => "resolved"}] =
             candidate["targets"]
  end

  test "omits an oracle hint when a name holds a control character the environment rejects" do
    root =
      fixture_root!(%{
        "test/control_character_name_test.exs" => """
        defmodule ControlCharacterNameTest do
          use ExUnit.Case, async: true
          test "uses names with NUL and tab bytes" do
            Application.put_env(:example, :"with\\0nul", true)
            :telemetry_test.attach_event_handlers(self(), [[:example, :"with\\ttab"]])
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert [
             %{
               "application" => "example",
               "key" => <<"with", 0, "nul">>,
               "kind" => "application_env",
               "oracle" => nil,
               "status" => "syntactic"
             },
             %{
               "event" => ["example", "with\ttab"],
               "kind" => "telemetry_event",
               "oracle" => nil,
               "status" => "resolved"
             }
           ] = Enum.sort_by(candidate["targets"], & &1["kind"])
  end

  test "bounds telemetry event targets deterministically" do
    events = Enum.map_join(1..65, ",\n", fn index -> "[:example, :event_#{index}]" end)

    root =
      fixture_root!(%{
        "test/many_events_test.exs" => """
        defmodule ManyEventsTest do
          use ExUnit.Case, async: true
          test "captures many events" do
            :telemetry_test.attach_event_handlers(self(), [
              #{events}
            ])
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [first]} = inventory} = Inventory.scan(root)
    assert {:ok, ^inventory} = Inventory.scan(root)
    assert first["target_count"] == 64
    assert first["targets_truncated"]
    assert Enum.all?(first["targets"], &(&1["kind"] == "telemetry_event"))
  end

  test "bounds the number of emitted target identities" do
    mutations =
      Enum.map_join(1..65, "\n", fn index ->
        "Application.put_env(:example, :target_#{index}, true)"
      end)

    root =
      fixture_root!(%{
        "test/bounded_targets_test.exs" => """
        defmodule BoundedTargetsTest do
          use ExUnit.Case, async: true
          test "changes many targets" do
            #{mutations}
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert candidate["target_count"] == 64
    assert candidate["targets_truncated"]
  end

  test "distinguishes declared cleanup and flags restoration that destroys absence" do
    root =
      fixture_root!(%{
        "test/exact_cleanup_test.exs" => """
        defmodule ExactCleanupTest do
          use ExUnit.Case, async: false
          setup do
            original = Application.get_env(:example, :key)
            Application.put_env(:example, :key, :temporary)
            on_exit(fn ->
              if original == nil do
                Application.delete_env(:example, :key)
              else
                Application.put_env(:example, :key, original)
              end
            end)
            :ok
          end
        end
        """,
        "test/lossy_cleanup_test.exs" => """
        defmodule LossyCleanupTest do
          use ExUnit.Case, async: false
          setup do
            prior = Application.get_env(:example, :key)
            Application.put_env(:example, :key, :temporary)
            on_exit(fn -> Application.put_env(:example, :key, prior || []) end)
            :ok
          end
        end
        """
      })

    assert {:ok, inventory} = Inventory.scan(root)
    candidates = Map.new(inventory["candidates"], &{&1["path"], &1})

    exact_codes = Enum.map(candidates["test/exact_cleanup_test.exs"]["reasons"], & &1["code"])
    lossy_codes = Enum.map(candidates["test/lossy_cleanup_test.exs"]["reasons"], & &1["code"])

    assert "application_env_cleanup_present" in exact_codes
    assert "application_env_absence_not_restored" in lossy_codes

    assert candidates["test/lossy_cleanup_test.exs"]["score"] >
             candidates["test/exact_cleanup_test.exs"]["score"]
  end

  test "a second delete_env does not restore an environment entry" do
    root =
      fixture_root!(%{
        "test/repeated_delete_test.exs" => """
        defmodule RepeatedDeleteTest do
          use ExUnit.Case, async: true
          test "deletes twice" do
            Elixir.Application.delete_env(:example, :mode)
            on_exit(fn -> Elixir.Application.delete_env(:example, :mode) end)
          end
        end
        """,
        "test/restore_deleted_test.exs" => """
        defmodule RestoreDeletedTest do
          use ExUnit.Case, async: true
          test "declares restoring the saved value" do
            original = Elixir.Application.get_env(:example, :mode)
            Elixir.Application.delete_env(:example, :mode)
            on_exit(fn -> Elixir.Application.put_env(:example, :mode, original) end)
          end
        end
        """
      })

    assert {:ok, %{"candidates" => candidates}} = Inventory.scan(root)
    by_path = Map.new(candidates, &{&1["path"], &1})

    assert Enum.map(by_path["test/repeated_delete_test.exs"]["reasons"], & &1["code"]) ==
             ["application_env_mutation"]

    assert Enum.map(by_path["test/restore_deleted_test.exs"]["reasons"], & &1["code"]) ==
             ["application_env_cleanup_present"]
  end

  test "only downgrades application mutations with matching cleanup" do
    root =
      fixture_root!(%{
        "test/mismatched_cleanup_test.exs" => """
        defmodule MismatchedCleanupTest do
          use ExUnit.Case, async: true
          setup do
            Application.put_env(:example, :changed, true)
            on_exit(fn -> Application.delete_env(:example, :other) end)
            :ok
          end
          test "runs", do: assert(true)
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_mutation"]
  end

  test "does not credit same-key cleanup owned by a different test" do
    root =
      fixture_root!(%{
        "test/cross_test_cleanup_test.exs" => """
        defmodule CrossTestCleanupTest do
          use ExUnit.Case, async: true
          test "mutates" do
            Application.put_env(:example, :shared, true)
          end
          test "unrelated owner" do
            on_exit(fn -> Application.delete_env(:example, :shared) end)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["application_env_mutation"]
  end

  test "recognizes tests built on application case templates" do
    root =
      fixture_root!(%{
        "test/data_case_test.exs" => """
        defmodule Example.DataCaseTest do
          use Example.DataCase, async: true

          test "waits for work" do
            Process.sleep(5)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert candidate["path"] == "test/data_case_test.exs"
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["sleep_or_timer_wait"]
  end

  test "downgrades telemetry attachment when matching cleanup is declared" do
    root =
      fixture_root!(%{
        "test/telemetry_test.exs" => """
        defmodule Example.TelemetryTest do
          use ExUnit.Case, async: true

          test "observes an event" do
            id = {:handler, System.unique_integer()}
            :telemetry.attach(id, [:example], fn _, _, _, _ -> :ok end, nil)
            on_exit(fn -> :telemetry.detach(id) end)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)

    assert Enum.map(candidate["reasons"], & &1["code"]) == [
             "global_telemetry_cleanup_present"
           ]

    assert candidate["score"] == 1
  end

  test "does not downgrade a telemetry attachment with mismatched cleanup" do
    root =
      fixture_root!(%{
        "test/telemetry_test.exs" => """
        defmodule Example.TelemetryTest do
          use ExUnit.Case, async: true
          test "observes an event" do
            :telemetry.attach(:live_handler, [:example], fn _, _, _, _ -> :ok end, nil)
            on_exit(fn -> :telemetry.detach(:different_handler) end)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["global_telemetry_handler"]
  end

  test "recognizes known OpenTelemetry global capture APIs" do
    root =
      fixture_root!(%{
        "test/otel_test.exs" => """
        defmodule Example.OtelTest do
          use ExUnit.Case, async: true
          test "replaces shared tracing state" do
            OpenTelemetry.set_tracer_provider(:test_provider)
            assert true
          end
        end
        """
      })

    assert {:ok, %{"candidates" => [candidate]}} = Inventory.scan(root)
    assert Enum.map(candidate["reasons"], & &1["code"]) == ["otel_global_capture"]
  end

  test "is deterministic and reports file-limit truncation" do
    root =
      fixture_root!(%{
        "test/a_test.exs" => risky_source("A"),
        "test/b_test.exs" => risky_source("B")
      })

    assert {:ok, first} = Inventory.scan(root, max_files: 1)
    assert {:ok, second} = Inventory.scan(root, max_files: 1)
    assert first == second
    assert first["status"] == "truncated"
    assert first["completeness"] == "truncated"
    assert first["truncated"]
    assert first["truncation_reasons"] == ["file_limit"]
    assert first["scanned_file_count"] == 1
    assert first["candidate_count"] == 1
  end

  test "rejects malformed keyword option lists as invalid input" do
    root = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})

    assert {:error, :invalid_options} =
             Inventory.scan(root, [{:max_files, 1}, :not_a_keyword_pair])
  end

  test "rejects selectors outside the declared repository root" do
    root = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})

    assert {:error, :selector_outside_root} = Inventory.scan(root, paths: ["../outside"])
  end

  test "rejects missing selectors instead of reporting a false clean result" do
    root = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})
    assert {:error, :selector_not_found} = Inventory.scan(root, paths: ["test/missing"])
  end

  test "validates every selector before file-limit truncation" do
    root =
      fixture_root!(%{
        "test/a_test.exs" => risky_source("A"),
        "test/b_test.exs" => risky_source("B")
      })

    assert {:error, :selector_not_found} =
             Inventory.scan(root, paths: ["test", "missing"], max_files: 1)
  end

  test "supports repeated exact selectors" do
    root =
      fixture_root!(%{
        "test/a_test.exs" => risky_source("A"),
        "test/b_test.exs" => risky_source("B")
      })

    assert {output, 2} =
             InventoryCLI.run([
               "--root",
               root,
               "--path",
               "test/a_test.exs",
               "--path",
               "test/b_test.exs"
             ])

    assert {:ok, %{"candidate_count" => 2}} = Jason.decode(output)
  end

  test "rejects repeated scalar CLI switches while retaining repeatable paths" do
    root = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})

    for {switch, first, second} <- [
          {"--root", root, root},
          {"--max-files", "1", "2"},
          {"--max-bytes", "1024", "2048"},
          {"--max-candidates", "1", "2"},
          {"--max-duration-ms", "100", "200"}
        ] do
      assert {output, 64} =
               InventoryCLI.run(["--root", root, switch, first, switch, second])

      assert {:ok,
              %{
                "schema" => "insider.exunit-candidate-inventory-error/v1",
                "status" => "invalid_input",
                "reason" => "invalid_arguments"
              }} = Jason.decode(output)
    end
  end

  test "does not follow a nested directory symlink outside the declared root" do
    root = fixture_root!(%{"test/inside_test.exs" => risky_source("Inside")})
    outside = fixture_root!(%{"outside_test.exs" => risky_source("Outside")})
    File.ln_s!(outside, Path.join(root, "test/linked"))

    assert {:ok, inventory} = Inventory.scan(root)
    assert inventory["status"] == "unsupported_source"
    assert Enum.map(inventory["candidates"], & &1["path"]) == ["test/inside_test.exs"]

    assert inventory["unsupported"] == [
             %{"path" => "test/linked", "reason" => "symlink_not_scanned"}
           ]

    refute inspect(inventory) =~ "outside_test.exs"
  end

  test "rejects an exact selector reached through an intermediate symlink" do
    root = fixture_root!(%{"test/inside_test.exs" => risky_source("Inside")})
    outside = fixture_root!(%{"escaped_test.exs" => risky_source("Escaped")})
    File.ln_s!(outside, Path.join(root, "test/linked"))

    assert {:error, :selector_symlink} =
             Inventory.scan(root, paths: ["test/linked/escaped_test.exs"])
  end

  test "rejects a symlink as the declared repository root" do
    target = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})
    link = Path.join(System.tmp_dir!(), "insider-root-link-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(link) end)
    File.ln_s!(target, link)

    assert {:error, :invalid_root} = Inventory.scan(link)
  end

  test "accounts actual bytes and stops before parsing beyond the byte bound" do
    root = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})
    assert {:ok, inventory} = Inventory.scan(root, max_total_bytes: 8)
    assert inventory["status"] == "truncated"
    assert inventory["truncation_reasons"] == ["byte_limit"]
    assert inventory["eligible_file_count"] == 1
    assert inventory["scanned_file_count"] == 0
    assert inventory["scanned_bytes"] == 0
  end

  test "parsing source does not intern previously unseen atoms" do
    unique = "insider_untrusted_atom_#{System.unique_integer([:positive])}"
    refute existing_atom?(unique)

    root =
      fixture_root!(%{
        "test/atom_test.exs" => """
        defmodule AtomTest do
          use ExUnit.Case, async: false
          test "contains identifier", do: #{unique}(:#{unique})
        end
        """
      })

    assert {:ok, _inventory} = Inventory.scan(root)
    refute existing_atom?(unique)
  end

  test "CLI emits one JSON result and a stable candidate exit status" do
    root = fixture_root!(%{"test/example_test.exs" => risky_source("Example")})

    assert {output, 2} = InventoryCLI.run(["--root", root])
    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["schema"] == "insider.exunit-candidate-inventory/v2"
    assert decoded["status"] == "candidates"
    assert decoded["completeness"] == "complete"
  end

  test "CLI distinguishes clean, invalid input, and inventory failure" do
    clean_root =
      fixture_root!(%{
        "test/example_test.exs" => """
        defmodule ExampleTest do
          use ExUnit.Case, async: true
          test "safe", do: assert(true)
        end
        """
      })

    assert {clean_output, 0} = InventoryCLI.run(["--root", clean_root])

    assert {:ok, %{"status" => "clean", "completeness" => "complete"}} =
             Jason.decode(clean_output)

    assert {invalid_output, 64} = InventoryCLI.run(["--unknown"])
    assert {:ok, %{"status" => "invalid_input"}} = Jason.decode(invalid_output)

    assert {failure_output, 70} = InventoryCLI.run(["--root", Path.join(clean_root, "missing")])

    assert {:ok,
            %{
              "status" => "failed",
              "completeness" => "infrastructure_failure",
              "reason" => "invalid_root"
            }} = Jason.decode(failure_output)

    assert {invalid_bound_output, 64} = InventoryCLI.run(["--max-files", "0"])

    assert {:ok, %{"status" => "invalid_input", "reason" => "invalid_options"}} =
             Jason.decode(invalid_bound_output)
  end

  defp fixture_root!(files) do
    root = Path.join(System.tmp_dir!(), "insider-inventory-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(files, fn {path, contents} ->
      destination = Path.join(root, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, contents)
    end)

    root
  end

  defp risky_source(module) do
    """
    defmodule Example.#{module}Test do
      use ExUnit.Case, async: false
      test "candidate", do: assert(true)
    end
    """
  end

  defp digest?("sha256:" <> digest), do: byte_size(digest) == 64
  defp digest?(_value), do: false

  defp existing_atom?(value) do
    String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
