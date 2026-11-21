# The api app: a JSON API for programs, members' API tokens, and RSS/Atom feeds.
module Api

using Juango
using Dates
using Random: RandomDevice, randstring
using SHA: sha256
using ..Posts: Post, for_display, feed, top_level

export ApiToken, juangout_api

const APP = App("api"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)

include("models.jl")
include("schemas.jl")
include("endpoints.jl")
include("feeds.jl")
include("views.jl")
include("urls.jl")

end
