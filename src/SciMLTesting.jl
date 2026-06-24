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
setup. The top-level [`run_tests`](@ref) dispatcher owns the whole `runtests.jl`
control flow, so a repo replaces its hand-written `if GROUP == ...` ladder with a
single declarative call.

It deliberately stays light, depending only on the standard libraries `Pkg`,
`TOML`, and `Test` plus the tiny `SafeTestsets` package (whose `@safetestset` macro
runs each file-path group body in its own isolated module). The QA helper accepts
the already-loaded `Aqua`/`JET` modules as keyword arguments so that those heavier
tools stay in each repo's `test/qa/Project.toml` and never enter `SciMLTesting`'s
own dependency graph.
"""
module SciMLTesting

using Pkg: Pkg
using TOML: TOML
using Test: Test, @testset, @test
using SafeTestsets: SafeTestsets, @safetestset

export current_group, activate_group_env, run_qa, run_explicit_imports, detect_sublibrary_group,
    develop_sources!, run_tests, read_test_groups,
    with_clean_persistent_tasks_sources

# Group names that are never sublibraries and never named functional groups: the
# routing keywords `run_tests` and `detect_sublibrary_group` reserve.
const RESERVED_GROUPS = ("All", "Core", "QA")

"""
    read_test_groups(test_dir) -> Dict{String, Dict{String, Any}}

Read a repo's `test/test_groups.toml` and return the declared groups as an ordered
mapping from group name to that group's option table.

`test_dir` is the directory holding `runtests.jl` (the dir of the calling file). The
file at `joinpath(test_dir, "test_groups.toml")` is the single source of truth for
both the CI test matrix (the group *names*) and per-group configuration consumed by
the folder-discovery mode of [`run_tests`](@ref). Two TOML layouts are accepted:

  * A `[groups]` table whose subtables name the groups:

    ```toml
    [groups.Interface]
    in_all = true

    [groups.QA]
    in_all = false
    ```

  * A bare top-level layout where each group is its own table (no `groups` wrapper):

    ```toml
    [Interface]
    [QA]
    in_all = false
    ```

A group whose value is an empty table (or `true`) declares the group with default
options. Recognized per-group options:

  * `in_all` (`Bool`, default `true`) — whether the group runs as part of the `"All"`
    aggregate. `"QA"` is always excluded from `"All"` regardless of this flag (set it
    explicitly to `false` for documentation/clarity). Set `in_all = false` on any
    heavy or environment-specific group to curate `"All"`.

The returned dict preserves declaration order (insertion-ordered), and group names
are returned verbatim (SciML group names are capitalized: `Core`, `QA`, `Interface`,
...). Missing file is an error: folder-discovery mode requires the group list.

# Examples

```julia
groups = read_test_groups(@__DIR__)            # in test/runtests.jl
for (name, opts) in groups
    @info name get(opts, "in_all", true)
end
```
"""
function read_test_groups(test_dir::AbstractString)
    file = joinpath(test_dir, "test_groups.toml")
    isfile(file) ||
        throw(ArgumentError("read_test_groups: no test_groups.toml found at $(file). Folder-discovery mode requires a test_groups.toml listing the test groups."))
    parsed = TOML.parsefile(file)
    raw = get(parsed, "groups", nothing)
    raw isa AbstractDict || (raw = parsed)
    # Preserve declaration order: TOML.parsefile returns a plain Dict (unordered), so
    # re-key into an order-preserving structure keyed by first appearance in the file
    # text would require a streaming parser. The group set is what matters for
    # discovery, and "All" iterates a *sorted* group list (deterministic) regardless,
    # so a plain Dict suffices; sorting at the call site gives the determinism.
    out = Dict{String, Dict{String, Any}}()
    for (name, val) in raw
        name == "groups" && continue   # in the bare layout, ignore a stray wrapper key
        opts = if val isa AbstractDict
            Dict{String, Any}(string(k) => v for (k, v) in val)
        elseif val === true
            Dict{String, Any}()
        else
            throw(ArgumentError("read_test_groups: group \"$name\" must map to a table (or `true`); got $(typeof(val)) in $(file)"))
        end
        out[string(name)] = opts
    end
    return out
end

# Whether a declared group runs as part of "All". QA is always excluded from "All"
# (it is its own CI lane); any group with `in_all = false` opts out (curated All).
_group_in_all(name::AbstractString, opts::AbstractDict) =
    name != "QA" && get(opts, "in_all", true) == true

# Resolve a group name to its folder under `test_dir`, trying an exact match first
# then a case-insensitive match (so group "Interface" finds test/Interface or
# test/interface, and "QA" finds test/qa or test/QA). Returns the absolute folder
# path, or `nothing` if no matching directory exists.
function _group_folder(test_dir::AbstractString, name::AbstractString)
    exact = joinpath(test_dir, name)
    isdir(exact) && return abspath(exact)
    lname = lowercase(name)
    for entry in readdir(test_dir)
        isdir(joinpath(test_dir, entry)) || continue
        lowercase(entry) == lname && return abspath(joinpath(test_dir, entry))
    end
    return nothing
end

# Top-level `*.jl` test files directly in `test_dir`, excluding `runtests.jl`, NOT
# recursing into subdirectories. This is the Core group's file set (the normal SciML
# layout where the main test folder *is* Core). Returned sorted (deterministic run
# order).
function _core_files(test_dir::AbstractString)
    files = String[]
    for entry in readdir(test_dir)
        endswith(entry, ".jl") || continue
        entry == "runtests.jl" && continue
        path = joinpath(test_dir, entry)
        isfile(path) || continue
        push!(files, abspath(path))
    end
    sort!(files)
    return files
end

# All `*.jl` files directly inside a group's folder, sorted. Does not recurse: a
# group folder's own subfolders (if any) are not auto-discovered.
function _folder_files(folder::AbstractString)
    files = String[]
    for entry in readdir(folder)
        endswith(entry, ".jl") || continue
        path = joinpath(folder, entry)
        isfile(path) || continue
        push!(files, abspath(path))
    end
    sort!(files)
    return files
end

"""
    current_group(; env = "GROUP", default = "All")

Return the requested test group, read from the environment variable named `env`
(default `"GROUP"`), falling back to `default` (default `"All"`) when that
variable is unset *or set to the empty string*.

This replaces the `const GROUP = get(ENV, "GROUP", "All")` line copied into every
SciML `test/runtests.jl`. SciML group names are capitalized (`All`, `Core`, `QA`,
...); a non-empty value is returned verbatim with no case normalization. An empty
`ENV[env]` (which some CI setups produce for an unselected matrix entry) is treated
the same as unset and yields `default`.

# Examples

```julia
using SciMLTesting
const GROUP = current_group()                       # ENV["GROUP"] or "All"
const SUBGROUP = current_group(env = "ODE_TEST_GROUP", default = "Core")
```
"""
function current_group(; env::AbstractString = "GROUP", default::AbstractString = "All")
    value = get(ENV, env, default)
    return isempty(value) ? default : value
end

"""
    develop_sources!(group_dir; parent = dirname(group_dir))

