# SciMLTesting.jl

[![Build Status](https://github.com/SciML/SciMLTesting.jl/workflows/Tests/badge.svg)](https://github.com/SciML/SciMLTesting.jl/actions?query=workflow%3ATests)
[![SciML Code Style](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle)

Shared test-harness helpers for SciML packages.

Every SciML test suite — single packages and monorepos alike — repeats the same
`test/runtests.jl` boilerplate: read a `GROUP` environment variable, activate a
per-group `test/<Group>/Project.toml` and `develop` the package under test by path,
run a standard Aqua/JET quality-assurance body, and (for monorepos) route a `GROUP`
value to the right `lib/<Sub>` sublibrary. `SciMLTesting` factors those pieces into
documented helpers so each repo's `runtests.jl` becomes `using SciMLTesting` plus a
few calls — or a single declarative [`run_tests`](#the-run_tests-dispatcher) call —
instead of copy-pasted setup.

The package depends only on the standard libraries `Pkg`, `TOML`, and `Test`. It is
intentionally **light**: it does not depend on Aqua or JET. The `run_qa` helper takes
the already-loaded `Aqua`/`JET` modules as keyword arguments, so those heavier tools
stay in each repo's `test/qa/Project.toml` and never enter `SciMLTesting`'s graph.

## Installation

```julia
using Pkg
Pkg.add("SciMLTesting")
```

In a package, add it to the `test` target (it is a test-only dependency):

```toml
[extras]
SciMLTesting = "09d9d899-5365-40a9-917a-5f67fddea283"

[targets]
test = ["Test", "SciMLTesting", ...]
```

## API

| Helper | Summary |
| --- | --- |
| `run_tests(; core, groups, qa, env, default, lib_dir, parent, pkg)` | Declarative top-level dispatcher: owns the whole `runtests.jl` group-routing flow. |
| `current_group(; env = "GROUP", default = "All")` | Read the test-group env var, defaulting to `"All"` (empty string also normalizes to the default). |
| `activate_group_env(group_dir; parent, develop, instantiate, develop_sources)` | `Pkg.activate` a per-group `Project.toml`, `develop` the parent package(s) by path, backport `[sources]`, `instantiate`. |
| `develop_sources!(group_dir; parent)` | On Julia < 1.11, `Pkg.develop` the env's `[sources]` path graph (recursively); a no-op on 1.11+. |
| `run_qa(pkg; Aqua, JET, aqua, jet, ...)` | Run the standard Aqua/JET QA body, taking the loaded modules as kwargs. |
| `detect_sublibrary_group(group, lib_dir; default_group = "Core")` | Map a `GROUP` value to a `(sublibrary, test_group)` pair for a monorepo. |

All are documented with full docstrings; `?run_tests` etc. at the REPL.

### No `Pkg` needed in your `[extras]`

`SciMLTesting` bundles `Pkg` and performs every `Pkg.activate`/`develop`/
`instantiate`/`test` internally. A repo whose `runtests.jl` uses `run_tests` (or the
`activate_group_env`/`detect_sublibrary_group` helpers) therefore no longer needs
`Pkg` in its own `[extras]`/`test` target — only `SciMLTesting` (plus whatever the
test bodies themselves load, e.g. `Aqua`/`JET` in a QA sub-env). This removes the
`Pkg`-in-`[extras]` dependency-compat nit.

## Usage

### The `run_tests` dispatcher

`run_tests` is the recommended top-level entry point: it owns the entire
group-routing control flow, so a repo replaces its hand-written
`if GROUP == "All" ... elseif GROUP == "QA" ...` ladder with one declarative call.

```julia
# test/runtests.jl
using SciMLTesting

run_tests(;
    # Core / default body: a file to include, or a 0-arg thunk. Run for "All"/"Core".
    core = joinpath(@__DIR__, "core_tests.jl"),

    # Extra functional groups: GROUP name => file/thunk, or a (; body, env, parent)
    # table to activate a per-group sub-env first. No-`env` groups also run under "All".
    groups = Dict(
        "Downstream" => joinpath(@__DIR__, "downstream_tests.jl"),
    ),

    # QA group: run for "QA" (and under "All"). A sub-env carries Aqua/JET.
    qa = (; env = joinpath(@__DIR__, "qa"), body = joinpath(@__DIR__, "qa", "qa.jl")),
)
```

and `test/qa/qa.jl`:

```julia
using MyPackage, Aqua
using SciMLTesting
run_qa(MyPackage; Aqua = Aqua)
```

Key guarantees:

  * **`using Test` is in scope for every included file.** File-path bodies are
    `include`d into a fresh module that has `using Test`, so an included file may use
    `@testset`/`@test`/`@test_throws` without its own `using Test`.
  * **Empty/unset `GROUP` and `"All"` are normalized correctly**, and the empty
    group and reserved names (`All`/`Core`/`QA`) are never misrouted to a
    sublibrary (even though `isdir(joinpath(lib_dir, ""))` is `true`).
  * **No `Pkg` in your `[extras]`** — see the note above.

For a monorepo, pass `lib_dir`; a `GROUP` naming a `lib/<Sub>` sublibrary is
activated and `Pkg.test`ed automatically, while `All`/`Core`/`QA`/empty fall through
to the root bodies:

```julia
# monorepo root test/runtests.jl
using SciMLTesting
run_tests(;
    core = joinpath(@__DIR__, "core_tests.jl"),
    lib_dir = joinpath(@__DIR__, "..", "lib"),
)
```

The lower-level helpers below remain available for repos that need bespoke control
flow beyond what `run_tests` expresses.

### A single-package `test/runtests.jl` (manual helpers)

```julia
using SciMLTesting
using SafeTestsets, Test

const GROUP = current_group()   # ENV["GROUP"] or "All"

@time begin
    if GROUP == "All" || GROUP == "Core"
        @safetestset "My Core Tests" include("core/core_tests.jl")
    end

    if GROUP == "All" || GROUP == "QA"
        # test/qa/Project.toml carries Aqua/JET; activate it and develop this repo.
        activate_group_env(joinpath(@__DIR__, "qa"))
        @safetestset "QA" include("qa/qa.jl")
    end
end
```

and `test/qa/qa.jl`:

```julia
using MyPackage, Aqua, JET
using SciMLTesting

run_qa(MyPackage; Aqua = Aqua, JET = JET, jet = true)
```

### A monorepo root `test/runtests.jl` (manual helpers)

```julia
using SciMLTesting
using Pkg, Test

const GROUP = current_group()
const LIB_DIR = joinpath(@__DIR__, "..", "lib")

sublib, grp = detect_sublibrary_group(GROUP, LIB_DIR)
# Guard the empty group: isdir(joinpath(LIB_DIR, "")) is true, so an empty/unset
# GROUP must not be misrouted to a sublibrary.
if !isempty(sublib) && isdir(joinpath(LIB_DIR, sublib))
    Pkg.activate(joinpath(LIB_DIR, sublib))
    withenv("MYPKG_TEST_GROUP" => grp) do
        Pkg.test(sublib; allow_reresolve = true)
    end
else
    # root-package dispatch on `GROUP` ...
end
```

A monorepo sublibrary group that must develop both the sublibrary and the monorepo
root:

```julia
activate_group_env(
    joinpath(@__DIR__, "qa");
    parent = [joinpath(@__DIR__, ".."), joinpath(@__DIR__, "..", "..", "..")],
)
```

## License

MIT. See [LICENSE](LICENSE).
