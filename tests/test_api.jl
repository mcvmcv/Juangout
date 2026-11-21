# manage.jl test only looks in tests/ for now (Juango #239), so run the app's tests from here.
include(joinpath(@__DIR__, "..", "api", "tests.jl"))
