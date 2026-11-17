%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      files: %{
        included: ["lib/", "test/", "fixtures/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.Specs, files: %{excluded: ["test/"]}},
          # Lifecycle tests need an explicit upper bound; reject only short
          # ad-hoc values that tend to become timing-dependent flakes.
          {Jump.CredoChecks.AssertReceiveTimeout, min_assert_receive_timeout: 1_000},
          {Jump.CredoChecks.AvoidFunctionLevelElse, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          {Jump.CredoChecks.ConditionalAssertion, []},
          {Jump.CredoChecks.SafeBinaryToTerm, []},
          {Jump.CredoChecks.TestHasNoAssertions, []},
          {Jump.CredoChecks.TopLevelAliasImportRequire, []},
          {Jump.CredoChecks.WeakAssertion, []},
          # Repository-contract tests execute hooks and inspect workflow files;
          # they intentionally do not call the shipped Insider runtime.
          {Jump.CredoChecks.VacuousTest,
           files: %{excluded: ["test/guardrails_test.exs"]}}
        ] ++ Enum.map(ExSlop.recommended_checks(), &{&1, []}),
        disabled: [
          {Credo.Check.Readability.SinglePipe, []}
        ]
      }
    }
  ]
}
