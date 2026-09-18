using Documenter
using SciMLTesting

makedocs(;
    modules = [SciMLTesting],
    authors = "SciML Contributors",
    sitename = "SciMLTesting.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://docs.sciml.ai/SciMLTesting/stable/",
    ),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
    ],
)

deploydocs(;
    repo = "github.com/SciML/SciMLTesting.jl.git",
)