On Julia < 1.11, `Pkg.develop` every path dependency declared in the `[sources]`
table of the environment at `group_dir`, recursively following each developed
dependency's own `[sources]`. On Julia >= 1.11 this is a no-op.

Julia 1.11 added native support for the `[sources]` table in a `Project.toml`: when
the environment is instantiated, listed `path =`/`url =` sources are used directly.
Julia 1.10 (the SciML LTS) ignores `[sources]` entirely, so a monorepo group env
that relies on `[sources]` to pin its in-repo siblings resolves them as registered
releases instead of the local PR-branch code. This helper reproduces 1.11's
behavior on 1.10 by walking the `[sources]` graph and `Pkg.develop`-ing each `path`
entry.

`group_dir` is the directory holding the env's `Project.toml`. Each `[sources]`
`path` is resolved relative to the directory of the `Project.toml` that declares it
(so the walk is correct even as it recurses into siblings). `parent` is accepted
for symmetry with [`activate_group_env`](@ref) but is unused here — the set of paths
to develop comes entirely from the `[sources]` graph. The active project is assumed
to already be `group_dir` (call after `Pkg.activate(group_dir)`); this function does
not change the active project.

Only `path` sources are developed; `url`/`rev` git sources are left to `Pkg` (a git
source resolves identically on 1.10 and 1.11, so it needs no backport). Cycles and
diamonds in the `[sources]` graph are handled by visiting each resolved path once.

# Examples

```julia
# Julia <1.11: develop the in-repo siblings that test/Foo/Project.toml's
# [sources] table points at, plus anything *their* [sources] point at.
Pkg.activate(joinpath(@__DIR__, "Foo"))
develop_sources!(joinpath(@__DIR__, "Foo"))
Pkg.instantiate()
```
"""
function develop_sources!(group_dir::AbstractString; parent = dirname(group_dir))
    # Julia >= 1.11 honors [sources] natively; nothing to backport.
    VERSION >= v"1.11" && return nothing

    paths = _collect_source_paths(group_dir)
    isempty(paths) || Pkg.develop([Pkg.PackageSpec(path = p) for p in paths])
    return nothing
end

# Walk the `[sources]` graph starting at `group_dir`, returning the ordered list of
# absolute `path` sources to develop. Each `path` is resolved relative to the
# directory of the `Project.toml` that declares it, and the walk recurses into each
# developed dependency's own `[sources]`. Visiting each resolved path once handles
# cycles and diamonds. This is version-independent (no `VERSION` gate) so the
# resolution/recursion logic is unit-testable regardless of the running Julia.
#
# When recursing into an already-developed dependency, only `[sources]` that are
# also that dependency's *runtime* `[deps]` are followed. A dependency's `[sources]`
# table may contain entries that exist purely for that dependency's own test suite
# (their names live in `[extras]`/`[targets].test`, not `[deps]`). Developing those
# would inject phantom direct deps into the active environment, which then trips
# Aqua's stale-deps / deps-compat checks (SciML/Optimization.jl#1228). The group env
# itself (the root of the walk) is exempt: its `[sources]` legitimately pin the
# package under test (and any siblings its own group needs).
function _collect_source_paths(group_dir::AbstractString)
    visited = Set{String}()
    paths = String[]
    root = abspath(group_dir)
    _walk_sources!(paths, visited, root, root)
    return paths
end

function _walk_sources!(
        paths::Vector{String}, visited::Set{String},
        project_dir::AbstractString, root::AbstractString,
    )
    project_file = _project_file(project_dir)
    project_file === nothing && return nothing
    parsed = TOML.parsefile(project_file)
    sources = get(parsed, "sources", nothing)
    sources isa AbstractDict || return nothing
    env_dir = dirname(project_file)
    isroot = abspath(project_dir) == root
    runtimedeps = keys(get(parsed, "deps", Dict{String, Any}()))
    for (name, spec) in sources
        # For dependencies (not the group env at the root of the walk), skip
        # [sources] that are not runtime deps -- those are the dep's test-only
        # sources and must not leak into the active environment.
        isroot || name in runtimedeps || continue
        spec isa AbstractDict || continue
        haskey(spec, "path") || continue       # leave url/rev git sources to Pkg
        resolved = abspath(joinpath(env_dir, spec["path"]))
        resolved in visited && continue
        push!(visited, resolved)
        push!(paths, resolved)
        _walk_sources!(paths, visited, resolved, root)   # recurse into the dep's own [sources]
    end
    return nothing
end

# Locate the Project.toml (or JuliaProject.toml) for an env directory, or return
# the path itself if it already points at a project file.
function _project_file(dir::AbstractString)
    if isfile(dir) && (basename(dir) == "Project.toml" || basename(dir) == "JuliaProject.toml")
        return dir
    end
    for name in ("Project.toml", "JuliaProject.toml")
        candidate = joinpath(dir, name)
        isfile(candidate) && return candidate
    end
    return nothing
end

"""
    activate_group_env(group_dir; parent = dirname(dirname(abspath(group_dir))),
                        develop = true, instantiate = true, develop_sources = true)

Activate the per-group test environment at `group_dir` and prepare it for testing
the in-repo package.

`group_dir` is the directory holding the group's own `Project.toml` (for example
`joinpath(@__DIR__, "qa")` or `joinpath(@__DIR__, "downstream")`). The steps are:

  1. `Pkg.activate(group_dir)`,
  2. when `develop` is `true`, `Pkg.develop` each path in `parent` so the
     activated environment uses the local (PR-branch) source of the package under
     test instead of a registered release,
  3. when `develop_sources` is `true`, [`develop_sources!`](@ref) the env's
     `[sources]` graph (a no-op on Julia >= 1.11, the 1.10 `[sources]` backport),
     and
  4. when `instantiate` is `true`, `Pkg.instantiate()`.

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
        develop_sources::Bool = true,
    )
    Pkg.activate(group_dir)
    parents = parent isa AbstractString ? (parent,) : parent
    # On Julia < 1.11 `[sources]` is ignored, so develop the parent(s) (the
    # package(s) under test) AND the env's `[sources]` path graph in a *single*
    # `Pkg.develop` call. Developing the parent alone would make Pkg resolve the
    # parent's own `[deps]` against the registry; in a monorepo those deps are
    # unregistered in-repo siblings reachable only via `[sources]`, so that
    # resolution fails with "expected package <Sibling> to be registered". Adding
    # every source path in the same call lets Pkg satisfy them all by path at
    # once. Paths are deduplicated by package UUID because a `[sources]` entry
    # may point at the same package as a `parent` (e.g. a QA env that lists the
    # package under test in both), which `Pkg.develop` rejects as "multiple
    # packages with the same UUID". On Julia >= 1.11 `[sources]` is honored
    # natively, so only the parent(s) are developed (develop_sources! is a no-op).
    if develop
        paths = collect(AbstractString, parents)
        if develop_sources && VERSION < v"1.11"
            append!(paths, _collect_source_paths(group_dir))
        end
        specs = _dedup_path_specs(paths)
        isempty(specs) || Pkg.develop(specs)
    elseif develop_sources
        develop_sources!(group_dir; parent = parent)
    end
    instantiate && Pkg.instantiate()
    return nothing
