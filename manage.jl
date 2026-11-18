#!/usr/bin/env julia
# Project management script: julia --project manage.jl <command>

# `runserver` reloads your code when it changes, with Revise.jl installed in your global
# environment (`julia -e 'using Pkg; Pkg.add("Revise")'`); --noreload turns it off.
if "runserver" in ARGS && !("--noreload" in ARGS)
    try
        @eval using Revise
    catch
        @info "Install Revise.jl (in your global environment) and runserver reloads code when it changes."
    end
end
include(joinpath(@__DIR__, "project.jl"))
Juango.execute_from_command_line(ARGS)
