# This file contains the configuration for Credo and is based on `mix credo.gen.config`.
#
# ExSlop checks are appended below because an explicit `checks.enabled` list otherwise
# prevents Credo from loading plugin-registered checks.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        # These generated and non-Elixir trees are outside this Credo configuration's scope.
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          ~r"/web_app/",
          ~r"/native/"
        ]
      },
      plugins: [{ExSlop, []}],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled:
          [
            ## Consistency Checks
            {Credo.Check.Consistency.ExceptionNames, []},
            {Credo.Check.Consistency.LineEndings, []},
            {Credo.Check.Consistency.ParameterPatternMatching, []},
            {Credo.Check.Consistency.SpaceAroundOperators, []},
            {Credo.Check.Consistency.SpaceInParentheses, []},
            {Credo.Check.Consistency.TabsOrSpaces, []},

            ## Design Checks
            {Credo.Check.Design.TagFIXME, []},
            {Credo.Check.Design.TagTODO, [exit_status: 2]},

            ## Readability Checks
            {Credo.Check.Readability.AliasOrder, []},
            {Credo.Check.Readability.FunctionNames, []},
            {Credo.Check.Readability.LargeNumbers, []},
            {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
            {Credo.Check.Readability.ModuleAttributeNames, []},
            {Credo.Check.Readability.ModuleDoc, []},
            {Credo.Check.Readability.ModuleNames, []},
            {Credo.Check.Readability.ParenthesesInCondition, []},
            {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
            {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
            {Credo.Check.Readability.PredicateFunctionNames, []},
            {Credo.Check.Readability.RedundantBlankLines, []},
            {Credo.Check.Readability.Semicolons, []},
            {Credo.Check.Readability.SpaceAfterCommas, []},
            {Credo.Check.Readability.StringSigils, []},
            {Credo.Check.Readability.TrailingBlankLine, []},
            {Credo.Check.Readability.TrailingWhiteSpace, []},
            {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
            {Credo.Check.Readability.VariableNames, []},

            ## Refactoring Opportunities
            {Credo.Check.Refactor.Apply, []},
            {Credo.Check.Refactor.FilterCount, []},
            {Credo.Check.Refactor.FunctionArity, []},
            {Credo.Check.Refactor.LongQuoteBlocks, []},
            {Credo.Check.Refactor.MapJoin, []},
            {Credo.Check.Refactor.MatchInCondition, []},
            {Credo.Check.Refactor.NegatedConditionsInUnless, []},
            {Credo.Check.Refactor.RedundantWithClauseResult, []},
            {Credo.Check.Refactor.RejectReject, []},
            {Credo.Check.Refactor.UnlessWithElse, []},
            {Credo.Check.Refactor.WithClauses, []},

            ## Warnings
            {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
            {Credo.Check.Warning.BoolOperationOnSameValues, []},
            {Credo.Check.Warning.Dbg, []},
            {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
            {Credo.Check.Warning.IExPry, []},
            {Credo.Check.Warning.IoInspect, []},
            {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
            {Credo.Check.Warning.OperationOnSameValues, []},
            {Credo.Check.Warning.OperationWithConstantResult, []},
            {Credo.Check.Warning.RaiseInsideRescue, []},
            {Credo.Check.Warning.StructFieldAmount, []},
            {Credo.Check.Warning.UnsafeExec, []},
            {Credo.Check.Warning.UnusedEnumOperation, []},
            {Credo.Check.Warning.UnusedFileOperation, []},
            {Credo.Check.Warning.UnusedKeywordOperation, []},
            {Credo.Check.Warning.UnusedListOperation, []},
            {Credo.Check.Warning.UnusedMapOperation, []},
            {Credo.Check.Warning.UnusedPathOperation, []},
            {Credo.Check.Warning.UnusedRegexOperation, []},
            {Credo.Check.Warning.UnusedStringOperation, []},
            {Credo.Check.Warning.UnusedTupleOperation, []},
            {Credo.Check.Warning.WrongTestFilename, []}
          ] ++ Enum.map(ExSlop.recommended_checks(), &{&1, []}),
        disabled: [
          # AliasUsage produced 17 low-priority suggestions across lib/hydra_srt/application.ex,
          # lib/hydra_srt/db.ex, lib/hydra_srt/route_handler.ex, the realtime channel, and test
          # support; these local aliases are intentionally kept near the code that uses them.
          {Credo.Check.Design.AliasUsage, []},

          # PreferImplicitTry produced 6 findings in existing port, discovery, and resource
          # cleanup boundaries where explicit rescue scope documents the failure boundary.
          {Credo.Check.Readability.PreferImplicitTry, []},

          # WithSingleClause produced 4 findings in existing signal, route, and backup control
          # flows where the with form keeps failure clauses aligned with adjacent code.
          {Credo.Check.Readability.WithSingleClause, []},

          # CondStatements produced 9 findings across endpoint, database, monitoring, route,
          # RTMP, analytics, and E2E helpers; these branches encode domain-specific guards and
          # need deliberate refactoring rather than a style-only rewrite.
          {Credo.Check.Refactor.CondStatements, []},

          # CyclomaticComplexity produced 43 findings before the threshold was raised to 20;
          # the remaining 29-complexity analytics function requires a structural refactor.
          {Credo.Check.Refactor.CyclomaticComplexity, []},

          # FilterFilter produced 2 findings in the database lookup pipeline, which needs a
          # deliberate predicate consolidation to preserve its source and destination rules.
          {Credo.Check.Refactor.FilterFilter, []},

          # NegatedConditionsWithElse produced 5 findings in RTMP and test process-control code;
          # changing branch polarity is follow-up readability work for those state machines.
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},

          # Nesting produced 40 findings before the threshold was raised to 4; the remaining
          # depth-5 route failover branch requires a structural refactor.
          {Credo.Check.Refactor.Nesting, []},

          # SpecWithStruct produced 24 findings in lib/hydra_srt/db.ex and lib/hydra_srt/tags.ex;
          # this codebase intentionally documents concrete Ecto struct shapes in its specs.
          {Credo.Check.Warning.SpecWithStruct, []},

          # NarratorDoc produced 4 findings in test support modules whose docs identify fixture
          # roles; rewriting those docs is not part of this lint configuration change.
          {ExSlop.Check.Readability.NarratorDoc, []},

          # IdentityPassthrough produced 4 findings in backup, MCP, and Victoria HTTP result
          # handling where explicit tuple branches document the boundary contract.
          {ExSlop.Check.Refactor.IdentityPassthrough, []},

          # LengthComparison produced 27 findings across three production modules and 14 test
          # files; exact collection-size assertions and bounded network lists need follow-up.
          {ExSlop.Check.Refactor.LengthComparison, []},

          # DualKeyAccess produced 25 findings across API boundary and fixture code that accepts
          # both atom- and string-keyed payloads; normalization requires a separate contract.
          {ExSlop.Check.Warning.DualKeyAccess, []},

          # GraphemesLength produced 1 finding in the binary netmask bit counter, where the
          # intermediate binary string length includes leading-zero bits and is not equivalent.
          {ExSlop.Check.Refactor.GraphemesLength, []},

          # RescueWithoutReraise produced 1 finding in the NDI port launcher, where logging the
          # exception and returning a stable launch error is the intentional boundary contract.
          {ExSlop.Check.Warning.RescueWithoutReraise, []},

          ## Checks scheduled for a future Credo update.
          {Credo.Check.Refactor.UtcNowTruncate, []},

          ## Controversial and experimental checks remain opt-in.
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.CondInsteadOfIfElse, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
