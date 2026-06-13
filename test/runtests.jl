using SciMLTesting
using Test
using Pkg

# Stand-in modules so the test exercises run_qa without a hard dependency on
# Aqua/JET: they only need to expose the methods run_qa calls. Modules must be
# defined at top level, not inside a @testset.
module FakeAqua
    using Test: @test
    import ..SciMLTesting
    test_all(pkg; kwargs...) = (@test pkg === SciMLTesting; true)
end

module FakeJET
    using Test: @test
    import ..SciMLTesting
    function test_package(pkg; target_modules = nothing, mode = nothing, kwargs...)
        @test pkg === SciMLTesting
        @test mode === :typo
        return true
    end
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

    @testset "run_qa" begin
        # Aqua-only (the default).
        run_qa(SciMLTesting; Aqua = FakeAqua)
        # Aqua + JET.
        run_qa(SciMLTesting; Aqua = FakeAqua, JET = FakeJET, jet = true)
        # JET-only.
        run_qa(SciMLTesting; JET = FakeJET, aqua = false, jet = true)

        # Helpful errors when a requested tool was not supplied.
        @test_throws ArgumentError run_qa(SciMLTesting)
        @test_throws ArgumentError run_qa(SciMLTesting; aqua = false, jet = true)
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
        # develop_sources! is a no-op).
        root = mktempdir()
        # Layout:
        #   root/env/Project.toml   [sources] A -> ../A
        #   root/A/Project.toml     [sources] B -> ../B   (relative to A, not env)
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
            "name = \"A\"\nuuid = \"00000000-0000-0000-0000-000000000002\"\n\n[sources]\nB = { path = \"../B\" }\n"
        )
        write(
            joinpath(b, "Project.toml"),
            "name = \"B\"\nuuid = \"00000000-0000-0000-0000-000000000003\"\n"
        )

        paths = SciMLTesting._collect_source_paths(envd)
        @test paths == [abspath(a), abspath(b)]

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

        # A cycle (A -> B -> A) terminates and visits each path once.
        croot = mktempdir()
        ca = joinpath(croot, "A"); mkpath(ca)
        cb = joinpath(croot, "B"); mkpath(cb)
        write(
            joinpath(ca, "Project.toml"),
            "[sources]\nB = { path = \"../B\" }\n"
        )
        write(
            joinpath(cb, "Project.toml"),
            "[sources]\nA = { path = \"../A\" }\n"
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
                "@testset \"$(name)\" begin\n    @test true\nend\nwrite(\"$(marker(name))\", \"1\")\n"
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

        # "All" runs core + every in-process group + qa.
        clear!()
        withenv("GROUP" => "All") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test ran("core") && ran("extra") && ran("qa")

        # Empty GROUP normalizes to the default "All".
        clear!()
        withenv("GROUP" => "") do
            run_tests(; core = core, groups = Dict("Extra" => extra), qa = qa)
        end
        @test ran("core") && ran("extra") && ran("qa")

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
                "write(\"$(marker)\", \"ok\")\n"
        )
        withenv("GROUP" => "Core") do
            run_tests(; core = body)
        end
        @test isfile(marker)
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
end
