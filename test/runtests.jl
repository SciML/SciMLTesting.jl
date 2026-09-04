using SciMLTesting
using Test
using Pkg
using TOML
# Aqua and ExplicitImports are direct SciMLTesting deps, so they load with it. `using
# JET` triggers SciMLTesting's JET weakdep extension, whose `__init__` registers JET
# with SciMLTesting (see the "JET auto-detection" testset); JET must be available in
# the test env for the extension to load.
using JET

@testset "stdlib compat entries" begin
    project = TOML.parsefile(joinpath(pkgdir(SciMLTesting), "Project.toml"))
    for dependency in ("Pkg", "REPL", "Test")
        @test haskey(project["compat"], dependency)
    end
end

# Stand-in modules so the test exercises run_qa without a hard dependency on
# Aqua/JET: they only need to expose the methods run_qa calls. Modules must be
# defined at top level, not inside a @testset.
module FakeAqua
    using Test: @test
    import ..SciMLTesting
    # Record the keyword arguments the most recent test_all call received so a test
    # can assert that a known-broken sub-check was disabled in the call.
    const LAST_KWARGS = Ref{Any}(nothing)
    function test_all(pkg; kwargs...)
        @test pkg === SciMLTesting
        LAST_KWARGS[] = (; kwargs...)
        return true
    end
end

module FakeJET
    using Test: @test
    import ..SciMLTesting
    # Records what test_package actually received so a test can assert that a partial
    # `jet_kwargs` override still carries the standard configuration for the keys it omits.
    const LAST_TEST_KWARGS = Ref{Any}(nothing)
    function test_package(pkg; target_modules = nothing, mode = nothing, kwargs...)
        @test pkg === SciMLTesting
        @test mode === :typo
        LAST_TEST_KWARGS[] = (; target_modules, mode, kwargs...)
        return true
    end
    # report_package variant for jet_broken. Returns a fake "result" carrying a list of
    # reports; get_reports returns it. report_package is report-only, so run_qa must
    # NOT pass `mode` here — assert we never receive it. REPORTS controls emptiness so a
    # test can exercise both the Broken (non-empty) and Unexpected-Pass (empty) paths.
    const REPORTS = Ref{Vector{Symbol}}(Symbol[:fake_report])
    const LAST_REPORT_KWARGS = Ref{Any}(nothing)
    struct FakeResult
        reports::Vector{Symbol}
    end
    function report_package(pkg; mode = :__never__, kwargs...)
        @test pkg === SciMLTesting
        @test mode === :__never__         # `mode` must be dropped for report mode
        LAST_REPORT_KWARGS[] = (; kwargs...)
        return FakeResult(REPORTS[])
    end
    get_reports(r::FakeResult) = r.reports
end

# Stand-in ExplicitImports: the 6 checks run_qa/run_explicit_imports call. Each
# returns `nothing` on success (matching ExplicitImports' API); the public check
# also asserts it received the per-check ignore-list routed through `ei_kwargs`. To
# exercise the `ei_broken` Broken path, FINDINGS names the checks that should report a
# *finding* (a non-`nothing` return) so `@test_broken check(...) === nothing` registers
# Broken; default empty => all checks pass (preserving the non-broken tests).
module FakeExplicitImports
    using Test: @test
    import ..SciMLTesting
    const FINDINGS = Ref{Vector{Symbol}}(Symbol[])
    const CHECK_CALLS = Ref(0)
    const PUBLIC_CALLED = Ref(false)   # set when a public-API check stub runs (gated to >= 1.11)
    _short(f::Symbol) = Symbol(replace(String(f), "check_" => ""))
    _result(f::Symbol) = _short(f) in FINDINGS[] ? "<finding>" : nothing
    for f in (
            :check_no_implicit_imports, :check_no_stale_explicit_imports,
            :check_all_explicit_imports_via_owners, :check_all_qualified_accesses_via_owners,
            :check_all_explicit_imports_are_public,
        )
        @eval $f(pkg; kwargs...) = (@test pkg === SciMLTesting; CHECK_CALLS[] += 1; _result($(QuoteNode(f))))
    end
    function check_all_qualified_accesses_are_public(pkg; ignore = (), kwargs...)
        PUBLIC_CALLED[] = true
        CHECK_CALLS[] += 1
        @test pkg === SciMLTesting
        @test ignore == (
            :internal_thing, :Broadcasted, :broadcastable, :dotview, :materialize!,
        )
        return _result(:check_all_qualified_accesses_are_public)
    end
end

# Fixture exercising run_api_docs / public_api_names against a real module with a
# known mix of documented and undocumented public API. On Julia >= 1.11 it also
# declares `public` names (the eval(Expr(:public, ...)) form is a syntax error on the
# 1.10 LTS, so it is guarded out there — matching how public_api_names sees only
# exported names on 1.10).
module ApiFixture
    export documented_fn, undocumented_fn, DocumentedType
    "documented_fn doc" documented_fn(x) = x
    undocumented_fn(x) = x
    "DocumentedType doc" struct DocumentedType end
    @static if VERSION >= v"1.11"
        eval(Expr(:public, :documented_public, :undocumented_public))
    end
    "documented_public doc" documented_public(x) = x
    undocumented_public(x) = x
end

module EnumFixture
    module Generated
        @enum T first second
    end

    module Ordinary
        const T = Int
    end
end

module ModuleReexportFixture
    import SciMLTesting
    export SciMLTesting
end

module FunctionReexportFixture
    import SciMLTesting: run_qa
    export run_qa
end

module ConstantOwnerA
    export shared_constant
    "shared constant from owner A"
    const shared_constant = 1
end

module ConstantOwnerB
    export shared_constant
    "shared constant from owner B"
    const shared_constant = 1
end

module AmbiguousConstantReexportFixture
    using ..ConstantOwnerA, ..ConstantOwnerB
    export shared_constant
end

module ReexportOwnerFixture
    export owned_function, OwnedType, OwnedModule, owned_scalar, @owned_macro
    owned_function() = nothing
    struct OwnedType end
    module OwnedModule end
    const owned_scalar = 42
    macro owned_macro()
        return nothing
    end
end

module ComprehensiveReexportFixture
    import ..ReexportOwnerFixture: owned_function, OwnedType, OwnedModule, owned_scalar
    export owned_function, OwnedType, OwnedModule, owned_scalar, local_function,
        LocalType, local_scalar
    local_function() = nothing
    struct LocalType end
    const local_scalar = 7
end

module AliasReexportFixture
    import ..ReexportOwnerFixture
    const aliased_function = ReexportOwnerFixture.owned_function
    const AliasedType = ReexportOwnerFixture.OwnedType
    const AliasedModule = ReexportOwnerFixture.OwnedModule
    export aliased_function, AliasedType, AliasedModule
end

module MacroReexportFixture
    import ..ReexportOwnerFixture: @owned_macro
    export @owned_macro
end

module OperatorReexportFixture
    import Base: +
    export +
end

module UndefinedExportFixture
    export undefined_name
end

module PublicOnlyReexportFixture
    import ..ReexportOwnerFixture: owned_function
    @static if VERSION >= v"1.11"
        eval(Expr(:public, :owned_function))
    end
end

module NestedOwnerFixture
    module Internal
        nested_function() = nothing
        struct NestedType end
        module NestedModule end
        const nested_scalar = 11
        var"-->"(x, y) = x
        macro nested_macro()
            return nothing
        end
    end
    import .Internal: nested_function, NestedType, NestedModule, nested_scalar, -->,
        @nested_macro
    export nested_function, NestedType, NestedModule, nested_scalar, -->, @nested_macro
end

module LocalModuleFixture
    module LocalSubmodule end
    export LocalSubmodule
end

# Fixture for the scoped-```@autodocs``` rendered check. Every public name is
# documented here, so its docstrings resolve to this module and to this source file
# and an `@autodocs` block can be shown to cover them exactly when its `Modules` /
# `Pages` / `Public` scope really selects them.
module ScopedAutoDocsFixture
    export scoped_documented, ScopedDocumentedType
    "scoped_documented doc"
    scoped_documented(x) = x
    "ScopedDocumentedType doc"
    struct ScopedDocumentedType end
end

const REAL_JET_FIXTURE_PATH = joinpath(@__DIR__, "fixtures", "RealJETFixture")
const REAL_JET_FIXTURE_PKGID = Base.PkgId(
    Base.UUID("d0f5c5f0-7c1e-4f9c-9df0-5d2d2a4e6a11"),
    "RealJETFixture",
)

function _load_real_jet_fixture()
    Pkg.activate(REAL_JET_FIXTURE_PATH; io = devnull)
    return Base.require(REAL_JET_FIXTURE_PKGID)
end

# Reexports an undocumented external module and an undocumented external function
# next to an undocumented local name, so the docstrings check can be shown to exempt
# the module and only the module.
module UndocumentedModuleReexportFixture
    import ..ReexportOwnerFixture: OwnedModule, owned_function
    export OwnedModule, owned_function, local_undocumented
    local_undocumented() = nothing
end

# A minimal AbstractTestSet that just collects every recorded result (including
# nested testsets) and NEVER throws on finish. Wrapping a run_qa call in one lets a
# test inspect the Broken/Pass/Fail/Error counts a broken-marker produced without
# those results bubbling up to (and failing) the enclosing suite. `Test.NoThrowTestSet`
# is unexported and absent on Julia 1.10, so we define our own.
mutable struct ProbeTestSet <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    ProbeTestSet(desc::String; kwargs...) = new(desc, Any[])
end
Test.record(ts::ProbeTestSet, res) = (push!(ts.results, res); res)
# `@testset` dynamically propagates this set's type to nested plain `@testset` blocks
# (even those compiled in another module, e.g. run_qa's), so each nested set is a
# ProbeTestSet too. On finish a nested set must attach itself to its parent (exactly
# as DefaultTestSet does) so the full result tree is reachable from the outermost set;
# the outermost set just returns itself and never throws.
function Test.finish(ts::ProbeTestSet)
    if Test.get_testset_depth() != 0
        Test.record(Test.get_testset(), ts)
    end
    return ts
end

