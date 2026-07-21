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

Beyond the standard libraries `Pkg`, `TOML`, and `Test` (and the tiny
`SafeTestsets`), it depends only on the lightweight, broad-compat QA tools **Aqua**
and **ExplicitImports** — so `run_qa` always has them and your `qa.jl` neither
`using`s them nor lists them as test dependencies. The heavier,
compiler-version-pinned **JET** is kept a *weak* dependency (loaded via a package
extension) so it can never constrain or break `SciMLTesting`'s own load on a Julia
version JET doesn't yet support: add `using JET` in your `qa.jl` and its extension
auto-registers it, turning the JET check on.

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
| `run_tests(; test_dir, core, groups, qa, env, default, sublib_env, all, umbrellas, lib_dir, parent, pkg, isolate_group_environments)` | Declarative top-level dispatcher: owns the whole `runtests.jl` group-routing flow. With no `core`/`groups`/`qa` it runs in folder-discovery mode (groups = folders); supplying any of them selects the explicit-args mode. Reserved aggregates: `"All"` (curated subset for `Pkg.test`) and `"Everything"` (uncurated full suite). Set `isolate_group_environments = true` to run environment-backed aggregate members in fresh Julia processes. |
| `run_everything(; env = "GROUP", kwargs...)` | Convenience: set `ENV[env] = "Everything"` and call `run_tests`. Prefer for agents / long local full-suite runs. See [Running every test](#running-every-test-groupeverything). |
| `read_test_groups(test_dir)` | Read `test_dir/test_groups.toml` (the group list + per-group config such as `in_all`) used by folder-discovery mode. |
| `current_group(; env = "GROUP", default = "All")` | Read the test-group env var, defaulting to `"All"` (empty string also normalizes to the default). |
| `activate_group_env(group_dir; parent, develop, instantiate, develop_sources)` | `Pkg.activate` a per-group `Project.toml`, `develop` the parent package(s) by path, backport `[sources]`, `instantiate`. |
| `develop_sources!(group_dir; parent)` | On Julia < 1.11, `Pkg.develop` the env's `[sources]` path graph (recursively); a no-op on 1.11+. |
| `run_qa(pkg; Aqua, JET, ExplicitImports, aqua, jet, explicit_imports, api_docs, aqua_broken, jet_broken, ei_broken, ...)` | Run the standard Aqua/JET/ExplicitImports QA body, plus the public-API documentation check. Aqua + ExplicitImports come from SciMLTesting's deps (always available; `aqua` on by default, `explicit_imports` opt-in); `using JET` registers JET via its weakdep extension and turns the JET check on; `api_docs` is **on by default** and runs `run_api_docs` (configure via `api_docs_kwargs`, or `api_docs = false` to skip). The `*_broken` kwargs mark known-broken findings as `@test_broken` (see [Known-broken findings](#known-broken-findings-aqua_broken-jet_broken-ei_broken)). |
| `run_api_docs(pkg; docstrings = true, rendered = false, docs_src, ignore, rendered_ignore, docstrings_broken, rendered_broken)` | Assert every exported/`public` name of `pkg` has a docstring (and, opt-in, is rendered in a `@docs` block under `docs/src`). The shared replacement for per-repo `test/QA/public_api_docs.jl` files. |
| `public_api_names(pkg)` | The sorted public API of `pkg` (exported names, plus `public` names on Julia ≥ 1.11), with the module's own name dropped. |
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
    (curated All — what a bare `Pkg.test` runs).
  * **`Everything`** → Core **plus every** group folder in `test_groups.toml`,
    **including** `QA` and groups with `in_all = false`. The uncurated full suite;
    see [Running every test](#running-every-test-groupeverything).

Guarantees specific to folder mode:

  * **Enforced coverage.** *Every* `*.jl` in the selected group's folder runs — you
    cannot forget to register a test file by leaving it out of an `include` list. A
    declared group whose folder is **missing or empty** is an **error** (catches a
    misnamed or empty group), as is an empty `Core` and an unknown `GROUP`.
  * **Sub-env per group.** If a group folder has its own `Project.toml` (e.g.
    `test/qa/Project.toml`), it is activated (`Pkg.activate` + develop the package by
    path + `instantiate`, with the `<1.11` `[sources]` backport) before its files
    run. Core has no `Project.toml`, so it uses the main test env. With
    `isolate_group_environments = true`, environment-backed folders selected through
    `"All"` or `"Everything"` run in fresh Julia processes, preventing packages
    loaded from an earlier environment from leaking into the group.
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
using SciMLTesting, MyPackage
run_qa(MyPackage; explicit_imports = true)
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
flow that a uniform `GROUP` dispatch cannot express. Four optional kwargs cover
them; all default to the v1.0.0 behavior, so existing callers are unchanged.

  * **`sublib_env`** — the env var the sublibrary handoff sets, defaulting to `env`.
    OrdinaryDiffEq's root reads `GROUP` to pick a sublibrary, but the sublibraries
    read `ODEDIFFEQ_TEST_GROUP`. Set `sublib_env = "ODEDIFFEQ_TEST_GROUP"`: the root
    still reads `env` (`GROUP`) to select the sublibrary, but the sub-group is handed
    off via `withenv(sublib_env => subgroup)`, not `env`.

  * **`all`** — a curated list of the group keys `"All"` runs, replacing the
    hardwired "`core` + every env-less group". `core` runs under `"All"` only if
    `"Core"` is listed — so a repo can exclude heavy groups (OrdinaryDiffEq's
    `"All"` excludes `AlgConvergence_*`, Downstream, GPU, …) while keeping them
    selectable by name. `"QA"` is never part of `"All"` (even if listed). The
    reserved `"Everything"` group ignores this list and runs every group plus QA.

  * **`umbrellas`** — a `Dict` mapping an umbrella key to a list of member group
    keys. When `GROUP` equals the umbrella key, every member runs in order. Members
    may name `groups` entries or the reserved `"Core"`/`"QA"` bodies; an umbrella key
    wins over an identically named `groups` entry.

  * **`isolate_group_environments`** — default `false`. When `true`, a group that
    declares an `env` and is selected through `"All"`, `"Everything"`, or an umbrella
    runs in a fresh Julia process. The child re-enters the test entrypoint with the
    member group selected, develops path-tracked packages from the active test
    project unless the group declares its own source for that package, and preserves
    Julia flags such as coverage, depwarn, bounds checking, and startup-file settings.

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

    # Keep packages from different per-group environments out of the same process.
    isolate_group_environments = true,

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
using SciMLTesting, JET, MyPackage

# Aqua + ExplicitImports come from SciMLTesting's deps; `using JET` turns the JET
# check on. The per-repo qa.jl collapses to `explicit_imports = true` plus the
# genuinely-per-repo kwargs (the ExplicitImports per-check ignore-lists).
run_qa(MyPackage; explicit_imports = true,
    ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_dep_name,))))
