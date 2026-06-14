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
| `run_tests(; test_dir, core, groups, qa, env, default, sublib_env, all, umbrellas, lib_dir, parent, pkg)` | Declarative top-level dispatcher: owns the whole `runtests.jl` group-routing flow. With no `core`/`groups`/`qa` it runs in folder-discovery mode (groups = folders); supplying any of them selects the explicit-args mode. |
| `read_test_groups(test_dir)` | Read `test_dir/test_groups.toml` (the group list + per-group config such as `in_all`) used by folder-discovery mode. |
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

### Folder-discovery mode (the default — `run_tests()`)

The recommended layout uses **folder discovery**: call `run_tests()` with no
arguments and let it discover test files from folders. A whole `test/runtests.jl`
becomes:

```julia
# test/runtests.jl
using SciMLTesting
run_tests()
```

with a `test/test_groups.toml` that is the single source of truth for both the CI
matrix and the test groups:

```toml
# test/test_groups.toml — lists the groups (CI matrix) + per-group config
[Core]
versions = ["lts", "1", "pre"]
os = ["ubuntu-latest", "macos-latest", "windows-latest"]

[Interface]              # a named group => test/Interface/*.jl

[QA]                     # QA => test/qa/*.jl; always excluded from "All"
versions = ["lts", "1"]
```

and a test directory laid out as folders:

```
test/
├── runtests.jl          # using SciMLTesting; run_tests()
├── test_groups.toml     # the group list + CI config
├── basic_tests.jl       # Core  = the top-level test/*.jl files
├── more_tests.jl        # Core  (every top-level file runs, runtests.jl excluded)
├── Interface/           # group "Interface"  => all of test/Interface/*.jl
│   ├── a.jl
│   └── b.jl
├── qa/                  # group "QA"  => all of test/qa/*.jl
│   ├── Project.toml     #   a sub-env: Aqua/JET/... live here, activated first
│   └── qa.jl
└── shared/              # NOT a declared group => never auto-discovered
    └── fixtures.jl      #   helpers/fixtures `include`d by test files live here
```

How a `GROUP` maps to files (each file runs via the isolated `@safetestset` include
path, in sorted order, labelled `"<group>/<basename>"`):

  * **`Core`** → every top-level `test/*.jl` **except** `runtests.jl`, without
    recursing into subdirectories. (Core = the main test folder, the normal SciML
    layout.) Core uses the main test env — no activation.
  * **a named group `X`** (any `test_groups.toml` key other than `Core`/`QA`) → every
    `*.jl` in `test/X/`, matching the folder name exactly then case-insensitively
    (`Interface` finds `test/Interface/` or `test/interface/`).
  * **`QA`** → every `*.jl` in `test/qa/` (or `test/QA/`).
  * **`All`** (unset/empty `GROUP`) → Core **plus** every group folder in
    `test_groups.toml` **except** `QA` and except any group marked `in_all = false`
    (curated All).

Guarantees specific to folder mode:

  * **Enforced coverage.** *Every* `*.jl` in the selected group's folder runs — you
    cannot forget to register a test file by leaving it out of an `include` list. A
    declared group whose folder is **missing or empty** is an **error** (catches a
    mis-named or empty group), as is an empty `Core` and an unknown `GROUP`.
  * **Sub-env per group.** If a group folder has its own `Project.toml` (e.g.
    `test/qa/Project.toml`), it is activated (`Pkg.activate` + develop the package by
    path + `instantiate`, with the `<1.11` `[sources]` backport) before its files
    run. Core has no `Project.toml`, so it uses the main test env.
  * **Helpers/fixtures.** Only the *selected group's* folder is globbed, so a subfolder
    that is **not** a declared group (e.g. `test/shared/`) is never auto-discovered —
    that is where shared `include` fixtures and helper files live.

Override the discovered directory with `test_dir = @__DIR__` if `run_tests` cannot
infer the call site (e.g. when called indirectly). Supplying any of `core`/`groups`/
`qa` switches to the explicit-args mode documented next.

> **Add `SafeTestsets` (and `Test`) to your test target.** Folder mode runs each file
> inside a `@safetestset`, whose generated module does `using Test, SafeTestsets`, so
> both must be resolvable from the active project — list `SafeTestsets` and `Test` in
> the repo's `[extras]`/`test` target, and in any group sub-env (e.g.
> `test/qa/Project.toml`) whose files also run under `@safetestset`. This matches the
> existing SciML convention for `@safetestset`-based suites (OrdinaryDiffEq.jl, ...).

