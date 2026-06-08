"""
    SciMLTesting

Shared test-harness helpers for SciML packages.

The SciML test suites (both single packages and monorepos like OrdinaryDiffEq.jl
and Corleone.jl) repeat the same boilerplate in every `test/runtests.jl` and every
`lib/<Sub>/test/runtests.jl`:

  * reading the `GROUP` environment variable to select which test group to run,
  * activating a per-group `test/<Group>/Project.toml`, `Pkg.develop`-ing the
    package under test by path (so CI tests the PR-branch code rather than a
    registered version), and `Pkg.instantiate`-ing,
  * a standard QA group body that runs Aqua and JET, and
  * a monorepo root dispatcher that maps a `GROUP` value to a `(sublibrary, group)`
    pair so the bare sublibrary name selects its `Core` group and
    `"<sublibrary>_<group>"` selects a named group.

This package factors those pieces into documented helpers so each repo's
`runtests.jl` becomes `using SciMLTesting` plus a few calls instead of copy-pasted
setup. It deliberately depends only on the standard libraries `Pkg`, `TOML`, and
`Test`; the QA helper accepts the already-loaded `Aqua`/`JET` modules as keyword
arguments so that those heavier tools stay in each repo's `test/qa/Project.toml`
and never enter `SciMLTesting`'s own dependency graph.
"""
module SciMLTesting

using Pkg: Pkg
using TOML: TOML
using Test: @testset, @test

export current_group, activate_group_env, run_qa, detect_sublibrary_group

"""
    current_group(; env = "GROUP", default = "All")

Return the requested test group, read from the environment variable named `env`
(default `"GROUP"`), falling back to `default` (default `"All"`) when that
variable is unset.

This replaces the `const GROUP = get(ENV, "GROUP", "All")` line copied into every
SciML `test/runtests.jl`. SciML group names are capitalized (`All`, `Core`, `QA`,
...); the value is returned verbatim with no case normalization.

# Examples

```julia
using SciMLTesting
const GROUP = current_group()                       # ENV["GROUP"] or "All"
const SUBGROUP = current_group(env = "ODE_TEST_GROUP", default = "Core")
```
"""
function current_group(; env::AbstractString = "GROUP", default::AbstractString = "All")
    return get(ENV, env, default)
end

"""
    activate_group_env(group_dir; parent = dirname(dirname(abspath(group_dir))),
                        develop = true, instantiate = true)

Activate the per-group test environment at `group_dir` and prepare it for testing
the in-repo package.

`group_dir` is the directory holding the group's own `Project.toml` (for example
`joinpath(@__DIR__, "qa")` or `joinpath(@__DIR__, "downstream")`). The steps are:

  1. `Pkg.activate(group_dir)`,
  2. when `develop` is `true`, `Pkg.develop` each path in `parent` so the
     activated environment uses the local (PR-branch) source of the package under
     test instead of a registered release, and
  3. when `instantiate` is `true`, `Pkg.instantiate()`.

`parent` may be a single path or an iterable of paths (a monorepo sublibrary group
typically develops both the sublibrary and the monorepo root). It defaults to the
repository root inferred from `group_dir` as `test/<Group>` ⇒ repo root, i.e.
`dirname(dirname(group_dir))`.

This replaces the `activate_qa_env` / `activate_downstream_env` /
`activate_examples_env` helpers copied into every SciML `runtests.jl`, which all
do `Pkg.activate(...)`, `Pkg.develop(path = ...)`, `Pkg.instantiate()`.

# Examples

```julia
# single-package QA group: test/qa/Project.toml, develop the repo root
activate_group_env(joinpath(@__DIR__, "qa"))

# monorepo sublibrary group: develop both the sublibrary and the monorepo root
activate_group_env(
    joinpath(@__DIR__, "qa");
    parent = [joinpath(@__DIR__, ".."), joinpath(@__DIR__, "..", "..", "..")],
)
```
"""
function activate_group_env(
        group_dir::AbstractString;
        parent = dirname(dirname(abspath(group_dir))),
        develop::Bool = true,
        instantiate::Bool = true,
    )
    Pkg.activate(group_dir)
    if develop
        parents = parent isa AbstractString ? (parent,) : parent
        specs = [Pkg.PackageSpec(path = abspath(p)) for p in parents]
        isempty(specs) || Pkg.develop(specs)
    end
    instantiate && Pkg.instantiate()
    return nothing
end