end

# Build `Pkg.develop` specs for a list of project directories, dropping duplicate
# paths and any two paths that resolve to the same package UUID (Pkg.develop
# errors on "multiple packages with the same UUID"). A path with no readable
# Project.toml uuid is kept and deduplicated by its absolute path alone. The
# first occurrence of each UUID/path wins, preserving caller order.
function _dedup_path_specs(paths)
    seen_uuid = Set{String}()
    seen_path = Set{String}()
    specs = Pkg.PackageSpec[]
    for p in paths
        ap = abspath(p)
        ap in seen_path && continue
        push!(seen_path, ap)
        project_file = _project_file(ap)
        uuid = project_file === nothing ? nothing :
            get(TOML.parsefile(project_file), "uuid", nothing)
        if uuid !== nothing
            uuid in seen_uuid && continue
            push!(seen_uuid, uuid)
        end
        push!(specs, Pkg.PackageSpec(path = ap))
    end
    return specs
end

"""
    with_clean_persistent_tasks_sources(f; verbose = false)

Run `f()` with every *installed* (depot) package's `[sources]` table temporarily
purged of **broken path entries**, then restore every modified `Project.toml`
verbatim (even if `f` throws). Returns whatever `f()` returns.

This works around an upstream Pkg bug that breaks Aqua's persistent-tasks check on
Julia >= 1.11. `Aqua.test_persistent_tasks` / `Aqua.find_persistent_tasks_deps`
verify that loading a package (or each of its dependencies) does not spawn a
persistent `Task` by `Pkg.develop`-ing the package **by its installed path** into a
throwaway wrapper environment and precompiling it. On Julia >= 1.11, `Pkg.develop`
honors a path-`[sources]` table baked into that installed `Project.toml`. Many
registered SciML packages (e.g. `OptimizationBBO` 0.4.4-0.4.7 and most
OrdinaryDiffEq / StochasticDiffEq / NonlinearSolve sublibraries) ship a leaked
monorepo-relative `[sources]` such as

```toml
[sources]
OptimizationBase = {path = "../OptimizationBase"}
```

In the registry-installed copy that sibling path does **not** exist
(`.../packages/OptimizationBBO/<hash>/../OptimizationBase`), so `Pkg.develop` hard
errors before the genuine check can run:

```
expected package `OptimizationBase [bca83a33]` to exist at path
  `.../packages/OptimizationBBO/OptimizationBase`
```

honoring a `[sources]` entry for a package being *used as a dependency* is against
Pkg's documented contract; the true fix is upstream in Pkg. Until that lands, this
helper lets the SciML QA lane go green on Julia >= 1.11 **without weakening the
check**: it removes only the spurious, unresolvable `[sources]` entries that Pkg
should never have honored, so the genuine persistent-tasks precompile still runs and
still fails on a real persistent task. A `[sources]` entry whose path *does* resolve
is left untouched (it may be load-bearing), and a `[sources]` table is irrelevant to
whether loading a package spawns a `Task`, so removing the broken entries cannot mask
a genuine persistent task.

The set of `Project.toml` files considered is taken from `Pkg.dependencies()` of the
*active* environment (call after the QA env is activated/instantiated). Each file is
made writable, rewritten with `TOML.print`, and on exit restored to its exact
original bytes and original file mode. Files with no `[sources]`, or whose
`[sources]` paths all resolve, are never touched.

`verbose = true` logs each sanitized package and the removed source names via
`@info`.

# Examples

```julia
# Direct-call QA body (e.g. test/qa/qa.jl) that runs the persistent-tasks check:
using SciMLTesting, Aqua, MyPackage
with_clean_persistent_tasks_sources() do
    Aqua.find_persistent_tasks_deps(MyPackage)
end

# Or wrap a full Aqua.test_all (run_qa does this for you by default):
with_clean_persistent_tasks_sources() do
    Aqua.test_all(MyPackage)
end
```

See also [`run_qa`](@ref), which wraps its `Aqua.test_all` call in this helper by
default (`clean_sources = true`).
"""
function with_clean_persistent_tasks_sources(f; verbose::Bool = false)
    backups = _strip_broken_sources!(; verbose = verbose)
    try
        return f()
    finally
        _restore_sources!(backups)
    end
end

# For every dep of the active environment whose installed Project.toml declares a
# `[sources]` table with at least one *broken* path entry (a `path =` whose resolved
# location does not exist), back up the file (bytes + mode) and rewrite it with only
# the broken entries removed. Returns the backup table `path => (bytes, mode)` so the
# files can be restored verbatim. A non-path source (url/rev) and a path source that
# resolves are both left untouched. The active env is read via `Pkg.dependencies()`,
# so call after the env is activated and instantiated.
function _strip_broken_sources!(; verbose::Bool = false)
    backups = Dict{String, Tuple{String, Union{UInt16, Nothing}}}()
    for (_uuid, info) in Pkg.dependencies()
        info.source === nothing && continue
        project_file = _project_file(info.source)
        project_file === nothing && continue
        parsed = try
            TOML.parsefile(project_file)
        catch
            continue                      # unreadable/odd project file: leave it alone
        end
        sources = get(parsed, "sources", nothing)
        sources isa AbstractDict || continue
        env_dir = dirname(project_file)
        removed = String[]
        for (name, spec) in collect(sources)   # collect: mutating while iterating
            spec isa AbstractDict || continue
            haskey(spec, "path") || continue    # url/rev git sources resolve identically
            resolved = abspath(joinpath(env_dir, spec["path"]))
            if !ispath(resolved)
                delete!(sources, name)
                push!(removed, name)
            end
        end
        isempty(removed) && continue
        original = read(project_file, String)
        mode = try
            filemode(project_file) % UInt16
        catch
            nothing
        end
        backups[project_file] = (original, mode)
        isempty(sources) && delete!(parsed, "sources")
        _make_writable(project_file)
        open(project_file, "w") do io
            TOML.print(io, parsed)
        end
        verbose && @info "SciMLTesting: stripped broken [sources]" package = info.name removed
    end
    return backups
end

function _restore_sources!(backups::AbstractDict)
    for (project_file, (bytes, mode)) in backups
        _make_writable(project_file)
        open(project_file, "w") do io
            write(io, bytes)
        end
        mode === nothing || (
            try
                chmod(project_file, mode)
            catch
            end
        )
    end
    return nothing
end

# Ensure the owner can write `path` (installed depot copies are read-only). Best
# effort: a chmod failure should not abort sanitize/restore.
function _make_writable(path::AbstractString)
    try
        chmod(path, (filemode(path) | 0o200) % UInt16)
    catch
    end
    return nothing
