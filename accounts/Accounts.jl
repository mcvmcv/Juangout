# The accounts app: Juangout's members and their profiles.
module Accounts

using Juango
using Dates

export Member

const APP = App("accounts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)

include("models.jl")
include("admin.jl")
include("views.jl")
include("urls.jl")

end
