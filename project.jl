# Loads the whole project (apps, urls, settings).
using Juango
using Dates

const BASE_DIR = @__DIR__

# Apps: each is a module with its own models, views, urls, templates and migrations
# (posts first: accounts' profile pages use it)
Juango.project_include(joinpath(BASE_DIR, "posts", "Posts.jl"))
using .Posts
Juango.project_include(joinpath(BASE_DIR, "accounts", "Accounts.jl"))
using .Accounts
Juango.project_include(joinpath(BASE_DIR, "notifications", "Notifications.jl"))
using .Notifications
Juango.project_include(joinpath(BASE_DIR, "moderation", "Moderation.jl"))
using .Moderation
Juango.project_include(joinpath(BASE_DIR, "api", "Api.jl"))
using .Api

# project_include: tracked by Revise for runserver's reloading when Revise is loaded
Juango.project_include(joinpath(BASE_DIR, "urls.jl"))
Juango.project_include(joinpath(BASE_DIR, "settings.jl"))
# after a reload, apply the settings again (they hold `urlpatterns`, which urls.jl may have rebuilt)
Juango.on_reload!(() -> Base.include(@__MODULE__, joinpath(BASE_DIR, "settings.jl")))