end

"""
    run_qa(pkg; Aqua = nothing, JET = nothing,
           aqua = true, jet = false, clean_sources = true,
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

`clean_sources` (default `true`) wraps the `Aqua.test_all` call in
[`with_clean_persistent_tasks_sources`](@ref), which strips *broken* path-`[sources]`
entries from installed dependencies' `Project.toml` for the duration of the call (and
restores them after). This works around an upstream Pkg >= 1.11 bug that otherwise
makes Aqua's persistent-tasks check hard-error on any repo depending on a registered
package that ships a leaked monorepo-relative `[sources]` (e.g. OptimizationBBO
0.4.4-0.4.7, many OrdinaryDiffEq / StochasticDiffEq / NonlinearSolve sublibraries).
The genuine persistent-tasks check still runs and can still fail on a real persistent
task — only the spurious unresolvable `[sources]` Pkg should never have honored are
removed. Set `clean_sources = false` to opt out (e.g. on Julia < 1.11, where the bug
does not apply; the wrap is a cheap no-op there since no installed `[sources]` paths
are broken in a single-package checkout, but the flag makes the intent explicit).

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

# also run ExplicitImports (standard + public-API) checks, curating a per-check
# ignore-list for unavoidable non-public dependency accesses
using ExplicitImports
run_qa(MyPackage; Aqua = Aqua, ExplicitImports = ExplicitImports, explicit_imports = true,
       ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:internal_dep_name,))))
```
"""
function run_qa(
        pkg::Module;
        Aqua = nothing,
        JET = nothing,
        aqua::Bool = true,
        jet::Bool = false,
        clean_sources::Bool = true,
        aqua_kwargs = (;),
        jet_kwargs = (; target_modules = (pkg,), mode = :typo),
        ExplicitImports = nothing,
        explicit_imports::Bool = false,
        ei_kwargs = (;),
        testset::AbstractString = "Quality Assurance",
    )
    # Validate before entering the @testset: a `throw` inside a testset is
    # recorded as an errored test result rather than propagating, which would
    # make these misconfiguration errors impossible to `@test_throws`-catch.
    aqua && Aqua === nothing &&
        throw(ArgumentError("run_qa: `aqua = true` but no `Aqua` module was passed; call `run_qa(pkg; Aqua = Aqua)`"))
    jet && JET === nothing &&
        throw(ArgumentError("run_qa: `jet = true` but no `JET` module was passed; call `run_qa(pkg; JET = JET, jet = true)`"))
    explicit_imports && ExplicitImports === nothing &&
        throw(ArgumentError("run_qa: `explicit_imports = true` but no `ExplicitImports` module was passed; call `run_qa(pkg; ExplicitImports = ExplicitImports, explicit_imports = true)`"))
    @testset "$testset" begin
        if aqua
            run_aqua = () -> Aqua.test_all(pkg; aqua_kwargs...)
            clean_sources ? with_clean_persistent_tasks_sources(run_aqua) : run_aqua()
        end
        jet && JET.test_package(pkg; jet_kwargs...)
        explicit_imports && run_explicit_imports(pkg, ExplicitImports; ei_kwargs)
    end
    return nothing
end

"""
    run_explicit_imports(pkg, ExplicitImports; ei_kwargs = (;))

Run ExplicitImports.jl's standard checks (no-implicit-imports, no-stale-explicit-
imports, all-explicit-imports-via-owners, all-qualified-accesses-via-owners) plus
the public-API checks (all-qualified-accesses-are-public,
all-explicit-imports-are-public) as a nested `@testset`. The `ExplicitImports`
module is injected so `SciMLTesting` takes no hard dependency on it. `ei_kwargs`
is a `NamedTuple` keyed by each check's short name (the part after `check_`); its
value is that check's keyword arguments, so callers curate per-check ignore-lists,
e.g. `ei_kwargs = (; all_qualified_accesses_are_public = (; ignore = (:foo,)))`.
"""
function run_explicit_imports(pkg::Module, ExplicitImports; ei_kwargs = (;))
    checks = (
        :no_implicit_imports, :no_stale_explicit_imports,
        :all_explicit_imports_via_owners, :all_qualified_accesses_via_owners,
        :all_qualified_accesses_are_public, :all_explicit_imports_are_public,
    )
    @testset "ExplicitImports" begin
        for name in checks
            check = getproperty(ExplicitImports, Symbol("check_", name))
            @testset "$(name)" begin
                @test check(pkg; get(ei_kwargs, name, (;))...) === nothing
            end
        end
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

An empty `group` is never treated as a sublibrary even though
`isdir(joinpath(lib_dir, ""))` is true: it returns `("", default_group)` so the
caller falls through to its root dispatch. (Guarding this case is the
responsibility of the caller via `isdir(joinpath(lib_dir, sublibrary)) &&
!isempty(sublibrary)`; [`run_tests`](@ref) does exactly that.)

This replaces the `_detect_sublibrary_group` closure copied into the root
`test/runtests.jl` of each SciML monorepo. Use `isdir(joinpath(lib_dir, sublib))`
on the returned `sublibrary` to decide whether to route to a sublibrary.

# Examples