@testset "SciMLTesting" begin
    @testset "current_group" begin
        # Default when unset.
        delete!(ENV, "GROUP")
        @test current_group() == "All"
        @test current_group(default = "Core") == "Core"

        # Reads the named variable verbatim (SciML group names are capitalized).
        withenv("GROUP" => "QA") do
            @test current_group() == "QA"
        end
        withenv("ODE_TEST_GROUP" => "Interface") do
            @test current_group(env = "ODE_TEST_GROUP") == "Interface"
            @test current_group() == "All"  # GROUP still unset
        end
    end

    @testset "detect_sublibrary_group" begin
        lib = mktempdir()
        mkdir(joinpath(lib, "OrdinaryDiffEqTsit5"))
        mkdir(joinpath(lib, "Corleone_OED"))  # sublibrary name containing an underscore

        # Bare sublibrary name -> that sublibrary's Core group.
        @test detect_sublibrary_group("OrdinaryDiffEqTsit5", lib) ==
            ("OrdinaryDiffEqTsit5", "Core")

        # "<sublib>_<group>" -> named group.
        @test detect_sublibrary_group("OrdinaryDiffEqTsit5_QA", lib) ==
            ("OrdinaryDiffEqTsit5", "QA")

        # Longest existing-directory prefix wins (the sublib name has an underscore).
        @test detect_sublibrary_group("Corleone_OED", lib) == ("Corleone_OED", "Core")
        @test detect_sublibrary_group("Corleone_OED_QA", lib) == ("Corleone_OED", "QA")

        # No matching sublibrary -> fall through with the default group.
        @test detect_sublibrary_group("InterfaceII", lib) == ("InterfaceII", "Core")
        @test detect_sublibrary_group("Foo", lib; default_group = "All") == ("Foo", "All")
    end

    @testset "activate_group_env" begin
        # Remember the active project so the test leaves the environment unchanged.
        original_project = Base.active_project()

        # Build a tiny fake repo: a "package" root with a Project.toml plus a
        # test/<Group> directory holding the per-group Project.toml that
        # activate_group_env should activate.
        repo = mktempdir()
        write(
            joinpath(repo, "Project.toml"),
            """
            name = "TinyPkg"
            uuid = "11111111-1111-1111-1111-111111111111"
            version = "0.1.0"
            """,
        )
        mkdir(joinpath(repo, "src"))
        write(joinpath(repo, "src", "TinyPkg.jl"), "module TinyPkg\nend\n")

        group_dir = joinpath(repo, "test", "qa")
        mkpath(group_dir)
        # An empty (deps-free) group Project.toml: activate_group_env develops the
        # repo root into it and instantiates.
        write(joinpath(group_dir, "Project.toml"), "")

        try
            activate_group_env(group_dir)
            # The activated project is a sandbox copy of the group's Project.toml ...
            @test basename(Base.active_project()) == "Project.toml"
            @test !samefile(dirname(Base.active_project()), group_dir)
            # ... the repo-root package was developed into it by path ...
            deps = Pkg.TOML.parsefile(Base.active_project())
            @test haskey(deps, "deps") && haskey(deps["deps"], "TinyPkg")
            # ... and the env in the repo was left untouched.
            @test read(joinpath(group_dir, "Project.toml"), String) == ""

            # `sandbox = false` activates the env in the repo itself.
            activate_group_env(group_dir; sandbox = false, develop = false, instantiate = false)
            @test Base.active_project() == joinpath(group_dir, "Project.toml")

            # `develop = false` / `instantiate = false` just activates.
            other = joinpath(repo, "test", "core")
            mkpath(other)
            write(joinpath(other, "Project.toml"), "")
            activate_group_env(other; develop = false, instantiate = false)
            parsed = Pkg.TOML.parsefile(Base.active_project())
            @test !haskey(get(parsed, "deps", Dict()), "TinyPkg")
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "activate_group_env monorepo [sources] (Julia <1.11)" begin
        # Regression (SciML/OptimalUncertaintyQuantification.jl QA lts): a monorepo
        # root package depends on an unregistered in-repo sibling, and the group
        # env lists BOTH the root and the sibling in [sources]. On Julia < 1.11,
        # developing the root parent alone made Pkg resolve the root's [deps]
        # (which include the sibling) against the registry and fail with
        # "expected package <Sibling> to be registered". activate_group_env must
        # develop the parent and the [sources] siblings together so every local
        # package is satisfied by path.
        original_project = Base.active_project()
        repo = mktempdir()
        # Sibling (unregistered, in-repo).
        sib = joinpath(repo, "lib", "Sib"); mkpath(joinpath(sib, "src"))
        write(
            joinpath(sib, "Project.toml"),
            "name = \"Sib\"\nuuid = \"00000000-0000-0000-0000-0000000000b1\"\nversion = \"0.1.0\"\n"
        )
        write(joinpath(sib, "src", "Sib.jl"), "module Sib\nend\n")
        # Root package depends on the sibling and pins it via [sources].
        write(
            joinpath(repo, "Project.toml"),
            "name = \"RootPkg\"\nuuid = \"00000000-0000-0000-0000-0000000000b2\"\nversion = \"0.1.0\"\n\n" *
                "[deps]\nSib = \"00000000-0000-0000-0000-0000000000b1\"\n\n" *
                "[sources]\nSib = { path = \"lib/Sib\" }\n"
        )
        mkdir(joinpath(repo, "src"))
        write(joinpath(repo, "src", "RootPkg.jl"), "module RootPkg\nusing Sib\nend\n")
        # QA group env lists the root AND the sibling in [sources] (the OUQ layout).
        group_dir = joinpath(repo, "test", "qa"); mkpath(group_dir)
        write(
            joinpath(group_dir, "Project.toml"),
            "[deps]\nRootPkg = \"00000000-0000-0000-0000-0000000000b2\"\n" *
                "Sib = \"00000000-0000-0000-0000-0000000000b1\"\n\n" *
                "[sources]\n" *
                "RootPkg = { path = \"../..\" }\nSib = { path = \"../../lib/Sib\" }\n"
        )

        try
            # Must not throw "expected package Sib to be registered" on 1.10, nor
            # "multiple packages with the same UUID" (RootPkg is both a parent and a
            # [sources] entry).
            activate_group_env(group_dir)
            @test basename(Base.active_project()) == "Project.toml"
            if VERSION < v"1.11"
                manifest = Pkg.TOML.parsefile(joinpath(dirname(Base.active_project()), "Manifest.toml"))
                entries = get(manifest, "deps", manifest)
                @test get(entries["Sib"][1], "path", nothing) == abspath(sib)
                @test get(entries["RootPkg"][1], "path", nothing) == abspath(repo)
            end
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "activate_group_env leaves the group env's Project.toml untouched" begin
        # Regression (SciML/SciMLTesting.jl#46): the group env is a git-tracked
        # directory of the repo under test, and `Pkg.develop` rewrites the project
        # it is called on. A monorepo sublibrary QA group develops BOTH the
        # sublibrary and the monorepo root, and the root is not among the env's
        # [deps], so every QA run added it (plus Pkg's TOML normalization) to a
        # tracked file. The activated env must be a copy.
        original_project = Base.active_project()
        repo = mktempdir()
        sib = joinpath(repo, "lib", "Sib"); mkpath(joinpath(sib, "src"))
        write(
            joinpath(sib, "Project.toml"),
            "name = \"Sib\"\nuuid = \"00000000-0000-0000-0000-0000000000d1\"\nversion = \"0.1.0\"\n"
        )
        write(joinpath(sib, "src", "Sib.jl"), "module Sib\nend\n")
        sub = joinpath(repo, "lib", "Sub"); mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"),
            "name = \"Sub\"\nuuid = \"00000000-0000-0000-0000-0000000000d2\"\nversion = \"0.1.0\"\n\n" *
                "[deps]\nSib = \"00000000-0000-0000-0000-0000000000d1\"\n\n" *
                "[sources]\nSib = { path = \"../Sib\" }\n"
        )
        write(joinpath(sub, "src", "Sub.jl"), "module Sub\nusing Sib\nend\n")
        write(
            joinpath(repo, "Project.toml"),
            "name = \"RootPkg\"\nuuid = \"00000000-0000-0000-0000-0000000000d3\"\nversion = \"0.1.0\"\n\n" *
                "[deps]\nSub = \"00000000-0000-0000-0000-0000000000d2\"\n\n" *
                "[sources]\nSub = { path = \"lib/Sub\" }\n"
        )
        mkdir(joinpath(repo, "src"))
        write(joinpath(repo, "src", "RootPkg.jl"), "module RootPkg\nusing Sub\nend\n")
        # Sublibrary QA env: the relative [sources] path escapes the env's directory,
        # so a copy elsewhere on disk only resolves it if the path is rewritten.
        group_dir = joinpath(sub, "test", "qa"); mkpath(group_dir)
        project_file = joinpath(group_dir, "Project.toml")
        write(
            project_file,
            "[deps]\nSub = \"00000000-0000-0000-0000-0000000000d2\"\n" *
                "Sib = \"00000000-0000-0000-0000-0000000000d1\"\n\n" *
                "[sources.Sib]\npath = \"../../../Sib\"\n"
        )
        before = read(project_file, String)

        try
            # The real monorepo call: develop the sublibrary AND the repo root.
            activate_group_env(group_dir; parent = [sub, repo])
            @test read(project_file, String) == before
            @test !isfile(joinpath(group_dir, "Manifest.toml"))
            # The sandbox is a working env: both parents developed, and the env's
            # relative [sources] sibling still resolved to the in-repo package.
            active = Pkg.TOML.parsefile(Base.active_project())
            @test haskey(get(active, "deps", Dict()), "RootPkg")
            @test active["sources"]["Sib"]["path"] == abspath(sib)
            manifest = Pkg.TOML.parsefile(joinpath(dirname(Base.active_project()), "Manifest.toml"))
            entries = get(manifest, "deps", manifest)
            @test abspath(dirname(Base.active_project()), entries["Sib"][1]["path"]) == abspath(sib)
            @test abspath(dirname(Base.active_project()), entries["Sub"][1]["path"]) == abspath(sub)
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "_dedup_path_specs" begin
        # Same UUID via two different paths -> first wins, second dropped.
        root = mktempdir()
        a = joinpath(root, "A"); mkpath(a)
        alink = joinpath(root, "A2"); mkpath(alink)  # same uuid, different dir
        write(joinpath(a, "Project.toml"), "name=\"A\"\nuuid=\"00000000-0000-0000-0000-0000000000c1\"\n")
        write(joinpath(alink, "Project.toml"), "name=\"A\"\nuuid=\"00000000-0000-0000-0000-0000000000c1\"\n")
        b = joinpath(root, "B"); mkpath(b)
        write(joinpath(b, "Project.toml"), "name=\"B\"\nuuid=\"00000000-0000-0000-0000-0000000000c2\"\n")
        # A path with no Project.toml uuid is kept (deduped by path only).
        noproj = joinpath(root, "NoProj"); mkpath(noproj)

        specs = SciMLTesting._dedup_path_specs([a, alink, b, noproj, b])
        got = [s.path for s in specs]
        @test got == [abspath(a), abspath(b), abspath(noproj)]
    end

    @testset "JET auto-detection (weakdep extension registered)" begin
        # `using JET` at the top of this file loaded SciMLTesting's JET extension,
        # whose `__init__` registered the real module. JET is the only registry-backed
        # tool; Aqua and ExplicitImports are direct deps (not weakdeps), so they are
        # never registered — `run_qa` uses them directly.
        @test SciMLTesting._qa_tool(:JET) === JET
        @test SciMLTesting._qa_tool(:Aqua) === nothing
        @test SciMLTesting._qa_tool(:ExplicitImports) === nothing
        # An unregistered tool name returns `nothing`.
        @test SciMLTesting._qa_tool(:NotATool) === nothing
    end

    @testset "run_qa explicit-module path" begin
        # Explicit module args override the defaults (the real Aqua/ExplicitImports
        # deps and the JET registry), so these exercise the run-logic against the Fake
        # stand-ins. `aqua`/`jet` default to "module !== nothing" (so passing a Fake
        # turns it on, passing `nothing` turns it off); ExplicitImports is default-on,
        # so tests that omit its module disable it explicitly.

        # Aqua-only.
        run_qa(
            SciMLTesting;
            Aqua = FakeAqua,
            JET = nothing,
            ExplicitImports = nothing,
            explicit_imports = false,
            api_docs = false,
        )
        # Aqua + JET.
        run_qa(
            SciMLTesting;
            Aqua = FakeAqua,
            JET = FakeJET,
            ExplicitImports = nothing,
            explicit_imports = false,
            api_docs = false,
        )
        # JET-only (Aqua off via Aqua = nothing).
        run_qa(
            SciMLTesting;
            Aqua = nothing,
            JET = FakeJET,
            ExplicitImports = nothing,
            explicit_imports = false,
            api_docs = false,
        )

        # Aqua + ExplicitImports (standard + public-API); per-check ignore-list routed via ei_kwargs.
        FakeExplicitImports.CHECK_CALLS[] = 0
        run_qa(
            SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = FakeExplicitImports,
            api_docs = false,
            ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,)))
        )
        @test FakeExplicitImports.CHECK_CALLS[] == (VERSION >= v"1.11" ? 6 : 4)
        # The direct helper.
        run_explicit_imports(
            SciMLTesting, FakeExplicitImports;
            ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,)))
        )

        # Backward-compat: old explicit `Aqua = Aqua, jet = true` form behaves identically.
        run_qa(
            SciMLTesting; Aqua = FakeAqua, JET = FakeJET, jet = true,
            ExplicitImports = nothing,
            explicit_imports = false,
            api_docs = false,
        )

        # A partial `jet_kwargs` override merges over the standard configuration instead
        # of replacing it. Regression: `jet_kwargs` used to be a whole-NamedTuple default,
        # so passing any entry dropped `mode = :typo` and silently reverted JET to its far
        # more expensive `BasicPass`.
        FakeJET.LAST_TEST_KWARGS[] = nothing
        run_qa(
            SciMLTesting; Aqua = nothing, JET = FakeJET, ExplicitImports = nothing,
            explicit_imports = false, api_docs = false,
            jet_kwargs = (; ignore_throws = false),
        )
        @test FakeJET.LAST_TEST_KWARGS[].mode === :typo
        @test FakeJET.LAST_TEST_KWARGS[].target_modules == (SciMLTesting,)
        @test FakeJET.LAST_TEST_KWARGS[].ignore_throws === false

        # An explicit entry still wins over the default it collides with.
        @test SciMLTesting._standard_jet_kwargs(SciMLTesting, (; mode = :sound)).mode ===
            :sound
        @test SciMLTesting._standard_jet_kwargs(
            SciMLTesting, (; target_modules = (Base,))
        ).target_modules == (Base,)

        # `target_defined_modules` is a separate JET configuration. `false` does not
        # replace the standard target_modules filter; `true` asks JET to derive its own
        # target set and therefore replaces only the default target.
        disabled = SciMLTesting._standard_jet_kwargs(
            SciMLTesting, (; target_defined_modules = false)
        )
        @test disabled.mode === :typo
        @test disabled.target_defined_modules === false
        @test disabled.target_modules == (SciMLTesting,)

        derived = SciMLTesting._standard_jet_kwargs(
            SciMLTesting, (; target_defined_modules = true)
        )
        @test derived.mode === :typo
        @test derived.target_defined_modules === true
        @test !haskey(derived, :target_modules)

        explicit = SciMLTesting._standard_jet_kwargs(
            SciMLTesting, (; target_defined_modules = true, target_modules = (Base,))
        )
        @test explicit.target_modules == (Base,)

        # Helpful errors when an enable flag is forced on but the module is unavailable.
        @test_throws ArgumentError run_qa(
            SciMLTesting; Aqua = nothing, aqua = true,
            JET = nothing, ExplicitImports = nothing, explicit_imports = false,
            api_docs = false,
        )
        @test_throws ArgumentError run_qa(
            SciMLTesting; Aqua = nothing, JET = nothing,
            jet = true, ExplicitImports = nothing, explicit_imports = false,
            api_docs = false,
        )
        @test_throws ArgumentError run_qa(
            SciMLTesting; Aqua = nothing, JET = nothing,
            ExplicitImports = nothing, explicit_imports = true, api_docs = false
        )
    end

    @testset "real JET target_defined_modules precedence" begin
        # Newer supported JET versions removed the legacy keyword, so FakeJET checks
        # forwarding of that key above while real JET checks the resulting target path.
        original_project = Base.active_project()
        try
            RealJETFixture = _load_real_jet_fixture()
            effective = SciMLTesting._standard_jet_kwargs(
                RealJETFixture, (; target_defined_modules = false)
            )
            @test effective.target_modules == (RealJETFixture,)
            JET.test_package(
                RealJETFixture;
                mode = effective.mode,
                target_modules = effective.target_modules,
            )
        finally
            Pkg.activate(original_project; io = devnull)
        end
    end

    @testset "Aqua ambiguity subprocess resolves SciMLTesting dependencies" begin
        original_load_path = copy(LOAD_PATH)
        original_project = Base.active_project()
        child_can_load_aqua() = success(
            pipeline(
                `$(Base.julia_cmd()) --startup-file=no -e $("$(Base.load_path_setup_code())\nusing Aqua")`;
                stdout = devnull, stderr = devnull,
            ),
        )

        mktempdir() do qa_environment
            try
                Pkg.activate(qa_environment; io = devnull)
                qa_project = joinpath(qa_environment, "Project.toml")
                empty!(LOAD_PATH)
                append!(LOAD_PATH, (qa_environment, "@stdlib"))
                @test Base.active_project() == qa_project
                @test !child_can_load_aqua()

                SciMLTesting._with_aqua_dependency_load_path() do
                    @test Base.active_project() == qa_project
                    @test child_can_load_aqua()
                end
                @test Base.active_project() == qa_project
            finally
                original_project === nothing ? Pkg.activate(; io = devnull) :
                    Pkg.activate(original_project; io = devnull)
                empty!(LOAD_PATH)
                append!(LOAD_PATH, original_load_path)
            end
        end
    end

    @testset "run_qa broken markers" begin
        # Count every test result of a kind recursively in a testset's results tree
        # (a testset's children are themselves testsets). Used to assert that the
        # broken-marker kwargs register `Broken`/`Error` results without `Fail`s.
        function count_results(ts)
            counts = Dict(:pass => 0, :fail => 0, :error => 0, :broken => 0)
            for r in ts.results
                if r isa Test.Pass
                    counts[:pass] += 1
                elseif r isa Test.Fail
                    counts[:fail] += 1
                elseif r isa Test.Error
                    counts[:error] += 1
                elseif r isa Test.Broken
                    counts[:broken] += 1
                elseif r isa Test.AbstractTestSet
                    sub = count_results(r)
                    for k in keys(counts)
                        counts[k] += sub[k]
                    end
                end
            end
            return counts
        end

        # Run a body inside a ProbeTestSet and return the result counts. Because the
        # nested @testset that run_qa opens does not name its own type, Test propagates
        # ProbeTestSet to it (and to its children), so NOTHING throws on finish — even
        # the Unexpected-Pass (Error) case — and every result is collected for counting.
        function counts_of(body)
            ts = @testset ProbeTestSet "probe" begin
                body()
            end
            return count_results(ts)
        end

        # `aqua_broken` disables the named sub-check in the test_all call AND emits one
        # placeholder Broken per name. No JET/EI here.
        FakeAqua.LAST_KWARGS[] = nothing
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false,
                clean_sources = false, aqua_broken = (:ambiguities, :deps_compat),
            )
        end
        # The disabled sub-checks were merged into the Aqua.test_all call as `false`.
        kw = FakeAqua.LAST_KWARGS[]
        @test kw.ambiguities === false
        @test kw.deps_compat === false
        # Two placeholder Broken results (one per name), zero failures.
        @test c[:broken] == 2
        @test c[:fail] == 0
        @test c[:error] == 0

        # Broken-disable wins over a conflicting aqua_kwargs entry.
        FakeAqua.LAST_KWARGS[] = nothing
        counts_of() do
            run_qa(
                SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false,
                clean_sources = false,
                aqua_kwargs = (; ambiguities = true), aqua_broken = (:ambiguities,),
            )
        end
        @test FakeAqua.LAST_KWARGS[].ambiguities === false   # broken-disable overrode `true`

        # Standard SciML solver extension hooks are accepted centrally, while caller
        # supplied Aqua hooks remain present.
        kwargs = SciMLTesting._standard_aqua_kwargs(
            (; piracies = (; treat_as_own = [Vector, identity])), [length, identity]
        )
        @test kwargs.piracies.treat_as_own ==
            Union{Function, Type}[Vector, identity, length]
        disabled_kwargs = SciMLTesting._standard_aqua_kwargs(
            (; piracies = false), [identity]
        )
        @test disabled_kwargs.piracies === false
        enabled_kwargs = SciMLTesting._standard_aqua_kwargs(
            (; piracies = true), [identity]
        )
        @test enabled_kwargs.piracies.treat_as_own ==
            Union{Function, Type}[identity]

        # `jet_broken` with a non-empty report registers exactly one Broken (the
        # `@test_broken isempty(...)`), no failures; and `mode` was dropped (FakeJET's
        # report_package asserts it never receives `mode`), while target_modules passes through.
        FakeJET.REPORTS[] = Symbol[:fake_report]
        FakeJET.LAST_REPORT_KWARGS[] = nothing
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = nothing, JET = FakeJET, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false,
                jet_broken = true,
                jet_kwargs = (; target_modules = (SciMLTesting,), mode = :typo),
            )
        end
        @test c[:broken] == 1
        @test c[:fail] == 0
        @test c[:error] == 0
        @test FakeJET.LAST_REPORT_KWARGS[].target_modules == (SciMLTesting,)
        @test !haskey(FakeJET.LAST_REPORT_KWARGS[], :mode)

        # `jet_broken` with an EMPTY report -> `@test_broken isempty(...)` is an
        # Unexpected Pass, which Test records as an Error (auto-flag the fix). No Fail.
        FakeJET.REPORTS[] = Symbol[]
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = nothing, JET = FakeJET, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false,
                jet_broken = true,
            )
        end
        @test c[:error] == 1     # Unexpected Pass surfaces as an Error
        @test c[:broken] == 0
        @test c[:fail] == 0
        FakeJET.REPORTS[] = Symbol[:fake_report]   # restore default for other testsets

        # `ei_broken` routes the named check through @test_broken. With that check
        # reporting a finding, it registers Broken (the finding is suppressed); the
        # other five pass. One name broken -> 1 Broken, 0 Fail, 0 Error.
        FakeExplicitImports.FINDINGS[] = Symbol[:no_implicit_imports]
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = nothing, JET = nothing,
                ExplicitImports = FakeExplicitImports, explicit_imports = true,
                api_docs = false,
                ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,))),
                ei_broken = (:no_implicit_imports,),
            )
        end
        @test c[:broken] == 1
        @test c[:pass] >= 5      # the other checks pass (plus FakeExplicitImports @tests)
        @test c[:fail] == 0
        @test c[:error] == 0

        # A still-failing check NOT listed in ei_broken stays a hard @test (Fail), so a
        # genuine regression is never silently swallowed by the broken machinery.
        FakeExplicitImports.FINDINGS[] = Symbol[:no_stale_explicit_imports]
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = nothing, JET = nothing,
                ExplicitImports = FakeExplicitImports, explicit_imports = true,
                api_docs = false,
                ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,))),
                ei_broken = (:no_implicit_imports,),   # different check than the finding
            )
        end
        @test c[:fail] == 1      # the unlisted finding fails hard
        @test c[:broken] == 0

        # An ei_broken check that has been FIXED (no finding) is an Unexpected Pass
        # (Error) -> auto-flag prompting the caller to drop the name.
        FakeExplicitImports.FINDINGS[] = Symbol[]
        c = counts_of() do
            run_explicit_imports(
                SciMLTesting, FakeExplicitImports;
                ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,))),
                ei_broken = (:no_implicit_imports,),
            )
        end
        @test c[:error] == 1     # Unexpected Pass surfaces as Error
        @test c[:broken] == 0
        @test c[:fail] == 0

        # The direct helper honors ei_broken too (Broken path).
        FakeExplicitImports.FINDINGS[] = Symbol[:all_explicit_imports_via_owners]
        c = counts_of() do
            run_explicit_imports(
                SciMLTesting, FakeExplicitImports;
                ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,))),
                ei_broken = (:all_explicit_imports_via_owners,),
            )
        end
        @test c[:broken] == 1
        @test c[:fail] == 0
        FakeExplicitImports.FINDINGS[] = Symbol[]   # restore default for other testsets

        # All three at once (the realistic conversion case): Aqua ambiguities broken +
        # JET broken + one EI check broken. Broken count > 0, zero failures.
        FakeJET.REPORTS[] = Symbol[:fake_report]
        FakeExplicitImports.FINDINGS[] = Symbol[:no_implicit_imports]
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = FakeAqua, JET = FakeJET,
                ExplicitImports = FakeExplicitImports, explicit_imports = true,
                api_docs = false,
                clean_sources = false,
                aqua_broken = (:ambiguities,), jet_broken = true,
                ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,))),
                ei_broken = (:no_implicit_imports,),
            )
        end
        @test c[:broken] == 3    # aqua placeholder + jet + ei
        @test c[:fail] == 0
        @test c[:error] == 0
        FakeExplicitImports.FINDINGS[] = Symbol[]   # restore default for other testsets

        # Defaults: empty broken-sets reproduce pre-1.6 behavior (no Broken, no Fail).
        FakeAqua.LAST_KWARGS[] = nothing
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = FakeAqua, JET = FakeJET, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false,
                clean_sources = false,
            )
        end
        @test c[:broken] == 0
        @test c[:fail] == 0
        @test c[:error] == 0
        # No broken-disable keys leaked into the Aqua call.
        @test !haskey(FakeAqua.LAST_KWARGS[], :ambiguities)
        @test FakeAqua.LAST_KWARGS[].persistent_tasks.tmax == 60

        FakeAqua.LAST_KWARGS[] = nothing
        counts_of() do
            run_qa(
                SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false, clean_sources = false,
                aqua_kwargs = (; persistent_tasks = (; exclude = (:fixture,))),
            )
        end
        persistent_tasks = FakeAqua.LAST_KWARGS[].persistent_tasks
        @test persistent_tasks.tmax == 60
        @test persistent_tasks.exclude == (:fixture,)

        FakeAqua.LAST_KWARGS[] = nothing
        counts_of() do
            run_qa(
                SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = nothing,
                explicit_imports = false, api_docs = false, clean_sources = false,
                aqua_kwargs = (; persistent_tasks = false),
            )
        end
        @test FakeAqua.LAST_KWARGS[].persistent_tasks === false
    end

    @testset "public-API EI checks gated to Julia >= 1.11" begin
        FakeExplicitImports.FINDINGS[] = Symbol[]
        FakeExplicitImports.PUBLIC_CALLED[] = false
        run_explicit_imports(
            SciMLTesting, FakeExplicitImports;
            ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,))),
        )
        @test FakeExplicitImports.PUBLIC_CALLED[] == (VERSION >= v"1.11")
    end

    @testset "generated enum modules are excluded from source analysis" begin
        @test SciMLTesting._generated_enum_modules(EnumFixture) == (EnumFixture.Generated,)
        kwargs = SciMLTesting._explicit_imports_kwargs(
            EnumFixture,
            :no_implicit_imports,
            (; no_implicit_imports = (; allow_unanalyzable = (ApiFixture,))),
        )
        @test kwargs.allow_unanalyzable == (ApiFixture, EnumFixture.Generated)
        @test SciMLTesting._explicit_imports_kwargs(
            EnumFixture, :all_qualified_accesses_are_public, (;)
        ) == (; ignore = SciMLTesting.BASE_BROADCAST_EXTENSION_HOOKS)
    end

    @testset "run_qa enable-flag defaulting" begin
        # `jet` defaults from the registry (the one weakdep): registered => on,
        # unregistered => off. `explicit_imports` is disabled here because this
        # testset isolates the JET/aqua defaulting behavior. `api_docs` is also off;
        # the default-on API-docs check has its own testset.
        saved = copy(SciMLTesting._QA_MODULES)
        try
            delete!(SciMLTesting._QA_MODULES, :JET)
            # JET unregistered + aqua/EI/api_docs off => run_qa is a no-op (no error).
            run_qa(SciMLTesting; aqua = false, explicit_imports = false, api_docs = false)

            # Register a Fake JET: `jet` now defaults on and run_qa runs it.
            SciMLTesting._register_qa_tool!(:JET, FakeJET)
            @test SciMLTesting._qa_tool(:JET) === FakeJET
            run_qa(SciMLTesting; aqua = false, explicit_imports = false, api_docs = false)              # runs FakeJET via the registry default
            run_qa(SciMLTesting; aqua = false, jet = false, explicit_imports = false, api_docs = false) # explicit off skips it (no error)
        finally
            empty!(SciMLTesting._QA_MODULES)
            merge!(SciMLTesting._QA_MODULES, saved)
        end
    end

    @testset "with_clean_persistent_tasks_sources" begin
        # The bug: a *registry-installed* dependency's Project.toml ships a leaked
        # path-`[sources]` whose sibling path does not exist in the depot, and Pkg
        # >=1.11 hard-errors honoring it during Aqua's persistent-tasks `Pkg.develop`.
        # Model that with a path-dev'd package whose ON-DISK Project.toml is given a
        # `[sources]` with one BROKEN path entry (unresolvable, the leaked case) and
        # one RESOLVING path entry. The sanitizer must, for the duration of the
        # wrapped call, remove only the broken entry, leave the resolving one, and
        # restore the file byte-for-byte (and mode) afterward — including on throw.
        original_project = Base.active_project()
        root = mktempdir()

        # A real sibling the resolving [sources] entry points at.
        good = joinpath(root, "GoodSib"); mkpath(joinpath(good, "src"))
        write(
            joinpath(good, "Project.toml"),
            "name = \"GoodSib\"\nuuid = \"00000000-0000-0000-0000-0000000000cc\"\nversion = \"0.1.0\"\n"
        )
        write(joinpath(good, "src", "GoodSib.jl"), "module GoodSib\nend\n")

        # The package under test. Develop it CLEAN (no [sources]) so the env
        # activates on all Julia versions, then inject the leaked [sources] into its
        # on-disk Project.toml afterward — mirroring how the bug manifests (the
        # broken [sources] lives in the installed copy on disk, not in a resolved
        # env we control). The sanitizer reads the dependency `source` dir from
        # Pkg.dependencies(), exactly like Aqua's persistent-tasks check does.
        pkg = joinpath(root, "PkgUT"); mkpath(joinpath(pkg, "src"))
        write(
            joinpath(pkg, "Project.toml"),
            "name = \"PkgUT\"\nuuid = \"00000000-0000-0000-0000-0000000000dd\"\nversion = \"0.1.0\"\n"
        )
        write(joinpath(pkg, "src", "PkgUT.jl"), "module PkgUT\nend\n")

        envd = joinpath(root, "env"); mkpath(envd)
        try
            Pkg.activate(envd)
            Pkg.develop(Pkg.PackageSpec(path = pkg); io = devnull)

            pkg_toml = joinpath(pkg, "Project.toml")
            # Inject the leaked [sources] post-develop (the depot-copy scenario).
            open(pkg_toml, "a") do io
                println(io)
                println(io, "[sources]")
                println(io, "GoodSib = { path = \"../GoodSib\" }")
                println(io, "Missing = { path = \"../DoesNotExist\" }")
            end
            before_bytes = read(pkg_toml, String)
            before_mode = filemode(pkg_toml)

            local saw_inside
            ret = with_clean_persistent_tasks_sources() do
                parsed = Pkg.TOML.parsefile(pkg_toml)
                srcs = get(parsed, "sources", Dict{String, Any}())
                # Broken "Missing" entry removed; resolving "GoodSib" entry kept.
                saw_inside = (haskey(srcs, "GoodSib"), haskey(srcs, "Missing"))
                42
            end

            # Return value passes through.
            @test ret == 42
            # During the call: broken stripped, resolving kept.
            @test saw_inside == (true, false)
            # After the call: file restored byte-for-byte and mode unchanged.
            @test read(pkg_toml, String) == before_bytes
            @test filemode(pkg_toml) == before_mode

            # Restoration also happens when the wrapped body throws.
            @test_throws ErrorException with_clean_persistent_tasks_sources() do
                error("boom")
            end
            @test read(pkg_toml, String) == before_bytes
            @test filemode(pkg_toml) == before_mode
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "current_group empty normalization" begin
        # Empty ENV[env] is treated like unset (some CI matrices set GROUP="").
        withenv("GROUP" => "") do
            @test current_group() == "All"
            @test current_group(default = "Core") == "Core"
        end
        withenv("ODE_TEST_GROUP" => "") do
            @test current_group(env = "ODE_TEST_GROUP", default = "Interface") == "Interface"
        end
    end

    @testset "detect_sublibrary_group empty guard" begin
        # Regression: isdir(joinpath(lib_dir, "")) is true, so an empty group used
        # to be misdetected as a sublibrary (the Corleone bug). It must fall
        # through with the default group instead.
        lib = mktempdir()
        mkdir(joinpath(lib, "SomeSublib"))
        @test detect_sublibrary_group("", lib) == ("", "Core")
        @test detect_sublibrary_group("", lib; default_group = "All") == ("", "All")
    end

    @testset "_collect_source_paths" begin
        # Regression: develop_sources! must resolve a [sources] `path` against the
        # declaring Project.toml's directory and recurse into that dep's own
        # [sources]. Tested version-independently via the path collector so the
        # resolution logic is exercised on Julia >= 1.11 too (where the public
        # develop_sources! is a no-op). A's runtime source B is followed only
        # because B is one of A's runtime [deps] (see the test-only-skip case below).
        root = mktempdir()
        # Layout:
        #   root/env/Project.toml   [sources] A -> ../A
        #   root/A/Project.toml     [deps] B; [sources] B -> ../B   (relative to A, not env)
        #   root/B/Project.toml     (no sources)
        envd = joinpath(root, "env"); mkpath(envd)
        a = joinpath(root, "A"); mkpath(a)
        b = joinpath(root, "B"); mkpath(b)
        write(
            joinpath(envd, "Project.toml"),
            "name = \"Env\"\nuuid = \"00000000-0000-0000-0000-000000000001\"\n\n[sources]\nA = { path = \"../A\" }\n"
        )
        write(
            joinpath(a, "Project.toml"),
            "name = \"A\"\nuuid = \"00000000-0000-0000-0000-000000000002\"\n\n" *
                "[deps]\nB = \"00000000-0000-0000-0000-000000000003\"\n\n[sources]\nB = { path = \"../B\" }\n"
        )
        write(
            joinpath(b, "Project.toml"),
            "name = \"B\"\nuuid = \"00000000-0000-0000-0000-000000000003\"\n"
        )

        paths = SciMLTesting._collect_source_paths(envd)
        @test paths == [abspath(a), abspath(b)]

        # Regression (SciML/Optimization.jl#1228, SciML/NeuralLyapunov.jl): a
        # *non-root* dependency's test-only [sources] -- a source whose name is NOT
        # one of that dependency's runtime [deps] -- must NOT be developed. Otherwise
        # it leaks into the active env as a phantom direct dep and trips Aqua's
        # stale-deps check. The root env's own [sources] are still followed.
        troot = mktempdir()
        tenv = joinpath(troot, "env"); mkpath(tenv)
        tpkg = joinpath(troot, "Pkg"); mkpath(tpkg)
        tlib = joinpath(troot, "Lib"); mkpath(tlib)
        write(
            joinpath(tenv, "Project.toml"),
            "name = \"Env\"\nuuid = \"00000000-0000-0000-0000-0000000000e1\"\n\n[sources]\nPkg = { path = \"../Pkg\" }\n"
        )
        # Pkg lists Lib only in [extras]/[targets].test (a test-only dep), pinned via
        # [sources] -- exactly the NeuralLyapunov ⇒ NeuralLyapunovProblemLibrary shape.
        write(
            joinpath(tpkg, "Project.toml"),
            "name = \"Pkg\"\nuuid = \"00000000-0000-0000-0000-0000000000p1\"\n\n" *
                "[extras]\nLib = \"00000000-0000-0000-0000-0000000000l1\"\n\n" *
                "[sources]\nLib = { path = \"../Lib\" }\n\n" *
                "[targets]\ntest = [\"Lib\"]\n"
        )
        write(
            joinpath(tlib, "Project.toml"),
            "name = \"Lib\"\nuuid = \"00000000-0000-0000-0000-0000000000l1\"\n"
        )
        tpaths = SciMLTesting._collect_source_paths(tenv)
        @test tpaths == [abspath(tpkg)]               # Pkg developed
        @test !(abspath(tlib) in tpaths)              # Lib (test-only) NOT developed

        # A url/rev (git) source is left to Pkg, not collected as a path.
        gitenv = mktempdir()
        write(
            joinpath(gitenv, "Project.toml"),
            "[sources]\nFoo = { url = \"https://example.com/Foo.jl\", rev = \"main\" }\n"
        )
        @test isempty(SciMLTesting._collect_source_paths(gitenv))

        # No [sources] table -> nothing to develop.
        plainenv = mktempdir()
        write(joinpath(plainenv, "Project.toml"), "name = \"Plain\"\n")
        @test isempty(SciMLTesting._collect_source_paths(plainenv))

        # A cycle (A -> B -> A) terminates and visits each path once. The root A
        # follows B; the non-root B follows A only because A is in B's [deps].
        croot = mktempdir()
        ca = joinpath(croot, "A"); mkpath(ca)
        cb = joinpath(croot, "B"); mkpath(cb)
        write(
            joinpath(ca, "Project.toml"),
            "[sources]\nB = { path = \"../B\" }\n"
        )
        write(
            joinpath(cb, "Project.toml"),
            "[deps]\nA = \"00000000-0000-0000-0000-0000000000a1\"\n\n[sources]\nA = { path = \"../A\" }\n"
        )
        cpaths = SciMLTesting._collect_source_paths(ca)
        @test sort(cpaths) == sort([abspath(cb), abspath(ca)])
    end

    @testset "develop_sources! against a real env" begin
        original_project = Base.active_project()
        # A consumer env whose [sources] points at an in-repo sibling package.
        root = mktempdir()
        sib = joinpath(root, "Sibling"); mkpath(joinpath(sib, "src"))
        write(
            joinpath(sib, "Project.toml"),
            "name = \"Sibling\"\nuuid = \"00000000-0000-0000-0000-0000000000aa\"\nversion = \"0.1.0\"\n"
        )
        write(joinpath(sib, "src", "Sibling.jl"), "module Sibling\nend\n")

        envd = joinpath(root, "env"); mkpath(envd)
        # Sibling must be listed in [deps] for the [sources] pin to validate on
        # Julia >= 1.11 (Pkg validates [sources] entries against deps on activate).
        write(
            joinpath(envd, "Project.toml"),
            "[deps]\nSibling = \"00000000-0000-0000-0000-0000000000aa\"\n\n" *
                "[sources]\nSibling = { path = \"../Sibling\" }\n"
        )

        try
            Pkg.activate(envd)
            before = read(Base.active_project(), String)
            develop_sources!(envd)
            after = read(Base.active_project(), String)
            if VERSION >= v"1.11"
                # No-op on 1.11+: native [sources] support means develop_sources!
                # touches nothing.
                @test before == after
                # The dep is present (declared + pinned natively).
                @test haskey(Pkg.TOML.parse(after)["deps"], "Sibling")
            else
                # 1.10 backport: the path source is developed into the env so the
                # local Sibling source is used. The dep resolves to the on-disk path.
                manifest = Pkg.TOML.parsefile(joinpath(envd, "Manifest.toml"))
                entries = get(manifest, "deps", manifest)  # 1.10 manifest layout
                sib_entry = entries["Sibling"][1]
                @test get(sib_entry, "path", nothing) == abspath(sib)
            end
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "public_api_names" begin
        api = public_api_names(ApiFixture)
        @test issorted(api)
        @test !(nameof(ApiFixture) in api)     # the module's own name is dropped
        # Exported names are always present; `public`-declared names only on >= 1.11.
        @test :documented_fn in api
        @test :undocumented_fn in api
        @test :DocumentedType in api
        if VERSION >= v"1.11"
            @test :documented_public in api
            @test :undocumented_public in api
        else
            @test !(:documented_public in api)   # `public` keyword is 1.11+
        end

        # SciMLTesting's own exported API is exactly what `export` lists (it declares
        # no `public` names), independent of Julia version.
        st = public_api_names(SciMLTesting)
        @test length(st) == 13
        @test :run_api_docs in st && :run_qa in st && :run_tests in st
        @test :run_everything in st
        @test :public_reexports in st
        @test !(:SciMLTesting in st)
    end

    @testset "_doc_entry_name" begin
        @test SciMLTesting._doc_entry_name("foo") == :foo
        @test SciMLTesting._doc_entry_name("MyPkg.foo") == :foo
        @test SciMLTesting._doc_entry_name("foo(x::Int)") == :foo
        @test SciMLTesting._doc_entry_name("MyPkg.foo(x::Int, y)") == :foo
        @test SciMLTesting._doc_entry_name("Base.SubMod.bar") == :bar
        @test SciMLTesting._doc_entry_name("@mac") == Symbol("@mac")
        @test SciMLTesting._doc_entry_name("MyPkg.@mac") == Symbol("@mac")
        @test SciMLTesting._doc_entry_name("MyPkg.:<ₑ") == Symbol("<ₑ")
        @test SciMLTesting._doc_entry_name("Base.:+") == :+
        @test SciMLTesting._doc_entry_name("Base.:(+)") == :+
    end

    @testset "public_reexports" begin
        @test public_reexports(ModuleReexportFixture) == [:SciMLTesting]
        @test public_reexports(FunctionReexportFixture) == [:run_qa]
        @test public_reexports(AmbiguousConstantReexportFixture) == [:shared_constant]
        @test public_reexports(ComprehensiveReexportFixture) ==
            [:OwnedModule, :OwnedType, :owned_function, :owned_scalar]
        @test public_reexports(AliasReexportFixture) ==
            [:AliasedModule, :AliasedType, :aliased_function]
        @test public_reexports(MacroReexportFixture) == [Symbol("@owned_macro")]
        @test isempty(public_reexports(MacroReexportFixture; allow = (Symbol("@owned_macro"),)))
        @test public_reexports(OperatorReexportFixture) == [:+]
        @test isempty(public_reexports(OperatorReexportFixture; allow = (:+,)))
        @test isempty(public_reexports(UndefinedExportFixture))
        @test isempty(public_reexports(LocalModuleFixture))
        @test isempty(public_reexports(NestedOwnerFixture))
        if VERSION >= v"1.11"
            @test public_reexports(PublicOnlyReexportFixture) == [:owned_function]
        else
            @test isempty(public_reexports(PublicOnlyReexportFixture))
        end
        @test public_reexports(
            ComprehensiveReexportFixture;
            allow = (:OwnedModule, :OwnedType, :owned_function, :owned_scalar),
        ) == Symbol[]
        @test public_reexports(
            ComprehensiveReexportFixture; allow = (:owned_scalar,),
        ) == [:OwnedModule, :OwnedType, :owned_function]
    end

    @testset "_rendered_doc_names" begin
        # A docs/src tree with a @docs block (module-qualified + signature entries) in
        # one file and a plain-prose file with no block in another.
        droot = mktempdir()
        src = joinpath(droot, "src"); mkpath(joinpath(src, "manual"))
        write(
            joinpath(src, "index.md"),
            "# Home\n\nsome prose\n\n```@docs\nMyPkg.foo\nbar(x::Int)\n@mac\n```\n\nmore prose\n",
        )
        write(joinpath(src, "manual", "extra.md"), "# Extra\n\n```@docs\nbaz\n```\n")
        write(joinpath(src, "prose.md"), "# Just prose\n\nno docs block here\n")
        (rendered, autodocs) = SciMLTesting._rendered_doc_names(src)
        @test rendered == Set([:foo, :bar, Symbol("@mac"), :baz])
        @test isempty(autodocs)

        # Each @autodocs block is captured with the scope it declares, so a narrow
        # block stays narrow instead of reading as whole-package coverage.
        adroot = mktempdir()
        asrc = joinpath(adroot, "src"); mkpath(asrc)
        write(
            joinpath(asrc, "api.md"),
            """
            # API

            ```@autodocs
            Modules = [MyPkg, MyPkg.Inner]
            Pages = ["systems/analysis_points.jl"]
            Private = false
            ```

            ```@autodocs
            Modules = [MyPkg]
            ```
            """,
        )
        (_, blocks) = SciMLTesting._rendered_doc_names(asrc)
        @test length(blocks) == 2
        @test blocks[1].modules == [["MyPkg"], ["MyPkg", "Inner"]]
        @test blocks[1].pages == ["systems/analysis_points.jl"]
        @test blocks[1].public && !blocks[1].private
        @test blocks[1].order == [:module, :constant, :type, :function, :macro]
        @test blocks[1].unfiltered
        @test blocks[2].modules == [["MyPkg"]]
        @test isempty(blocks[2].pages)
        @test blocks[2].public && blocks[2].private

        # Settings that cannot be read as literals are retained for diagnostics but cannot
        # satisfy the rendered check.
        uroot = mktempdir()
        usrc = joinpath(uroot, "src"); mkpath(usrc)
        write(
            joinpath(usrc, "api.md"),
            "```@autodocs\nModules = collect_modules()\nFilter = t -> false\n```\n",
        )
        (_, unreadable) = SciMLTesting._rendered_doc_names(usrc)
        @test length(unreadable) == 1
        @test unreadable[1].modules === nothing
        @test isempty(unreadable[1].pages)
        @test !unreadable[1].unfiltered

        # Documenter renders nothing for a block with no `Modules`, so it is dropped
        # instead of being read as unrestricted coverage.
        mroot = mktempdir()
        msrc = joinpath(mroot, "src"); mkpath(msrc)
        write(joinpath(msrc, "api.md"), "```@autodocs\nPages = [\"a.jl\"]\n```\n")
        @test isempty(last(SciMLTesting._rendered_doc_names(msrc)))

        # A missing docs dir yields an empty set (never errors).
        (empty_rendered, empty_auto) = SciMLTesting._rendered_doc_names(joinpath(droot, "nope"))
        @test isempty(empty_rendered) && isempty(empty_auto)
    end

    @testset "_find_docs_src" begin
        repository = mktempdir()
        package_root = joinpath(repository, "lib", "ApiFixture")
        mkpath(package_root)
        repository_docs = joinpath(repository, "docs", "src")
        mkpath(repository_docs)
        write(joinpath(repository, "Project.toml"), "name = \"FixtureRepository\"\n")
        @test SciMLTesting._find_docs_src(package_root, "ApiFixture") == repository_docs

        unrelated_root = joinpath(repository, "packages", "ApiFixture")
        mkpath(unrelated_root)
        @test SciMLTesting._find_docs_src(unrelated_root, "ApiFixture") ==
            joinpath(unrelated_root, "docs", "src")

        mismatched_root = joinpath(repository, "lib", "OtherPackage")
        mkpath(mismatched_root)
        @test SciMLTesting._find_docs_src(mismatched_root, "ApiFixture") ==
            joinpath(mismatched_root, "docs", "src")

        package_docs = joinpath(package_root, "docs", "src")
        mkpath(package_docs)
        @test SciMLTesting._find_docs_src(package_root, "ApiFixture") == package_docs

        rm(joinpath(package_root, "docs"); recursive = true)
        write(
            joinpath(repository, "docs", "Project.toml"),
            "[deps]\nOtherPackage = \"00000000-0000-0000-0000-000000000000\"\n",
        )
        sibling_docs = joinpath(repository, "lib", "Facade", "docs", "src")
        mkpath(sibling_docs)
        write(
            joinpath(dirname(sibling_docs), "Project.toml"),
            "[deps]\nApiFixture = \"00000000-0000-0000-0000-000000000001\"\n",
        )
        @test SciMLTesting._find_docs_src(package_root, "ApiFixture") == sibling_docs

        workspace = mktempdir()
        workspace_package = joinpath(workspace, "ApiFixture.jl")
        mkpath(workspace_package)
        workspace_docs = joinpath(workspace, "docs", "src")
        mkpath(workspace_docs)
        write(
            joinpath(workspace, "Project.toml"),
            "[workspace]\nprojects = [\"ApiFixture.jl\"]\n",
        )
        @test SciMLTesting._find_docs_src(workspace_package, "ApiFixture") == workspace_docs
    end

    @testset "run_api_docs docstrings check" begin
        # Reuse the ProbeTestSet + count_results helpers from the broken-markers set to
        # count Pass/Fail/Broken without failing the enclosing suite.
        function count_results(ts)
            counts = Dict(:pass => 0, :fail => 0, :error => 0, :broken => 0)
            for r in ts.results
                if r isa Test.Pass
                    counts[:pass] += 1
                elseif r isa Test.Fail
                    counts[:fail] += 1
                elseif r isa Test.Error
                    counts[:error] += 1
                elseif r isa Test.Broken
                    counts[:broken] += 1
                elseif r isa Test.AbstractTestSet
                    sub = count_results(r)
                    for k in keys(counts)
                        counts[k] += sub[k]
                    end
                end
            end
            return counts
        end
        counts_of(body) = count_results(
            @testset ProbeTestSet "probe" begin
                body()
            end
        )

        # All-documented public API passes with no failures. SciMLTesting itself is the
        # real, non-mocked case: every exported name has a docstring, so this both
        # proves the happy path AND guards the package's own API-doc coverage.
        c = counts_of() do
            run_api_docs(SciMLTesting)
        end
        @test c[:fail] == 0 && c[:error] == 0
        @test c[:pass] >= 1

        # An explicitly imported public binding is documented by its owner; a
        # facade should not need to duplicate that definition-site docstring.
        c = counts_of() do
            run_api_docs(FunctionReexportFixture; rendered = false)
        end
        @test c[:fail] == 0 && c[:error] == 0

        # The fixture has undocumented public API -> one Fail (the docstrings @test).
        c = counts_of() do
            run_api_docs(ApiFixture; rendered = false)
        end
        @test c[:fail] == 1
        @test c[:broken] == 0

        binding_is_ambiguous = try
            which(AmbiguousConstantReexportFixture, :shared_constant)
            false
        catch
            true
        end
        c = counts_of() do
            run_api_docs(AmbiguousConstantReexportFixture; rendered = false)
        end
        @test c[:error] == 0
        @test c[:fail] == binding_is_ambiguous
        @test c[:pass] == !binding_is_ambiguous

        # Ignoring the undocumented names makes it pass. (:undocumented_public is not in
        # the API on 1.10, so ignoring it there is a harmless no-op.)
        c = counts_of() do
            run_api_docs(
                ApiFixture;
                rendered = false,
                ignore = (:undocumented_fn, :undocumented_public),
            )
        end
        @test c[:fail] == 0 && c[:error] == 0
        @test c[:pass] == 1

        # A reexported external module is public only because Julia exports a module's
        # own name; documenting it belongs to the package that defines it.
        c = counts_of() do
            run_api_docs(
                UndocumentedModuleReexportFixture;
                rendered = false,
                ignore = (:owned_function, :local_undocumented),
            )
        end
        @test c[:fail] == 0 && c[:error] == 0

        # The exemption covers modules only: a reexported function is still reported.
        c = counts_of() do
            run_api_docs(
                UndocumentedModuleReexportFixture;
                rendered = false,
                ignore = (:local_undocumented,),
            )
        end
        @test c[:fail] == 1

        @test SciMLTesting._is_external_module_reexport(
            UndocumentedModuleReexportFixture, :OwnedModule
        )
        @test !SciMLTesting._is_external_module_reexport(
            UndocumentedModuleReexportFixture, :owned_function
        )
        @test !SciMLTesting._is_external_module_reexport(
            LocalModuleFixture, :LocalSubmodule
        )

        # A package's own undocumented submodule is still the package's to document.
        # Only on 1.11+: the 1.10 `@doc` fallback renders an undocumented module as
        # "No docstring or readme file found", which `_has_docstring`'s substring never
        # matched, so no module is ever reported as undocumented there.
        @static if VERSION >= v"1.11"
            c = counts_of() do
                run_api_docs(LocalModuleFixture; rendered = false)
            end
            @test c[:fail] == 1
        end

        # docstrings_broken records Broken while names remain undocumented (migration).
        c = counts_of() do
            run_api_docs(ApiFixture; rendered = false, docstrings_broken = true)
        end
        @test c[:broken] == 1
        @test c[:fail] == 0

        # A fully-documented API under docstrings_broken is an Unexpected Pass (Error),
        # auto-flagging the caller to drop the flag.
        c = counts_of() do
            run_api_docs(SciMLTesting; rendered = false, docstrings_broken = true)
        end
        @test c[:error] == 1
        @test c[:broken] == 0
        @test c[:fail] == 0
    end

    @testset "run_api_docs rendered check" begin
        function count_results(ts)
            counts = Dict(:pass => 0, :fail => 0, :error => 0, :broken => 0)
            for r in ts.results
                if r isa Test.Pass
                    counts[:pass] += 1
                elseif r isa Test.Fail
                    counts[:fail] += 1
                elseif r isa Test.Error
                    counts[:error] += 1
                elseif r isa Test.Broken
                    counts[:broken] += 1
                elseif r isa Test.AbstractTestSet
                    sub = count_results(r)
                    for k in keys(counts)
                        counts[k] += sub[k]
                    end
                end
            end
            return counts
        end
        counts_of(body) = count_results(
            @testset ProbeTestSet "probe" begin
                body()
            end
        )

        api = public_api_names(ApiFixture)
        # A docs/src listing every public API name in a @docs block -> rendered passes.
        droot = mktempdir()
        src = joinpath(droot, "src"); mkpath(src)
        write(
            joinpath(src, "api.md"),
            "# API\n\n```@docs\n" * join(("ApiFixture." * String(n) for n in api), "\n") * "\n```\n",
        )
        c = counts_of() do
            run_api_docs(ApiFixture; docstrings = false, docs_src = src)
        end
        @test c[:fail] == 0 && c[:error] == 0
        @test c[:pass] == 1

        # Dropping one name from the block -> rendered fails (that name is unrendered).
        write(
            joinpath(src, "api.md"),
            "# API\n\n```@docs\n" *
                join(("ApiFixture." * String(n) for n in api if n != first(api)), "\n") * "\n```\n",
        )
        c = counts_of() do
            run_api_docs(ApiFixture; docstrings = false, rendered = true, docs_src = src)
        end
        @test c[:fail] == 1

        # ... but rendered_ignore on the dropped name makes it pass again.
        c = counts_of() do
            run_api_docs(
                ApiFixture; docstrings = false, rendered = true, docs_src = src,
                rendered_ignore = (first(api),),
            )
        end
        @test c[:fail] == 0 && c[:pass] == 1

        # External reexports are checked by public_reexports, not the local rendered
        # API-doc requirement.
        rroot = mktempdir()
        rsrc = joinpath(rroot, "src"); mkpath(rsrc)
        c = counts_of() do
            run_api_docs(ModuleReexportFixture; docstrings = false, docs_src = rsrc)
        end
        @test c[:fail] == 0 && c[:error] == 0 && c[:pass] == 1
        @test :SciMLTesting in public_api_names(ModuleReexportFixture)
        @test !SciMLTesting._requires_local_rendering(ModuleReexportFixture, :SciMLTesting)

        # The standalone defaults run both the docstring and rendered checks.
        c = counts_of() do
            run_api_docs(ScopedAutoDocsFixture; docs_src = rsrc)
        end
        @test c[:pass] == 1 && c[:fail] == 1 && c[:error] == 0

        c = counts_of() do
            run_api_docs(FunctionReexportFixture; docstrings = false, docs_src = rsrc)
        end
        @test c[:fail] == 0 && c[:error] == 0 && c[:pass] == 1
        @test :run_qa in public_api_names(FunctionReexportFixture)
        @test !SciMLTesting._requires_local_rendering(FunctionReexportFixture, :run_qa)
        @test !SciMLTesting._requires_local_rendering(ComprehensiveReexportFixture, :OwnedType)
        @test SciMLTesting._requires_local_rendering(NestedOwnerFixture, :NestedModule)

        # A package-owned submodule remains part of this package's rendered manual.
        c = counts_of() do
            run_api_docs(LocalModuleFixture; docstrings = false, docs_src = rsrc)
        end
        @test c[:fail] == 1

        # An @autodocs block counts only for the names its own scope renders.
        adroot = mktempdir()
        asrc = joinpath(adroot, "src"); mkpath(asrc)
        function autodocs_counts(settings)
            write(joinpath(asrc, "api.md"), "```@autodocs\n" * settings * "```\n")
            return counts_of() do
                run_api_docs(
                    ScopedAutoDocsFixture;
                    docstrings = false, rendered = true, docs_src = asrc,
                )
            end
        end

        # Scoped to the module, and to the file, the docstrings really come from.
        for settings in (
                "Modules = [ScopedAutoDocsFixture]\n",
                "Modules = [Main.ScopedAutoDocsFixture]\n",
                "Modules = [ScopedAutoDocsFixture]\nPages = [\"runtests.jl\"]\n",
                "Modules = [ScopedAutoDocsFixture]\nPrivate = false\n",
                "Modules = [ScopedAutoDocsFixture]\nOrder = [:function, :type]\n",
            )
            c = autodocs_counts(settings)
            @test c[:fail] == 0 && c[:error] == 0 && c[:pass] == 1
        end

        # Scoped to another module, to a module path that is not this one (including one
        # longer than the module's own name), to another source file, or away from public
        # names: the public API is not rendered, and a narrow block must not hide that.
        for settings in (
                "Modules = [SomeOtherPackage]\n",
                "Modules = [Outer.Nested.ScopedAutoDocsFixture]\n",
                "Modules = [ScopedAutoDocsFixture]\nPages = [\"systems/analysis_points.jl\"]\n",
                "Modules = [ScopedAutoDocsFixture]\nPublic = false\n",
                "Modules = [ScopedAutoDocsFixture]\nFilter = t -> false\n",
                "Modules = [ScopedAutoDocsFixture]\nFilter = dynamic_filter\n",
                "Modules = [ScopedAutoDocsFixture]\nOrder = [:type]\n",
                "Modules = [ScopedAutoDocsFixture]\nOrder = dynamic_order\n",
                "Modules = filter(_ -> false, [ScopedAutoDocsFixture])\n",
            )
            c = autodocs_counts(settings)
            @test c[:fail] == 1
        end

        # Documenter renders nothing for a `Modules`-less block, so one cannot stand in
        # for a rendered API either.
        c = autodocs_counts("Pages = [\"runtests.jl\"]\n")
        @test c[:fail] == 1

        # A public name whose docstring the docsystem cannot locate falls back to the
        # package itself, so a module-scoped block still covers ApiFixture's
        # undocumented exports rather than reporting them twice.
        write(joinpath(asrc, "api.md"), "```@autodocs\nModules = [ApiFixture]\n```\n")
        c = counts_of() do
            run_api_docs(ApiFixture; docstrings = false, rendered = true, docs_src = asrc)
        end
        @test c[:fail] == 0 && c[:pass] == 1
    end

    @testset "run_qa api_docs integration (default on)" begin
        function count_results(ts)
            counts = Dict(:pass => 0, :fail => 0, :error => 0, :broken => 0)
            for r in ts.results
                if r isa Test.Pass
                    counts[:pass] += 1
                elseif r isa Test.Fail
                    counts[:fail] += 1
                elseif r isa Test.Error
                    counts[:error] += 1
                elseif r isa Test.Broken
                    counts[:broken] += 1
                elseif r isa Test.AbstractTestSet
                    sub = count_results(r)
                    for k in keys(counts)
                        counts[k] += sub[k]
                    end
                end
            end
            return counts
        end
        counts_of(body) = count_results(
            @testset ProbeTestSet "probe" begin
                body()
            end
        )

        # api_docs defaults to `true`: a plain run_qa (all other tools off) still runs
        # the public-API docstring check. Against SciMLTesting (fully documented) that is
        # a clean pass — the default-on check fires (>=1 pass) with no failures.
        c = counts_of() do
            run_qa(
                SciMLTesting;
                Aqua = nothing,
                JET = nothing,
                ExplicitImports = nothing,
                explicit_imports = false,
            )
        end
        @test c[:pass] >= 1
        @test c[:fail] == 0 && c[:error] == 0 && c[:broken] == 0

        # api_docs_kwargs is forwarded (docstrings_broken flips the pass to a Broken).
        c = counts_of() do
            run_qa(
                SciMLTesting;
                Aqua = nothing,
                JET = nothing,
                ExplicitImports = nothing,
                explicit_imports = false,
                api_docs_kwargs = (; docstrings_broken = true),
            )
        end
        @test c[:error] == 1     # fully-documented under docstrings_broken => Unexpected Pass
        @test c[:fail] == 0

        # api_docs = false skips the check entirely: with every tool off, run_qa records
        # nothing at all.
        c = counts_of() do
            run_qa(
                SciMLTesting;
                Aqua = nothing,
                JET = nothing,
                ExplicitImports = nothing,
                explicit_imports = false,
                api_docs = false,
                check_reexports = false,
            )
        end
        @test c[:pass] == 0 && c[:fail] == 0 && c[:error] == 0 && c[:broken] == 0
    end

    @testset "run_qa public reexport integration (default on)" begin
        function count_results(ts)
            counts = Dict(:pass => 0, :fail => 0, :error => 0, :broken => 0)
            for r in ts.results
                if r isa Test.Pass
                    counts[:pass] += 1
                elseif r isa Test.Fail
                    counts[:fail] += 1
                elseif r isa Test.Error
                    counts[:error] += 1
                elseif r isa Test.Broken
                    counts[:broken] += 1
                elseif r isa Test.AbstractTestSet
                    sub = count_results(r)
                    for k in keys(counts)
                        counts[k] += sub[k]
                    end
                end
            end
            return counts
        end
        counts_of(body) = count_results(
            @testset ProbeTestSet "probe" begin
                body()
            end
        )
        qa_kwargs = (;
            Aqua = nothing, JET = nothing, ExplicitImports = nothing,
            explicit_imports = false, api_docs = false,
        )

        # The default path rejects every unapproved public reexport.
        c = counts_of() do
            run_qa(ComprehensiveReexportFixture; qa_kwargs...)
        end
        @test c[:fail] == 1 && c[:error] == 0

        # The enable flag still has an explicit diagnostic escape hatch.
        c = counts_of() do
            run_qa(ComprehensiveReexportFixture; qa_kwargs..., check_reexports = false)
        end
        @test c[:pass] == 0 && c[:fail] == 0 && c[:error] == 0

        # Intentional facade API passes only when every reexport is listed.
        c = counts_of() do
            run_qa(
                ComprehensiveReexportFixture;
                qa_kwargs...,
                reexports_allow = (:OwnedModule, :OwnedType, :owned_function, :owned_scalar),
            )
        end
        @test c[:pass] == 1 && c[:fail] == 0 && c[:error] == 0

        c = counts_of() do
            run_qa(
                UndocumentedModuleReexportFixture;
                Aqua = nothing,
                JET = nothing,
                ExplicitImports = nothing,
                explicit_imports = false,
                api_docs_kwargs = (; rendered = false, ignore = (:local_undocumented,)),
                reexports_allow = (:OwnedModule, :owned_function),
            )
        end
        @test c[:pass] == 1 && c[:fail] == 1 && c[:error] == 0

        c = counts_of() do
            run_qa(
                UndocumentedModuleReexportFixture;
                Aqua = nothing,
                JET = nothing,
                ExplicitImports = nothing,
                explicit_imports = false,
                api_docs_kwargs = (; rendered = false),
                reexports_allow = (:OwnedModule, :owned_function, :local_undocumented),
            )
        end
        @test c[:pass] == 1 && c[:fail] == 1 && c[:error] == 0
    end

    @testset "run_tests routing" begin
        # A scratch test/runtests-like layout with body files we can detect having
        # run via marker files (so we can assert routing without nested Pkg.test).
        root = mktempdir()
        marker(name) = joinpath(root, "ran_$(name)")
        ran(name) = isfile(marker(name))
        clear!() = foreach(["core", "extra", "qa"]) do n
            isfile(marker(n)) && rm(marker(n))
        end
        bodyfile(name) = begin
            p = joinpath(root, "$(name).jl")
            # The included body uses @testset/@test WITHOUT its own `using Test`:
            # run_tests must bring Test into scope for it.
            write(
                p,
                "@testset \"$(name)\" begin\n    @test true\nend\nwrite($(repr(marker(name))), \"1\")\n"
            )
            p
        end
        core = bodyfile("core")
        extra = bodyfile("extra")
        qa = bodyfile("qa")

        # "Core" runs only core.
        clear!()
        withenv("GROUP" => "Core") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test ran("core") && !ran("extra") && !ran("qa")

        # "All" runs core + every in-process group but NEVER qa: QA is its own
        # GROUP=QA lane, so a downstream harness that mutates the package's
        # Project.toml and runs GROUP=All cannot trip the package's Aqua checks.
        clear!()
        withenv("GROUP" => "All") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test ran("core") && ran("extra") && !ran("qa")

        # Empty GROUP normalizes to the default "All".
        clear!()
        withenv("GROUP" => "") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test ran("core") && ran("extra") && !ran("qa")

        # Curated "All" that explicitly lists "QA" still excludes it (QA is never
        # part of "All"); the other listed groups still run.
        clear!()
        withenv("GROUP" => "All") do
            run_tests(;
                core = core, groups = Dict("Extra" => extra), qa = qa,
                all = ["Core", "Extra", "QA"]
            )
        end
        @test ran("core") && ran("extra") && !ran("qa")

        # A named functional group runs only that group.
        clear!()
        withenv("GROUP" => "Extra") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test !ran("core") && ran("extra") && !ran("qa")

        # "QA" runs only qa.
        clear!()
        withenv("GROUP" => "QA") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test !ran("core") && !ran("extra") && ran("qa")

        # QA requested but not provided -> error.
        withenv("GROUP" => "QA") do
            @test_throws ArgumentError run_tests(; core = core)
        end

        # Unknown group falls through to core.
        clear!()
        withenv("GROUP" => "Nonexistent") do
            run_tests(; core = core, groups = Dict("Extra" => extra))
        end
        @test ran("core") && !ran("extra")

        # A 0-arg thunk body works too.
        clear!()
        thunk_ran = Ref(false)
        withenv("GROUP" => "Core") do
            run_tests(; core = () -> (thunk_ran[] = true))
        end
        @test thunk_ran[]
    end

    @testset "run_tests included file uses @testset without using Test" begin
        # Regression (ConcreteStructs bug): the included file references @testset
        # and @test with NO `using Test` of its own; run_tests must guarantee Test
        # is in scope for it.
        root = mktempdir()
        marker = joinpath(root, "did_run")
        body = joinpath(root, "body.jl")
        write(
            body,
            "@testset \"no using Test here\" begin\n" *
                "    @test 1 + 1 == 2\n" *
                "    @test_throws BoundsError [1][2]\n" *
                "end\n" *
                "write($(repr(marker)), \"ok\")\n"
        )
        withenv("GROUP" => "Core") do
            run_tests(; core = body)
        end
        @test isfile(marker)
    end

    @testset "run_tests file body: nested include define-then-call (world age)" begin
        # Regression (MuladdMacro pattern, InternalJunk#51): a file-path Core body
        # that, inside a single @testset, defines a function via a nested `include`
        # of a fixture file and then CALLS that function in the same testset. Under
        # the old fresh-module `Base.include` (or thunk invokelatest) this raised a
        # world-age `MethodError` ("method too new to be called from this world
        # context"); running the body inside its own `@safetestset` (an isolated
        # module whose body advances world age per top-level statement, exactly like
        # a hand-written runtests.jl's toplevel `include`) makes the
        # nested-include-defined method callable in the same expression.
        root = mktempdir()
        marker = joinpath(root, "did_run")
        # Fixture defining the function, included by the body (mirrors MuladdMacro's
        # `include(to_muladd, testfile)` defining test_muladd_include).
        fixture = joinpath(root, "fixture.jl")
        write(fixture, "wa_defined(a, b, c) = a * b + c\n")
        body = joinpath(root, "core.jl")
        # Note: the body deliberately has NO `using Test` of its own, and the
        # include + call happen inside the SAME @testset (the world-age trap).
        write(
            body,
            "@testset \"nested include define-then-call\" begin\n" *
                "    include($(repr(fixture)))\n" *
                "    @test wa_defined(2.0, 3.0, 4.0) == 10.0\n" *
                "end\n" *
                "write($(repr(marker)), \"ok\")\n",
        )
        withenv("GROUP" => "Core") do
            run_tests(; core = body)
        end
        @test isfile(marker)
    end

    @testset "run_tests file bodies are isolated (@safetestset, no cross-group leak)" begin
        # Regression: file-path group bodies run in their own `@safetestset` module,
        # so a global/const/method defined by one group is INVISIBLE to the next.
        # Group A defines a const, a plain global, and a method; group B must NOT see
        # any of them (each reference must raise an UndefVarError), proving the two
        # bodies do not share a namespace.
        root = mktempdir()
        a_ran = joinpath(root, "a_ran")
        b_ran = joinpath(root, "b_ran")

        a = joinpath(root, "a.jl")
        write(
            a,
            "const ISO_CONST = 7\n" *
                "global iso_global = 11\n" *
                "iso_method() = ISO_CONST + iso_global\n" *
                "@testset \"A defines symbols\" begin\n" *
                "    @test iso_method() == 18\n" *
                "end\n" *
                "write($(repr(a_ran)), \"ok\")\n",
        )

        # Group B references each of A's symbols; in an isolated module each lookup
        # must throw UndefVarError. If the bodies shared a namespace these would
        # resolve and the @test ... isa UndefVarError assertions would fail.
        b = joinpath(root, "b.jl")
        write(
            b,
            "@testset \"B cannot see A's symbols\" begin\n" *
                "    @test (try; ISO_CONST;  catch e; e; end) isa UndefVarError\n" *
                "    @test (try; iso_global; catch e; e; end) isa UndefVarError\n" *
                "    @test (try; iso_method(); catch e; e; end) isa UndefVarError\n" *
                "end\n" *
                "write($(repr(b_ran)), \"ok\")\n",
        )

        # Run A then B as two separate file groups via the umbrella expansion (each
        # is dispatched as its own group, exactly as a real run would route them).
        withenv("GROUP" => "Both") do
            run_tests(;
                core = () -> nothing,
                groups = Dict("A" => a, "B" => b),
                umbrellas = Dict("Both" => ["A", "B"]),
            )
        end
        @test isfile(a_ran)   # A ran and defined its symbols
        @test isfile(b_ran)   # B ran and (its @tests) confirmed it could not see them
    end

    @testset "run_tests sublib_env handoff (distinct read/handoff vars)" begin
        # Extension 1: a monorepo whose root reads one variable (`GROUP`) but whose
        # sublibraries read a *different* one (`ODEDIFFEQ_TEST_GROUP`). The root must
        # pick the sublibrary off `env` and hand the sub-group off via `sublib_env`,
        # NOT via `env`. We exercise this without a real nested Pkg.test by building a
        # fake sublibrary package whose own runtests records which env vars it saw.
        root = mktempdir()
        lib = joinpath(root, "lib")
        sub = joinpath(lib, "MySub")
        mkpath(joinpath(sub, "src"))
        write(
            joinpath(sub, "Project.toml"),
            """
            name = "MySub"
            uuid = "22222222-2222-2222-2222-222222222222"
            version = "0.1.0"

            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

            [targets]
            test = ["Test"]
            """,
        )
        write(joinpath(sub, "src", "MySub.jl"), "module MySub\nend\n")
        # The sublibrary's runtests records the read var (handoff) and the root var,
        # so the assertion can prove the handoff arrived on `sublib_env`, not `env`.
        seen = joinpath(root, "seen.txt")
        mkpath(joinpath(sub, "test"))
        write(
            joinpath(sub, "test", "runtests.jl"),
            """
            handoff = get(ENV, "SUB_TEST_GROUP", "<unset>")
            rootvar = get(ENV, "GROUP", "<unset>")
            open($(repr(seen)), "w") do io
                println(io, "handoff=", handoff)
                println(io, "rootvar=", rootvar)
            end
            """,
        )

        original_project = Base.active_project()
        try
            # Root reads GROUP="MySub_Special"; sublib must receive Special on
            # SUB_TEST_GROUP. GROUP itself is left at the root value during the
            # sublibrary Pkg.test, so the sublibrary reading GROUP would see the
            # *wrong* (root) value — proving the handoff must use sublib_env.
            withenv("GROUP" => "MySub_Special", "SUB_TEST_GROUP" => nothing) do
                run_tests(;
                    core = () -> nothing,
                    lib_dir = lib,
                    sublib_env = "SUB_TEST_GROUP",
                )
            end
            contents = read(seen, String)
            @test occursin("handoff=Special", contents)
            # The root var, if the sublibrary had (wrongly) read it for its group,
            # carries the full unstripped root value — definitely not "Special".
            @test occursin("rootvar=MySub_Special", contents)
            @test !occursin("handoff=MySub_Special", contents)
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "run_tests curated `all` (excludes a group and QA)" begin
        # Extension 2: a curated `all` list that runs Core + a chosen subset, while
        # EXCLUDING both a registered functional group (Heavy) and QA. The excluded
        # groups must NOT run under "All" but MUST still run when selected by name.
        root = mktempdir()
        marker(name) = joinpath(root, "ran_$(name)")
        ran(name) = isfile(marker(name))
        clear!() = foreach(["core", "light", "heavy", "qa"]) do n
            isfile(marker(n)) && rm(marker(n))
        end
        bodyfile(name) = begin
            p = joinpath(root, "$(name).jl")
            write(
                p,
                "@testset \"$(name)\" begin\n    @test true\nend\nwrite($(repr(marker(name))), \"1\")\n",
            )
            p
        end
        core = bodyfile("core")
        light = bodyfile("light")
        heavy = bodyfile("heavy")
        qa = bodyfile("qa")
        groups = Dict("Light" => light, "Heavy" => heavy)

        # Curated "All": Core + Light only. Heavy and QA are excluded.
        clear!()
        withenv("GROUP" => "All") do
            run_tests(;
                core = core, groups = groups, qa = qa,
                all = ["Core", "Light"]
            )
        end
        @test ran("core") && ran("light")
        @test !ran("heavy") && !ran("qa")

        # The excluded group is still selectable by name.
        clear!()
        withenv("GROUP" => "Heavy") do
            run_tests(;
                core = core, groups = groups, qa = qa,
                all = ["Core", "Light"]
            )
        end
        @test ran("heavy") && !ran("core") && !ran("light") && !ran("qa")

        # QA, excluded from "All", is still selectable by name.
        clear!()
        withenv("GROUP" => "QA") do
            run_tests(;
                core = core, groups = groups, qa = qa,
                all = ["Core", "Light"]
            )
        end
        @test ran("qa") && !ran("core") && !ran("light") && !ran("heavy")

        # A curated list omitting "Core" does NOT run core under "All".
        clear!()
        withenv("GROUP" => "All") do
            run_tests(;
                core = core, groups = groups, qa = qa,
                all = ["Light"]
            )
        end
        @test ran("light") && !ran("core") && !ran("heavy") && !ran("qa")

        # A curated list naming an unknown key errors.
        withenv("GROUP" => "All") do
            @test_throws ArgumentError run_tests(;
                core = core, groups = groups,
                qa = qa, all = ["Core", "Nonexistent"]
            )
        end
    end

    @testset "run_tests Everything (uncurated full suite, explicit mode)" begin
        # "Everything" ignores the curated `all` list and runs core + every groups
        # entry + qa. Contrast with "All", which only runs the curated list and
        # never QA. (Sub-env activation is covered by other activate_group_env /
        # QA-folder tests; here bodies are plain thunks so we isolate routing.)
        root = mktempdir()
        marker(name) = joinpath(root, "ran_$(name)")
        ran(name) = isfile(marker(name))
        clear!() = foreach(["core", "light", "heavy", "qa"]) do n
            isfile(marker(n)) && rm(marker(n))
        end
        touch!(name) = write(marker(name), "1")
        core = () -> touch!("core")
        groups = Dict(
            "Light" => () -> touch!("light"),
            "Heavy" => () -> touch!("heavy"),
        )
        qa = () -> touch!("qa")
        curated = ["Core", "Light"]   # deliberately omits Heavy and QA

        # Under "All" with a curated list: only Core + Light; never QA / Heavy.
        clear!()
        withenv("GROUP" => "All") do
            run_tests(; core = core, groups = groups, qa = qa, all = curated)
        end
        @test ran("core") && ran("light")
        @test !ran("heavy") && !ran("qa")

        # Under "Everything": core + Heavy + Light + QA, ignoring curated `all`.
        clear!()
        withenv("GROUP" => "Everything") do
            run_tests(; core = core, groups = groups, qa = qa, all = curated)
        end
        @test ran("core") && ran("light") && ran("heavy") && ran("qa")

        # run_everything is the thin withenv wrapper around the same path.
        clear!()
        run_everything(; core = core, groups = groups, qa = qa, all = curated)
        @test ran("core") && ran("light") && ran("heavy") && ran("qa")

        # "Everything" is reserved: never misrouted to a sublibrary even with lib_dir.
        lib = mktempdir()
        mkdir(joinpath(lib, "SomeSublib"))
        clear!()
        withenv("GROUP" => "Everything") do
            run_tests(;
                core = core,
                groups = Dict("Light" => () -> touch!("light")),
                qa = qa, lib_dir = lib,
            )
        end
        @test ran("core") && ran("light") && ran("qa")
    end

    @testset "run_tests umbrella groups" begin
        # Extension 3: an umbrella key expands to >= 2 member groups, each run in
        # turn. Selecting the umbrella runs all members; selecting a member alone
        # runs just it. Members may include the reserved "Core"/"QA" bodies.
        root = mktempdir()
        marker(name) = joinpath(root, "ran_$(name)")
        ran(name) = isfile(marker(name))
        clear!() = foreach(["core", "i1", "i2", "i3", "qa"]) do n
            isfile(marker(n)) && rm(marker(n))
        end
        bodyfile(name) = begin
            p = joinpath(root, "$(name).jl")
            write(
                p,
                "@testset \"$(name)\" begin\n    @test true\nend\nwrite($(repr(marker(name))), \"1\")\n",
            )
            p
        end
        core = bodyfile("core")
        i1 = bodyfile("i1")
        i2 = bodyfile("i2")
        i3 = bodyfile("i3")
        qa = bodyfile("qa")
        groups = Dict("InterfaceI" => i1, "InterfaceII" => i2, "InterfaceIII" => i3)
        umbrellas = Dict("Interface" => ["InterfaceI", "InterfaceII", "InterfaceIII"])

        # The umbrella runs all three members and nothing else.
        clear!()
        withenv("GROUP" => "Interface") do
            run_tests(; core = core, groups = groups, qa = qa, umbrellas = umbrellas)
        end
        @test ran("i1") && ran("i2") && ran("i3")
        @test !ran("core") && !ran("qa")

        # A member is still selectable on its own.
        clear!()
        withenv("GROUP" => "InterfaceII") do
            run_tests(; core = core, groups = groups, qa = qa, umbrellas = umbrellas)
        end
        @test ran("i2") && !ran("i1") && !ran("i3") && !ran("core")

        # An umbrella whose members include reserved Core/QA bodies.
        clear!()
        umb2 = Dict("Bundle" => ["Core", "InterfaceI", "QA"])
        withenv("GROUP" => "Bundle") do
            run_tests(; core = core, groups = groups, qa = qa, umbrellas = umb2)
        end
        @test ran("core") && ran("i1") && ran("qa") && !ran("i2") && !ran("i3")

        # An umbrella member that is not a known group errors.
        clear!()
        withenv("GROUP" => "Bad") do
            @test_throws ArgumentError run_tests(;
                core = core, groups = groups,
                umbrellas = Dict("Bad" => ["InterfaceI", "Ghost"])
            )
        end

        # An umbrella key takes precedence over an identically named groups entry.
        clear!()
        groups_clash = Dict("Interface" => i3, "InterfaceI" => i1, "InterfaceII" => i2)
        withenv("GROUP" => "Interface") do
            run_tests(;
                core = core, groups = groups_clash, qa = qa,
                umbrellas = Dict("Interface" => ["InterfaceI", "InterfaceII"])
            )
        end
        @test ran("i1") && ran("i2") && !ran("i3")
    end

    @testset "run_tests sublibrary empty-group guard" begin
        # Regression (Corleone bug): with a lib/ dir present, an empty/unset GROUP
        # must route to core, NOT be misdetected as a sublibrary because
        # isdir(joinpath(lib_dir, "")) is true. Reserved names must also fall
        # through rather than being treated as sublibraries.
        root = mktempdir()
        lib = joinpath(root, "lib"); mkpath(joinpath(lib, "RealSublib"))
        ran_core = Ref(0)
        corethunk = () -> (ran_core[] += 1)

        # Empty GROUP -> core, never a (bogus) sublibrary Pkg.test.
        withenv("GROUP" => "") do
            run_tests(; core = corethunk, lib_dir = lib)
        end
        @test ran_core[] == 1

        # "All" (a reserved name) with a lib dir present -> core, not a sublibrary.
        withenv("GROUP" => "All") do
            run_tests(; core = corethunk, lib_dir = lib)
        end
        @test ran_core[] == 2

        # "Core" reserved -> core.
        withenv("GROUP" => "Core") do
            run_tests(; core = corethunk, lib_dir = lib)
        end
        @test ran_core[] == 3

        # A GROUP that is not an existing sublibrary and not a known group also
        # falls through to core (does not attempt a Pkg.test on a missing lib).
        withenv("GROUP" => "NotASublib") do
            run_tests(; core = corethunk, lib_dir = lib)
        end
        @test ran_core[] == 4
    end

    @testset "read_test_groups" begin
        # [groups.X] layout with per-group options.
        d1 = mktempdir()
        write(
            joinpath(d1, "test_groups.toml"),
            """
            [groups.Interface]
            in_all = true

            [groups.QA]
            in_all = false
            """,
        )
        g1 = read_test_groups(d1)
        @test sort(collect(keys(g1))) == ["Interface", "QA"]
        @test g1["Interface"]["in_all"] == true
        @test g1["QA"]["in_all"] == false

        # Bare top-level layout (each group its own table), empty table = defaults.
        d2 = mktempdir()
        write(
            joinpath(d2, "test_groups.toml"),
            """
            [Interface]
            [QA]
            in_all = false
            """,
        )
        g2 = read_test_groups(d2)
        @test sort(collect(keys(g2))) == ["Interface", "QA"]
        @test isempty(g2["Interface"])           # no options -> default in_all = true
        @test g2["QA"]["in_all"] == false

        # Missing file is an error (folder mode requires the group list).
        d3 = mktempdir()
        @test_throws ArgumentError read_test_groups(d3)
    end

    @testset "run_tests folder mode: Core = top-level files only" begin
        # Core = all top-level test/*.jl EXCEPT runtests.jl, NOT recursing into
        # subfolders. Marker files prove exactly which files ran.
        tdir = mktempdir()
        write(joinpath(tdir, "test_groups.toml"), "[Interface]\n")
        # runtests.jl must NOT be (recursively) run by Core discovery.
        write(joinpath(tdir, "runtests.jl"), "error(\"runtests.jl was discovered/run\")\n")
        mkfile(name) = begin
            write(
                joinpath(tdir, "$(name).jl"),
                "@testset \"$(name)\" begin\n  @test true\nend\nwrite(joinpath(@__DIR__, \"ran_$(name)\"), \"1\")\n",
            )
        end
        mkfile("a_core")
        mkfile("b_core")
        # A subfolder under the test dir must NOT be picked up by Core (no recursion).
        mkpath(joinpath(tdir, "subdir"))
        write(joinpath(tdir, "subdir", "deep.jl"), "error(\"Core recursed into a subfolder\")\n")
        ran(n) = isfile(joinpath(tdir, "ran_$(n)"))

        withenv("GROUP" => "Core") do
            run_tests(; test_dir = tdir)
        end
        @test ran("a_core") && ran("b_core")  # both top-level files ran
        # runtests.jl not run (no error thrown) and subdir not recursed (no error).
    end

    @testset "run_tests folder mode: named group runs ALL its files (enforced)" begin
        # A named group folder runs EVERY *.jl in it: 3 files -> all 3 run. This is the
        # enforcement guarantee (you cannot forget to register a file).
        tdir = mktempdir()
        write(joinpath(tdir, "test_groups.toml"), "[Interface]\n")
        write(joinpath(tdir, "core_only.jl"), "@test true\n")  # a Core file (unused here)
        gdir = joinpath(tdir, "Interface"); mkpath(gdir)
        for f in ("one", "two", "three")
            write(
                joinpath(gdir, "$(f).jl"),
                "@testset \"$(f)\" begin\n  @test true\nend\nwrite(joinpath(@__DIR__, \"ran_$(f)\"), \"1\")\n",
            )
        end
        ran(n) = isfile(joinpath(gdir, "ran_$(n)"))

        withenv("GROUP" => "Interface") do
            run_tests(; test_dir = tdir)
        end
        @test ran("one") && ran("two") && ran("three")  # all 3 files ran
    end

    @testset "run_tests folder mode: case-insensitive folder match" begin
        # group "Interface" finds a lowercase test/interface/ folder.
        tdir = mktempdir()
        write(joinpath(tdir, "test_groups.toml"), "[Interface]\n")
        write(joinpath(tdir, "c.jl"), "@test true\n")
        gdir = joinpath(tdir, "interface"); mkpath(gdir)   # lowercase folder
        write(
            joinpath(gdir, "x.jl"),
            "@testset \"x\" begin @test true end\nwrite(joinpath(@__DIR__, \"ran\"), \"1\")\n",
        )
        withenv("GROUP" => "Interface") do
            run_tests(; test_dir = tdir)
        end
        @test isfile(joinpath(gdir, "ran"))
    end

    @testset "run_tests folder mode: QA folder with own Project.toml is activated" begin
        # QA folder has its own Project.toml -> activate_group_env (Pkg.activate +
        # develop pkg by path + instantiate) before running its files. We prove
        # activation happened by having the QA file record Base.active_project().
        original_project = Base.active_project()
        repo = mktempdir()
        write(
            joinpath(repo, "Project.toml"),
            """
            name = "TinyQAPkg"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.1.0"
            """,
        )
        mkpath(joinpath(repo, "src"))
        write(joinpath(repo, "src", "TinyQAPkg.jl"), "module TinyQAPkg\nend\n")
        tdir = joinpath(repo, "test"); mkpath(tdir)
        write(joinpath(tdir, "test_groups.toml"), "[QA]\nin_all = false\n")
        write(joinpath(tdir, "main.jl"), "@test true\n")  # a Core file
        qadir = joinpath(tdir, "qa"); mkpath(qadir)
        # Empty (deps-free) group Project.toml -> activate_group_env develops the repo
        # root into it and instantiates.
        write(joinpath(qadir, "Project.toml"), "")
        seen = joinpath(repo, "seen_project")
        write(
            joinpath(qadir, "qa.jl"),
            "@testset \"qa\" begin\n  @test true\nend\n" *
                "write($(repr(seen)), Base.active_project())\n",
        )
        try
            withenv("GROUP" => "QA") do
                run_tests(; test_dir = tdir)
            end
            @test isfile(seen)
            # The active project during the QA file run was the sandbox copy of the
            # qa/ group env, with the repo-root package developed into it, and the
            # env in the repo itself was left untouched.
            active = read(seen, String)
            @test basename(active) == "Project.toml"
            @test !samefile(dirname(active), qadir)
            envdeps = Pkg.TOML.parsefile(active)
            @test haskey(get(envdeps, "deps", Dict()), "TinyQAPkg")
            @test read(joinpath(qadir, "Project.toml"), String) == ""
        finally
            Pkg.activate(original_project)
        end
    end

    @testset "run_tests folder mode: All = Core + groups, NOT QA, honors in_all=false" begin
        # "All" runs Core (top-level files) + every group folder EXCEPT QA and except
        # any group with in_all = false. Heavy (in_all = false) and QA must not run;
        # Light must.
        tdir = mktempdir()
        write(
            joinpath(tdir, "test_groups.toml"),
            """
            [Light]
            [Heavy]
            in_all = false
            [QA]
            """,
        )
        markerfile(rel, name) = "write(joinpath(@__DIR__, \"$(rel)ran_$(name)\"), \"1\")\n"
        # Core top-level file.
        write(
            joinpath(tdir, "core.jl"),
            "@testset \"core\" begin @test true end\n" * markerfile("", "core"),
        )
        for (grp, file) in (("Light", "l"), ("Heavy", "h"))
            d = joinpath(tdir, grp); mkpath(d)
            write(
                joinpath(d, "$(file).jl"),
                "@testset \"$(file)\" begin @test true end\n" * markerfile("../", "$(grp)"),
            )
        end
        qd = joinpath(tdir, "qa"); mkpath(qd)
        write(
            joinpath(qd, "q.jl"),
            "@testset \"q\" begin @test true end\n" * markerfile("../", "QA"),
        )
        ran(n) = isfile(joinpath(tdir, "ran_$(n)"))

        withenv("GROUP" => "All") do
            run_tests(; test_dir = tdir)
        end
        @test ran("core")          # Core (top-level files) ran
        @test ran("Light")         # in_all (default) group ran
        @test !ran("Heavy")        # in_all = false excluded from All
        @test !ran("QA")           # QA always excluded from All

        # Heavy and QA are still selectable by name.
        rm(joinpath(tdir, "ran_core")); rm(joinpath(tdir, "ran_Light"))
        withenv("GROUP" => "Heavy") do
            run_tests(; test_dir = tdir)
        end
        @test ran("Heavy") && !ran("Light") && !ran("core") && !ran("QA")

        # "Everything" runs Core + Light + Heavy + QA (ignores in_all, includes QA).
        for n in ("core", "Light", "Heavy", "QA")
            isfile(joinpath(tdir, "ran_$(n)")) && rm(joinpath(tdir, "ran_$(n)"))
        end
        withenv("GROUP" => "Everything") do
            run_tests(; test_dir = tdir)
        end
        @test ran("core") && ran("Light") && ran("Heavy") && ran("QA")

        # run_everything hits the same path for folder mode.
        for n in ("core", "Light", "Heavy", "QA")
            isfile(joinpath(tdir, "ran_$(n)")) && rm(joinpath(tdir, "ran_$(n)"))
        end
        run_everything(; test_dir = tdir)
        @test ran("core") && ran("Light") && ran("Heavy") && ran("QA")
    end

    @testset "run_tests folder mode: matrix-only `group` alias section demands no folder" begin
        # A section with a `group` key (e.g. a 32-bit CI lane `["Core 32-bit"]
        # group = "Core"`) is a matrix-only alias for another group's body. It has
        # no test folder, so All/Everything must SKIP it (not throw "folder missing"),
        # and selecting it by name runs the target group.
        tdir = mktempdir()
        write(
            joinpath(tdir, "test_groups.toml"),
            """
            ["Core 32-bit"]
            group = "Core"
            arch = "x86"
            [Light]
            """,
        )
        markerfile(rel, name) = "write(joinpath(@__DIR__, \"$(rel)ran_$(name)\"), \"1\")\n"
        write(
            joinpath(tdir, "core.jl"),
            "@testset \"core\" begin @test true end\n" * markerfile("", "core"),
        )
        ld = joinpath(tdir, "Light"); mkpath(ld)
        write(
            joinpath(ld, "l.jl"),
            "@testset \"l\" begin @test true end\n" * markerfile("../", "Light"),
        )
        ran(n) = isfile(joinpath(tdir, "ran_$(n)"))
        clear() = for n in ("core", "Light")
            isfile(joinpath(tdir, "ran_$(n)")) && rm(joinpath(tdir, "ran_$(n)"))
        end

        # All: the alias section is skipped — no `test/Core 32-bit/` folder is
        # demanded (previously this threw ArgumentError), Core + Light still run.
        withenv("GROUP" => "All") do
            run_tests(; test_dir = tdir)
        end
        @test ran("core") && ran("Light")

        # Everything: same skip, no throw.
        clear()
        withenv("GROUP" => "Everything") do
            run_tests(; test_dir = tdir)
        end
        @test ran("core") && ran("Light")

        # Selecting the alias by name runs the target group's body (Core), not Light.
        clear()
        withenv("GROUP" => "Core 32-bit") do
            run_tests(; test_dir = tdir)
        end
        @test ran("core") && !ran("Light")
    end

    @testset "run_tests folder mode: non-group subfolder (shared/) is ignored" begin
        # A subfolder that is NOT a declared group (test/shared/) is never discovered.
        # It is where shared include/fixture files live. Selecting any group must not
        # run files inside it.
        tdir = mktempdir()
        write(joinpath(tdir, "test_groups.toml"), "[Interface]\n")
        write(
            joinpath(tdir, "core.jl"),
            "@testset \"c\" begin @test true end\nwrite(joinpath(@__DIR__, \"ran_core\"), \"1\")\n",
        )
        gdir = joinpath(tdir, "Interface"); mkpath(gdir)
        write(
            joinpath(gdir, "i.jl"),
            "@testset \"i\" begin @test true end\nwrite(joinpath(@__DIR__, \"..\", \"ran_i\"), \"1\")\n",
        )
        # shared/ is NOT a group: its file must never auto-run (it would error if it did).
        shared = joinpath(tdir, "shared"); mkpath(shared)
        write(joinpath(shared, "fixture.jl"), "error(\"shared/ was auto-discovered\")\n")

        ran(n) = isfile(joinpath(tdir, "ran_$(n)"))
        withenv("GROUP" => "Core") do
            run_tests(; test_dir = tdir)
        end
        @test ran("core")  # Core ran; shared/ not discovered (no error)
        rm(joinpath(tdir, "ran_core"))
        withenv("GROUP" => "Interface") do
            run_tests(; test_dir = tdir)
        end
        @test ran("i")     # Interface ran; shared/ still not discovered
    end

    @testset "run_tests folder mode: @safetestset isolation between files" begin
        # Each discovered file runs in its own @safetestset module, so a def in one
        # file is invisible to another in the same group. File a defines symbols; file
        # b asserts each lookup throws UndefVarError. Sorted order makes a.jl run first.
        tdir = mktempdir()
        write(joinpath(tdir, "test_groups.toml"), "[Iso]\n")
        write(joinpath(tdir, "main.jl"), "@test true\n")
        gdir = joinpath(tdir, "Iso"); mkpath(gdir)
        write(
            joinpath(gdir, "a.jl"),
            "const ISO_CONST = 7\n" *
                "global iso_global = 11\n" *
                "iso_method() = ISO_CONST + iso_global\n" *
                "@testset \"a defines\" begin @test iso_method() == 18 end\n" *
                "write(joinpath(@__DIR__, \"ran_a\"), \"1\")\n",
        )
        write(
            joinpath(gdir, "b.jl"),
            "@testset \"b cannot see a\" begin\n" *
                "  @test (try; ISO_CONST;   catch e; e; end) isa UndefVarError\n" *
                "  @test (try; iso_global;  catch e; e; end) isa UndefVarError\n" *
                "  @test (try; iso_method(); catch e; e; end) isa UndefVarError\n" *
                "end\n" *
                "write(joinpath(@__DIR__, \"ran_b\"), \"1\")\n",
        )
        withenv("GROUP" => "Iso") do
            run_tests(; test_dir = tdir)
        end
        @test isfile(joinpath(gdir, "ran_a")) && isfile(joinpath(gdir, "ran_b"))
    end

    @testset "run_tests folder mode: missing / empty group folder errors" begin
        # A declared group whose folder is MISSING is an error (misnamed group).
        tdir = mktempdir()
        write(joinpath(tdir, "test_groups.toml"), "[Interface]\n")
        write(joinpath(tdir, "core.jl"), "@test true\n")
        # No test/Interface/ folder at all.
        withenv("GROUP" => "Interface") do
            @test_throws ArgumentError run_tests(; test_dir = tdir)
        end

        # A declared group whose folder EXISTS but is EMPTY (no *.jl) is an error.
        tdir2 = mktempdir()
        write(joinpath(tdir2, "test_groups.toml"), "[Interface]\n")
        write(joinpath(tdir2, "core.jl"), "@test true\n")
        mkpath(joinpath(tdir2, "Interface"))  # empty folder
        withenv("GROUP" => "Interface") do
            @test_throws ArgumentError run_tests(; test_dir = tdir2)
        end

        # An empty Core (no top-level test files) is an error.
        tdir3 = mktempdir()
        write(joinpath(tdir3, "test_groups.toml"), "[Interface]\n")
        mkpath(joinpath(tdir3, "Interface"))
        write(joinpath(tdir3, "Interface", "i.jl"), "@test true\n")
        # runtests.jl alone is not a Core test file; Core is empty.
        write(joinpath(tdir3, "runtests.jl"), "@test true\n")
        withenv("GROUP" => "Core") do
            @test_throws ArgumentError run_tests(; test_dir = tdir3)
        end

        # An unknown GROUP (not All/Core/QA, not declared) is an error.
        tdir4 = mktempdir()
        write(joinpath(tdir4, "test_groups.toml"), "[Interface]\n")
        write(joinpath(tdir4, "core.jl"), "@test true\n")
        withenv("GROUP" => "Bogus") do
            @test_throws ArgumentError run_tests(; test_dir = tdir4)
        end
    end

    @testset "run_tests explicit-args mode still works (backward-compat)" begin
        # Supplying core (or groups/qa) selects the v1.1.x explicit-args mode even
        # without a test_groups.toml present in the caller's dir.
        root = mktempdir()
        marker = joinpath(root, "core_ran")
        body = joinpath(root, "body.jl")
        write(
            body,
            "@testset \"explicit core\" begin @test true end\nwrite($(repr(marker)), \"1\")\n",
        )
        withenv("GROUP" => "Core") do
            run_tests(; core = body)   # explicit core -> legacy mode, no folder discovery
        end
        @test isfile(marker)

        # Explicit groups-only (core unset) also selects legacy mode.
        marker2 = joinpath(root, "grp_ran")
        gbody = joinpath(root, "grp.jl")
        write(
            gbody,
            "@testset \"g\" begin @test true end\nwrite($(repr(marker2)), \"1\")\n",
        )
        withenv("GROUP" => "G") do
            run_tests(; groups = Dict("G" => gbody))
        end
        @test isfile(marker2)
    end
end