```

### Public-API documentation check (`run_api_docs` / `api_docs = true`)

Several SciML repos had grown a hand-copied `test/QA/public_api_docs.jl` asserting that
every exported name has a docstring (and is rendered in the manual). `run_api_docs`
replaces those per-repo files with one shared, maintained helper. It runs **by default
inside `run_qa`** (`api_docs = true`), so a plain `run_qa(MyPackage)` already enforces
the docstring check — configure it with `api_docs_kwargs`, or pass `api_docs = false` to
skip:

```julia
using SciMLTesting, MyPackage

# In the QA body — the docstring check runs by default:
run_qa(MyPackage; explicit_imports = true)

# Also require each public name is rendered in a docs/src @docs block:
run_qa(MyPackage; explicit_imports = true, api_docs_kwargs = (; rendered = true))

# Standalone (outside run_qa), e.g. as its own QA file:
run_api_docs(MyPackage)                    # every exported/`public` name has a docstring
run_api_docs(MyPackage; rendered = true)   # also require each is in a docs/src @docs block
```

  * **`docstrings`** (default `true`) — every name in `public_api_names(pkg)` has a
    docstring. A re-exported name documented in its defining package counts as
    documented (the check follows the binding), so you are not forced to redocument
    dependency re-exports.
  * **`rendered`** (default `false`, opt-in) — every public name appears in a
    ` ```@docs ` block under `docs_src` (defaults to `<pkgroot>/docs/src`). A
    ` ```@autodocs ` block satisfies it wholesale. Opt-in because not every repo has a
    resolvable local manual (monorepos with shared docs, packages with no manual).
  * **`ignore` / `rendered_ignore`** — names to exclude (e.g. an un-documentable
    re-export), with a comment pointing at the tracking issue.
  * **`docstrings_broken` / `rendered_broken`** — mark the check `@test_broken` for a
    repo mid-migration; auto-flags an `Unexpected Pass` once the API is fully documented.

On the Julia 1.10 LTS `public_api_names` returns only the exported names (the `public`
keyword is 1.11+), so no per-repo `if VERSION` guards are needed.

### Known-broken findings (`aqua_broken`, `jet_broken`, `ei_broken`)

When converting a hand-rolled `qa.jl` to `run_qa` would otherwise re-red a repo that
has a *known* Aqua/JET/ExplicitImports finding tracked in a GitHub issue (today
expressed as `@test_broken`), three `run_qa` kwargs preserve those suppressions so the
QA lane records `Broken` rather than `Fail`. All default to empty/`false`, so omitting
them is exactly the pre-1.6 behavior.

```julia
using SciMLTesting, JET, MyPackage
run_qa(MyPackage; explicit_imports = true,
    aqua_broken = (:ambiguities,),         # disable + placeholder for a tracked Aqua sub-check
    jet_broken = true,                     # report_package + @test_broken isempty(reports)
    ei_broken = (:no_implicit_imports,))   # route this EI check through @test_broken
