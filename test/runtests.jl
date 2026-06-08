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
end