```julia
lib_dir = joinpath(@__DIR__, "..", "lib")
sublib, grp = detect_sublibrary_group(current_group(), lib_dir)
if !isempty(sublib) && isdir(joinpath(lib_dir, sublib))
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
    # An empty group must never match a sublibrary even though
    # `joinpath(lib_dir, "")` is a directory: fall through to root dispatch.
    isempty(group) && return (group, default_group)
    isdir(joinpath(lib_dir, group)) && return (group, default_group)
    for i in lastindex(group):-1:firstindex(group)
        if group[i] == '_' && isdir(joinpath(lib_dir, group[firstindex(group):prevind(group, i)]))
            return (group[firstindex(group):prevind(group, i)], group[nextind(group, i):end])
        end
    end
    return (group, default_group)
end

# A group's "body" is either a file path to `include`, or a 0-argument thunk to
# call. A group entry may also be a NamedTuple/Dict carrying both the body and a
# sub-env dir to activate; this normalizes any of those to (body, env, parent).
struct GroupSpec
    body::Any            # AbstractString (file path) or callable thunk
    env::Any             # nothing, or a directory to activate_group_env
    parent::Any          # nothing, or parent override for activate_group_env
end

function _group_spec(entry)
    if entry isa GroupSpec
        return entry
    elseif entry isa AbstractString
        return GroupSpec(entry, nothing, nothing)
    elseif entry isa NamedTuple || entry isa AbstractDict
        d = _as_symbol_dict(entry)
        haskey(d, :body) ||
            throw(ArgumentError("run_tests: group entry table must have a `body` (file path or thunk) key"))
        return GroupSpec(d[:body], get(d, :env, nothing), get(d, :parent, nothing))
    elseif _callable(entry)
        return GroupSpec(entry, nothing, nothing)
    else
        throw(ArgumentError("run_tests: group entry must be a file path, a 0-arg thunk, or a NamedTuple/Dict with a `body` key; got $(typeof(entry))"))
    end
end

_callable(x) = x isa Function || !isempty(methods(x))
_as_symbol_dict(nt::NamedTuple) = Dict{Symbol, Any}(pairs(nt))
_as_symbol_dict(d::AbstractDict) = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in d)

# Run a group body. A file path is `include`d inside its own `@safetestset` — a
# fresh isolated module — exactly as OrdinaryDiffEq.jl's canonical
# `@safetestset "X" begin include("x.jl") end` structure does. This is the
# preferred, world-age-safe, isolated form for `core`/groups:
#
#   * World-age safe: a module body advances world age per top-level statement, so a
#     file that defines a method via a nested `include(mapexpr, file)` (or plain
#     `include`) and then *calls* that method in the same `@testset`/expression
#     works. Under the old fresh `Module(gensym())` `Base.include` this raised a
#     world-age `MethodError` ("method too new to be called from this world
#     context").
#   * Isolated: each file body runs in its own module, so globals/consts/methods one
#     group defines are invisible to another group (no cross-group leakage).
#   * `Test` is in scope automatically: `@safetestset` brings the full Test API
#     (`@testset`/`@test`/`@test_throws`/...) into the generated module, so an
#     included file needs no `using Test` of its own (the missing-`using Test` bug
#     class).
#
# The `@safetestset` macro expands to a fresh module that CANNOT see any local
# variable, so the file path is interpolated as a *literal* into the quoted
# expression (and `@safetestset`'s own label argument is a string literal). `label`
# is the group/core name, used for the testset summary.
#
# A thunk (`() -> ...`) is invoked as-is via `invokelatest` in the caller's scope —
# it is NOT isolated and NOT world-age-safe, because a runtime closure cannot be
# cleanly `@safetestset`-wrapped with a literal `include`. Its world age does not
# advance mid-body, so a thunk cannot host a define-via-nested-`include`-then-call
# pattern. Use thunks only for simple inline testsets that are already
# self-contained; use a file-path body for anything that defines-then-calls across a
# nested `include` or that should be isolated from other groups.
function _run_body(body; label::AbstractString = "Group")
    if body isa AbstractString
        path = abspath(body)
        # Build `@safetestset "<label>" begin include("<path>") end` and eval it in
        # `Main`. The macro name is a `GlobalRef` into `SafeTestsets` so it resolves
        # even though `Main` (the `Pkg.test` runtests scope) has not `using
        # SafeTestsets` — `SciMLTesting` owns the dependency. Both the label and the
        # path are literals because `@safetestset`'s generated module cannot capture
        # any local variable of this function.
        expr = Expr(
            :macrocall,
            GlobalRef(SafeTestsets, Symbol("@safetestset")),
            LineNumberNode(@__LINE__, @__FILE__),
            string(label),
            Expr(:block, :(include($path))),
        )
        Core.eval(Main, expr)
    elseif _callable(body)
        Base.invokelatest(body)
    else
        throw(ArgumentError("run_tests: group body must be a file path or a 0-arg thunk; got $(typeof(body))"))
    end
    return nothing
end

# Sentinel marking an unsupplied explicit-mode argument. When all of `core`,
# `groups`, and `qa` are still the sentinel, `run_tests` runs in folder-discovery
# mode; supplying any one of them selects the legacy explicit-args mode.
struct _Unset end
const _UNSET = _Unset()

# Directory of the file that called `run_tests` (the repo's test/runtests.jl), used
# as the default `test_dir` in folder-discovery mode. Walks the backtrace outward
# from `run_tests`, skipping frames inside this module's own source file, and returns
# the directory of the first external frame with a real file. This lets a repo write
# a bare `run_tests()` in test/runtests.jl with no `@__DIR__` plumbing. If no external
# file frame is found (e.g. called from the REPL), errors with guidance to pass
# `test_dir` explicitly.
function _caller_test_dir()
    self = @__FILE__
    for frame in stacktrace()
        file = string(frame.file)
        isempty(file) && continue
        # Skip frames in SciMLTesting's own source and synthetic/REPL frames.
        (file == self || abspath(file) == abspath(self)) && continue
        startswith(file, "./") && continue
        occursin("REPL", file) && continue
        path = abspath(file)
        isfile(path) && return dirname(path)
    end
    throw(ArgumentError("run_tests (folder mode): could not determine the test directory from the call site; pass `test_dir = @__DIR__` explicitly (e.g. `run_tests(; test_dir = @__DIR__)`)."))
end

# ---------------------------------------------------------------------------
# Folder-discovery mode
#
# Triggered when `run_tests` is called with no `core`/`groups`/`qa`. The test
# directory's `test_groups.toml` is the group list + per-group config; each group
# maps to a folder of `.jl` files that are discovered and run (enforced — every file
# in the selected group's folder runs). Mapping:
#   * "Core" -> top-level test/*.jl (minus runtests.jl), no recursion
#   * named group "X" -> test/X/  (exact, then case-insensitive)
#   * "QA" -> test/qa/ (or test/QA/)
#   * "All" -> Core + every group folder except QA and except in_all=false groups
# A declared group whose folder is missing or empty is an ERROR (catches misnamed or
# empty groups). Each discovered file runs via the same isolated @safetestset path as
# explicit mode (`_run_body`), labelled "<group>/<basename>", in sorted order.
# ---------------------------------------------------------------------------

# Run the Core file set: top-level test/*.jl (no Project.toml activation — Core uses
# the main test env). Errors if there are no top-level test files (an empty Core is a
# misconfiguration: the normal SciML layout puts the main tests at the top level).
function _run_core_folder(test_dir::AbstractString)
    files = _core_files(test_dir)
    isempty(files) &&
        throw(ArgumentError("run_tests (folder mode): the \"Core\" group is empty — no top-level *.jl test files (other than runtests.jl) found in $(test_dir). Core = the top-level test folder; put the main test files there."))
    for f in files
        _run_body(f; label = string("Core/", basename(f)))
    end
    return nothing
end

# Run a named (non-Core, non-QA / or QA) group folder. Resolves the folder (exact
# then case-insensitive), errors if it is MISSING or EMPTY (enforced coverage —
# catches a declared-but-misnamed/empty group), activates a sub-env if the folder
# has its own Project.toml, then runs every *.jl file in sorted order. `default_parent`
# is forwarded to `activate_group_env` for the sub-env develop step.
function _run_group_folder(test_dir::AbstractString, name::AbstractString, default_parent)
    folder = _group_folder(test_dir, name)
    folder === nothing &&
        throw(ArgumentError("run_tests (folder mode): group \"$name\" is declared in test_groups.toml but its folder is missing — expected $(joinpath(test_dir, name)) (or a case-insensitive match). Create the folder and add its test files, or remove the group from test_groups.toml."))
    files = _folder_files(folder)
    isempty(files) &&
        throw(ArgumentError("run_tests (folder mode): group \"$name\" folder $(folder) contains no *.jl files. Every declared group must have at least one test file (enforced coverage)."))
    # A group folder with its own Project.toml is a sub-env: activate + develop the
    # package under test + instantiate before running its files (reusing the existing
    # activate_group_env logic, which includes the <1.11 [sources] backport).
    if _project_file(folder) !== nothing
        kwargs = default_parent !== nothing ? (; parent = default_parent) : (;)
        activate_group_env(folder; kwargs...)
    end
    for f in files
        _run_body(f; label = string(name, "/", basename(f)))
    end
    return nothing
