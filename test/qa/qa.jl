using SciMLTesting
using ExplicitImports
using JET
using Test

run_qa(
    SciMLTesting;
    explicit_imports = true,
    ei_kwargs = (;
        all_qualified_accesses_are_public = (;
            ignore = (
                # Aqua has no public API for the composite entry point
                :test_all,
                # Pkg has no public API for the active-env dependency graph
                :dependencies,
                # Base has no public API for the loaded-module table
                :loaded_modules,
                # Base.Docs has no public Binding / meta API for docstring lookup
                :Binding,
                :meta,
                # JET weakdep extension registration hook; intentionally non-public
                :_register_qa_tool!,
            ),
        ),
    ),
)

# `throw = false` needs ExplicitImports 1.15, above the package's `ExplicitImports = "1"`
# floor that the Downgrade lane resolves, so this check belongs to QA rather than Core.
@testset "local public replacements for qualified accesses" begin
    result = ExplicitImports.check_all_qualified_accesses_are_public(
        SciMLTesting;
        ignore = SciMLTesting.BASE_BROADCAST_EXTENSION_HOOKS,
        throw = false,
    )
    flagged = result === nothing ? Symbol[] :
        Symbol[row.name for row in result.bad_imports]
    @test !(:eval in flagged)
    @test !(:structdiff in flagged)
    @test !(:parseall in flagged)
end