### The `run_tests` dispatcher (explicit-args mode)

For repos that need bespoke routing, `run_tests` also accepts explicit `core`/
`groups`/`qa` arguments — supplying any of them selects this mode. It owns the entire
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

  * **File-path bodies run in an isolated `@safetestset` (world-age-safe + isolated).**
    A file-path body is run inside its own `@safetestset` — a fresh module —
    mirroring OrdinaryDiffEq.jl's canonical
    `@safetestset "X" begin include("x.jl") end`. A module body advances world age
    per top-level statement, so a file that defines a method via a nested
    `include(mapexpr, file)` (or plain `include`) and then calls it in the same
    `@testset` works, and each group runs in its own namespace so globals/consts/
    methods one group defines do not leak into the next. (A thunk runs in a single
    function world in the caller's scope: it is neither world-age-safe nor isolated,
    so use a file path for any define-then-call or isolation-sensitive body.)
  * **`using Test` is in scope for every included file.** `@safetestset` brings the
    full Test API into the generated module, so an included file may use
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

#### Complex monorepos: `sublib_env`, curated `all`, umbrella groups

Some monorepo roots (OrdinaryDiffEq.jl, RecursiveArrayTools.jl, ...) need control
flow that a uniform `GROUP` dispatch cannot express. Three optional kwargs cover
them; all default to the v1.0.0 behavior, so existing callers are unchanged.

  * **`sublib_env`** — the env var the sublibrary handoff sets, defaulting to `env`.
    OrdinaryDiffEq's root reads `GROUP` to pick a sublibrary, but the sublibraries
    read `ODEDIFFEQ_TEST_GROUP`. Set `sublib_env = "ODEDIFFEQ_TEST_GROUP"`: the root
    still reads `env` (`GROUP`) to select the sublibrary, but the sub-group is handed
    off via `withenv(sublib_env => subgroup)`, not `env`.

  * **`all`** — a curated list of the group keys `"All"` runs, replacing the
    hardwired "`core` + every env-less group + `qa`". `core` runs under `"All"` only
    if `"Core"` is listed, and `qa` only if `"QA"` is listed — so a repo can exclude
    `qa` and heavy groups (OrdinaryDiffEq's `"All"` excludes `AlgConvergence_*` and
    QA) while keeping them selectable by name.

  * **`umbrellas`** — a `Dict` mapping an umbrella key to a list of member group
    keys. When `GROUP` equals the umbrella key, every member runs in order. Members
    may name `groups` entries or the reserved `"Core"`/`"QA"` bodies; an umbrella key
    wins over an identically named `groups` entry.

```julia
# complex monorepo root test/runtests.jl
using SciMLTesting
run_tests(;
    core = joinpath(@__DIR__, "core_tests.jl"),
    groups = Dict(
        "InterfaceI"  => joinpath(@__DIR__, "interface_i.jl"),
        "InterfaceII" => joinpath(@__DIR__, "interface_ii.jl"),
        "Regression_I"  => joinpath(@__DIR__, "regression_i.jl"),
        "Regression_II" => joinpath(@__DIR__, "regression_ii.jl"),
        "AlgConvergence_I" => joinpath(@__DIR__, "alg_i.jl"),  # excluded from "All"
    ),
    qa = (; env = joinpath(@__DIR__, "qa"), body = joinpath(@__DIR__, "qa", "qa.jl")),

    # "All" runs exactly these (Core + interfaces + regressions); QA and
    # AlgConvergence_* are excluded but remain selectable by name.
    all = ["Core", "InterfaceI", "InterfaceII", "Regression_I", "Regression_II"],

    # GROUP=Interface runs all five interface groups; GROUP=Regression runs both.
    umbrellas = Dict(
        "Interface"  => ["InterfaceI", "InterfaceII"],
        "Regression" => ["Regression_I", "Regression_II"],
    ),

    # Root reads GROUP; sublibraries read ODEDIFFEQ_TEST_GROUP.
    sublib_env = "ODEDIFFEQ_TEST_GROUP",
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
