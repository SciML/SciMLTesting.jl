# SciMLTesting.jl

```@docs
SciMLTesting
```

## Usage

A package's `test/runtests.jl` replaces its hand-written `GROUP` ladder with a
single call to [`run_tests`](@ref):

```julia
using SciMLTesting

run_tests()
```

The groups a package supports are declared in `test/test_groups.toml`. A group
that has its own environment can be selected by name through the `GROUP`
environment variable, which is what CI lanes use:

```sh
GROUP=Core julia --project -e 'using Pkg; Pkg.test()'
```

## API

See the [API Reference](@ref) for the full list of exported helpers.