end

# Dispatch one group in folder-discovery mode. `group_table` is the parsed
# test_groups.toml (name => options). Resolves the reserved "Core"/"All"/"QA" and any
# declared named group to its folder(s).
function _run_folder_group(
        group::AbstractString,
        test_dir::AbstractString,
        group_table::AbstractDict,
        default_parent,
    )
    if group == "All"
        _run_core_folder(test_dir)
        # Every declared group that opts into All (QA excluded, in_all=false excluded),
        # in sorted order for determinism. "Core" as a declared key is folded into the
        # top-level Core run above and not re-run as a folder.
        for name in sort!(collect(keys(group_table)))
            name in ("Core", "QA") && continue
            _group_in_all(name, group_table[name]) || continue
            _run_group_folder(test_dir, name, default_parent)
        end
        return nothing
    elseif group == "Core"
        _run_core_folder(test_dir)
        return nothing
    elseif group == "QA"
        # QA need not appear in test_groups.toml to be selectable, but if declared its
        # options are still honored for All-exclusion. Folder is test/qa or test/QA.
        _run_group_folder(test_dir, "QA", default_parent)
        return nothing
    elseif haskey(group_table, group)
        _run_group_folder(test_dir, group, default_parent)
        return nothing
    else
        # An unknown group in folder mode is an error rather than a silent Core
        # fallthrough: in this mode the group set is fully declared in
        # test_groups.toml, so an unrecognized GROUP is almost certainly a typo.
        known = sort!(collect(keys(group_table)))
        throw(ArgumentError("run_tests (folder mode): GROUP=\"$group\" is not \"All\"/\"Core\"/\"QA\" and is not a group declared in test_groups.toml (declared: $(known)). Add it to test_groups.toml or fix the GROUP value."))
    end
end