"""
    run_qa(pkg; Aqua = nothing, JET = nothing,
           aqua = true, jet = false,
           aqua_kwargs = (;), jet_kwargs = (; target_modules = (pkg,), mode = :typo),
           testset = "Quality Assurance")

Run the standard SciML quality-assurance body for module `pkg`.

`SciMLTesting` intentionally does not depend on Aqua or JET. To keep those tools in
each repo's `test/qa/Project.toml` only, pass the already-loaded modules in as the
`Aqua` and `JET` keyword arguments; whichever is supplied (and enabled) is run:

  * `Aqua` + `aqua = true` ⇒ `Aqua.test_all(pkg; aqua_kwargs...)`,
  * `JET` + `jet = true` ⇒ `JET.test_package(pkg; jet_kwargs...)`.

`aqua` defaults to `true` and `jet` to `false` (JET's typo/type checks are
opt-in per repo). The whole thing runs inside a `@testset` named `testset`.

This replaces the per-repo `qa.jl`/`jet.jl` bodies that all call
`Aqua.test_all(pkg)` and `JET.test_package(pkg; target_modules = (pkg,), mode = :typo)`.

# Examples

```julia
# in test/qa/qa.jl, after `using Aqua, MyPackage`
using SciMLTesting
run_qa(MyPackage; Aqua = Aqua)

# also run JET typo checks
using Aqua, JET
run_qa(MyPackage; Aqua = Aqua, JET = JET, jet = true)
```
"""
function run_qa(
        pkg::Module;
        Aqua = nothing,
        JET = nothing,
        aqua::Bool = true,
        jet::Bool = false,
        aqua_kwargs = (;),
        jet_kwargs = (; target_modules = (pkg,), mode = :typo),
        testset::AbstractString = "Quality Assurance",
    )
    # Validate before entering the @testset: a `throw` inside a testset is
    # recorded as an errored test result rather than propagating, which would
    # make these misconfiguration errors impossible to `@test_throws`-catch.
    aqua && Aqua === nothing &&
        throw(ArgumentError("run_qa: `aqua = true` but no `Aqua` module was passed; call `run_qa(pkg; Aqua = Aqua)`"))
    jet && JET === nothing &&
        throw(ArgumentError("run_qa: `jet = true` but no `JET` module was passed; call `run_qa(pkg; JET = JET, jet = true)`"))
    @testset "$testset" begin
        aqua && Aqua.test_all(pkg; aqua_kwargs...)
        jet && JET.test_package(pkg; jet_kwargs...)
    end
    return nothing
end

"""
    detect_sublibrary_group(group, lib_dir; default_group = "Core") -> (sublibrary, test_group)

Map a `GROUP` value to a `(sublibrary, test_group)` pair for a monorepo whose
sublibraries live under `lib_dir`.

The convention, shared by OrdinaryDiffEq.jl and Corleone.jl, is:

  * a bare sublibrary name (e.g. `"OrdinaryDiffEqTsit5"`) selects that sublibrary's
    `default_group` (`"Core"`), and
  * `"<sublibrary>_<group>"` (e.g. `"OrdinaryDiffEqTsit5_QA"`) selects the named
    group of that sublibrary.

Underscores are scanned right-to-left so that the longest existing-directory
prefix wins (sublibrary names themselves may contain underscores). If no
sublibrary directory matches, `(group, default_group)` is returned so the caller
can fall through to its root-package dispatch.

This replaces the `_detect_sublibrary_group` closure copied into the root
`test/runtests.jl` of each SciML monorepo. Use `isdir(joinpath(lib_dir, sublib))`
on the returned `sublibrary` to decide whether to route to a sublibrary.

# Examples

```julia
lib_dir = joinpath(@__DIR__, "..", "lib")
sublib, grp = detect_sublibrary_group(current_group(), lib_dir)
if isdir(joinpath(lib_dir, sublib))
    Pkg.activate(joinpath(lib_dir, sublib))
    withenv("MYPKG_TEST_GROUP" => grp) do
        Pkg.test(sublib; allow_reresolve = true)
    end
else
    # root-package dispatch on `grp`
end
```
"""
function detect_sublibrary_group(
        group::AbstractString,
        lib_dir::AbstractString;
        default_group::AbstractString = "Core",
    )
    isdir(joinpath(lib_dir, group)) && return (group, default_group)
    for i in lastindex(group):-1:firstindex(group)
        if group[i] == '_' && isdir(joinpath(lib_dir, group[firstindex(group):prevind(group, i)]))
            return (group[firstindex(group):prevind(group, i)], group[nextind(group, i):end])
        end
    end
    return (group, default_group)
end

end # module SciMLTesting
