using SciMLTesting
using Test
using Pkg
# Aqua and ExplicitImports are direct SciMLTesting deps, so they load with it. `using
# JET` triggers SciMLTesting's JET weakdep extension, whose `__init__` registers JET
# with SciMLTesting (see the "JET auto-detection" testset); JET must be available in
# the test env for the extension to load.
using JET

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
    function test_package(pkg; target_modules = nothing, mode = nothing, kwargs...)
        @test pkg === SciMLTesting
        @test mode === :typo
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
    const PUBLIC_CALLED = Ref(false)   # set when a public-API check stub runs (gated to >= 1.11)
    _short(f::Symbol) = Symbol(replace(String(f), "check_" => ""))
    _result(f::Symbol) = _short(f) in FINDINGS[] ? "<finding>" : nothing
    for f in (
            :check_no_implicit_imports, :check_no_stale_explicit_imports,
            :check_all_explicit_imports_via_owners, :check_all_qualified_accesses_via_owners,
            :check_all_explicit_imports_are_public,
        )
        @eval $f(pkg; kwargs...) = (@test pkg === SciMLTesting; _result($(QuoteNode(f))))
    end
    function check_all_qualified_accesses_are_public(pkg; ignore = (), kwargs...)
        PUBLIC_CALLED[] = true
        @test pkg === SciMLTesting
        @test ignore == (:internal_thing,)
        return _result(:check_all_qualified_accesses_are_public)
    end
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
            # The activated project is the group's Project.toml ...
            @test Base.active_project() == joinpath(group_dir, "Project.toml")
            # ... and the repo-root package was developed into it by path.
            deps = Pkg.TOML.parsefile(Base.active_project())
            @test haskey(deps, "deps") && haskey(deps["deps"], "TinyPkg")

            # `develop = false` / `instantiate = false` just activates.
            other = joinpath(repo, "test", "core")
            mkpath(other)
            write(joinpath(other, "Project.toml"), "")
            activate_group_env(other; develop = false, instantiate = false)
            @test Base.active_project() == joinpath(other, "Project.toml")
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
            @test Base.active_project() == joinpath(group_dir, "Project.toml")
            if VERSION < v"1.11"
                manifest = Pkg.TOML.parsefile(joinpath(group_dir, "Manifest.toml"))
                entries = get(manifest, "deps", manifest)
                @test get(entries["Sib"][1], "path", nothing) == abspath(sib)
                @test get(entries["RootPkg"][1], "path", nothing) == abspath(repo)
            end
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
        # turns it on, passing `nothing` turns it off); `explicit_imports` defaults to
        # `false` and must be requested explicitly.

        # Aqua-only.
        run_qa(SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = nothing)
        # Aqua + JET.
        run_qa(SciMLTesting; Aqua = FakeAqua, JET = FakeJET, ExplicitImports = nothing)
        # JET-only (Aqua off via Aqua = nothing).
        run_qa(SciMLTesting; Aqua = nothing, JET = FakeJET, ExplicitImports = nothing)

        # Aqua + ExplicitImports (standard + public-API); per-check ignore-list routed via ei_kwargs.
        run_qa(
            SciMLTesting; Aqua = FakeAqua, JET = nothing, ExplicitImports = FakeExplicitImports,
            explicit_imports = true,
            ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,)))
        )
        # The direct helper.
        run_explicit_imports(
            SciMLTesting, FakeExplicitImports;
            ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_thing,)))
        )

        # Backward-compat: old explicit `Aqua = Aqua, jet = true` form behaves identically.
        run_qa(
            SciMLTesting; Aqua = FakeAqua, JET = FakeJET, jet = true,
            ExplicitImports = nothing
        )

        # Helpful errors when an enable flag is forced on but the module is unavailable.
        @test_throws ArgumentError run_qa(
            SciMLTesting; Aqua = nothing, aqua = true,
            JET = nothing, ExplicitImports = nothing
        )
        @test_throws ArgumentError run_qa(
            SciMLTesting; Aqua = nothing, JET = nothing,
            jet = true, ExplicitImports = nothing
        )
        @test_throws ArgumentError run_qa(
            SciMLTesting; Aqua = nothing, JET = nothing,
            ExplicitImports = nothing, explicit_imports = true
        )
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
                clean_sources = false,
                aqua_kwargs = (; ambiguities = true), aqua_broken = (:ambiguities,),
            )
        end
        @test FakeAqua.LAST_KWARGS[].ambiguities === false   # broken-disable overrode `true`

        # `jet_broken` with a non-empty report registers exactly one Broken (the
        # `@test_broken isempty(...)`), no failures; and `mode` was dropped (FakeJET's
        # report_package asserts it never receives `mode`), while target_modules passes through.
        FakeJET.REPORTS[] = Symbol[:fake_report]
        FakeJET.LAST_REPORT_KWARGS[] = nothing
        c = counts_of() do
            run_qa(
                SciMLTesting; Aqua = nothing, JET = FakeJET, ExplicitImports = nothing,
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
                clean_sources = false,
            )
        end
        @test c[:broken] == 0
        @test c[:fail] == 0
        @test c[:error] == 0
        # No broken-disable keys leaked into the Aqua call.
        @test !haskey(FakeAqua.LAST_KWARGS[], :ambiguities)
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

    @testset "run_qa enable-flag defaulting" begin
        # `jet` defaults from the registry (the one weakdep): registered => on,
        # unregistered => off. `explicit_imports` defaults OFF even though
        # ExplicitImports is always available (opt-in, so a routine bump never turns
        # the per-repo ExplicitImports checks on for existing callers). `aqua` is
        # forced off throughout so the real Aqua never runs against SciMLTesting itself.
        saved = copy(SciMLTesting._QA_MODULES)
        try
            delete!(SciMLTesting._QA_MODULES, :JET)
            # JET unregistered + aqua off + EI default off => run_qa is a no-op (no error).
            run_qa(SciMLTesting; aqua = false)

            # Register a Fake JET: `jet` now defaults on and run_qa runs it.
            SciMLTesting._register_qa_tool!(:JET, FakeJET)
            @test SciMLTesting._qa_tool(:JET) === FakeJET
            run_qa(SciMLTesting; aqua = false)              # runs FakeJET via the registry default
            run_qa(SciMLTesting; aqua = false, jet = false) # explicit off skips it (no error)
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
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa,
                all = ["Core", "Extra", "QA"])
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
            # The active project during the QA file run was the qa/ group env, and the
            # repo-root package was developed into it. Compare with `samefile` rather
            # than string equality: on case-insensitive filesystems (macOS, Windows)
            # the group folder is resolved to the requested casing ("QA"), so the
            # recorded `active_project()` differs textually from the lowercase on-disk
            # `qadir` while pointing at the same directory.
            active = read(seen, String)
            @test basename(active) == "Project.toml"
            @test samefile(dirname(active), qadir)
            envdeps = Pkg.TOML.parsefile(joinpath(qadir, "Project.toml"))
            @test haskey(get(envdeps, "deps", Dict()), "TinyQAPkg")
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