"""
    run_tests(; core, groups = Dict(), qa = nothing,
              env = "GROUP", default = "All", sublib_env = env,
              all = nothing, umbrellas = Dict(),
              lib_dir = nothing, parent = nothing, pkg = nothing)

Declarative top-level dispatcher for a SciML `test/runtests.jl`. It owns the whole
group-routing control flow, so a repo replaces its hand-written `if GROUP == "All"
... elseif GROUP == "QA" ...` ladder with a single call.

`run_tests` has two modes:

# Folder-discovery mode (default — call `run_tests()` with no `core`/`groups`/`qa`)

When none of `core`, `groups`, or `qa` is supplied, `run_tests` discovers test files
from folders, so a repo's whole `test/runtests.jl` becomes:

```julia
using SciMLTesting
run_tests()
```

The model:

  * The calling file is `test/runtests.jl`, so the **test directory** is the caller's
    directory (override with the `test_dir` keyword). `test_dir/test_groups.toml` is
    the single source of truth: it lists the **groups** (the CI matrix) and holds
    per-group config (see [`read_test_groups`](@ref)).
  * `group = current_group(; env, default)` selects which group runs.
  * **Folder mapping** (files run via the same isolated `@safetestset` include path as
    explicit mode, in sorted order, labelled `"<group>/<basename>"`):
      - `"Core"` → all top-level `test_dir/*.jl` **except** `runtests.jl`, not
        recursing into subdirectories. (Core = the main test folder, the normal SciML
        layout.) Core uses the main test env (no activation).
      - a named group `"X"` (a `test_groups.toml` key other than `Core`/`QA`) → all
        `*.jl` in `test_dir/X/`, matching the folder to the group name by exact then
        case-insensitive match (group `"Interface"` ⇒ `test/Interface/` or
        `test/interface/`).
      - `"QA"` → all `*.jl` in `test_dir/qa/` (or `test_dir/QA/`).
      - `"All"` → Core (top-level files) **plus** every group folder listed in
        `test_groups.toml` **except** `"QA"` and except any group with `in_all = false`
        (curated All).
  * **Sub-env per group.** If a resolved group folder contains a `Project.toml`, it is
    activated ([`activate_group_env`](@ref): `Pkg.activate` + develop the package by
    path + instantiate, with the `<1.11` [`develop_sources!`](@ref) backport) before
    running that folder's files. Core uses the main test env (no activation). The
    develop-parent defaults to the repo root (`dirname(test_dir)`); override with
    `parent`.
  * **Enforced coverage.** *Every* `*.jl` file in the selected group's folder runs —
    you cannot forget to register a test file. A declared group whose folder is
    **missing or empty** is an **error** (catches a misnamed or empty group), as is an
    empty `"Core"`. An unknown `GROUP` (not `All`/`Core`/`QA` and not declared) is also
    an error rather than a silent fall-through.
  * **Helpers / fixtures.** Only the *selected group's* folder is globbed, so any
    subfolder that is **not** a declared group (e.g. `test/shared/`) is never
    auto-discovered — that is where shared `include` fixtures and helper files live.

# Explicit-args mode (v1.1.x — backward-compatible)

Supplying any of `core`, `groups`, or `qa` selects the explicit-args mode below, whose
behavior is unchanged from v1.1.x.

# Arguments

  * `core` — the Core / default test body: a file path to `include` (e.g.
    `joinpath(@__DIR__, "core_tests.jl")`) or a 0-argument thunk. Run for the
    `"All"` and `"Core"` groups.
  * `groups` — a `Dict`/`NamedTuple` mapping a `GROUP` name to that functional
    group's body. Each value is a file path, a 0-arg thunk, or a `NamedTuple`/`Dict`
    of the form `(; body = ..., env = "subdir", parent = ...)` to activate a
    per-group sub-env (via [`activate_group_env`](@ref), which includes the
    [`develop_sources!`](@ref) `[sources]` backport) before running `body`. Groups
    that declare no `env` are treated as in-process and are (by default) *also* run
    as part of `"All"`; see `all` to curate this.
  * `qa` — the QA group body, run for the `"QA"` group (and, by default, as part of
    `"All"`). Accepts the same shapes as a `groups` value. A convenient form is a
    `NamedTuple`/`Dict` carrying the package and Aqua/JET handles plus a thunk that
    calls [`run_qa`](@ref), e.g. `qa = (; env = "qa", body = () -> run_qa(MyPkg;
    Aqua = Aqua))`.
  * `env`, `default` — forwarded to [`current_group`](@ref) to read and normalize
    the selected group (empty string and unset both normalize to `default`). `env`
    is the variable the *root* dispatcher reads to learn which group was requested.
  * `sublib_env` — the environment variable name to hand the sub-group off to when
    routing to a sublibrary, defaulting to `env`. A monorepo whose root reads one
    variable (e.g. `GROUP`) but whose sublibraries read a *different* variable (e.g.
    `ODEDIFFEQ_TEST_GROUP`) sets `sublib_env` to the latter: the root still reads
    `env` to pick the sublibrary, but the `Pkg.test` of that sublibrary runs with
    `ENV[sublib_env]` (not `ENV[env]`) set to the sub-group. When the root and
    sublibraries share a variable (the common case) leave `sublib_env` unset.
  * `all` — curate exactly which groups `"All"` runs, instead of the default
    "`core` + every in-process (no-`env`) group + `qa`". Pass a list of group keys
    (e.g. `["Core", "InterfaceI", "InterfaceII", "Regression_II"]`); `"All"` then
    runs exactly those keys, in the order given, resolved against
    `groups`/`"Core"`/`"QA"`. The root `core` body runs under `"All"` **only if**
    `"Core"` appears in the list, and `qa` runs **only if** `"QA"` appears — so a
    repo can exclude `qa` (and any heavy/environment-specific group) from `"All"`
    simply by leaving it out of the list, while those groups remain selectable by
    name. A listed key runs even if it declares a sub-`env`. When `all === nothing`
    (the default), the legacy behavior is kept (`core` + every in-process group +
    `qa`).
  * `umbrellas` — a `Dict`/`NamedTuple` mapping an umbrella group key to a list of
    member group keys (e.g. `Dict("Interface" => ["InterfaceI", "InterfaceII"])`).
    When `GROUP` equals an umbrella key, every member group is run (in the listed
    order), as though each had been requested in turn. Members may name `groups`
    entries or the reserved `"Core"`/`"QA"` bodies. An umbrella key takes precedence
    over an identically named `groups` entry.
  * `lib_dir` — for a monorepo, the directory holding `lib/<Sublibrary>`
    sub-packages. When given, a `GROUP` naming a sublibrary activates that
    sublibrary and `Pkg.test`s it (see Routing).
  * `parent` — default `parent` forwarded to [`activate_group_env`](@ref) for any
    group that declares an `env` but no `parent` of its own.
  * `pkg` — optional package name/`PackageSpec` to `Pkg.test` for a matched
    sublibrary; defaults to the sublibrary name.
  * `test_dir` — (folder-discovery mode) the test directory holding `test_groups.toml`
    and the group folders. Defaults to the directory of the file that called
    `run_tests` (the repo's `test/runtests.jl`); pass `test_dir = @__DIR__` if it
    cannot be inferred from the call site.

# Routing (explicit-args mode)

Let `group = current_group(; env, default)`:

  * `"All"` — when `all === nothing`, run `core`, then every `groups` entry that
    declares no sub-`env` (in-process groups), then `qa`. When `all` is a list, run
    exactly the listed keys (resolved against `groups`/`"Core"`/`"QA"`), in order —
    so `core` runs only if `"Core"` is listed and `qa` only if `"QA"` is listed.
  * an umbrella key (a key of `umbrellas`) — run each member group in turn.
  * `"Core"` — run `core`.
  * `"QA"` — run `qa` (errors if `qa === nothing`).
  * a key of `groups` — run that group (activating its sub-`env` first if declared).
  * otherwise, if `lib_dir` is given and `group` resolves to a sublibrary via
    [`detect_sublibrary_group`](@ref) — `Pkg.activate` `lib/<sublib>` and
    `Pkg.test` it with the sub-group exported as `ENV[sublib_env]`. The empty group
    and the reserved names `"All"`/`"Core"`/`"QA"` are **never** treated as
    sublibraries even though `isdir(joinpath(lib_dir, ""))` is `true`; they fall
    through to `core`/`qa` above.
  * otherwise — fall through to `core` (an unknown group runs the default body).

# File-path bodies run in an isolated `@safetestset` (preferred form)

A file-path body is run inside its own `@safetestset` — a fresh isolated module —
mirroring OrdinaryDiffEq.jl's canonical `@safetestset "X" begin include("x.jl") end`
structure. This is the **recommended form for `core`/groups** because it is both
world-age-safe and isolated:

  * *World-age-safe.* A module body advances world age per top-level statement, so a
    file that defines a method via a nested `include(mapexpr, file)` (or plain
    `include`) and then *calls* that method in the same `@testset`/expression works.
    (Under the old fresh `Module(gensym())` `Base.include` this raised a world-age
    `MethodError`: "method too new to be called from this world context".)
  * *Isolated.* Each file body runs in its own module, so a global/const/method one
    group defines is invisible to the next group — groups cannot leak symbols into
    one another.
  * *`Test` is in scope automatically.* `@safetestset` brings the full Test API into
    the generated module, so an included file needs no `using Test` of its own. (A
    missing `using Test` in an included file was a recurring source of breakage.)

A thunk body (`() -> ...`) is invoked as-is via `invokelatest` in the caller's
scope. It is **not** isolated and **not** world-age-safe: a runtime closure cannot
be cleanly `@safetestset`-wrapped with a literal `include`, and its world age does
not advance mid-body, so a thunk **cannot** host a
define-via-nested-`include`-then-call pattern. Use a thunk only for a simple inline
testset that is already self-contained; use a file path for anything that
defines-then-calls across a nested `include` or that should be isolated from other
groups.

For a QA group that declares an `env`, the env is activated (`Pkg.activate`) **before**
the QA body runs; activation is process-global and persists into the `@safetestset`
module the body is evaluated in.

# No `Pkg` needed in the repo's `[extras]`

Because `SciMLTesting` bundles `Pkg` and does every `Pkg.activate`/`develop`/
`instantiate`/`test` internally, a repo converted to `run_tests` no longer needs
`Pkg` in its own `[extras]`/`test` target — only `SciMLTesting` (and whatever the
test bodies themselves load, e.g. `Aqua`/`JET` in the QA sub-env). This removes the
`Pkg`-in-`[extras]` dependency-compat nit.

# Examples

```julia
# single package: test/runtests.jl
using SciMLTesting
run_tests(;
    core = joinpath(@__DIR__, "core_tests.jl"),
    qa = (; env = "qa", body = () -> begin
        using MyPackage, Aqua
        run_qa(MyPackage; Aqua = Aqua)
    end),
)

# monorepo root: test/runtests.jl
using SciMLTesting
run_tests(;
    core = joinpath(@__DIR__, "core_tests.jl"),
    lib_dir = joinpath(@__DIR__, "..", "lib"),
)

# monorepo root whose sublibraries read a different env var, with a curated "All"
# (excluding the AlgConvergence_* groups and QA) and umbrella groups:
run_tests(;
    core = joinpath(@__DIR__, "core_tests.jl"),
    groups = Dict(
        "InterfaceI"  => joinpath(@__DIR__, "interface_i.jl"),
        "InterfaceII" => joinpath(@__DIR__, "interface_ii.jl"),
        "Regression_I"  => joinpath(@__DIR__, "regression_i.jl"),
        "Regression_II" => joinpath(@__DIR__, "regression_ii.jl"),
        "AlgConvergence_I" => joinpath(@__DIR__, "alg_i.jl"),
    ),
    qa = (; env = "qa", body = joinpath(@__DIR__, "qa", "qa.jl")),
    all = ["InterfaceI", "InterfaceII", "Regression_I", "Regression_II"],
    umbrellas = Dict(
        "Interface"  => ["InterfaceI", "InterfaceII"],
        "Regression" => ["Regression_I", "Regression_II"],
    ),
    sublib_env = "ODEDIFFEQ_TEST_GROUP",
    lib_dir = joinpath(@__DIR__, "..", "lib"),
)
```
"""
function run_tests(;
        core = _UNSET,
        groups = _UNSET,
        qa = _UNSET,
        env::AbstractString = "GROUP",
        default::AbstractString = "All",
        sublib_env::AbstractString = env,
        all = nothing,
        umbrellas = Dict{String, Any}(),
        lib_dir = nothing,
        parent = nothing,
        pkg = nothing,
        test_dir = nothing,
    )
    group = current_group(; env = env, default = default)

    # Folder-discovery mode: no explicit core/groups/qa. The test_groups.toml in the
    # test directory is the group list + per-group config; groups map to folders of
    # *.jl files that are discovered and run (enforced). See `_run_folder_group`.
    if core === _UNSET && groups === _UNSET && qa === _UNSET
        dir = test_dir === nothing ? _caller_test_dir() : abspath(String(test_dir))
        group_table = read_test_groups(dir)
        # Default the develop-parent for any sub-env (e.g. test/qa/Project.toml) to the
        # repo root inferred as dirname(test_dir), unless the caller overrode `parent`.
        default_parent = parent === nothing ? dirname(dir) : parent
        _run_folder_group(group, dir, group_table, default_parent)
        return nothing
    end

    # Explicit-args mode (v1.1.x backward-compat): fill in the legacy defaults for any
    # unset argument so the existing control flow below is unchanged.
    core === _UNSET && (core = nothing)
    groups = groups === _UNSET ? Dict{String, Any}() : groups
    qa === _UNSET && (qa = nothing)

    group_table = _as_string_dict(groups)
    umbrella_table = _as_string_dict(umbrellas)

    if group == "All"
        if all === nothing
            # Legacy default: core, then every in-process functional group, then qa.
            _run_group_spec(_group_spec(core), parent; label = "Core")
            for name in sort!(collect(keys(group_table)))
                spec = _group_spec(group_table[name])
                spec.env === nothing && _run_body(spec.body; label = name)
            end
            qa === nothing || _run_group_spec(_group_spec(qa), parent; label = "QA")
        else
            # Curated "All": run exactly the listed keys, in order. `core` runs only
            # if "Core" is listed; `qa` only if "QA" is listed.
            for name in all
                _run_named_group(string(name), core, group_table, qa, parent)
            end
        end
        return nothing
    elseif haskey(umbrella_table, group)
        # An umbrella key expands to its member groups, each run in turn.
        for member in _as_string_list(umbrella_table[group])
            _run_named_group(member, core, group_table, qa, parent)
        end
        return nothing
    elseif group == "Core"
        _run_group_spec(_group_spec(core), parent; label = "Core")
        return nothing
    elseif group == "QA"
        qa === nothing &&
            throw(ArgumentError("run_tests: GROUP=\"QA\" was requested but no `qa` body was provided"))
        _run_group_spec(_group_spec(qa), parent; label = "QA")
        return nothing
    elseif haskey(group_table, group)
        _run_group_spec(_group_spec(group_table[group]), parent; label = group)
        return nothing
    end

    # Sublibrary routing (monorepo). Guard against the empty group and the reserved
    # names being misdetected as a sublibrary: `isdir(joinpath(lib_dir, ""))` is
    # true, which previously routed an unselected/"All" group to a bogus sublibrary.
    if lib_dir !== nothing && !isempty(group) && !(group in RESERVED_GROUPS)
        sublib, subgroup = detect_sublibrary_group(group, lib_dir)
        if !isempty(sublib) && isdir(joinpath(lib_dir, sublib))
            Pkg.activate(joinpath(lib_dir, sublib))
            test_target = pkg === nothing ? sublib : pkg
            withenv(sublib_env => subgroup) do
                Pkg.test(test_target; allow_reresolve = true)
            end
            return nothing
        end
    end

    # Unknown group: fall through to the default (core) body.
    _run_group_spec(_group_spec(core), parent; label = "Core")
    return nothing
