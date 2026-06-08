# SciMLTesting.jl

[![Build Status](https://github.com/SciML/SciMLTesting.jl/workflows/Tests/badge.svg)](https://github.com/SciML/SciMLTesting.jl/actions?query=workflow%3ATests)
[![SciML Code Style](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle)

Shared test-harness helpers for SciML packages.

Every SciML test suite — single packages and monorepos alike — repeats the same
`test/runtests.jl` boilerplate: read a `GROUP` environment variable, activate a
per-group `test/<Group>/Project.toml` and `develop` the package under test by path,
run a standard Aqua/JET quality-assurance body, and (for monorepos) route a `GROUP`
value to the right `lib/<Sub>` sublibrary. `SciMLTesting` factors those pieces into
four documented helpers so each repo's `runtests.jl` becomes `using SciMLTesting`
plus a few calls instead of copy-pasted setup.

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
| `current_group(; env = "GROUP", default = "All")` | Read the test-group env var, defaulting to `"All"`. |
| `activate_group_env(group_dir; parent, develop, instantiate)` | `Pkg.activate` a per-group `Project.toml`, `develop` the parent package(s) by path, `instantiate`. |
| `run_qa(pkg; Aqua, JET, aqua, jet, ...)` | Run the standard Aqua/JET QA body, taking the loaded modules as kwargs. |
| `detect_sublibrary_group(group, lib_dir; default_group = "Core")` | Map a `GROUP` value to a `(sublibrary, test_group)` pair for a monorepo. |

All four are documented with full docstrings; `?current_group` etc. at the REPL.

## Usage

### A single-package `test/runtests.jl`

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

### A monorepo root `test/runtests.jl`

```julia
using SciMLTesting
using Pkg, Test

const GROUP = current_group()
const LIB_DIR = joinpath(@__DIR__, "..", "lib")

sublib, grp = detect_sublibrary_group(GROUP, LIB_DIR)
if isdir(joinpath(LIB_DIR, sublib))
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
