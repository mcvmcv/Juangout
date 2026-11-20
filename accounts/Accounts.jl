# The accounts app: Juangout's members and their profiles.
module Accounts

using Juango
using Dates
using ..Posts: for_display     # profiles show posts

export Member, Follow, MemberTimezoneMiddleware

const APP = App("accounts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)

include("models.jl")
include("admin.jl")
include("views.jl")
include("middleware.jl")
include("urls.jl")

end