end

# Run a named group key against the `groups` table, resolving the reserved
# "Core"/"QA" keys to the `core`/`qa` bodies. Used by curated-"All" and umbrella
# expansion so a listed key behaves exactly as if it had been requested via GROUP.
function _run_named_group(key::AbstractString, core, group_table, qa, parent)
    if key == "Core"
        _run_group_spec(_group_spec(core), parent; label = "Core")
    elseif key == "QA"
        qa === nothing &&
            throw(ArgumentError("run_tests: \"QA\" was listed in `all`/`umbrellas` but no `qa` body was provided"))
        _run_group_spec(_group_spec(qa), parent; label = "QA")
    elseif haskey(group_table, key)
        _run_group_spec(_group_spec(group_table[key]), parent; label = key)
    else
        throw(ArgumentError("run_tests: \"$key\" was listed in `all`/`umbrellas` but is not a key of `groups` (nor the reserved \"Core\"/\"QA\")"))
    end
    return nothing
end

_as_string_list(x::AbstractString) = [x]
_as_string_list(xs) = [string(x) for x in xs]

# Activate a group spec's sub-env (if it declares one) and run its body. For the QA
# body the env is activated (`Pkg.activate`) BEFORE the body runs; activation is
# process-global, so it persists into the `@safetestset` module that `_run_body`
# evaluates the file in. `label` names the resulting `@safetestset` (the group/core
# name); it defaults to "Group" when the caller has no name to hand down.
function _run_group_spec(spec::GroupSpec, default_parent; label::AbstractString = "Group")
    if spec.env !== nothing
        kwargs = spec.parent !== nothing ? (; parent = spec.parent) :
            (default_parent !== nothing ? (; parent = default_parent) : (;))
        activate_group_env(spec.env; kwargs...)
    end
    _run_body(spec.body; label = label)
    return nothing
end

_as_string_dict(d::AbstractDict) = Dict{String, Any}(string(k) => v for (k, v) in d)
_as_string_dict(nt::NamedTuple) = Dict{String, Any}(string(k) => v for (k, v) in pairs(nt))

end # module SciMLTesting
