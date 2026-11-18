# Loads the whole project (settings, models, views, urls).
using Juango
using Dates

const BASE_DIR = @__DIR__

# project_include: tracked by Revise for runserver's reloading when Revise is loaded
Juango.project_include(joinpath(BASE_DIR, "models.jl"))
Juango.project_include(joinpath(BASE_DIR, "admin.jl"))
Juango.project_include(joinpath(BASE_DIR, "views.jl"))
Juango.project_include(joinpath(BASE_DIR, "urls.jl"))
Juango.project_include(joinpath(BASE_DIR, "settings.jl"))
# after a reload, apply the settings again (they hold `urlpatterns`, which urls.jl may have rebuilt)
Juango.on_reload!(() -> Base.include(@__MODULE__, joinpath(BASE_DIR, "settings.jl")))