```

  * **`aqua_broken`** — a collection of `Aqua.test_all` sub-check names (`:ambiguities`,
    `:unbound_args`, `:undefined_exports`, `:project_extras`, `:stale_deps`,
    `:deps_compat`, `:piracies`, `:persistent_tasks`). Each named sub-check is
    **disabled** in the `Aqua.test_all` call (the broken-disable wins over any
    `aqua_kwargs` entry) and gets one `@test_broken false` in a nested
    `@testset "aqua: <name> (broken)"`. This is a **tracked placeholder, not an
    auto-detector**: a fixed sub-check is not flagged automatically — remove the name
    when the issue closes. (Reliable per-sub-check auto-flagging is not robust across
    Aqua versions, so this mirrors the fleet's existing `<check> = false` +
    `@test_broken` pattern.)
  * **`jet_broken::Bool`** — when the JET check runs, replaces the hard
    `JET.test_package` with `rep = JET.report_package(pkg; ...)` and
    `@test_broken isempty(JET.get_reports(rep))`. This **auto-flags**: once JET is clean
    the `@test_broken` becomes an `Unexpected Pass` (an `Error`), prompting you to drop
    `jet_broken`. `report_package` is report-only, so a `mode` key in `jet_kwargs` (a
    `test_package`-only pass/fail config) is dropped for the report call; the JET config
    keys `report_package` honors (`target_modules`, `target_defined_modules`,
    `ignored_modules`, ...) pass through unchanged.
  * **`ei_broken`** — a collection of ExplicitImports check short-names (the part after
    `check_`, e.g. `:no_implicit_imports`, `:all_explicit_imports_are_public`). A named
    check runs as `@test_broken check(pkg; ...) === nothing`. This **auto-flags** like
    `jet_broken`: once the check passes, the `@test_broken` becomes an `Unexpected Pass`.

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

## Running every test (`GROUP=Everything`)

`"All"` (the default when `GROUP` is unset — what a bare `Pkg.test` runs) is
**intentionally curated**. It covers a decent subset so local and CI smoke runs
finish in a reasonable time. Groups marked `in_all = false`, QA, Downstream,
GPU/CUDA, long AlgConvergence suites, and other heavy or environment-specific
groups are left out of `"All"` on purpose (OrdinaryDiffEq.jl and NonlinearSolve.jl
are the canonical examples of this curation).

Agents (and humans who want full confidence) sometimes need to run **everything**,
even when that takes many hours. Use the reserved group name `"Everything"`:

```bash
# Full suite — may take many hours on large monorepos (e.g. OrdinaryDiffEq).
# Do not use a short timeout; budget overnight-scale wall clock if needed.
GROUP=Everything julia --project -e 'using Pkg; Pkg.test(coverage=false)'

# Packages that read a non-default group env var (NonlinearSolve, …):
NONLINEARSOLVE_TEST_GROUP=Everything julia --project -e 'using Pkg; Pkg.test()'

# Direct runtests.jl when the test env is already active:
GROUP=Everything julia --project=test test/runtests.jl
```

Or the thin convenience wrapper (forwards every keyword to `run_tests`):

```julia
using SciMLTesting
run_everything()                                    # folder-discovery packages
run_everything(; env = "NONLINEARSOLVE_TEST_GROUP") # non-default group env var
run_everything(; test_dir = @__DIR__)               # if call-site inference fails
```

No per-repo change is required when the package already dispatches through
`run_tests` (OrdinaryDiffEq.jl, NonlinearSolve.jl, folder-discovery packages, …):
setting `GROUP=Everything` is enough.

If the suite loads groups from different package environments, pass
`isolate_group_environments = true` to `run_tests` (or `run_everything`). Each
environment-backed aggregate member then runs in a fresh Julia process; the default
remains the historical in-process behavior.

| | `"All"` (default / `Pkg.test`) | `"Everything"` |
| --- | --- | --- |
| Core | yes (unless curated `all` omits it) | yes (if a `core` body is supplied) |
| Groups with `in_all = false` | no | **yes** |
| Groups with a sub-`env` (Downstream, GPU, …) | no (explicit-mode default) | **yes** |
| Curated out of the `all = [...]` list | no | **yes** (list ignored) |
| QA | **never** | **yes** (if a `qa` body / QA folder exists) |
| Monorepo `lib/<Sublib>` packages | no | no — name those as their own `GROUP` |

**Caveats for agents**

  * **Runtime.** Large monorepos can take on the order of **hours** (≈11h is
    realistic for OrdinaryDiffEq). A multi-hour run is not a hang — wait it out.
  * **Hardware / env groups.** GPU, CUDA, and similar groups **are** included. On a
    machine without that hardware they will fail; that is intentional for a full
    suite. To skip them, select groups by name instead of using `"Everything"`.
  * **Special-cased groups outside `run_tests`.** A few monorepos still branch on a
    group before calling `run_tests` (e.g. NonlinearSolve's `Trim`). Those are not
    covered by `"Everything"` unless the repo also handles `GROUP == "Everything"`
    (or folds the group into `run_tests`). Prefer routing special groups through
    `run_tests` so `"Everything"` covers them automatically.
  * **Sublibraries.** `"Everything"` does not `Pkg.test` every `lib/<Sub>`. Cover a
    sublibrary with `GROUP=<Sublib>` / `GROUP=<Sublib>_<group>`, or the monorepo's
    sublibrary CI.

## License

MIT. See [LICENSE](LICENSE).
